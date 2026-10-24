/*
 * The Hypervisaur agent for Windows, which runs programs in the virtual machine for the Mac.
 *
 * It runs as a service, and talks to Hypervisaur over the virtio serial port named hypervisaur.agent, using the frames that
 * GuestAgentFrame.swift describes. Each program runs on a channel of its own, in a job object so that stopping it also stops
 * the programs it started, and with a pseudo console when it needs a terminal.
 */

#define WIN32_LEAN_AND_MEAN
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif

#include <windows.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SERVICE_NAME L"HypervisaurAgent"
#define PORT_PATH L"\\\\.\\Global\\hypervisaur.agent"
#define PROTOCOL_VERSION 1

#define HEADER_SIZE 9
#define MAX_PAYLOAD (1 << 20)
#define CHUNK_SIZE (16 * 1024)

/* How long a write to the port may take, so that the agent doesn't wait forever when Hypervisaur isn't reading. */
#define WRITE_TIMEOUT_MS 10000

/* How long output is still read after a program exits, since programs it started in the background can keep its output open. */
#define OUTPUT_DRAIN_TIMEOUT_MS 2000

enum {
    FRAME_RESET = 0x01,
    FRAME_OPEN = 0x02,
    FRAME_INPUT = 0x03,
    FRAME_INPUT_END = 0x04,
    FRAME_RESIZE = 0x05,
    FRAME_TERMINATE = 0x06,

    FRAME_HELLO = 0x41,
    FRAME_OUTPUT = 0x42,
    FRAME_ERROR_OUTPUT = 0x43,
    FRAME_EXITED = 0x44,
    FRAME_FAILED = 0x45,
};

typedef struct Session {
    uint32_t channel;
    HANDLE job;
    HANDLE process;
    HANDLE input;
    HANDLE output;
    HANDLE errorOutput;
    HPCON console;
    HANDLE outputThread;
    HANDLE errorThread;
    /* The script that runs the command, which is deleted when it exits. Empty for interactive shells. */
    wchar_t script[MAX_PATH];
    struct Session *next;
} Session;

typedef struct {
    Session *session;
    HANDLE pipe;
    uint8_t kind;
} OutputReader;

static HANDLE port = INVALID_HANDLE_VALUE;
static SRWLOCK portLock = SRWLOCK_INIT;
static CRITICAL_SECTION writeLock;
static SRWLOCK sessionsLock = SRWLOCK_INIT;
static Session *sessions;
static volatile LONG isStopping;
static HANDLE stopEvent;

static SERVICE_STATUS_HANDLE statusHandle;
static SERVICE_STATUS serviceStatus;

/* MARK: - Logging */

static CRITICAL_SECTION logLock;
static FILE *logFile;

static void openLog(void) {
    wchar_t path[MAX_PATH];
    DWORD length = GetEnvironmentVariableW(L"ProgramData", path, MAX_PATH);
    if (length == 0 || length >= MAX_PATH - 40) return;

    wcscat(path, L"\\Hypervisaur");
    CreateDirectoryW(path, NULL);
    wcscat(path, L"\\Agent.log");

    /* The log is started afresh when it gets large, so that it can't fill the disk. */
    WIN32_FILE_ATTRIBUTE_DATA attributes;
    const wchar_t *mode = L"a";
    if (GetFileAttributesExW(path, GetFileExInfoStandard, &attributes) && attributes.nFileSizeLow > 1024 * 1024) {
        mode = L"w";
    }
    logFile = _wfopen(path, mode);
}

static void logMessage(const char *format, ...) {
    if (!logFile) return;

    SYSTEMTIME time;
    GetLocalTime(&time);

    EnterCriticalSection(&logLock);
    fprintf(logFile, "%04d-%02d-%02d %02d:%02d:%02d ", time.wYear, time.wMonth, time.wDay, time.wHour, time.wMinute, time.wSecond);
    va_list arguments;
    va_start(arguments, format);
    vfprintf(logFile, format, arguments);
    va_end(arguments);
    fputc('\n', logFile);
    fflush(logFile);
    LeaveCriticalSection(&logLock);
}

/* MARK: - Port */

static void putUInt32(uint8_t *bytes, uint32_t value) {
    bytes[0] = (uint8_t)value;
    bytes[1] = (uint8_t)(value >> 8);
    bytes[2] = (uint8_t)(value >> 16);
    bytes[3] = (uint8_t)(value >> 24);
}

static uint32_t getUInt32(const uint8_t *bytes) {
    return (uint32_t)bytes[0] | (uint32_t)bytes[1] << 8 | (uint32_t)bytes[2] << 16 | (uint32_t)bytes[3] << 24;
}

static uint16_t getUInt16(const uint8_t *bytes) {
    return (uint16_t)(bytes[0] | bytes[1] << 8);
}

static BOOL writeAll(HANDLE handle, const uint8_t *bytes, DWORD count) {
    OVERLAPPED overlapped = {0};
    overlapped.hEvent = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!overlapped.hEvent) return FALSE;

    BOOL succeeded = TRUE;
    while (count > 0) {
        DWORD written = 0;
        ResetEvent(overlapped.hEvent);

        if (!WriteFile(handle, bytes, count, NULL, &overlapped)) {
            if (GetLastError() != ERROR_IO_PENDING) {
                succeeded = FALSE;
                break;
            }
            if (WaitForSingleObject(overlapped.hEvent, WRITE_TIMEOUT_MS) != WAIT_OBJECT_0) {
                CancelIoEx(handle, &overlapped);
                GetOverlappedResult(handle, &overlapped, &written, TRUE);
                succeeded = FALSE;
                break;
            }
        }
        if (!GetOverlappedResult(handle, &overlapped, &written, TRUE) || written == 0) {
            succeeded = FALSE;
            break;
        }

        bytes += written;
        count -= written;
    }

    CloseHandle(overlapped.hEvent);
    return succeeded;
}

/* Frames are dropped when they can't be sent, since nobody is listening for them then. */
static void sendFrame(uint8_t kind, uint32_t channel, const void *payload, uint32_t length) {
    uint8_t header[HEADER_SIZE];
    putUInt32(header, length);
    header[4] = kind;
    putUInt32(header + 5, channel);

    AcquireSRWLockShared(&portLock);
    EnterCriticalSection(&writeLock);
    if (port != INVALID_HANDLE_VALUE) {
        if (!writeAll(port, header, HEADER_SIZE) || (length > 0 && !writeAll(port, payload, length))) {
            logMessage("Couldn't send a frame of kind 0x%02x on channel %u (error %lu)", kind, channel, GetLastError());
        }
    }
    LeaveCriticalSection(&writeLock);
    ReleaseSRWLockShared(&portLock);
}

static void sendText(uint8_t kind, uint32_t channel, const char *text) {
    sendFrame(kind, channel, text, (uint32_t)strlen(text));
}

/* MARK: - Commands */

static BOOL writeBytes(HANDLE file, const void *bytes, DWORD count) {
    DWORD written;
    return WriteFile(file, bytes, count, &written, NULL) && written == count;
}

/*
 * Commands are written to a PowerShell script, so that they reach PowerShell exactly as they were written, and so that it reports
 * errors as text: given a command on its command line instead, it reports them as XML when its output isn't a console. The
 * script makes PowerShell's output UTF-8, hides progress, and exits with the status of the last program the command ran,
 * or 1 if the command failed. PowerShell 5 only reads scripts as UTF-8 when they start with a byte order mark.
 */
static BOOL writeScript(const char *command, uint32_t length, uint32_t channel, wchar_t *path) {
    static const uint8_t byteOrderMark[] = { 0xEF, 0xBB, 0xBF };
    static const char prefix[] =
        "$ProgressPreference = 'SilentlyContinue'\n"
        "[Console]::OutputEncoding = [Text.Encoding]::UTF8\n"
        "$OutputEncoding = [Text.Encoding]::UTF8\n";
    static const char suffix[] =
        "\nif ($LASTEXITCODE) { exit $LASTEXITCODE } elseif (-not $?) { exit 1 }\n";

    wchar_t directory[MAX_PATH];
    DWORD directoryLength = GetTempPathW(MAX_PATH, directory);
    if (directoryLength == 0 || directoryLength > MAX_PATH - 64) return FALSE;

    swprintf(path, MAX_PATH, L"%lsHypervisaur-%u-%llu.ps1", directory, channel, (unsigned long long)GetTickCount64());

    HANDLE file = CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_TEMPORARY, NULL);
    if (file == INVALID_HANDLE_VALUE) return FALSE;

    BOOL written = writeBytes(file, byteOrderMark, sizeof(byteOrderMark))
        && writeBytes(file, prefix, (DWORD)strlen(prefix))
        && writeBytes(file, command, length)
        && writeBytes(file, suffix, (DWORD)strlen(suffix));
    CloseHandle(file);

    if (!written) DeleteFileW(path);
    return written;
}

/* Runs the script, or an interactive PowerShell when there isn't one. */
static wchar_t *commandLine(const wchar_t *scriptPath, BOOL usesTerminal) {
    wchar_t systemDirectory[MAX_PATH];
    UINT systemLength = GetSystemDirectoryW(systemDirectory, MAX_PATH);
    if (systemLength == 0 || systemLength >= MAX_PATH) return NULL;

    static const wchar_t powershell[] = L"\\WindowsPowerShell\\v1.0\\powershell.exe";

    size_t size = systemLength + wcslen(powershell) + MAX_PATH + 128;
    wchar_t *line = calloc(size, sizeof(wchar_t));
    if (!line) return NULL;

    if (scriptPath) {
        swprintf(line, size, L"\"%ls%ls\" -NoLogo -NoProfile%ls -ExecutionPolicy Bypass -File \"%ls\"",
                 systemDirectory, powershell, usesTerminal ? L"" : L" -NonInteractive", scriptPath);
    } else {
        swprintf(line, size, L"\"%ls%ls\" -NoLogo", systemDirectory, powershell);
    }
    return line;
}

/* MARK: - Sessions */

static void addSession(Session *session) {
    AcquireSRWLockExclusive(&sessionsLock);
    session->next = sessions;
    sessions = session;
    ReleaseSRWLockExclusive(&sessionsLock);
}

static void removeSession(Session *session) {
    AcquireSRWLockExclusive(&sessionsLock);
    for (Session **link = &sessions; *link; link = &(*link)->next) {
        if (*link == session) {
            *link = session->next;
            break;
        }
    }
    ReleaseSRWLockExclusive(&sessionsLock);
}

/* Runs `action` with the session for the channel while the sessions can't change. */
static void withSession(uint32_t channel, void (*action)(Session *, const uint8_t *, uint32_t), const uint8_t *payload, uint32_t length) {
    AcquireSRWLockShared(&sessionsLock);
    for (Session *session = sessions; session; session = session->next) {
        if (session->channel == channel) {
            action(session, payload, length);
            break;
        }
    }
    ReleaseSRWLockShared(&sessionsLock);
}

static void writeInput(Session *session, const uint8_t *payload, uint32_t length) {
    if (session->input == NULL) return;

    DWORD written;
    while (length > 0 && WriteFile(session->input, payload, length, &written, NULL) && written > 0) {
        payload += written;
        length -= written;
    }
}

static void closeInput(Session *session, const uint8_t *payload, uint32_t length) {
    (void)payload;
    (void)length;

    /* A pseudo console's input stays open, since closing it would end the console. */
    if (session->console == NULL && session->input != NULL) {
        HANDLE input = (HANDLE)InterlockedExchangePointer(&session->input, NULL);
        if (input) CloseHandle(input);
    }
}

static void resizeTerminal(Session *session, const uint8_t *payload, uint32_t length) {
    if (session->console == NULL || length < 4) return;

    COORD size = { (SHORT)getUInt16(payload), (SHORT)getUInt16(payload + 2) };
    if (size.X > 0 && size.Y > 0) ResizePseudoConsole(session->console, size);
}

static void terminateSession(Session *session, const uint8_t *payload, uint32_t length) {
    (void)payload;
    (void)length;

    TerminateJobObject(session->job, 1);
}

static DWORD WINAPI readOutput(void *context) {
    OutputReader *reader = context;
    uint8_t *buffer = malloc(CHUNK_SIZE);

    DWORD count;
    while (buffer && ReadFile(reader->pipe, buffer, CHUNK_SIZE, &count, NULL) && count > 0) {
        sendFrame(reader->kind, reader->session->channel, buffer, count);
    }

    free(buffer);
    free(reader);
    return 0;
}

static HANDLE startReader(Session *session, HANDLE pipe, uint8_t kind) {
    OutputReader *reader = malloc(sizeof(OutputReader));
    if (!reader) return NULL;

    reader->session = session;
    reader->pipe = pipe;
    reader->kind = kind;

    HANDLE thread = CreateThread(NULL, 0, readOutput, reader, 0, NULL);
    if (!thread) free(reader);
    return thread;
}

static void waitForReader(HANDLE thread, DWORD timeout) {
    if (!thread) return;

    if (WaitForSingleObject(thread, timeout) == WAIT_TIMEOUT) {
        CancelSynchronousIo(thread);
        WaitForSingleObject(thread, INFINITE);
    }
}

/* Waits for the program to exit, then for its output, and reports how it exited. */
static DWORD WINAPI waitForSession(void *context) {
    Session *session = context;

    WaitForSingleObject(session->process, INFINITE);

    DWORD status = 1;
    GetExitCodeProcess(session->process, &status);

    if (session->console) {
        /* Closing the console flushes what it has left to draw, and then ends its output. */
        ClosePseudoConsole(session->console);
        session->console = NULL;
    }

    waitForReader(session->outputThread, OUTPUT_DRAIN_TIMEOUT_MS);
    waitForReader(session->errorThread, OUTPUT_DRAIN_TIMEOUT_MS);

    removeSession(session);

    uint8_t payload[4];
    putUInt32(payload, status);
    sendFrame(FRAME_EXITED, session->channel, payload, sizeof(payload));

    HANDLE input = (HANDLE)InterlockedExchangePointer(&session->input, NULL);
    if (input) CloseHandle(input);
    if (session->output) CloseHandle(session->output);
    if (session->errorOutput) CloseHandle(session->errorOutput);
    if (session->outputThread) CloseHandle(session->outputThread);
    if (session->errorThread) CloseHandle(session->errorThread);
    CloseHandle(session->process);
    CloseHandle(session->job);
    if (session->script[0]) DeleteFileW(session->script);
    free(session);
    return 0;
}

static BOOL createPipe(HANDLE *readEnd, HANDLE *writeEnd, BOOL childReads) {
    SECURITY_ATTRIBUTES attributes = { sizeof(attributes), NULL, TRUE };
    if (!CreatePipe(readEnd, writeEnd, &attributes, 1024 * 1024)) return FALSE;

    /* Only the child's end is inherited. */
    SetHandleInformation(childReads ? *writeEnd : *readEnd, HANDLE_FLAG_INHERIT, 0);
    return TRUE;
}

static void failOpen(uint32_t channel, const char *what) {
    char message[256];
    snprintf(message, sizeof(message), "%s (error %lu).", what, GetLastError());
    logMessage("Channel %u: %s", channel, message);
    sendText(FRAME_FAILED, channel, message);
}

static void openSession(uint32_t channel, const uint8_t *payload, uint32_t length) {
    if (length < 5) {
        sendText(FRAME_FAILED, channel, "The request to run a program is incomplete.");
        return;
    }

    BOOL usesTerminal = payload[0] & 1;
    COORD size = { (SHORT)getUInt16(payload + 1), (SHORT)getUInt16(payload + 3) };
    if (size.X <= 0) size.X = 80;
    if (size.Y <= 0) size.Y = 24;

    Session *session = calloc(1, sizeof(Session));
    if (!session) {
        failOpen(channel, "Couldn't start the program");
        return;
    }
    session->channel = channel;

    uint32_t commandLength = length - 5;
    if (commandLength > 0 && !writeScript((const char *)payload + 5, commandLength, channel, session->script)) {
        failOpen(channel, "Couldn't prepare the command");
        free(session);
        return;
    }

    wchar_t *line = commandLine(session->script[0] ? session->script : NULL, usesTerminal);
    if (!line) {
        failOpen(channel, "Couldn't prepare the command");
        if (session->script[0]) DeleteFileW(session->script);
        free(session);
        return;
    }

    HANDLE childInput = NULL, childOutput = NULL, childError = NULL;
    BOOL prepared;
    if (usesTerminal) {
        prepared = CreatePipe(&childInput, &session->input, NULL, 0) && CreatePipe(&session->output, &childOutput, NULL, 0)
            && SUCCEEDED(CreatePseudoConsole(size, childInput, childOutput, 0, &session->console));
    } else {
        prepared = createPipe(&childInput, &session->input, TRUE)
            && createPipe(&session->output, &childOutput, FALSE)
            && createPipe(&session->errorOutput, &childError, FALSE);
    }

    STARTUPINFOEXW startup = {0};
    startup.StartupInfo.cb = sizeof(startup);
    SIZE_T attributesSize = 0;

    if (prepared && usesTerminal) {
        InitializeProcThreadAttributeList(NULL, 1, 0, &attributesSize);
        startup.lpAttributeList = malloc(attributesSize);
        prepared = startup.lpAttributeList
            && InitializeProcThreadAttributeList(startup.lpAttributeList, 1, 0, &attributesSize)
            && UpdateProcThreadAttribute(startup.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, session->console, sizeof(HPCON), NULL, NULL);
    } else if (prepared) {
        startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
        startup.StartupInfo.hStdInput = childInput;
        startup.StartupInfo.hStdOutput = childOutput;
        startup.StartupInfo.hStdError = childError;
    }

    session->job = prepared ? CreateJobObjectW(NULL, NULL) : NULL;

    /* Programs start in the root of the system drive, since the service's own directory is System32. */
    wchar_t directory[MAX_PATH];
    if (!GetEnvironmentVariableW(L"SystemDrive", directory, MAX_PATH - 2)) wcscpy(directory, L"C:");
    wcscat(directory, L"\\");

    PROCESS_INFORMATION process = {0};
    BOOL started = session->job && CreateProcessW(
        NULL, line, NULL, NULL, !usesTerminal,
        CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT | (usesTerminal ? EXTENDED_STARTUPINFO_PRESENT : CREATE_NO_WINDOW),
        NULL, directory, &startup.StartupInfo, &process
    );

    if (startup.lpAttributeList) {
        DeleteProcThreadAttributeList(startup.lpAttributeList);
        free(startup.lpAttributeList);
    }
    free(line);

    /* The child has its own copies of its ends of the pipes, or the console does. */
    if (childInput) CloseHandle(childInput);
    if (childOutput) CloseHandle(childOutput);
    if (childError) CloseHandle(childError);

    if (!started || !AssignProcessToJobObject(session->job, process.hProcess)) {
        failOpen(channel, started ? "Couldn't manage the program" : "Couldn't start the program");
        if (started) {
            TerminateProcess(process.hProcess, 1);
            CloseHandle(process.hThread);
            CloseHandle(process.hProcess);
        }
        if (session->console) ClosePseudoConsole(session->console);
        if (session->input) CloseHandle(session->input);
        if (session->output) CloseHandle(session->output);
        if (session->errorOutput) CloseHandle(session->errorOutput);
        if (session->job) CloseHandle(session->job);
        if (session->script[0]) DeleteFileW(session->script);
        free(session);
        return;
    }

    session->process = process.hProcess;
    session->outputThread = startReader(session, session->output, FRAME_OUTPUT);
    if (session->errorOutput) session->errorThread = startReader(session, session->errorOutput, FRAME_ERROR_OUTPUT);

    addSession(session);

    ResumeThread(process.hThread);
    CloseHandle(process.hThread);

    HANDLE waiter = CreateThread(NULL, 0, waitForSession, session, 0, NULL);
    if (waiter) {
        CloseHandle(waiter);
    } else {
        logMessage("Channel %u: couldn't wait for the program (error %lu)", channel, GetLastError());
        TerminateJobObject(session->job, 1);
    }
}

/* Stops everything that's running, such as when Hypervisaur connects again after it quit. */
static void terminateAllSessions(void) {
    AcquireSRWLockShared(&sessionsLock);
    for (Session *session = sessions; session; session = session->next) {
        TerminateJobObject(session->job, 1);
    }
    ReleaseSRWLockShared(&sessionsLock);
}

/* MARK: - Protocol */

static void sendHello(void) {
    OSVERSIONINFOW version = {0};
    version.dwOSVersionInfoSize = sizeof(version);
    LONG (WINAPI *getVersion)(OSVERSIONINFOW *) = (void *)GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "RtlGetVersion");
    if (getVersion) getVersion(&version);

    SYSTEM_INFO system;
    GetNativeSystemInfo(&system);
    const char *architecture = system.wProcessorArchitecture == PROCESSOR_ARCHITECTURE_ARM64 ? "ARM64"
        : system.wProcessorArchitecture == PROCESSOR_ARCHITECTURE_AMD64 ? "x64" : "x86";

    char description[128];
    snprintf(description, sizeof(description), "Windows %s (%lu.%lu.%lu) %s",
             version.dwBuildNumber >= 22000 ? "11" : "10",
             version.dwMajorVersion, version.dwMinorVersion, version.dwBuildNumber, architecture);

    uint8_t payload[4 + sizeof(description)];
    putUInt32(payload, PROTOCOL_VERSION);
    size_t length = strlen(description);
    memcpy(payload + 4, description, length);
    sendFrame(FRAME_HELLO, 0, payload, (uint32_t)(4 + length));
}

static void handleFrame(uint8_t kind, uint32_t channel, const uint8_t *payload, uint32_t length) {
    switch (kind) {
    case FRAME_RESET:
        logMessage("Hypervisaur connected");
        terminateAllSessions();
        sendHello();
        break;
    case FRAME_OPEN:
        openSession(channel, payload, length);
        break;
    case FRAME_INPUT:
        withSession(channel, writeInput, payload, length);
        break;
    case FRAME_INPUT_END:
        withSession(channel, closeInput, payload, length);
        break;
    case FRAME_RESIZE:
        withSession(channel, resizeTerminal, payload, length);
        break;
    case FRAME_TERMINATE:
        withSession(channel, terminateSession, payload, length);
        break;
    default:
        break;
    }
}

static HANDLE openPort(void) {
    return CreateFileW(PORT_PATH, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, NULL);
}

static void closePort(void) {
    AcquireSRWLockExclusive(&portLock);
    if (port != INVALID_HANDLE_VALUE) {
        CloseHandle(port);
        port = INVALID_HANDLE_VALUE;
    }
    ReleaseSRWLockExclusive(&portLock);
}

/* Reads frames from the port until it fails, then opens it again, until the service stops. */
static DWORD WINAPI runAgent(void *context) {
    (void)context;

    uint8_t *buffer = malloc(HEADER_SIZE + MAX_PAYLOAD);
    if (!buffer) return 1;

    OVERLAPPED overlapped = {0};
    overlapped.hEvent = CreateEventW(NULL, TRUE, FALSE, NULL);

    /* Failures are only logged when they change, since the port is opened again every few seconds while they last. */
    DWORD lastError = (DWORD)-1;

    while (!isStopping) {
        HANDLE opened = openPort();
        if (opened == INVALID_HANDLE_VALUE) {
            DWORD error = GetLastError();
            if (error != lastError) logMessage("Couldn't open the port (error %lu), trying again", error);
            lastError = error;
            WaitForSingleObject(stopEvent, 5000);
            continue;
        }

        AcquireSRWLockExclusive(&portLock);
        port = opened;
        ReleaseSRWLockExclusive(&portLock);
        if (lastError != ERROR_SUCCESS) logMessage("Opened the port");
        lastError = ERROR_SUCCESS;

        sendHello();

        size_t buffered = 0;
        while (!isStopping) {
            DWORD count = 0;
            ResetEvent(overlapped.hEvent);

            BOOL read = ReadFile(opened, buffer + buffered, (DWORD)(HEADER_SIZE + MAX_PAYLOAD - buffered), NULL, &overlapped);
            if (!read && GetLastError() != ERROR_IO_PENDING) break;
            if (!GetOverlappedResult(opened, &overlapped, &count, TRUE)) break;

            /* Nothing is read while Hypervisaur isn't connected. */
            if (count == 0) {
                WaitForSingleObject(stopEvent, 250);
                continue;
            }

            buffered += count;
            while (buffered >= HEADER_SIZE) {
                uint32_t length = getUInt32(buffer);
                if (length > MAX_PAYLOAD) {
                    logMessage("Received a frame that's too large (%u bytes), discarding what was received", length);
                    buffered = 0;
                    break;
                }
                if (buffered < HEADER_SIZE + length) break;

                handleFrame(buffer[4], getUInt32(buffer + 5), buffer + HEADER_SIZE, length);

                memmove(buffer, buffer + HEADER_SIZE + length, buffered - HEADER_SIZE - length);
                buffered -= HEADER_SIZE + length;
            }
        }

        DWORD error = GetLastError();
        if (error != lastError && !isStopping) logMessage("The port closed (error %lu), opening it again", error);
        lastError = error;
        closePort();
        if (!isStopping) WaitForSingleObject(stopEvent, 1000);
    }

    CloseHandle(overlapped.hEvent);
    free(buffer);
    return 0;
}

/* MARK: - Service */

static void reportStatus(DWORD state) {
    serviceStatus.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
    serviceStatus.dwCurrentState = state;
    serviceStatus.dwControlsAccepted = state == SERVICE_RUNNING ? SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN : 0;
    serviceStatus.dwWin32ExitCode = NO_ERROR;
    SetServiceStatus(statusHandle, &serviceStatus);
}

static void stopAgent(void) {
    InterlockedExchange(&isStopping, 1);
    SetEvent(stopEvent);

    AcquireSRWLockShared(&portLock);
    if (port != INVALID_HANDLE_VALUE) CancelIoEx(port, NULL);
    ReleaseSRWLockShared(&portLock);

    terminateAllSessions();
}

static DWORD WINAPI handleControl(DWORD control, DWORD type, void *data, void *context) {
    (void)type;
    (void)data;
    (void)context;

    if (control == SERVICE_CONTROL_STOP || control == SERVICE_CONTROL_SHUTDOWN) {
        reportStatus(SERVICE_STOP_PENDING);
        stopAgent();
        return NO_ERROR;
    }
    return control == SERVICE_CONTROL_INTERROGATE ? NO_ERROR : ERROR_CALL_NOT_IMPLEMENTED;
}

static void WINAPI serviceMain(DWORD argumentCount, wchar_t **arguments) {
    (void)argumentCount;
    (void)arguments;

    statusHandle = RegisterServiceCtrlHandlerExW(SERVICE_NAME, handleControl, NULL);
    if (!statusHandle) return;

    reportStatus(SERVICE_START_PENDING);

    HANDLE agent = CreateThread(NULL, 0, runAgent, NULL, 0, NULL);
    if (!agent) {
        logMessage("Couldn't start (error %lu)", GetLastError());
        reportStatus(SERVICE_STOPPED);
        return;
    }

    reportStatus(SERVICE_RUNNING);
    logMessage("Started");

    WaitForSingleObject(agent, INFINITE);
    CloseHandle(agent);

    closePort();
    logMessage("Stopped");
    reportStatus(SERVICE_STOPPED);
}

int wmain(int argumentCount, wchar_t **arguments) {
    InitializeCriticalSection(&logLock);
    InitializeCriticalSection(&writeLock);
    stopEvent = CreateEventW(NULL, TRUE, FALSE, NULL);
    openLog();

    /* `HypervisaurAgent.exe console` runs the agent without the service manager, for testing. */
    if (argumentCount > 1 && wcscmp(arguments[1], L"console") == 0) {
        return (int)runAgent(NULL);
    }

    SERVICE_TABLE_ENTRYW services[] = {
        { (wchar_t *)SERVICE_NAME, serviceMain },
        { NULL, NULL },
    };
    if (!StartServiceCtrlDispatcherW(services)) {
        fwprintf(stderr, L"HypervisaurAgent runs as a service. Run it with \"console\" to run it in this window instead.\n");
        return 1;
    }
    return 0;
}

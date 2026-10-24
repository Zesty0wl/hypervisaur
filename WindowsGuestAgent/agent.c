/*
 * The Hypervisaur agent for Windows, which runs programs in the virtual machine for the Mac, and copies files and drags between them.
 *
 * It runs as a service, and talks to Hypervisaur over the virtio serial port named hypervisaur.agent, using the frames that
 * Documentation/GuestAgentProtocol.md describes. Each program runs on a channel of its own, in a job object so that stopping it also stops
 * the programs it started, and with a pseudo console when it needs a terminal. Files put in the guest are written on the thread
 * that reads frames, so that the port is read no faster than the disk is written, while files sent from the guest and drags
 * caught in it have threads of their own.
 */

#define WIN32_LEAN_AND_MEAN
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif

#include <windows.h>
#include <ole2.h>
#include <shellapi.h>
#include <shlobj.h>
#include <userenv.h>
#include <wtsapi32.h>
#include <limits.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#define SERVICE_NAME L"HypervisaurAgent"
#define PORT_PATH L"\\\\.\\Global\\hypervisaur.agent"
#define PROTOCOL_VERSION 2

#define HEADER_SIZE 9
#define MAX_PAYLOAD (1 << 20)
#define CHUNK_SIZE (16 * 1024)

/* How long a write to the port may take, so that the agent doesn't wait forever when Hypervisaur isn't reading. */
#define WRITE_TIMEOUT_MS 10000

/* How long output is still read after a program exits, since programs it started in the background can keep its output open. */
#define OUTPUT_DRAIN_TIMEOUT_MS 2000

/* File data is sent in pieces of this size, with at most TRANSFER_WINDOW of it waiting to be acknowledged. */
#define FILE_CHUNK_SIZE (256 * 1024)
#define TRANSFER_WINDOW ((uint64_t)4 << 20)

/* File data that's received is acknowledged at least this often, and after each file. */
#define ACKNOWLEDGEMENT_INTERVAL ((uint64_t)1 << 20)

/* How long sending files waits for Hypervisaur to acknowledge more of them before it gives up. */
#define ACKNOWLEDGEMENT_TIMEOUT_MS 120000

/* How long stopping waits for a transfer's thread, before it cancels what the thread is reading and waits again. */
#define TRANSFER_STOP_TIMEOUT_MS 5000

/*
 * The drag catcher gives up when no drag with files enters it within DRAG_ENTER_TIMEOUT_MS, and exits after DRAG_TIMEOUT_MS
 * in any case. The agent stops it if it's still running a little after that.
 */
#define DRAG_ENTER_TIMEOUT_MS 3000
#define DRAG_TIMEOUT_MS 10000
#define DRAG_HELPER_TIMEOUT_MS 10500
#define DRAG_CATCHER_SIZE 64

/* How many names are tried, such as `Name (2).ext`, when the name of an item is already used. */
#define MAX_NAME_ATTEMPTS 10000

/* Moving a folder fails while a file in it is open, such as while it's scanned for malware just after it's written, so moves are tried again for a while. */
#define MOVE_ATTEMPTS 50
#define MOVE_RETRY_DELAY_MS 100

/* Items put in a folder are written to a hidden folder in it whose name starts with this, so that they're only seen when they're complete. */
#define STAGING_PREFIX L".Hypervisaur-"

#define FILE_HEADER_SIZE 21
#define TRANSFER_SIZE_SIZE 12

#define OUT_OF_MEMORY "There isn't enough memory."

enum {
    FRAME_RESET = 0x01,
    FRAME_OPEN = 0x02,
    FRAME_INPUT = 0x03,
    FRAME_INPUT_END = 0x04,
    FRAME_RESIZE = 0x05,
    FRAME_TERMINATE = 0x06,
    FRAME_PUT_FILES = 0x07,
    FRAME_FILE_HEADER = 0x08,
    FRAME_FILE_DATA = 0x09,
    FRAME_FILES_END = 0x0A,
    FRAME_GET_FILES = 0x0B,
    FRAME_ACKNOWLEDGE = 0x0C,
    FRAME_CATCH_DRAG = 0x0D,
    FRAME_TRANSFER_SIZE = 0x0E,

    FRAME_HELLO = 0x41,
    FRAME_OUTPUT = 0x42,
    FRAME_ERROR_OUTPUT = 0x43,
    FRAME_EXITED = 0x44,
    FRAME_FAILED = 0x45,
    FRAME_TRANSFERRED = 0x46,
    FRAME_DRAG_ITEMS = 0x47,
};

enum {
    ITEM_FILE = 0,
    ITEM_FOLDER = 1,
};

enum {
    DESTINATION_DESKTOP = 0,
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

/* Set when a frame couldn't be sent, so that the thread that reads frames opens the port again. */
static volatile LONG needsReopening;

/* Whether the agent runs in the `console` mode, for testing, instead of as a service. */
static BOOL isConsoleMode;

/*
 * Handles are only inheritable while a program is being started, under this lock, so that programs started at the same time
 * on different threads don't inherit each other's pipes.
 */
static SRWLOCK inheritanceLock = SRWLOCK_INIT;

/*
 * The identifiers that the agent uses are defined here instead of being linked from libuuid, which would bring thousands of
 * others with them. They're the values in knownfolders.h, unknwn.h and oleidl.h.
 */
static const GUID desktopFolder = { 0xb4bfcc3a, 0xdb2c, 0x424c, { 0xb0, 0x29, 0x7f, 0xe9, 0x9a, 0x87, 0xc6, 0x41 } };
static const IID unknownInterface = { 0x00000000, 0x0000, 0x0000, { 0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 } };
static const IID dropTargetInterface = { 0x00000122, 0x0000, 0x0000, { 0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 } };

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

static void putUInt64(uint8_t *bytes, uint64_t value) {
    putUInt32(bytes, (uint32_t)value);
    putUInt32(bytes + 4, (uint32_t)(value >> 32));
}

static uint32_t getUInt32(const uint8_t *bytes) {
    return (uint32_t)bytes[0] | (uint32_t)bytes[1] << 8 | (uint32_t)bytes[2] << 16 | (uint32_t)bytes[3] << 24;
}

static uint64_t getUInt64(const uint8_t *bytes) {
    return (uint64_t)getUInt32(bytes) | (uint64_t)getUInt32(bytes + 4) << 32;
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

/*
 * Frames are dropped when they can't be sent, since nobody is listening for them then. Part of the frame may have been sent
 * already, which Hypervisaur couldn't make sense of, so the port is opened again, which Hypervisaur sees as the agent starting
 * again. A frame isn't sent if `isCancelled` is set, which is checked while no other frame can be sent, so that nothing is sent
 * on a channel once it's cancelled under the same lock. Returns whether the frame was sent.
 */
static BOOL sendFrameUnlessCancelled(volatile LONG *isCancelled, uint8_t kind, uint32_t channel, const void *payload, uint32_t length) {
    uint8_t header[HEADER_SIZE];
    putUInt32(header, length);
    header[4] = kind;
    putUInt32(header + 5, channel);

    BOOL sent = FALSE;
    AcquireSRWLockShared(&portLock);
    EnterCriticalSection(&writeLock);
    if (port != INVALID_HANDLE_VALUE && !needsReopening && !(isCancelled && *isCancelled)) {
        sent = writeAll(port, header, HEADER_SIZE) && (length == 0 || writeAll(port, payload, length));
        if (!sent) {
            logMessage("Couldn't send a frame of kind 0x%02x on channel %u (error %lu), opening the port again", kind, channel, GetLastError());
            InterlockedExchange(&needsReopening, 1);
            CancelIoEx(port, NULL);
        }
    }
    LeaveCriticalSection(&writeLock);
    ReleaseSRWLockShared(&portLock);
    return sent;
}

static BOOL sendFrame(uint8_t kind, uint32_t channel, const void *payload, uint32_t length) {
    return sendFrameUnlessCancelled(NULL, kind, channel, payload, length);
}

static void sendText(uint8_t kind, uint32_t channel, const char *text) {
    sendFrame(kind, channel, text, (uint32_t)strlen(text));
}

/* MARK: - Text */

/* Bytes that grow as they're added to, and that are kept terminated with a NUL so that text can be used as a string. */
typedef struct {
    char *bytes;
    size_t length;
    size_t capacity;
} Buffer;

static BOOL appendBytes(Buffer *buffer, const void *bytes, size_t count) {
    if (count > SIZE_MAX / 2 - buffer->length) return FALSE;

    size_t needed = buffer->length + count + 1;
    if (needed > buffer->capacity) {
        size_t capacity = buffer->capacity ? buffer->capacity : 256;
        while (capacity < needed) capacity *= 2;

        char *grown = realloc(buffer->bytes, capacity);
        if (!grown) return FALSE;
        buffer->bytes = grown;
        buffer->capacity = capacity;
    }

    memcpy(buffer->bytes + buffer->length, bytes, count);
    buffer->length += count;
    buffer->bytes[buffer->length] = 0;
    return TRUE;
}

static char *formatTextV(const char *format, va_list arguments) {
    va_list copy;
    va_copy(copy, arguments);
    int length = vsnprintf(NULL, 0, format, copy);
    va_end(copy);
    if (length < 0) return NULL;

    char *text = malloc((size_t)length + 1);
    if (text) vsnprintf(text, (size_t)length + 1, format, arguments);
    return text;
}

/* Returns new text made like printf does, or NULL if there isn't enough memory. */
static char *formatText(const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    char *text = formatTextV(format, arguments);
    va_end(arguments);
    return text;
}

static wchar_t *copyWide(const wchar_t *text) {
    size_t size = (wcslen(text) + 1) * sizeof(wchar_t);
    wchar_t *copy = malloc(size);
    if (copy) memcpy(copy, text, size);
    return copy;
}

/* Returns `length` bytes of UTF-8 as a new UTF-16 string, or NULL if they aren't valid UTF-8, contain a NUL, or there isn't enough memory. */
static wchar_t *wideFromUTF8(const char *text, size_t length) {
    if (length > INT_MAX || (length > 0 && memchr(text, 0, length))) return NULL;

    int count = 0;
    if (length > 0) {
        count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, (int)length, NULL, 0);
        if (count <= 0) return NULL;
    }

    wchar_t *wide = malloc(((size_t)count + 1) * sizeof(wchar_t));
    if (!wide) return NULL;
    if (count > 0 && MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, (int)length, wide, count) != count) {
        free(wide);
        return NULL;
    }
    wide[count] = 0;
    return wide;
}

/* Whether bytes are valid UTF-8 without NULs, which paths can't contain. */
static BOOL isValidUTF8(const char *text, size_t length) {
    if (length == 0) return TRUE;
    if (length > INT_MAX || memchr(text, 0, length)) return FALSE;
    return MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, (int)length, NULL, 0) > 0;
}

/* Returns the string in UTF-8, or NULL if there isn't enough memory. Unpaired surrogates, which Windows allows in names, become U+FFFD. */
static char *utf8FromWide(const wchar_t *text) {
    int size = WideCharToMultiByte(CP_UTF8, 0, text, -1, NULL, 0, NULL, NULL);
    if (size <= 0) return NULL;

    char *utf8 = malloc((size_t)size);
    if (utf8 && WideCharToMultiByte(CP_UTF8, 0, text, -1, utf8, size, NULL, NULL) != size) {
        free(utf8);
        return NULL;
    }
    return utf8;
}

/* MARK: - Paths */

/*
 * Paths made for transfers can be longer than MAX_PATH, so they're kept in the \\?\ form, which Windows doesn't limit to it,
 * and which it uses exactly as it's written.
 */

static BOOL hasPrefix(const wchar_t *text, const wchar_t *prefix) {
    return wcsncmp(text, prefix, wcslen(prefix)) == 0;
}

static BOOL isDotName(const wchar_t *name) {
    return name[0] == L'.' && (name[1] == 0 || (name[1] == L'.' && name[2] == 0));
}

static wchar_t *joinPath(const wchar_t *directory, const wchar_t *name) {
    size_t directoryLength = wcslen(directory), nameLength = wcslen(name);
    size_t separatorLength = directoryLength > 0 && directory[directoryLength - 1] != L'\\' ? 1 : 0;

    wchar_t *path = malloc((directoryLength + separatorLength + nameLength + 1) * sizeof(wchar_t));
    if (!path) return NULL;

    memcpy(path, directory, directoryLength * sizeof(wchar_t));
    if (separatorLength) path[directoryLength] = L'\\';
    memcpy(path + directoryLength + separatorLength, name, (nameLength + 1) * sizeof(wchar_t));
    return path;
}

/* Returns an absolute path in the \\?\ form, with `.` and `..` resolved, or NULL if it isn't one. */
static wchar_t *extendedPath(const wchar_t *path) {
    if (hasPrefix(path, L"\\\\?\\")) return copyWide(path);

    DWORD size = GetFullPathNameW(path, 0, NULL, NULL);
    if (size == 0) return NULL;
    wchar_t *full = malloc((size_t)size * sizeof(wchar_t));
    if (!full) return NULL;
    DWORD length = GetFullPathNameW(path, size, full, NULL);
    if (length == 0 || length >= size) {
        free(full);
        return NULL;
    }

    const wchar_t *prefix, *rest;
    if (full[0] == L'\\' && full[1] == L'\\') {
        /* Device paths are used as they are. */
        if ((full[2] == L'?' || full[2] == L'.') && full[3] == L'\\') return full;
        prefix = L"\\\\?\\UNC\\";
        rest = full + 2;
    } else if (full[0] != 0 && full[1] == L':' && full[2] == L'\\') {
        prefix = L"\\\\?\\";
        rest = full;
    } else {
        free(full);
        return NULL;
    }

    size_t prefixLength = wcslen(prefix), restLength = wcslen(rest);
    wchar_t *extended = malloc((prefixLength + restLength + 1) * sizeof(wchar_t));
    if (extended) {
        memcpy(extended, prefix, prefixLength * sizeof(wchar_t));
        memcpy(extended + prefixLength, rest, (restLength + 1) * sizeof(wchar_t));
    }
    free(full);
    return extended;
}

/* Returns the path in UTF-8 as people see it, without the \\?\ prefix. */
static char *displayPath(const wchar_t *path) {
    if (hasPrefix(path, L"\\\\?\\UNC\\")) {
        wchar_t *share = malloc((wcslen(path + 8) + 3) * sizeof(wchar_t));
        if (!share) return NULL;
        wcscpy(share, L"\\\\");
        wcscat(share, path + 8);
        char *text = utf8FromWide(share);
        free(share);
        return text;
    }
    return utf8FromWide(hasPrefix(path, L"\\\\?\\") ? path + 4 : path);
}

/* Describes a failure with a path, given a format with a %s for the path and a %lu for the error. */
static char *pathFailure(const char *format, const wchar_t *path, DWORD error) {
    char *shown = displayPath(path);
    char *text = shown ? formatText(format, shown, error) : NULL;
    free(shown);
    return text;
}

/*
 * Removes separators from the end of a path in the \\?\ form, then returns its last component, or NULL if it's the root of
 * a drive or a share, which aren't items of their own.
 */
static const wchar_t *lastComponent(wchar_t *path) {
    size_t length = wcslen(path);
    while (length > 4 && path[length - 1] == L'\\') path[--length] = 0;

    const wchar_t *component = wcsrchr(path, L'\\') + 1;
    if (component == path + 4 || *component == 0 || wcschr(component, L':')) return NULL;

    if (hasPrefix(path, L"\\\\?\\UNC\\")) {
        int separators = 0;
        for (const wchar_t *character = path + 8; *character; character++) {
            if (*character == L'\\') separators++;
        }
        if (separators < 2) return NULL;
    }
    return component;
}

/* The name for the `number`th item with a name, such as `Name (2).ext`. Folders keep what's after a dot in their names. */
static wchar_t *numberedName(const wchar_t *name, unsigned number, BOOL isFolder) {
    size_t length = wcslen(name), stem = length;
    if (!isFolder) {
        const wchar_t *dot = wcsrchr(name, L'.');
        if (dot && dot != name) stem = (size_t)(dot - name);
    }

    wchar_t suffix[16];
    int suffixLength = swprintf(suffix, sizeof(suffix) / sizeof(suffix[0]), L" (%u)", number);
    if (suffixLength < 0) return NULL;

    wchar_t *numbered = malloc((length + (size_t)suffixLength + 1) * sizeof(wchar_t));
    if (!numbered) return NULL;
    memcpy(numbered, name, stem * sizeof(wchar_t));
    memcpy(numbered + stem, suffix, (size_t)suffixLength * sizeof(wchar_t));
    memcpy(numbered + stem + suffixLength, name + stem, (length - stem + 1) * sizeof(wchar_t));
    return numbered;
}

/* Whether Windows reserves a name for a device, such as `CON` or `aux.c`, even with an extension. */
static BOOL isReservedName(const wchar_t *name) {
    int length = (int)wcscspn(name, L".");
    while (length > 0 && name[length - 1] == L' ') length--;

    static const wchar_t *const devices[] = { L"CON", L"PRN", L"AUX", L"NUL", L"CONIN$", L"CONOUT$" };
    for (size_t index = 0; index < sizeof(devices) / sizeof(devices[0]); index++) {
        if (CompareStringOrdinal(name, length, devices[index], -1, TRUE) == CSTR_EQUAL) return TRUE;
    }

    if (length == 4 && (CompareStringOrdinal(name, 3, L"COM", 3, TRUE) == CSTR_EQUAL || CompareStringOrdinal(name, 3, L"LPT", 3, TRUE) == CSTR_EQUAL)) {
        wchar_t digit = name[3];
        return (digit >= L'0' && digit <= L'9') || digit == 0x00B9 || digit == 0x00B2 || digit == 0x00B3;
    }
    return FALSE;
}

/*
 * Returns a name from a transfer as a name that Windows allows: characters that it doesn't allow become `_`, and trailing
 * dots and spaces are removed. Names that are empty then, or that are reserved for devices, get an underscore. Returns NULL
 * if the name isn't valid UTF-8.
 */
static wchar_t *windowsName(const char *component, size_t length) {
    wchar_t *name = wideFromUTF8(component, length);
    if (!name) return NULL;

    for (wchar_t *character = name; *character; character++) {
        if (*character < 0x20 || wcschr(L"<>:\"\\|?*", *character)) *character = L'_';
    }

    size_t nameLength = wcslen(name);
    while (nameLength > 0 && (name[nameLength - 1] == L'.' || name[nameLength - 1] == L' ')) name[--nameLength] = 0;

    if (nameLength == 0 || isReservedName(name)) {
        size_t base = wcscspn(name, L".");
        wchar_t *changed = malloc((nameLength + 2) * sizeof(wchar_t));
        if (!changed) {
            free(name);
            return NULL;
        }
        memcpy(changed, name, base * sizeof(wchar_t));
        changed[base] = L'_';
        memcpy(changed + base + 1, name + base, (nameLength - base + 1) * sizeof(wchar_t));
        free(name);
        return changed;
    }
    return name;
}

static BOOL moveItem(const wchar_t *source, const wchar_t *destination) {
    for (int attempt = 1;; attempt++) {
        if (MoveFileExW(source, destination, 0)) return TRUE;

        DWORD error = GetLastError();
        BOOL isBusy = error == ERROR_ACCESS_DENIED || error == ERROR_SHARING_VIOLATION || error == ERROR_LOCK_VIOLATION;
        if (!isBusy || attempt == MOVE_ATTEMPTS || GetFileAttributesW(destination) != INVALID_FILE_ATTRIBUTES) {
            SetLastError(error);
            return FALSE;
        }
        Sleep(MOVE_RETRY_DELAY_MS);
    }
}

/*
 * Creates a folder or a file in a folder, or moves an item there when `source` isn't NULL, with a new name such as
 * `Name (2).ext` if the name is used already. Returns the item's new path, or NULL with the last error set if it can't.
 */
static wchar_t *placeItem(const wchar_t *directory, const wchar_t *name, BOOL isFolder, const wchar_t *source, HANDLE *file) {
    for (unsigned number = 1; number <= MAX_NAME_ATTEMPTS; number++) {
        wchar_t *candidateName = number == 1 ? copyWide(name) : numberedName(name, number, isFolder);
        wchar_t *candidate = candidateName ? joinPath(directory, candidateName) : NULL;
        free(candidateName);
        if (!candidate) {
            SetLastError(ERROR_NOT_ENOUGH_MEMORY);
            return NULL;
        }

        BOOL isPlaced;
        if (source) {
            isPlaced = moveItem(source, candidate);
        } else if (isFolder) {
            isPlaced = CreateDirectoryW(candidate, NULL);
        } else {
            *file = CreateFileW(candidate, GENERIC_WRITE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_SEQUENTIAL_SCAN, NULL);
            isPlaced = *file != INVALID_HANDLE_VALUE;
        }
        if (isPlaced) return candidate;

        /* Some failures don't say that the name is used, such as creating a file where there's a folder. */
        DWORD error = GetLastError();
        BOOL exists = error == ERROR_ALREADY_EXISTS || error == ERROR_FILE_EXISTS || GetFileAttributesW(candidate) != INVALID_FILE_ATTRIBUTES;
        free(candidate);
        if (!exists) {
            SetLastError(error);
            return NULL;
        }
    }

    SetLastError(ERROR_FILE_EXISTS);
    return NULL;
}

/* Folders still to be looked in, from the last one found. */
typedef struct PendingFolder {
    wchar_t *path;
    /* The folder's path in a transfer, when there is one. */
    char *relative;
    struct PendingFolder *next;
} PendingFolder;

static void freePendingFolders(PendingFolder *folder) {
    while (folder) {
        PendingFolder *next = folder->next;
        free(folder->path);
        free(folder->relative);
        free(folder);
        folder = next;
    }
}

static BOOL removeEntry(const wchar_t *path, DWORD attributes) {
    if (attributes & FILE_ATTRIBUTE_READONLY) SetFileAttributesW(path, FILE_ATTRIBUTE_NORMAL);
    return attributes & FILE_ATTRIBUTE_DIRECTORY ? RemoveDirectoryW(path) : DeleteFileW(path);
}

/*
 * Removes an item, and everything in it if it's a folder, without following links. Folders are looked in without recursion,
 * since they can be nested more deeply than a thread's stack allows.
 */
static BOOL removeItem(const wchar_t *path) {
    DWORD attributes = GetFileAttributesW(path);
    if (attributes == INVALID_FILE_ATTRIBUTES) {
        DWORD error = GetLastError();
        return error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND;
    }
    if (!(attributes & FILE_ATTRIBUTE_DIRECTORY) || (attributes & FILE_ATTRIBUTE_REPARSE_POINT)) return removeEntry(path, attributes);

    PendingFolder *stack = calloc(1, sizeof(PendingFolder));
    if (!stack || !(stack->path = copyWide(path))) {
        freePendingFolders(stack);
        return FALSE;
    }

    /* Each folder's files are removed and its folders are added to the stack, and it's removed when it has no folders left. */
    BOOL succeeded = TRUE;
    while (stack && succeeded) {
        PendingFolder *folder = stack;
        BOOL hasFolders = FALSE;

        wchar_t *pattern = joinPath(folder->path, L"*");
        WIN32_FIND_DATAW data;
        HANDLE find = pattern ? FindFirstFileExW(pattern, FindExInfoBasic, &data, FindExSearchNameMatch, NULL, FIND_FIRST_EX_LARGE_FETCH) : INVALID_HANDLE_VALUE;
        DWORD error = pattern ? GetLastError() : ERROR_NOT_ENOUGH_MEMORY;
        free(pattern);

        if (find == INVALID_HANDLE_VALUE) {
            if (error != ERROR_FILE_NOT_FOUND) succeeded = FALSE;
        } else {
            do {
                if (isDotName(data.cFileName)) continue;

                wchar_t *child = joinPath(folder->path, data.cFileName);
                if (!child) {
                    succeeded = FALSE;
                    break;
                }

                if ((data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) && !(data.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
                    PendingFolder *pending = calloc(1, sizeof(PendingFolder));
                    if (!pending) {
                        free(child);
                        succeeded = FALSE;
                        break;
                    }
                    pending->path = child;
                    pending->next = stack;
                    stack = pending;
                    hasFolders = TRUE;
                } else {
                    if (!removeEntry(child, data.dwFileAttributes)) succeeded = FALSE;
                    free(child);
                }
            } while (succeeded && FindNextFileW(find, &data));
            FindClose(find);
        }

        if (succeeded && !hasFolders) {
            if (!removeEntry(folder->path, FILE_ATTRIBUTE_DIRECTORY)) succeeded = FALSE;
            stack = folder->next;
            folder->next = NULL;
            freePendingFolders(folder);
        }
    }

    freePendingFolders(stack);
    return succeeded;
}

/* MARK: - Dates */

#define UNIX_EPOCH_FILETIME 116444736000000000LL
#define FILETIME_TICKS_PER_SECOND 10000000LL

static BOOL fileTimeFromUnix(int64_t seconds, FILETIME *time) {
    if (seconds < -(UNIX_EPOCH_FILETIME / FILETIME_TICKS_PER_SECOND) || seconds > (INT64_MAX - UNIX_EPOCH_FILETIME) / FILETIME_TICKS_PER_SECOND) return FALSE;

    uint64_t ticks = (uint64_t)(seconds * FILETIME_TICKS_PER_SECOND + UNIX_EPOCH_FILETIME);
    time->dwLowDateTime = (DWORD)ticks;
    time->dwHighDateTime = (DWORD)(ticks >> 32);
    return TRUE;
}

/* Returns seconds since 1970, or 0 when the time isn't known. */
static int64_t unixFromFileTime(FILETIME time) {
    uint64_t ticks = (uint64_t)time.dwHighDateTime << 32 | time.dwLowDateTime;
    if (ticks == 0 || ticks > INT64_MAX) return 0;

    int64_t difference = (int64_t)ticks - UNIX_EPOCH_FILETIME;
    int64_t seconds = difference / FILETIME_TICKS_PER_SECOND;
    if (difference % FILETIME_TICKS_PER_SECOND < 0) seconds--;
    return seconds;
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

    AcquireSRWLockExclusive(&inheritanceLock);

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

    ReleaseSRWLockExclusive(&inheritanceLock);

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

/* MARK: - Signed-in user */

/* Sends `failed` with a description, or says that there wasn't enough memory when there isn't one, and frees it. */
static void sendFailure(uint32_t channel, char *message) {
    const char *text = message ? message : OUT_OF_MEMORY;
    logMessage("Channel %u: %s", channel, text);
    sendText(FRAME_FAILED, channel, text);
    free(message);
}

/*
 * Opens the token of the user signed in at the display, who's the user of the active console session. In the `console` mode,
 * the agent can't open other users' tokens, so it uses its own user instead, with *token set to NULL. Otherwise, it returns
 * FALSE with a description of why there isn't one in *error.
 */
static BOOL openConsoleUser(HANDLE *token, char **error) {
    *token = NULL;

    DWORD session = WTSGetActiveConsoleSessionId();
    if (session == 0xFFFFFFFF) {
        *error = formatText("Nobody is signed in to Windows.");
        return FALSE;
    }
    if (WTSQueryUserToken(session, token)) return TRUE;

    DWORD status = GetLastError();
    *token = NULL;
    if (isConsoleMode && status == ERROR_PRIVILEGE_NOT_HELD) return TRUE;

    *error = status == ERROR_NO_TOKEN ? formatText("Nobody is signed in to Windows.")
        : formatText("Couldn't find who's signed in to Windows (error %lu).", status);
    return FALSE;
}

/* Finds the desktop of the user signed in at the display, which may have been moved, such as to OneDrive, in the \\?\ form. */
static wchar_t *consoleDesktop(char **error) {
    HANDLE token;
    if (!openConsoleUser(&token, error)) return NULL;

    wchar_t *folder = NULL;
    HRESULT result = SHGetKnownFolderPath(&desktopFolder, 0, token, &folder);
    if (token) CloseHandle(token);

    wchar_t *desktop = SUCCEEDED(result) ? extendedPath(folder) : NULL;
    CoTaskMemFree(folder);

    if (!desktop) {
        *error = SUCCEEDED(result) ? formatText("Couldn't use the desktop of the user signed in to Windows.")
            : formatText("Couldn't find the desktop of the user signed in to Windows (error 0x%08lx).", (unsigned long)result);
    }
    return desktop;
}

/* MARK: - Putting files in the guest */

/*
 * Items are written into a hidden folder in the destination, so that they get its permissions: the service runs as SYSTEM, so
 * items written anywhere else would keep permissions that the user can't use. Folders are kept by their paths in the transfer,
 * so that the items in them can be found quickly however many there are, and their dates are set after everything in them
 * is written, since writing items in a folder changes its date. When all the items are received, the top-level ones are moved
 * into the destination.
 */

typedef struct ReceivedFolder {
    char *key;
    size_t keyLength;
    uint32_t hash;
    wchar_t *path;
    int64_t modified;
    struct ReceivedFolder *next;
} ReceivedFolder;

typedef struct {
    wchar_t *path;
    BOOL isFolder;
} TopItem;

typedef struct Upload {
    uint32_t channel;
    wchar_t *destination;
    wchar_t *staging;

    ReceivedFolder **folders;
    size_t folderBuckets;
    size_t folderCount;

    TopItem *items;
    size_t itemCount;
    size_t itemCapacity;

    /* The file being received, with its path in the transfer, how much of it is still to come, and its modification date. */
    HANDLE file;
    char *fileName;
    uint64_t fileRemaining;
    int64_t fileModified;

    /* How much file data has been written, and how much of that has been acknowledged. */
    uint64_t written;
    uint64_t acknowledged;
    BOOL hasSize;

    struct Upload *next;
} Upload;

/* Uploads are only used on the thread that reads frames. */
static Upload *uploads;

static uint32_t hashPath(const char *path, size_t length) {
    uint32_t hash = 2166136261u;
    for (size_t index = 0; index < length; index++) {
        hash ^= (uint8_t)path[index];
        hash *= 16777619u;
    }
    return hash;
}

static ReceivedFolder *findFolder(const Upload *upload, const char *path, size_t length) {
    if (upload->folderBuckets == 0) return NULL;

    uint32_t hash = hashPath(path, length);
    for (ReceivedFolder *folder = upload->folders[hash % upload->folderBuckets]; folder; folder = folder->next) {
        if (folder->hash == hash && folder->keyLength == length && memcmp(folder->key, path, length) == 0) return folder;
    }
    return NULL;
}

/* Adds a folder, which takes `path` when it succeeds. */
static BOOL addFolder(Upload *upload, const char *key, size_t keyLength, wchar_t *path, int64_t modified) {
    if (upload->folderCount >= upload->folderBuckets) {
        size_t bucketCount = upload->folderBuckets ? upload->folderBuckets * 2 : 64;
        ReceivedFolder **buckets = calloc(bucketCount, sizeof(ReceivedFolder *));
        if (!buckets) return FALSE;

        for (size_t index = 0; index < upload->folderBuckets; index++) {
            ReceivedFolder *folder = upload->folders[index];
            while (folder) {
                ReceivedFolder *next = folder->next;
                folder->next = buckets[folder->hash % bucketCount];
                buckets[folder->hash % bucketCount] = folder;
                folder = next;
            }
        }
        free(upload->folders);
        upload->folders = buckets;
        upload->folderBuckets = bucketCount;
    }

    ReceivedFolder *folder = malloc(sizeof(ReceivedFolder));
    char *copy = malloc(keyLength + 1);
    if (!folder || !copy) {
        free(folder);
        free(copy);
        return FALSE;
    }
    memcpy(copy, key, keyLength);
    copy[keyLength] = 0;

    folder->key = copy;
    folder->keyLength = keyLength;
    folder->hash = hashPath(key, keyLength);
    folder->path = path;
    folder->modified = modified;
    folder->next = upload->folders[folder->hash % upload->folderBuckets];
    upload->folders[folder->hash % upload->folderBuckets] = folder;
    upload->folderCount++;
    return TRUE;
}

static BOOL addTopItem(Upload *upload, const wchar_t *path, BOOL isFolder) {
    if (upload->itemCount == upload->itemCapacity) {
        size_t capacity = upload->itemCapacity ? upload->itemCapacity * 2 : 16;
        TopItem *items = realloc(upload->items, capacity * sizeof(TopItem));
        if (!items) return FALSE;
        upload->items = items;
        upload->itemCapacity = capacity;
    }

    wchar_t *copy = copyWide(path);
    if (!copy) return FALSE;
    upload->items[upload->itemCount].path = copy;
    upload->items[upload->itemCount].isFolder = isFolder;
    upload->itemCount++;
    return TRUE;
}

static Upload *findUpload(uint32_t channel) {
    for (Upload *upload = uploads; upload; upload = upload->next) {
        if (upload->channel == channel) return upload;
    }
    return NULL;
}

/* Stops receiving files on the channel without a reply, and removes the hidden folder with everything in it. */
static void discardUpload(Upload *upload) {
    for (Upload **link = &uploads; *link; link = &(*link)->next) {
        if (*link == upload) {
            *link = upload->next;
            break;
        }
    }

    if (upload->file != INVALID_HANDLE_VALUE) CloseHandle(upload->file);
    if (!removeItem(upload->staging)) logMessage("Channel %u: couldn't remove the folder the files were received in (error %lu)", upload->channel, GetLastError());

    for (size_t index = 0; index < upload->folderBuckets; index++) {
        ReceivedFolder *folder = upload->folders[index];
        while (folder) {
            ReceivedFolder *next = folder->next;
            free(folder->key);
            free(folder->path);
            free(folder);
            folder = next;
        }
    }
    free(upload->folders);

    for (size_t index = 0; index < upload->itemCount; index++) free(upload->items[index].path);
    free(upload->items);

    free(upload->fileName);
    free(upload->destination);
    free(upload->staging);
    free(upload);
}

/* Stops receiving files on the channel, removes what was received, and replies `failed` with the message, which it frees. */
static void failUpload(Upload *upload, char *message) {
    uint32_t channel = upload->channel;
    discardUpload(upload);
    sendFailure(channel, message);
}

static char *writeFailure(const char *name, DWORD error) {
    if (error == ERROR_DISK_FULL || error == ERROR_HANDLE_DISK_FULL) return formatText("There isn't enough space on the disk for %s.", name);
    return formatText("Couldn't write %s (error %lu).", name, error);
}

/* Removes hidden folders that transfers which didn't finish left behind, such as when Windows restarted during one. */
static void removeStagingFolders(const wchar_t *destination) {
    wchar_t *pattern = joinPath(destination, STAGING_PREFIX L"*");
    if (!pattern) return;

    WIN32_FIND_DATAW data;
    HANDLE find = FindFirstFileExW(pattern, FindExInfoBasic, &data, FindExSearchNameMatch, NULL, 0);
    free(pattern);
    if (find == INVALID_HANDLE_VALUE) return;

    do {
        DWORD attributes = data.dwFileAttributes;
        if (!(attributes & FILE_ATTRIBUTE_DIRECTORY) || !(attributes & FILE_ATTRIBUTE_HIDDEN) || (attributes & FILE_ATTRIBUTE_REPARSE_POINT)) continue;

        wchar_t *path = joinPath(destination, data.cFileName);
        if (!path) break;

        BOOL isInUse = FALSE;
        for (Upload *upload = uploads; upload && !isInUse; upload = upload->next) {
            isInUse = CompareStringOrdinal(upload->staging, -1, path, -1, TRUE) == CSTR_EQUAL;
        }
        if (!isInUse) {
            if (removeItem(path)) logMessage("Removed a folder that an earlier transfer left behind");
            else logMessage("Couldn't remove a folder that an earlier transfer left behind (error %lu)", GetLastError());
        }
        free(path);
    } while (FindNextFileW(find, &data));
    FindClose(find);
}

static wchar_t *createStagingFolder(const wchar_t *destination, uint32_t channel) {
    ULONGLONG time = GetTickCount64();
    for (unsigned attempt = 0; attempt < 100; attempt++) {
        wchar_t name[64];
        swprintf(name, sizeof(name) / sizeof(name[0]), STAGING_PREFIX L"%u-%llx", channel, (unsigned long long)(time + attempt));

        wchar_t *path = joinPath(destination, name);
        if (!path) {
            SetLastError(ERROR_NOT_ENOUGH_MEMORY);
            return NULL;
        }

        if (CreateDirectoryW(path, NULL)) {
            if (SetFileAttributesW(path, FILE_ATTRIBUTE_HIDDEN)) return path;

            DWORD error = GetLastError();
            RemoveDirectoryW(path);
            free(path);
            SetLastError(error);
            return NULL;
        }

        DWORD error = GetLastError();
        free(path);
        if (error != ERROR_ALREADY_EXISTS) {
            SetLastError(error);
            return NULL;
        }
    }

    SetLastError(ERROR_ALREADY_EXISTS);
    return NULL;
}

static void startUpload(uint32_t channel, const uint8_t *payload, uint32_t length) {
    if (findUpload(channel)) {
        logMessage("Channel %u: is already receiving files, so another request to put files on it is ignored", channel);
        return;
    }
    if (length < 1) {
        sendText(FRAME_FAILED, channel, "The request to put files is incomplete.");
        return;
    }
    if (payload[0] != DESTINATION_DESKTOP) {
        sendFailure(channel, formatText("Files can't be put in destination %u.", payload[0]));
        return;
    }

    char *error = NULL;
    wchar_t *destination = consoleDesktop(&error);
    if (!destination) {
        sendFailure(channel, error);
        return;
    }

    removeStagingFolders(destination);

    wchar_t *staging = createStagingFolder(destination, channel);
    if (!staging) {
        sendFailure(channel, formatText("Couldn't prepare the desktop for the files (error %lu).", GetLastError()));
        free(destination);
        return;
    }

    Upload *upload = calloc(1, sizeof(Upload));
    if (!upload) {
        RemoveDirectoryW(staging);
        free(staging);
        free(destination);
        sendFailure(channel, NULL);
        return;
    }

    upload->channel = channel;
    upload->destination = destination;
    upload->staging = staging;
    upload->file = INVALID_HANDLE_VALUE;
    upload->next = uploads;
    uploads = upload;
    logMessage("Channel %u: receiving files", channel);
}

static void acknowledgeUpload(Upload *upload) {
    if (upload->written == upload->acknowledged) return;

    uint8_t payload[8];
    putUInt64(payload, upload->written);
    sendFrame(FRAME_ACKNOWLEDGE, upload->channel, payload, sizeof(payload));
    upload->acknowledged = upload->written;
}

/* The size is only used to check that there's space for the files, since the items say how large they are. */
static void receiveTransferSize(Upload *upload, const uint8_t *payload, uint32_t length) {
    if (length < TRANSFER_SIZE_SIZE) {
        failUpload(upload, formatText("The size of the transfer is incomplete."));
        return;
    }
    if (upload->hasSize) return;
    upload->hasSize = TRUE;

    /* The folder ends with a separator, which a folder on a network share needs. */
    uint64_t size = getUInt64(payload);
    wchar_t *folder = joinPath(upload->staging, L"");
    ULARGE_INTEGER available;
    BOOL hasSpace = !folder || !GetDiskFreeSpaceExW(folder, &available, NULL, NULL) || available.QuadPart >= size;
    free(folder);
    if (!hasSpace) {
        logMessage("Channel %u: the files need %llu bytes, and %llu are available", upload->channel, (unsigned long long)size, (unsigned long long)available.QuadPart);
        failUpload(upload, formatText("There isn't enough space on the disk for the files."));
    }
}

/* Whether a path in a transfer is relative, without empty, `.` or `..` components. */
static BOOL isValidItemPath(const char *path, size_t length) {
    size_t start = 0;
    for (size_t index = 0; index <= length; index++) {
        if (index < length && path[index] != '/') continue;

        size_t count = index - start;
        if (count == 0 || (count == 1 && path[start] == '.') || (count == 2 && path[start] == '.' && path[start + 1] == '.')) return FALSE;
        start = index + 1;
    }
    return TRUE;
}

static void finishFile(Upload *upload) {
    FILETIME time;
    if (upload->fileModified != 0 && fileTimeFromUnix(upload->fileModified, &time) && !SetFileTime(upload->file, NULL, NULL, &time)) {
        logMessage("Channel %u: couldn't set the modification date of %s (error %lu)", upload->channel, upload->fileName, GetLastError());
    }

    CloseHandle(upload->file);
    upload->file = INVALID_HANDLE_VALUE;
    free(upload->fileName);
    upload->fileName = NULL;

    acknowledgeUpload(upload);
}

static void receiveHeader(Upload *upload, const uint8_t *payload, uint32_t length) {
    if (upload->file != INVALID_HANDLE_VALUE) {
        failUpload(upload, formatText("The next item started before all of %s was received.", upload->fileName));
        return;
    }
    if (length < FILE_HEADER_SIZE) {
        failUpload(upload, formatText("An item's header is incomplete."));
        return;
    }

    uint8_t type = payload[0];
    uint64_t size = getUInt64(payload + 1);
    /* The permissions, at payload + 9, aren't used, since Windows doesn't have POSIX permissions. */
    int64_t modified = (int64_t)getUInt64(payload + 13);
    const char *path = (const char *)payload + FILE_HEADER_SIZE;
    size_t pathLength = length - FILE_HEADER_SIZE;
    int shownLength = (int)pathLength;

    if (pathLength == 0) {
        failUpload(upload, formatText("An item doesn't have a path."));
        return;
    }
    /* The path is checked first, so that descriptions of what's wrong with it are valid UTF-8. */
    if (!isValidUTF8(path, pathLength)) {
        failUpload(upload, formatText("An item's path isn't valid UTF-8."));
        return;
    }
    if (type != ITEM_FILE && type != ITEM_FOLDER) {
        failUpload(upload, formatText("%.*s is an unknown type of item (%u).", shownLength, path, type));
        return;
    }
    if (!isValidItemPath(path, pathLength)) {
        failUpload(upload, formatText("The path %.*s isn't allowed.", shownLength, path));
        return;
    }

    BOOL isFolder = type == ITEM_FOLDER;
    size_t nameStart = pathLength;
    while (nameStart > 0 && path[nameStart - 1] != '/') nameStart--;

    const wchar_t *parent = upload->staging;
    if (nameStart > 0) {
        ReceivedFolder *folder = findFolder(upload, path, nameStart - 1);
        if (!folder) {
            failUpload(upload, formatText("%.*s isn't in a folder that came before it.", shownLength, path));
            return;
        }
        parent = folder->path;
    }
    if (isFolder && findFolder(upload, path, pathLength)) {
        failUpload(upload, formatText("%.*s was sent more than once.", shownLength, path));
        return;
    }

    wchar_t *name = windowsName(path + nameStart, pathLength - nameStart);
    if (!name) {
        failUpload(upload, NULL);
        return;
    }

    HANDLE file = INVALID_HANDLE_VALUE;
    wchar_t *placed = placeItem(parent, name, isFolder, NULL, &file);
    DWORD error = GetLastError();
    free(name);

    if (!placed) {
        char *shown = formatText("%.*s", shownLength, path);
        failUpload(upload, shown ? writeFailure(shown, error) : NULL);
        free(shown);
        return;
    }

    /* The file is kept by the upload straight away, so that it's closed if the upload fails. */
    upload->file = file;

    if (nameStart == 0 && !addTopItem(upload, placed, isFolder)) {
        free(placed);
        failUpload(upload, NULL);
        return;
    }

    if (isFolder) {
        if (!addFolder(upload, path, pathLength, placed, modified)) {
            free(placed);
            failUpload(upload, NULL);
        }
        return;
    }
    free(placed);

    upload->fileName = formatText("%.*s", shownLength, path);
    if (!upload->fileName) {
        failUpload(upload, NULL);
        return;
    }
    upload->fileRemaining = size;
    upload->fileModified = modified;
    if (size == 0) finishFile(upload);
}

static void receiveData(Upload *upload, const uint8_t *payload, uint32_t length) {
    if (length == 0) return;

    if (upload->file == INVALID_HANDLE_VALUE) {
        failUpload(upload, formatText("File data was received when no file had started."));
        return;
    }
    if (length > upload->fileRemaining) {
        failUpload(upload, formatText("More data was received for %s than its size.", upload->fileName));
        return;
    }

    if (!writeBytes(upload->file, payload, length)) {
        failUpload(upload, writeFailure(upload->fileName, GetLastError()));
        return;
    }

    upload->written += length;
    upload->fileRemaining -= length;
    if (upload->fileRemaining == 0) {
        finishFile(upload);
    } else if (upload->written - upload->acknowledged >= ACKNOWLEDGEMENT_INTERVAL) {
        acknowledgeUpload(upload);
    }
}

static void setFolderDates(Upload *upload) {
    for (size_t index = 0; index < upload->folderBuckets; index++) {
        for (ReceivedFolder *folder = upload->folders[index]; folder; folder = folder->next) {
            FILETIME time;
            if (folder->modified == 0 || !fileTimeFromUnix(folder->modified, &time)) continue;

            HANDLE handle = CreateFileW(folder->path, FILE_WRITE_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                                        NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
            if (handle == INVALID_HANDLE_VALUE || !SetFileTime(handle, NULL, NULL, &time)) {
                logMessage("Channel %u: couldn't set the modification date of %s (error %lu)", upload->channel, folder->key, GetLastError());
            }
            if (handle != INVALID_HANDLE_VALUE) CloseHandle(handle);
        }
    }
}

/* Moves the items into the destination, and replies with where they were put. */
static void finishUpload(Upload *upload) {
    if (upload->file != INVALID_HANDLE_VALUE) {
        failUpload(upload, formatText("The transfer ended before all of %s was received.", upload->fileName));
        return;
    }

    acknowledgeUpload(upload);
    setFolderDates(upload);

    wchar_t **placed = calloc(upload->itemCount ? upload->itemCount : 1, sizeof(wchar_t *));
    if (!placed) {
        failUpload(upload, NULL);
        return;
    }

    for (size_t index = 0; index < upload->itemCount; index++) {
        const TopItem *item = &upload->items[index];
        const wchar_t *name = wcsrchr(item->path, L'\\') + 1;
        placed[index] = placeItem(upload->destination, name, item->isFolder, item->path, NULL);
        if (placed[index]) continue;

        /* The items that were moved already are removed too, since the transfer failed. */
        char *message = pathFailure("Couldn't move %s to the desktop (error %lu).", item->path, GetLastError());
        for (size_t moved = 0; moved < index; moved++) {
            if (!removeItem(placed[moved])) logMessage("Channel %u: couldn't remove an item after the transfer failed (error %lu)", upload->channel, GetLastError());
            free(placed[moved]);
        }
        free(placed);
        failUpload(upload, message);
        return;
    }

    /* The reply can only be as long as a frame, which is enough for thousands of items. */
    Buffer reply = {0};
    for (size_t index = 0; index < upload->itemCount; index++) {
        char *shown = displayPath(placed[index]);
        size_t shownLength = shown ? strlen(shown) : 0;
        size_t separatorLength = reply.length > 0 ? 1 : 0;

        if (!shown || reply.length + separatorLength + shownLength > MAX_PAYLOAD
            || (separatorLength && !appendBytes(&reply, "\n", 1)) || !appendBytes(&reply, shown, shownLength)) {
            logMessage("Channel %u: couldn't say where all of the items were put", upload->channel);
            free(shown);
            break;
        }
        free(shown);
    }

    uint32_t channel = upload->channel;
    size_t itemCount = upload->itemCount;
    logMessage("Channel %u: received %zu items (%llu bytes)", channel, itemCount, (unsigned long long)upload->written);
    discardUpload(upload);
    sendFrame(FRAME_TRANSFERRED, channel, reply.bytes, (uint32_t)reply.length);

    for (size_t index = 0; index < itemCount; index++) free(placed[index]);
    free(placed);
    free(reply.bytes);
}

/* Cancels receiving files on the channel, if it's receiving them. */
static BOOL cancelUpload(uint32_t channel) {
    Upload *upload = findUpload(channel);
    if (!upload) return FALSE;

    failUpload(upload, formatText("Cancelled."));
    return TRUE;
}

/* MARK: - Transfers on threads of their own */

/*
 * Sending files from the guest and catching drags run on threads of their own, so that the thread that reads frames can go on
 * reading, including the acknowledgements that sending waits for. Each thread removes its transfer when it ends.
 */
typedef struct Transfer {
    uint32_t channel;
    HANDLE thread;
    /* Set when Hypervisaur acknowledges file data or the transfer is cancelled. */
    HANDLE wake;
    volatile LONG isCancelled;
    volatile LONG64 acknowledged;
    /* Whether a frame couldn't be sent, so that the transfer can't go on. Only used on the transfer's thread. */
    BOOL hasLostConnection;
    uint8_t *request;
    uint32_t requestLength;
    struct Transfer *next;
} Transfer;

static SRWLOCK transfersLock = SRWLOCK_INIT;
static Transfer *transfers;

static void freeTransfer(Transfer *transfer) {
    if (transfer->thread) CloseHandle(transfer->thread);
    if (transfer->wake) CloseHandle(transfer->wake);
    free(transfer->request);
    free(transfer);
}

static BOOL startTransfer(uint32_t channel, const uint8_t *payload, uint32_t length, LPTHREAD_START_ROUTINE routine) {
    Transfer *transfer = calloc(1, sizeof(Transfer));
    if (!transfer) {
        SetLastError(ERROR_NOT_ENOUGH_MEMORY);
        return FALSE;
    }

    transfer->channel = channel;
    transfer->request = malloc((size_t)length + 1);
    transfer->wake = CreateEventW(NULL, FALSE, FALSE, NULL);
    if (transfer->request) {
        if (length > 0) memcpy(transfer->request, payload, length);
        transfer->request[length] = 0;
        transfer->requestLength = length;
    }

    /* The thread starts once the transfer is in the list, since it removes itself from it. */
    if (transfer->request && transfer->wake) transfer->thread = CreateThread(NULL, 0, routine, transfer, CREATE_SUSPENDED, NULL);
    if (!transfer->thread) {
        DWORD error = transfer->request && transfer->wake ? GetLastError() : ERROR_NOT_ENOUGH_MEMORY;
        freeTransfer(transfer);
        SetLastError(error);
        return FALSE;
    }

    AcquireSRWLockExclusive(&transfersLock);
    transfer->next = transfers;
    transfers = transfer;
    ReleaseSRWLockExclusive(&transfersLock);

    ResumeThread(transfer->thread);
    return TRUE;
}

/* Called by a transfer's thread when it's done. */
static void endTransfer(Transfer *transfer) {
    AcquireSRWLockExclusive(&transfersLock);
    for (Transfer **link = &transfers; *link; link = &(*link)->next) {
        if (*link == transfer) {
            *link = transfer->next;
            break;
        }
    }
    ReleaseSRWLockExclusive(&transfersLock);

    freeTransfer(transfer);
}

static BOOL isTransferCancelled(Transfer *transfer) {
    return InterlockedCompareExchange(&transfer->isCancelled, 0, 0) != 0;
}

/* Sends a frame on the transfer's channel, unless it was cancelled. */
static BOOL sendOnTransfer(Transfer *transfer, uint8_t kind, const void *payload, uint32_t length) {
    if (isTransferCancelled(transfer)) return FALSE;
    if (sendFrameUnlessCancelled(&transfer->isCancelled, kind, transfer->channel, payload, length)) return TRUE;
    if (isTransferCancelled(transfer)) return FALSE;

    transfer->hasLostConnection = TRUE;
    return FALSE;
}

/* Replies `failed` on the transfer's channel, unless it was cancelled or the frame can't be sent, and frees the message. */
static void failTransfer(Transfer *transfer, char *message) {
    if (!isTransferCancelled(transfer) && !transfer->hasLostConnection) {
        const char *text = message ? message : OUT_OF_MEMORY;
        logMessage("Channel %u: %s", transfer->channel, text);
        sendOnTransfer(transfer, FRAME_FAILED, text, (uint32_t)strlen(text));
    }
    free(message);
}

/* Cancels a transfer while no frame is being sent, so that none is sent on its channel afterwards. */
static void markTransferCancelled(Transfer *transfer) {
    EnterCriticalSection(&writeLock);
    InterlockedExchange(&transfer->isCancelled, 1);
    LeaveCriticalSection(&writeLock);
    SetEvent(transfer->wake);
}

static void acknowledgeTransfer(uint32_t channel, const uint8_t *payload, uint32_t length) {
    if (length < 8) return;
    LONG64 value = (LONG64)getUInt64(payload);

    AcquireSRWLockShared(&transfersLock);
    for (Transfer *transfer = transfers; transfer; transfer = transfer->next) {
        if (transfer->channel != channel) continue;

        /* Acknowledgements only ever increase, even if they arrive out of order. */
        LONG64 current = InterlockedCompareExchange64(&transfer->acknowledged, 0, 0);
        while (value > current) {
            LONG64 previous = InterlockedCompareExchange64(&transfer->acknowledged, value, current);
            if (previous == current) break;
            current = previous;
        }
        SetEvent(transfer->wake);
        break;
    }
    ReleaseSRWLockShared(&transfersLock);
}

/* Cancels the transfer on the channel, if there is one. It stops without a reply. */
static BOOL cancelTransfer(uint32_t channel) {
    BOOL found = FALSE;
    AcquireSRWLockShared(&transfersLock);
    for (Transfer *transfer = transfers; transfer; transfer = transfer->next) {
        if (transfer->channel == channel) {
            markTransferCancelled(transfer);
            found = TRUE;
            break;
        }
    }
    ReleaseSRWLockShared(&transfersLock);
    return found;
}

/*
 * Cancels every transfer, and waits for them to stop, so that none of them sends anything once Hypervisaur has connected
 * again. Threads that are stuck reading a file, such as one that's being downloaded from OneDrive, have the read cancelled.
 */
static void stopAllTransfers(void) {
    while (uploads) discardUpload(uploads);

    AcquireSRWLockShared(&transfersLock);
    size_t count = 0;
    for (Transfer *transfer = transfers; transfer; transfer = transfer->next) count++;

    HANDLE *threads = count ? calloc(count, sizeof(HANDLE)) : NULL;
    size_t threadCount = 0;
    for (Transfer *transfer = transfers; transfer; transfer = transfer->next) {
        markTransferCancelled(transfer);
        if (threads && DuplicateHandle(GetCurrentProcess(), transfer->thread, GetCurrentProcess(), &threads[threadCount], 0, FALSE, DUPLICATE_SAME_ACCESS)) {
            threadCount++;
        }
    }
    ReleaseSRWLockShared(&transfersLock);

    if (count > 0 && threadCount < count) logMessage("Couldn't wait for %zu transfers to stop", count - threadCount);

    for (size_t index = 0; index < threadCount; index++) {
        if (WaitForSingleObject(threads[index], TRANSFER_STOP_TIMEOUT_MS) == WAIT_TIMEOUT) {
            CancelSynchronousIo(threads[index]);
            if (WaitForSingleObject(threads[index], TRANSFER_STOP_TIMEOUT_MS) == WAIT_TIMEOUT) logMessage("A transfer didn't stop when it was cancelled");
        }
        CloseHandle(threads[index]);
    }
    free(threads);
}

/* MARK: - Getting files from the guest */

/* A path that was asked for, with the name of its top-level item in the transfer. */
typedef struct {
    wchar_t *path;
    wchar_t *name;
    char *relative;
} Source;

typedef struct {
    BOOL isFolder;
    uint64_t size;
    int64_t modified;
    const wchar_t *path;
    const char *relative;
} Item;

/* Called for each item, folders before what's in them. Returns FALSE to stop, with a description in *error unless it was cancelled. */
typedef BOOL (*ItemHandler)(Transfer *transfer, const Item *item, void *context, char **error);

static void freeSources(Source *sources, size_t count) {
    for (size_t index = 0; index < count; index++) {
        free(sources[index].path);
        free(sources[index].name);
        free(sources[index].relative);
    }
    free(sources);
}

/* Adds a path that was asked for. Top-level items are given names such as `Name (2).ext` when two of them have the same name. */
static BOOL addSource(Source **sources, size_t *count, size_t *capacity, const char *line, size_t length, char **error) {
    int shownLength = (int)length;
    if (!isValidUTF8(line, length)) {
        *error = formatText("A path that was asked for isn't valid UTF-8.");
        return FALSE;
    }
    wchar_t *requested = wideFromUTF8(line, length);
    if (!requested) {
        *error = NULL;
        return FALSE;
    }
    for (wchar_t *character = requested; *character; character++) {
        if (*character == L'/') *character = L'\\';
    }

    BOOL isAbsolute = (requested[0] != 0 && requested[1] == L':' && requested[2] == L'\\') || (requested[0] == L'\\' && requested[1] == L'\\');
    const wchar_t *checked = hasPrefix(requested, L"\\\\?\\") ? requested + 4 : requested;
    wchar_t *path = isAbsolute && !wcspbrk(checked, L"*?") ? extendedPath(requested) : NULL;
    free(requested);
    if (!path) {
        *error = formatText("%.*s isn't an absolute path.", shownLength, line);
        return FALSE;
    }

    const wchar_t *component = lastComponent(path);
    if (!component) {
        free(path);
        *error = formatText("%.*s can't be sent, since it's a whole drive.", shownLength, line);
        return FALSE;
    }

    DWORD attributes = GetFileAttributesW(path);
    BOOL isFolder = attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_DIRECTORY);
    wchar_t *name = copyWide(component);
    for (unsigned number = 2; name && number <= MAX_NAME_ATTEMPTS; number++) {
        BOOL isUsed = FALSE;
        for (size_t index = 0; index < *count && !isUsed; index++) {
            isUsed = CompareStringOrdinal((*sources)[index].name, -1, name, -1, TRUE) == CSTR_EQUAL;
        }
        if (!isUsed) break;

        free(name);
        name = numberedName(component, number, isFolder);
    }
    char *relative = name ? utf8FromWide(name) : NULL;

    if (*count == *capacity) {
        size_t grownCapacity = *capacity ? *capacity * 2 : 8;
        Source *grown = relative ? realloc(*sources, grownCapacity * sizeof(Source)) : NULL;
        if (grown) {
            *sources = grown;
            *capacity = grownCapacity;
        }
    }
    if (!relative || *count == *capacity) {
        free(path);
        free(name);
        free(relative);
        *error = NULL;
        return FALSE;
    }

    (*sources)[*count].path = path;
    (*sources)[*count].name = name;
    (*sources)[*count].relative = relative;
    (*count)++;
    return TRUE;
}

/* Reads the paths that were asked for, one per line. Empty lines are ignored, and so are carriage returns at the ends of lines. */
static BOOL parseSources(const Transfer *transfer, Source **sources, size_t *count, char **error) {
    const char *request = (const char *)transfer->request;
    size_t length = transfer->requestLength, capacity = 0;
    *sources = NULL;
    *count = 0;

    for (size_t start = 0; start < length;) {
        const char *newline = memchr(request + start, '\n', length - start);
        size_t end = newline ? (size_t)(newline - request) : length;
        size_t lineLength = end - start;
        if (lineLength > 0 && request[start + lineLength - 1] == '\r') lineLength--;

        if (lineLength > 0 && !addSource(sources, count, &capacity, request + start, lineLength, error)) return FALSE;
        start = end + 1;
    }

    if (*count == 0) {
        *error = formatText("No files were asked for.");
        return FALSE;
    }
    return TRUE;
}

/* Symbolic links and junctions aren't sent. Other reparse points, such as OneDrive's files, are sent like any other item. */
static BOOL isLink(const WIN32_FIND_DATAW *data) {
    return (data->dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) && IsReparseTagNameSurrogate(data->dwReserved0);
}

static Item itemFromFindData(const WIN32_FIND_DATAW *data, const wchar_t *path, const char *relative) {
    Item item;
    item.isFolder = (data->dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
    item.size = item.isFolder ? 0 : (uint64_t)data->nFileSizeHigh << 32 | data->nFileSizeLow;
    item.modified = unixFromFileTime(data->ftLastWriteTime);
    item.path = path;
    item.relative = relative;
    return item;
}

/* Calls the handler for each item in a folder, and adds the folders in it to the stack. */
static BOOL walkFolder(Transfer *transfer, const PendingFolder *folder, PendingFolder **stack, ItemHandler handler, void *context, char **error) {
    wchar_t *pattern = joinPath(folder->path, L"*");
    if (!pattern) {
        *error = NULL;
        return FALSE;
    }

    WIN32_FIND_DATAW data;
    HANDLE find = FindFirstFileExW(pattern, FindExInfoBasic, &data, FindExSearchNameMatch, NULL, FIND_FIRST_EX_LARGE_FETCH);
    DWORD status = GetLastError();
    free(pattern);
    if (find == INVALID_HANDLE_VALUE) {
        if (status == ERROR_FILE_NOT_FOUND) return TRUE;
        *error = pathFailure("Couldn't read %s (error %lu).", folder->path, status);
        return FALSE;
    }

    BOOL succeeded = TRUE;
    do {
        if (isDotName(data.cFileName) || isLink(&data)) continue;
        if (isTransferCancelled(transfer)) {
            succeeded = FALSE;
            break;
        }

        wchar_t *path = joinPath(folder->path, data.cFileName);
        char *name = utf8FromWide(data.cFileName);
        char *relative = name ? formatText("%s/%s", folder->relative, name) : NULL;
        free(name);
        if (!path || !relative) {
            free(path);
            free(relative);
            *error = NULL;
            succeeded = FALSE;
            break;
        }

        Item item = itemFromFindData(&data, path, relative);
        succeeded = handler(transfer, &item, context, error);
        if (succeeded && item.isFolder) {
            PendingFolder *pending = malloc(sizeof(PendingFolder));
            if (pending) {
                pending->path = path;
                pending->relative = relative;
                pending->next = *stack;
                *stack = pending;
                path = NULL;
                relative = NULL;
            } else {
                *error = NULL;
                succeeded = FALSE;
            }
        }
        free(path);
        free(relative);
    } while (succeeded && FindNextFileW(find, &data));

    if (succeeded) {
        status = GetLastError();
        if (status != ERROR_NO_MORE_FILES) {
            *error = pathFailure("Couldn't read %s (error %lu).", folder->path, status);
            succeeded = FALSE;
        }
    }
    FindClose(find);
    return succeeded;
}

/* Calls the handler for a path that was asked for and everything in it. Folders are looked in without recursion, since they can be nested deeply. */
static BOOL walkSource(Transfer *transfer, const Source *source, ItemHandler handler, void *context, char **error) {
    WIN32_FIND_DATAW data;
    HANDLE find = FindFirstFileExW(source->path, FindExInfoBasic, &data, FindExSearchNameMatch, NULL, 0);
    if (find == INVALID_HANDLE_VALUE) {
        *error = pathFailure("Couldn't read %s (error %lu).", source->path, GetLastError());
        return FALSE;
    }
    FindClose(find);

    if (isLink(&data)) return TRUE;

    Item item = itemFromFindData(&data, source->path, source->relative);
    if (!handler(transfer, &item, context, error)) return FALSE;
    if (!item.isFolder) return TRUE;

    PendingFolder *stack = calloc(1, sizeof(PendingFolder));
    if (stack) {
        stack->path = copyWide(source->path);
        stack->relative = formatText("%s", source->relative);
    }
    if (!stack || !stack->path || !stack->relative) {
        freePendingFolders(stack);
        *error = NULL;
        return FALSE;
    }

    BOOL succeeded = TRUE;
    while (stack && succeeded) {
        PendingFolder *folder = stack;
        stack = folder->next;
        folder->next = NULL;
        succeeded = walkFolder(transfer, folder, &stack, handler, context, error);
        freePendingFolders(folder);
    }
    freePendingFolders(stack);
    return succeeded;
}

typedef struct {
    uint64_t size;
    uint64_t count;
} TransferTotals;

static BOOL countItem(Transfer *transfer, const Item *item, void *context, char **error) {
    (void)error;

    TransferTotals *totals = context;
    totals->size += item->size;
    totals->count++;
    return !isTransferCancelled(transfer);
}

typedef struct {
    uint8_t *buffer;
    uint64_t sent;
} Sender;

/* Waits until `count` more bytes can be sent without more than TRANSFER_WINDOW of them waiting to be acknowledged. */
static BOOL waitForAcknowledgements(Transfer *transfer, uint64_t sent, uint32_t count, char **error) {
    uint64_t acknowledged = (uint64_t)InterlockedCompareExchange64(&transfer->acknowledged, 0, 0);
    ULONGLONG lastProgress = GetTickCount64();

    while (sent + count > acknowledged + TRANSFER_WINDOW) {
        if (isTransferCancelled(transfer)) return FALSE;
        WaitForSingleObject(transfer->wake, 1000);

        uint64_t latest = (uint64_t)InterlockedCompareExchange64(&transfer->acknowledged, 0, 0);
        if (latest != acknowledged) {
            acknowledged = latest;
            lastProgress = GetTickCount64();
        } else if (GetTickCount64() - lastProgress >= ACKNOWLEDGEMENT_TIMEOUT_MS) {
            *error = formatText("Hypervisaur stopped receiving the files.");
            return FALSE;
        }
    }
    return !isTransferCancelled(transfer);
}

static BOOL sendItem(Transfer *transfer, const Item *item, void *context, char **error) {
    Sender *sender = context;

    /* Files are sent with the size they have when they're opened, in case they changed since they were counted. */
    HANDLE file = INVALID_HANDLE_VALUE;
    uint64_t size = 0;
    if (!item->isFolder) {
        file = CreateFileW(item->path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING, FILE_FLAG_SEQUENTIAL_SCAN, NULL);
        LARGE_INTEGER fileSize;
        if (file == INVALID_HANDLE_VALUE || !GetFileSizeEx(file, &fileSize)) {
            *error = pathFailure("Couldn't read %s (error %lu).", item->path, GetLastError());
            if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
            return FALSE;
        }
        size = (uint64_t)fileSize.QuadPart;
    }

    size_t relativeLength = strlen(item->relative);
    uint8_t *header = relativeLength <= MAX_PAYLOAD - FILE_HEADER_SIZE ? malloc(FILE_HEADER_SIZE + relativeLength) : NULL;
    if (!header) {
        *error = relativeLength > MAX_PAYLOAD - FILE_HEADER_SIZE ? pathFailure("The path of %s is too long to send (error %lu).", item->path, ERROR_FILENAME_EXCED_RANGE) : NULL;
        if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
        return FALSE;
    }

    header[0] = item->isFolder ? ITEM_FOLDER : ITEM_FILE;
    putUInt64(header + 1, size);
    /* Windows doesn't have POSIX permissions, so they're reported as unknown. */
    putUInt32(header + 9, 0);
    putUInt64(header + 13, (uint64_t)item->modified);
    memcpy(header + FILE_HEADER_SIZE, item->relative, relativeLength);
    BOOL succeeded = sendOnTransfer(transfer, FRAME_FILE_HEADER, header, (uint32_t)(FILE_HEADER_SIZE + relativeLength));
    free(header);

    uint64_t remaining = size;
    while (succeeded && remaining > 0) {
        DWORD count = remaining < FILE_CHUNK_SIZE ? (DWORD)remaining : FILE_CHUNK_SIZE;
        DWORD read = 0;

        if (!waitForAcknowledgements(transfer, sender->sent, count, error)) {
            succeeded = FALSE;
        } else if (!ReadFile(file, sender->buffer, count, &read, NULL)) {
            *error = pathFailure("Couldn't read %s (error %lu).", item->path, GetLastError());
            succeeded = FALSE;
        } else if (read == 0) {
            *error = pathFailure("%s got smaller while it was being sent (error %lu).", item->path, ERROR_HANDLE_EOF);
            succeeded = FALSE;
        } else {
            succeeded = sendOnTransfer(transfer, FRAME_FILE_DATA, sender->buffer, read);
            sender->sent += read;
            remaining -= read;
        }
    }

    if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
    return succeeded;
}

/*
 * Sends the files that were asked for: first the size of the transfer, which needs a pass to count them, then each item. If
 * a path can't be read, the agent replies `failed`, before anything else when it's found while they're counted.
 */
static DWORD WINAPI sendFiles(void *context) {
    Transfer *transfer = context;
    uint32_t channel = transfer->channel;
    Source *sources = NULL;
    size_t sourceCount = 0;
    TransferTotals totals = {0};
    Sender sender = {0};
    char *error = NULL;

    BOOL succeeded = parseSources(transfer, &sources, &sourceCount, &error);
    for (size_t index = 0; succeeded && index < sourceCount; index++) {
        succeeded = walkSource(transfer, &sources[index], countItem, &totals, &error);
    }
    if (succeeded && totals.count > UINT32_MAX) {
        error = formatText("There are too many items to send.");
        succeeded = FALSE;
    }

    if (succeeded) {
        sender.buffer = malloc(FILE_CHUNK_SIZE);
        uint8_t size[TRANSFER_SIZE_SIZE];
        putUInt64(size, totals.size);
        putUInt32(size + 8, (uint32_t)totals.count);
        succeeded = sender.buffer && sendOnTransfer(transfer, FRAME_TRANSFER_SIZE, size, sizeof(size));
    }
    for (size_t index = 0; succeeded && index < sourceCount; index++) {
        succeeded = walkSource(transfer, &sources[index], sendItem, &sender, &error);
    }
    if (succeeded) succeeded = sendOnTransfer(transfer, FRAME_FILES_END, NULL, 0);

    if (succeeded) {
        logMessage("Channel %u: sent %llu items (%llu bytes)", channel, (unsigned long long)totals.count, (unsigned long long)sender.sent);
        free(error);
    } else if (isTransferCancelled(transfer)) {
        logMessage("Channel %u: stopped sending files", channel);
        free(error);
    } else if (transfer->hasLostConnection) {
        logMessage("Channel %u: couldn't send the files to Hypervisaur", channel);
        free(error);
    } else {
        failTransfer(transfer, error);
    }

    freeSources(sources, sourceCount);
    free(sender.buffer);
    endTransfer(transfer);
    return 0;
}

/* MARK: - Catching drags */

/*
 * The service runs in session 0, which can't show windows on the user's desktop, so drags are caught by starting the agent
 * as the drag catcher in the session of the user signed in at the display. When a drag with files enters its window, it
 * prints them, one per line, then an empty line, and the agent replies with the lines it printed. The empty line says that
 * the list is complete, since the catcher keeps running until the drag is dropped on it.
 */

typedef struct {
    HANDLE pipe;
    Buffer bytes;
    /* Whether the output got larger than a frame, or there wasn't enough memory for it. */
    BOOL isTooLong;
    BOOL isComplete;
} HelperOutput;

/* Reads the drag catcher's output until the empty line that ends it, or until the catcher exits. */
static DWORD WINAPI readHelperOutput(void *context) {
    HelperOutput *output = context;
    char bytes[4096];
    DWORD count;
    uint64_t total = 0;
    char last = 0, beforeLast = 0;

    while (!output->isComplete && ReadFile(output->pipe, bytes, sizeof(bytes), &count, NULL) && count > 0) {
        /* Paths can't contain newlines, so two in a row, or one on its own, can only be the end. */
        for (DWORD index = 0; index < count && !output->isComplete; index++) {
            beforeLast = last;
            last = bytes[index];
            total++;
            output->isComplete = last == '\n' && (total == 1 || beforeLast == '\n');
        }

        /* The output can be two newlines longer than a frame, since they aren't sent. */
        if (output->isTooLong) continue;
        if (output->bytes.length + count > (size_t)MAX_PAYLOAD + 2 || !appendBytes(&output->bytes, bytes, count)) output->isTooLong = TRUE;
    }
    return 0;
}

static wchar_t *modulePath(void) {
    for (DWORD size = MAX_PATH; size <= 32768; size *= 2) {
        wchar_t *path = malloc((size_t)size * sizeof(wchar_t));
        if (!path) return NULL;

        DWORD length = GetModuleFileNameW(NULL, path, size);
        if (length > 0 && length < size) return path;
        free(path);
        if (length == 0) return NULL;
    }
    return NULL;
}

/* Starts the drag catcher in the session of the user signed in at the display, with a pipe for its output. */
static BOOL startDragCatcher(PROCESS_INFORMATION *process, HANDLE *output, char **error) {
    HANDLE token;
    if (!openConsoleUser(&token, error)) return FALSE;

    wchar_t *program = modulePath();
    size_t lineSize = program ? wcslen(program) + 32 : 0;
    wchar_t *line = program ? malloc(lineSize * sizeof(wchar_t)) : NULL;
    if (line) swprintf(line, lineSize, L"\"%ls\" dragcatcher", program);

    void *environment = NULL;
    if (token && !CreateEnvironmentBlock(&environment, token, FALSE)) {
        logMessage("Couldn't make the environment of the user signed in to Windows (error %lu)", GetLastError());
        environment = NULL;
    }

    AcquireSRWLockExclusive(&inheritanceLock);

    HANDLE readEnd = NULL, writeEnd = NULL;
    BOOL prepared = line && createPipe(&readEnd, &writeEnd, FALSE);

    /* The catcher only inherits its output, and not handles that other threads made inheritable to start programs of their own. */
    STARTUPINFOEXW startup = {0};
    startup.StartupInfo.cb = sizeof(startup);
    BOOL hasAttributes = FALSE;
    if (prepared) {
        SIZE_T attributesSize = 0;
        InitializeProcThreadAttributeList(NULL, 1, 0, &attributesSize);
        startup.lpAttributeList = malloc(attributesSize);
        hasAttributes = startup.lpAttributeList && InitializeProcThreadAttributeList(startup.lpAttributeList, 1, 0, &attributesSize);
        prepared = hasAttributes
            && UpdateProcThreadAttribute(startup.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, &writeEnd, sizeof(HANDLE), NULL, NULL);
    }

    wchar_t desktop[] = L"winsta0\\default";
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    startup.StartupInfo.hStdOutput = writeEnd;
    if (token) startup.StartupInfo.lpDesktop = desktop;

    /* The catcher doesn't have a console, which would start a console host that could keep a copy of its output. */
    DWORD flags = DETACHED_PROCESS | EXTENDED_STARTUPINFO_PRESENT | (environment ? CREATE_UNICODE_ENVIRONMENT : 0);
    BOOL started = FALSE;
    if (prepared) {
        started = token
            ? CreateProcessAsUserW(token, program, line, NULL, NULL, TRUE, flags, environment, NULL, &startup.StartupInfo, process)
            : CreateProcessW(program, line, NULL, NULL, TRUE, flags, NULL, NULL, &startup.StartupInfo, process);
    }
    DWORD status = prepared ? GetLastError() : (line ? GetLastError() : ERROR_NOT_ENOUGH_MEMORY);

    /* The catcher has its own copy of its output. */
    if (writeEnd) CloseHandle(writeEnd);
    ReleaseSRWLockExclusive(&inheritanceLock);

    if (hasAttributes) DeleteProcThreadAttributeList(startup.lpAttributeList);
    free(startup.lpAttributeList);
    if (environment) DestroyEnvironmentBlock(environment);
    if (token) CloseHandle(token);
    free(program);
    free(line);

    if (!started) {
        if (readEnd) CloseHandle(readEnd);
        *error = formatText("Couldn't start catching drags (error %lu).", status);
        return FALSE;
    }

    CloseHandle(process->hThread);
    process->hThread = NULL;
    *output = readEnd;
    return TRUE;
}

/*
 * Replies `dragItems` with the files that the drag catcher printed, or with nothing if it didn't print any before it exited or
 * before DRAG_HELPER_TIMEOUT_MS. Then it waits for the catcher to exit, which it does when the drag is dropped on it.
 */
static DWORD WINAPI catchDrag(void *context) {
    Transfer *transfer = context;
    uint32_t channel = transfer->channel;
    ULONGLONG deadline = GetTickCount64() + DRAG_HELPER_TIMEOUT_MS;
    PROCESS_INFORMATION process = {0};
    HelperOutput output = {0};
    char *error = NULL;

    if (!startDragCatcher(&process, &output.pipe, &error)) {
        failTransfer(transfer, error);
        endTransfer(transfer);
        return 0;
    }

    HANDLE reader = CreateThread(NULL, 0, readHelperOutput, &output, 0, NULL);
    DWORD readerError = reader ? ERROR_SUCCESS : GetLastError();
    BOOL hasOutput = FALSE;
    while (reader && !isTransferCancelled(transfer)) {
        ULONGLONG now = GetTickCount64();
        if (now >= deadline) break;

        HANDLE handles[] = { reader, transfer->wake };
        DWORD result = WaitForMultipleObjects(2, handles, FALSE, (DWORD)(deadline - now));
        if (result == WAIT_OBJECT_0) {
            hasOutput = TRUE;
            break;
        }
        if (result != WAIT_OBJECT_0 + 1) break;
    }

    /* Stopping the catcher closes its output, which ends the reader. */
    if (!hasOutput) {
        TerminateProcess(process.hProcess, 1);
        if (reader) WaitForSingleObject(reader, INFINITE);
    }

    if (isTransferCancelled(transfer)) {
        logMessage("Channel %u: stopped catching drags", channel);
    } else if (!reader) {
        failTransfer(transfer, formatText("Couldn't catch drags (error %lu).", readerError));
    } else if (!hasOutput) {
        logMessage("Channel %u: the drag catcher didn't finish in time", channel);
        sendOnTransfer(transfer, FRAME_DRAG_ITEMS, NULL, 0);
    } else if (!output.isComplete) {
        /* The catcher exited without printing anything, which it does when no drag with files entered it, unless it failed. */
        DWORD status = 1;
        WaitForSingleObject(process.hProcess, (DWORD)(deadline > GetTickCount64() ? deadline - GetTickCount64() : 0));
        if (!GetExitCodeProcess(process.hProcess, &status) || status != 0) {
            failTransfer(transfer, formatText("Couldn't catch drags in Windows (status %lu).", status));
        } else {
            sendOnTransfer(transfer, FRAME_DRAG_ITEMS, NULL, 0);
        }
    } else if (output.isTooLong) {
        failTransfer(transfer, formatText("Too many items are being dragged."));
    } else {
        /* The lines are sent without the newline after the last one, and the empty line that ended them. */
        size_t length = output.bytes.length;
        while (length > 0 && output.bytes.bytes[length - 1] == '\n') length--;
        sendOnTransfer(transfer, FRAME_DRAG_ITEMS, output.bytes.bytes, (uint32_t)length);
    }

    while (WaitForSingleObject(process.hProcess, 0) == WAIT_TIMEOUT && !isTransferCancelled(transfer)) {
        ULONGLONG now = GetTickCount64();
        if (now >= deadline) break;

        HANDLE handles[] = { process.hProcess, transfer->wake };
        WaitForMultipleObjects(2, handles, FALSE, (DWORD)(deadline - now));
    }
    if (WaitForSingleObject(process.hProcess, 0) == WAIT_TIMEOUT) {
        logMessage("Channel %u: stopping the drag catcher", channel);
        TerminateProcess(process.hProcess, 1);
    }

    if (reader) CloseHandle(reader);
    CloseHandle(process.hProcess);
    CloseHandle(output.pipe);
    free(output.bytes.bytes);
    endTransfer(transfer);
    return 0;
}

/* MARK: - Drag catcher */

/*
 * `HypervisaurAgent.exe dragcatcher` shows a nearly transparent window centred on the pointer that drags with files can be
 * dropped on. When one enters it, it prints each file, with `f` for a file or `d` for a folder, a tab, and its path in UTF-8,
 * one per line, then an empty line, and closes its output. It refuses the drop, so that the drag doesn't change anything, and exits.
 */

enum {
    TIMER_ENTER = 1,
    TIMER_LIMIT = 2,
};

typedef struct {
    IDropTarget target;
    LONG references;
    /* Whether the drag over the window has files, and whether they've been printed. */
    BOOL hasFiles;
    BOOL hasPrinted;
} DragCatcher;

static FORMATETC dropFormat = { CF_HDROP, NULL, DVASPECT_CONTENT, -1, TYMED_HGLOBAL };

static void printDraggedFiles(IDataObject *data) {
    Buffer lines = {0};
    STGMEDIUM medium;

    if (SUCCEEDED(data->lpVtbl->GetData(data, &dropFormat, &medium))) {
        HDROP drop = (HDROP)medium.hGlobal;
        UINT count = DragQueryFileW(drop, 0xFFFFFFFF, NULL, 0);

        for (UINT index = 0; index < count; index++) {
            UINT length = DragQueryFileW(drop, index, NULL, 0);
            wchar_t *path = length > 0 ? malloc(((size_t)length + 1) * sizeof(wchar_t)) : NULL;
            if (!path) continue;
            if (DragQueryFileW(drop, index, path, length + 1) == 0) {
                free(path);
                continue;
            }

            wchar_t *extended = extendedPath(path);
            DWORD attributes = GetFileAttributesW(extended ? extended : path);
            char *text = utf8FromWide(path);
            if (attributes != INVALID_FILE_ATTRIBUTES && text) {
                char kind[2] = { attributes & FILE_ATTRIBUTE_DIRECTORY ? 'd' : 'f', '\t' };
                appendBytes(&lines, kind, sizeof(kind));
                appendBytes(&lines, text, strlen(text));
                appendBytes(&lines, "\n", 1);
            }
            free(text);
            free(extended);
            free(path);
        }
        ReleaseStgMedium(&medium);
    }

    /* The empty line tells the agent that these are all of the files. The output is closed too, since nothing more is printed. */
    appendBytes(&lines, "\n", 1);
    HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE);
    if (output && output != INVALID_HANDLE_VALUE) {
        writeBytes(output, lines.bytes, (DWORD)lines.length);
        CloseHandle(output);
        SetStdHandle(STD_OUTPUT_HANDLE, NULL);
    }
    free(lines.bytes);
}

static HRESULT STDMETHODCALLTYPE catcherQueryInterface(IDropTarget *target, REFIID identifier, void **object) {
    if (!object) return E_POINTER;

    if (IsEqualIID(identifier, &unknownInterface) || IsEqualIID(identifier, &dropTargetInterface)) {
        *object = target;
        target->lpVtbl->AddRef(target);
        return S_OK;
    }
    *object = NULL;
    return E_NOINTERFACE;
}

/* The catcher is a static, so it isn't freed when it's released for the last time. */
static ULONG STDMETHODCALLTYPE catcherAddRef(IDropTarget *target) {
    return (ULONG)InterlockedIncrement(&((DragCatcher *)target)->references);
}

static ULONG STDMETHODCALLTYPE catcherRelease(IDropTarget *target) {
    return (ULONG)InterlockedDecrement(&((DragCatcher *)target)->references);
}

static HRESULT STDMETHODCALLTYPE catcherDragEnter(IDropTarget *target, IDataObject *data, DWORD keys, POINTL point, DWORD *effect) {
    (void)keys;
    (void)point;

    DragCatcher *catcher = (DragCatcher *)target;
    catcher->hasFiles = data && data->lpVtbl->QueryGetData(data, &dropFormat) == S_OK;
    if (catcher->hasFiles && !catcher->hasPrinted) {
        catcher->hasPrinted = TRUE;
        printDraggedFiles(data);
    }

    if (effect) *effect = catcher->hasFiles ? DROPEFFECT_COPY : DROPEFFECT_NONE;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE catcherDragOver(IDropTarget *target, DWORD keys, POINTL point, DWORD *effect) {
    (void)keys;
    (void)point;

    if (effect) *effect = ((DragCatcher *)target)->hasFiles ? DROPEFFECT_COPY : DROPEFFECT_NONE;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE catcherDragLeave(IDropTarget *target) {
    (void)target;
    return S_OK;
}

/* The drop is refused, so that the source of the drag does nothing. */
static HRESULT STDMETHODCALLTYPE catcherDrop(IDropTarget *target, IDataObject *data, DWORD keys, POINTL point, DWORD *effect) {
    (void)target;
    (void)data;
    (void)keys;
    (void)point;

    if (effect) *effect = DROPEFFECT_NONE;
    PostQuitMessage(0);
    return S_OK;
}

static IDropTargetVtbl catcherFunctions = {
    .QueryInterface = catcherQueryInterface,
    .AddRef = catcherAddRef,
    .Release = catcherRelease,
    .DragEnter = catcherDragEnter,
    .DragOver = catcherDragOver,
    .DragLeave = catcherDragLeave,
    .Drop = catcherDrop,
};

static DragCatcher catcher = { { &catcherFunctions }, 1, FALSE, FALSE };

static LRESULT CALLBACK catcherWindowProcedure(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
    switch (message) {
    case WM_TIMER:
        KillTimer(window, wParam);
        if (wParam == TIMER_LIMIT || !catcher.hasPrinted) PostQuitMessage(0);
        return 0;
    case WM_MOUSEACTIVATE:
        return MA_NOACTIVATE;
    default:
        return DefWindowProcW(window, message, wParam, lParam);
    }
}

static int runDragCatcher(void) {
    /* Nothing that the catcher starts, such as through OLE, keeps a copy of its output. */
    HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE);
    if (output && output != INVALID_HANDLE_VALUE) SetHandleInformation(output, HANDLE_FLAG_INHERIT, 0);

    if (FAILED(OleInitialize(NULL))) return 1;

    HINSTANCE instance = GetModuleHandleW(NULL);
    WNDCLASSW windowClass = {0};
    windowClass.lpfnWndProc = catcherWindowProcedure;
    windowClass.hInstance = instance;
    windowClass.hCursor = LoadCursorW(NULL, (LPCWSTR)IDC_ARROW);
    windowClass.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    windowClass.lpszClassName = L"HypervisaurDragCatcher";
    BOOL isRegistered = RegisterClassW(&windowClass) != 0;

    HWND window = NULL;
    POINT pointer;
    if (isRegistered && GetCursorPos(&pointer)) {
        window = CreateWindowExW(
            WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, windowClass.lpszClassName, L"Hypervisaur", WS_POPUP,
            pointer.x - DRAG_CATCHER_SIZE / 2, pointer.y - DRAG_CATCHER_SIZE / 2, DRAG_CATCHER_SIZE, DRAG_CATCHER_SIZE,
            NULL, NULL, instance, NULL
        );
    }

    /* Windows that are completely transparent don't get drops, so the window is almost transparent instead. */
    int status = 1;
    if (window && SetLayeredWindowAttributes(window, 0, 1, LWA_ALPHA) && SUCCEEDED(RegisterDragDrop(window, &catcher.target))) {
        ShowWindow(window, SW_SHOWNOACTIVATE);
        SetTimer(window, TIMER_ENTER, DRAG_ENTER_TIMEOUT_MS, NULL);
        SetTimer(window, TIMER_LIMIT, DRAG_TIMEOUT_MS, NULL);

        MSG message;
        while (GetMessageW(&message, NULL, 0, 0) > 0) {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }

        RevokeDragDrop(window);
        status = 0;
    }

    if (window) DestroyWindow(window);
    if (isRegistered) UnregisterClassW(windowClass.lpszClassName, instance);
    OleUninitialize();
    return status;
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
    Upload *upload;

    switch (kind) {
    case FRAME_RESET:
        logMessage("Hypervisaur connected");
        terminateAllSessions();
        stopAllTransfers();
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
        if (!cancelUpload(channel) && !cancelTransfer(channel)) withSession(channel, terminateSession, payload, length);
        break;
    case FRAME_PUT_FILES:
        startUpload(channel, payload, length);
        break;
    case FRAME_TRANSFER_SIZE:
        if ((upload = findUpload(channel))) receiveTransferSize(upload, payload, length);
        break;
    case FRAME_FILE_HEADER:
        if ((upload = findUpload(channel))) receiveHeader(upload, payload, length);
        break;
    case FRAME_FILE_DATA:
        if ((upload = findUpload(channel))) receiveData(upload, payload, length);
        break;
    case FRAME_FILES_END:
        if ((upload = findUpload(channel))) finishUpload(upload);
        break;
    case FRAME_GET_FILES:
        if (!startTransfer(channel, payload, length, sendFiles)) failOpen(channel, "Couldn't start sending the files");
        break;
    case FRAME_ACKNOWLEDGE:
        acknowledgeTransfer(channel, payload, length);
        break;
    case FRAME_CATCH_DRAG:
        if (!startTransfer(channel, payload, length, catchDrag)) failOpen(channel, "Couldn't start catching drags");
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
        while (!isStopping && !needsReopening) {
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

        /* Transfers can't go on without the port, since frames may have been lost. */
        stopAllTransfers();
        InterlockedExchange(&needsReopening, 0);
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
    /* `HypervisaurAgent.exe dragcatcher` is the drag catcher, which the agent starts in the signed-in user's session. It doesn't log, since the log is the service's. */
    if (argumentCount > 1 && wcscmp(arguments[1], L"dragcatcher") == 0) {
        return runDragCatcher();
    }

    InitializeCriticalSection(&logLock);
    InitializeCriticalSection(&writeLock);
    stopEvent = CreateEventW(NULL, TRUE, FALSE, NULL);
    openLog();

    /* `HypervisaurAgent.exe console` runs the agent without the service manager, for testing. */
    if (argumentCount > 1 && wcscmp(arguments[1], L"console") == 0) {
        isConsoleMode = TRUE;
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

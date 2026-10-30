/*
 * The network of a Windows virtual machine: libslirp's user networking, which QEMU connects to with a stream network device.
 *
 * QEMU's own user networking gives the guest the Mac's loopback interface at the host's address, 10.0.2.2, and at every
 * other address in its network that it doesn't use for something else, so a program in the guest could reach services on
 * the Mac that only accept connections from the Mac itself. QEMU has no option to stop that, but libslirp does, so this runs
 * libslirp with it, and with the same addresses as QEMU's user networking, which Windows has already been set up with.
 *
 *     HypervisaurNetwork <libslirp> <socket> [<address> <port> <command>]
 *
 * libslirp is loaded from Homebrew, where QEMU's package installs it. The network listens on the socket for QEMU to connect,
 * and exits when QEMU disconnects. With an address, a port and a command, each connection that the guest makes to the
 * address and port is served by the command, which reads and writes the connection on its standard input and output.
 */

#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include "libslirp/libslirp.h"

/* The largest frame QEMU sends over a stream network device, and so the largest it's expected to receive. */
#define MAX_FRAME_SIZE (4096 + 65536)

/* How much may wait to be sent to QEMU before frames are dropped, as a network card drops them when it has no room. */
#define MAX_PENDING_OUTPUT (4 * 1024 * 1024)

/* How long QEMU has to connect before the network gives up. Hypervisaur starts QEMU straight after the network. */
#define CONNECTION_TIMEOUT_MS 30000

static struct {
    __typeof__(slirp_new) *new;
    __typeof__(slirp_pollfds_fill_socket) *pollfdsFill;
    __typeof__(slirp_pollfds_poll) *pollfdsPoll;
    __typeof__(slirp_input) *input;
    __typeof__(slirp_handle_timer) *handleTimer;
    __typeof__(slirp_add_exec) *addExec;
} slirpFunctions;

typedef struct Timer {
    struct Timer *next;
    SlirpTimerId id;
    void *callbackOpaque;
    /* When the timer fires, in milliseconds on the network's clock, or -1 if it isn't set. */
    int64_t expiry;
} Timer;

typedef struct {
    Slirp *slirp;
    int qemu;
    Timer *timers;

    uint8_t *input;
    size_t inputLength;

    uint8_t *output;
    size_t outputLength;

    struct pollfd *pollfds;
    size_t pollfdCount;
    size_t pollfdCapacity;
} Network;

static void fail(const char *format, ...) __attribute__((format(printf, 1, 2), noreturn));

static void fail(const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    fputs("HypervisaurNetwork: ", stderr);
    vfprintf(stderr, format, arguments);
    fputc('\n', stderr);
    va_end(arguments);
    exit(EXIT_FAILURE);
}

static void *requireSymbol(void *library, const char *name) {
    void *symbol = dlsym(library, name);
    if (!symbol) fail("libslirp has no %s: %s", name, dlerror());
    return symbol;
}

static void loadSlirp(const char *path) {
    void *library = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!library) fail("Couldn't load libslirp: %s", dlerror());

    slirpFunctions.new = requireSymbol(library, "slirp_new");
    slirpFunctions.pollfdsFill = requireSymbol(library, "slirp_pollfds_fill_socket");
    slirpFunctions.pollfdsPoll = requireSymbol(library, "slirp_pollfds_poll");
    slirpFunctions.input = requireSymbol(library, "slirp_input");
    slirpFunctions.handleTimer = requireSymbol(library, "slirp_handle_timer");
    slirpFunctions.addExec = requireSymbol(library, "slirp_add_exec");
}

static int64_t clockNanoseconds(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (int64_t)now.tv_sec * 1000000000 + now.tv_nsec;
}

static int64_t clockMilliseconds(void) {
    return clockNanoseconds() / 1000000;
}

// MARK: - Sending to QEMU

/* Writes as much of what's waiting as QEMU takes without waiting for it. Returns false if QEMU has gone. */
static bool flushOutput(Network *network) {
    size_t written = 0;
    while (written < network->outputLength) {
        ssize_t count = write(network->qemu, network->output + written, network->outputLength - written);
        if (count < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN) break;
            return false;
        }
        written += (size_t)count;
    }
    memmove(network->output, network->output + written, network->outputLength - written);
    network->outputLength -= written;
    return true;
}

/* Each frame is sent with its length first, as four bytes in network order. */
static slirp_ssize_t sendPacket(const void *buffer, size_t length, void *opaque) {
    Network *network = opaque;
    if (length > MAX_FRAME_SIZE || network->outputLength + 4 + length > MAX_PENDING_OUTPUT) return (slirp_ssize_t)length;

    uint32_t header = htonl((uint32_t)length);
    memcpy(network->output + network->outputLength, &header, 4);
    memcpy(network->output + network->outputLength + 4, buffer, length);
    network->outputLength += 4 + length;

    if (!flushOutput(network)) fail("Couldn't send to QEMU: %s", strerror(errno));
    return (slirp_ssize_t)length;
}

// MARK: - Receiving from QEMU

/* Passes each whole frame that QEMU has sent to libslirp. Returns false once QEMU has disconnected. */
static bool receiveFrames(Network *network) {
    ssize_t count = read(network->qemu, network->input + network->inputLength, 4 + MAX_FRAME_SIZE - network->inputLength);
    if (count < 0) {
        if (errno == EINTR || errno == EAGAIN) return true;
        fail("Couldn't receive from QEMU: %s", strerror(errno));
    }
    if (count == 0) return false;
    network->inputLength += (size_t)count;

    size_t offset = 0;
    while (network->inputLength - offset >= 4) {
        uint32_t header;
        memcpy(&header, network->input + offset, 4);
        size_t length = ntohl(header);
        if (length > MAX_FRAME_SIZE) fail("QEMU sent a frame of %zu bytes", length);
        if (network->inputLength - offset - 4 < length) break;

        slirpFunctions.input(network->slirp, network->input + offset + 4, (int)length);
        offset += 4 + length;
    }
    memmove(network->input, network->input + offset, network->inputLength - offset);
    network->inputLength -= offset;
    return true;
}

// MARK: - libslirp's callbacks

/* QEMU only logs these when it's asked to log the guest's errors, which Hypervisaur doesn't ask for, so they aren't logged here either. */
static void guestError(const char *message, void *opaque) {
    (void)message;
    (void)opaque;
}

static int64_t clockGetNanoseconds(void *opaque) {
    (void)opaque;
    return clockNanoseconds();
}

static void *timerNew(SlirpTimerId id, void *callbackOpaque, void *opaque) {
    Network *network = opaque;
    Timer *timer = calloc(1, sizeof(Timer));
    if (!timer) fail("Out of memory");

    timer->id = id;
    timer->callbackOpaque = callbackOpaque;
    timer->expiry = -1;
    timer->next = network->timers;
    network->timers = timer;
    return timer;
}

static void timerFree(void *timer, void *opaque) {
    Network *network = opaque;
    for (Timer **link = &network->timers; *link; link = &(*link)->next) {
        if (*link == timer) {
            *link = ((Timer *)timer)->next;
            free(timer);
            return;
        }
    }
}

static void timerModify(void *timer, int64_t expiry, void *opaque) {
    (void)opaque;
    ((Timer *)timer)->expiry = expiry;
}

/* The loop polls every socket that libslirp has each time round, so it doesn't need to be told about them. */
static void registerPollSocket(slirp_os_socket socket, void *opaque) {
    (void)socket;
    (void)opaque;
}

static void unregisterPollSocket(slirp_os_socket socket, void *opaque) {
    (void)socket;
    (void)opaque;
}

static void notify(void *opaque) {
    (void)opaque;
}

static const SlirpCb callbacks = {
    .send_packet = sendPacket,
    .guest_error = guestError,
    .clock_get_ns = clockGetNanoseconds,
    .timer_free = timerFree,
    .timer_mod = timerModify,
    .notify = notify,
    .timer_new_opaque = timerNew,
    .register_poll_socket = registerPollSocket,
    .unregister_poll_socket = unregisterPollSocket,
};

// MARK: - Polling

static int addPoll(slirp_os_socket socket, int events, void *opaque) {
    Network *network = opaque;
    if (network->pollfdCount == network->pollfdCapacity) {
        size_t capacity = network->pollfdCapacity * 2;
        struct pollfd *pollfds = realloc(network->pollfds, capacity * sizeof(struct pollfd));
        if (!pollfds) fail("Out of memory");
        network->pollfds = pollfds;
        network->pollfdCapacity = capacity;
    }

    short pollEvents = 0;
    if (events & SLIRP_POLL_IN) pollEvents |= POLLIN;
    if (events & SLIRP_POLL_OUT) pollEvents |= POLLOUT;
    if (events & SLIRP_POLL_PRI) pollEvents |= POLLPRI;

    network->pollfds[network->pollfdCount] = (struct pollfd){ .fd = socket, .events = pollEvents };
    return (int)network->pollfdCount++;
}

static int getEvents(int index, void *opaque) {
    Network *network = opaque;
    short events = network->pollfds[index].revents;

    int slirpEvents = 0;
    if (events & POLLIN) slirpEvents |= SLIRP_POLL_IN;
    if (events & POLLOUT) slirpEvents |= SLIRP_POLL_OUT;
    if (events & POLLPRI) slirpEvents |= SLIRP_POLL_PRI;
    if (events & (POLLERR | POLLNVAL)) slirpEvents |= SLIRP_POLL_ERR;
    if (events & POLLHUP) slirpEvents |= SLIRP_POLL_HUP;
    return slirpEvents;
}

/* How long until the next timer fires, in milliseconds, or UINT32_MAX if none is set. */
static uint32_t timeUntilNextTimer(Network *network) {
    int64_t now = clockMilliseconds();
    uint32_t timeout = UINT32_MAX;
    for (Timer *timer = network->timers; timer; timer = timer->next) {
        if (timer->expiry < 0) continue;
        int64_t remaining = timer->expiry - now;
        if (remaining <= 0) return 0;
        if (remaining < timeout) timeout = (uint32_t)remaining;
    }
    return timeout;
}

/* Fires the timers that are due. A timer that fires can change the timers, so the list is looked through again after each. */
static void fireTimers(Network *network) {
    bool fired;
    do {
        fired = false;
        int64_t now = clockMilliseconds();
        for (Timer *timer = network->timers; timer; timer = timer->next) {
            if (timer->expiry < 0 || timer->expiry > now) continue;
            timer->expiry = -1;
            slirpFunctions.handleTimer(network->slirp, timer->id, timer->callbackOpaque);
            fired = true;
            break;
        }
    } while (fired);
}

static void run(Network *network) {
    for (;;) {
        network->pollfdCount = 0;
        short qemuEvents = POLLIN | (network->outputLength > 0 ? POLLOUT : 0);
        network->pollfds[network->pollfdCount++] = (struct pollfd){ .fd = network->qemu, .events = qemuEvents };

        uint32_t timeout = timeUntilNextTimer(network);
        slirpFunctions.pollfdsFill(network->slirp, &timeout, addPoll, network);

        int result = poll(network->pollfds, (nfds_t)network->pollfdCount, timeout == UINT32_MAX ? -1 : (int)(timeout > INT_MAX ? INT_MAX : timeout));
        if (result < 0 && errno != EINTR) fail("Couldn't poll: %s", strerror(errno));

        short qemuResult = result > 0 ? network->pollfds[0].revents : 0;
        slirpFunctions.pollfdsPoll(network->slirp, result < 0, getEvents, network);

        if (qemuResult & POLLOUT) {
            if (!flushOutput(network)) fail("Couldn't send to QEMU: %s", strerror(errno));
        }
        if (qemuResult & (POLLIN | POLLHUP | POLLERR)) {
            if (!receiveFrames(network)) return;
        }

        fireTimers(network);
    }
}

// MARK: - Setting up

/*
 * The socket is made under another name and renamed once it's listening, so that it only appears once QEMU can connect to it.
 */
static int listenForQEMU(const char *path) {
    struct sockaddr_un address = { .sun_family = AF_UNIX };
    char temporaryPath[sizeof(address.sun_path)];
    if (snprintf(temporaryPath, sizeof(temporaryPath), "%s.new", path) >= (int)sizeof(temporaryPath)) fail("The socket's path is too long: %s", path);
    strcpy(address.sun_path, temporaryPath);

    int listener = socket(AF_UNIX, SOCK_STREAM, 0);
    if (listener < 0) fail("Couldn't make a socket: %s", strerror(errno));

    unlink(temporaryPath);
    if (bind(listener, (struct sockaddr *)&address, sizeof(address)) != 0) fail("Couldn't make %s: %s", temporaryPath, strerror(errno));
    if (chmod(temporaryPath, 0600) != 0 || listen(listener, 1) != 0 || rename(temporaryPath, path) != 0) {
        int error = errno;
        unlink(temporaryPath);
        fail("Couldn't listen on %s: %s", path, strerror(error));
    }
    return listener;
}

/* Only the first connection is taken, and the socket is then removed, since QEMU only connects once. */
static int acceptQEMU(int listener, const char *path) {
    struct pollfd pollfd = { .fd = listener, .events = POLLIN };
    int result;
    do {
        result = poll(&pollfd, 1, CONNECTION_TIMEOUT_MS);
    } while (result < 0 && errno == EINTR);
    if (result == 0) fail("QEMU didn't connect");
    if (result < 0) fail("Couldn't wait for QEMU: %s", strerror(errno));

    int connection = accept(listener, NULL, NULL);
    if (connection < 0) fail("Couldn't accept QEMU's connection: %s", strerror(errno));
    close(listener);
    unlink(path);

    if (fcntl(connection, F_SETFL, fcntl(connection, F_GETFL) | O_NONBLOCK) != 0) fail("Couldn't set up QEMU's connection: %s", strerror(errno));
    return connection;
}

/* The same network as QEMU's user networking, apart from the Mac's loopback interface. */
static Slirp *makeSlirp(Network *network) {
    SlirpConfig configuration = {
        .version = 6,
        .in_enabled = true,
        .in6_enabled = true,
        .vprefix_len = 64,
        .disable_host_loopback = true,
    };
    inet_pton(AF_INET, "10.0.2.0", &configuration.vnetwork);
    inet_pton(AF_INET, "255.255.255.0", &configuration.vnetmask);
    inet_pton(AF_INET, "10.0.2.2", &configuration.vhost);
    inet_pton(AF_INET, "10.0.2.15", &configuration.vdhcp_start);
    inet_pton(AF_INET, "10.0.2.3", &configuration.vnameserver);
    inet_pton(AF_INET6, "fec0::", &configuration.vprefix_addr6);
    inet_pton(AF_INET6, "fec0::2", &configuration.vhost6);
    inet_pton(AF_INET6, "fec0::3", &configuration.vnameserver6);

    Slirp *slirp = slirpFunctions.new(&configuration, &callbacks, network);
    if (!slirp) fail("libslirp couldn't make the network. It needs to be version 4.9 or later");
    return slirp;
}

static void addForward(Network *network, const char *addressString, const char *portString, const char *command) {
    struct in_addr address;
    if (inet_pton(AF_INET, addressString, &address) != 1) fail("Not an IPv4 address: %s", addressString);

    char *end;
    long port = strtol(portString, &end, 10);
    if (*portString == 0 || *end != 0 || port < 1 || port > 65535) fail("Not a port: %s", portString);

    if (slirpFunctions.addExec(network->slirp, command, &address, (int)port) != 0) fail("Couldn't forward %s:%ld", addressString, port);
}

int main(int argc, const char *argv[]) {
    if (argc != 3 && argc != 6) {
        fprintf(stderr, "Usage: HypervisaurNetwork <libslirp> <socket> [<address> <port> <command>]\n");
        return EXIT_FAILURE;
    }

    signal(SIGPIPE, SIG_IGN);
    loadSlirp(argv[1]);

    Network network = {
        .input = malloc(4 + MAX_FRAME_SIZE),
        .output = malloc(MAX_PENDING_OUTPUT),
        .pollfdCapacity = 64,
    };
    network.pollfds = malloc(network.pollfdCapacity * sizeof(struct pollfd));
    if (!network.input || !network.output || !network.pollfds) fail("Out of memory");

    network.slirp = makeSlirp(&network);
    if (argc == 6) addForward(&network, argv[3], argv[4], argv[5]);

    int listener = listenForQEMU(argv[2]);
    network.qemu = acceptQEMU(listener, argv[2]);

    run(&network);
    return EXIT_SUCCESS;
}

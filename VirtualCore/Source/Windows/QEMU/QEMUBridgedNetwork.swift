import Foundation
import Darwin
import OSLog
import vmnet

/// Connects a network device of a Windows virtual machine to one of the Mac's network interfaces with vmnet's bridged mode,
/// so that Windows joins that interface's network as a computer of its own.
///
/// Bridging needs the `com.apple.vm.networking` entitlement, which QEMU from Homebrew doesn't have, so QEMU connects the device
/// to a stream network device instead, as it does for NAT, and this passes frames between that connection and vmnet in
/// Hypervisaur's process. Each frame is sent over the connection with its length first, as four bytes in network order.
///
/// The connection to QEMU stays open while the device is bridged to another interface, or bridged again. Frames are dropped
/// while it isn't bridged to any, as a network card drops them while its cable is unplugged.
///
/// Its work happens on a queue of its own, so its methods can be called from anywhere. ``close()`` must be called once it's
/// no longer needed.
final class QEMUBridgedNetwork: @unchecked Sendable {
    /// The largest frame QEMU sends over a stream network device, and so the largest it's expected to receive.
    private static let maxFrameSize = 4096 + 65536
    /// How much may wait to be sent to QEMU before frames are dropped, as a network card drops them when it has no room.
    private static let maxPendingOutput = 4 * 1024 * 1024
    /// How long QEMU has to connect. Hypervisaur starts QEMU straight after its networks.
    private static let connectionTimeout = DispatchTimeInterval.seconds(30)
    /// How many packets are read from vmnet at once.
    private static let readBatchSize = 64

    let socketURL: URL
    private let queue: DispatchQueue
    private let logger: Logger

    private let listener: Int32
    private var listenerSource: DispatchSourceRead?
    private var connectionTimer: DispatchSourceTimer?

    private var qemu: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var isWriteSourceSuspended = false

    private let input: UnsafeMutableRawPointer
    private var inputLength = 0
    private let output: UnsafeMutableRawPointer
    private var outputLength = 0

    private var interface: interface_ref?
    private var interfaceIdentifier: String?
    /// The largest packet the interface takes or gives, which vmnet says once the interface has started.
    private var maxPacketSize = 0
    /// Where packets are read from vmnet into, with room for ``readBatchSize`` of them.
    private var packetBuffer: UnsafeMutableRawPointer?
    /// vmnet failures are only logged once for each interface, since they'd otherwise be logged for every packet.
    private var didLogInterfaceFailure = false
    /// Increases each time the device is bridged to an interface or disconnected, so that an interface that started for a
    /// request that has since been overtaken isn't used.
    private var generation = 0
    private var isClosed = false

    /// Starts listening for QEMU on the socket, which appears once QEMU can connect to it. The device isn't bridged to an
    /// interface until ``connect(toInterface:)`` is called.
    init(socketURL: URL, logger: Logger) throws {
        let listener = try Self.listen(at: socketURL)

        self.socketURL = socketURL
        self.logger = logger
        self.listener = listener
        self.queue = DispatchQueue(label: "Hypervisaur.QEMUBridgedNetwork", qos: .userInitiated)
        self.input = .allocate(byteCount: 4 + Self.maxFrameSize, alignment: 4)
        self.output = .allocate(byteCount: Self.maxPendingOutput, alignment: 4)

        let listenerSource = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        listenerSource.setEventHandler { [weak self] in
            self?.acceptQEMU()
        }
        listenerSource.setCancelHandler {
            Darwin.close(listener)
        }
        self.listenerSource = listenerSource

        let connectionTimer = DispatchSource.makeTimerSource(queue: queue)
        connectionTimer.schedule(deadline: .now() + Self.connectionTimeout)
        connectionTimer.setEventHandler { [weak self] in
            guard let self else { return }
            logger.error("QEMU didn’t connect to the bridged network at \(socketURL.path, privacy: .public)")
            closeOnQueue()
        }
        self.connectionTimer = connectionTimer

        listenerSource.activate()
        connectionTimer.activate()
    }

    deinit {
        input.deallocate()
        output.deallocate()
        packetBuffer?.deallocate()
    }

    /// Bridges the device to the Mac's network interface with the identifier, such as `en0`, instead of the one it's bridged
    /// to now. Throws if vmnet can't bridge to it, which leaves the device disconnected.
    func connect(toInterface identifier: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.replaceInterface(with: identifier) { continuation.resume(with: $0) }
            }
        }
    }

    /// Stops bridging the device to an interface, so that its frames are dropped until it's connected again.
    func disconnect() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.replaceInterface(with: nil) { _ in continuation.resume() }
            }
        }
    }

    /// Stops bridging, and closes the connection to QEMU or stops waiting for it.
    func close() {
        queue.async {
            self.closeOnQueue()
        }
    }

    // MARK: - Connecting to QEMU

    /// The socket is made under another name and renamed once it's listening, so that it only appears once QEMU can connect to it.
    private static func listen(at socketURL: URL) throws -> Int32 {
        let path = socketURL.path
        let temporaryPath = path + ".new"

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        guard temporaryPath.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw Failure("The network socket’s path is too long: \(path)")
        }

        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: temporaryPath.utf8)
            buffer[temporaryPath.utf8.count] = 0
        }

        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError.current }

        _ = fcntl(listener, F_SETFD, FD_CLOEXEC)
        unlink(temporaryPath)

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bound == 0,
              chmod(temporaryPath, 0o600) == 0,
              Darwin.listen(listener, 1) == 0,
              fcntl(listener, F_SETFL, fcntl(listener, F_GETFL) | O_NONBLOCK) == 0,
              rename(temporaryPath, path) == 0
        else {
            let error = POSIXError.current
            Darwin.close(listener)
            unlink(temporaryPath)
            throw error
        }

        return listener
    }

    /// Only the first connection is taken, and the socket is then removed, since QEMU only connects once.
    private func acceptQEMU() {
        let connection = accept(listener, nil, nil)
        guard connection >= 0 else {
            guard errno != EAGAIN, errno != EINTR else { return }
            logger.error("Couldn’t accept QEMU’s connection to the bridged network: \(String(cString: strerror(errno)), privacy: .public)")
            closeOnQueue()
            return
        }

        stopListening()

        var noSigPipe: Int32 = 1
        guard fcntl(connection, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(connection, F_SETFL, fcntl(connection, F_GETFL) | O_NONBLOCK) == 0,
              setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size)) == 0
        else {
            logger.error("Couldn’t set up QEMU’s connection to the bridged network: \(String(cString: strerror(errno)), privacy: .public)")
            Darwin.close(connection)
            closeOnQueue()
            return
        }

        qemu = connection

        /// The descriptor is closed once both sources that use it have been cancelled.
        let closer = DescriptorCloser(descriptor: connection, users: 2)

        let readSource = DispatchSource.makeReadSource(fileDescriptor: connection, queue: queue)
        readSource.setEventHandler { [weak self] in
            self?.receiveFromQEMU()
        }
        readSource.setCancelHandler {
            closer.userFinished()
        }

        let writeSource = DispatchSource.makeWriteSource(fileDescriptor: connection, queue: queue)
        writeSource.setEventHandler { [weak self] in
            self?.flushOutput()
        }
        writeSource.setCancelHandler {
            closer.userFinished()
        }

        self.readSource = readSource
        self.writeSource = writeSource

        readSource.activate()
        writeSource.activate()
        writeSource.suspend()
        isWriteSourceSuspended = true

        logger.info("QEMU connected to the bridged network")
    }

    private func stopListening() {
        connectionTimer?.cancel()
        connectionTimer = nil

        guard let listenerSource else { return }

        listenerSource.cancel()
        self.listenerSource = nil
        unlink(socketURL.path)
    }

    // MARK: - Receiving from QEMU

    /// Passes each whole frame that QEMU has sent to the interface.
    private func receiveFromQEMU() {
        guard qemu >= 0 else { return }

        let count = read(qemu, input + inputLength, 4 + Self.maxFrameSize - inputLength)
        guard count != 0 else {
            logger.info("QEMU disconnected from the bridged network")
            closeOnQueue()
            return
        }
        guard count > 0 else {
            guard errno != EAGAIN, errno != EINTR else { return }
            logger.error("Couldn’t receive from QEMU: \(String(cString: strerror(errno)), privacy: .public)")
            closeOnQueue()
            return
        }

        inputLength += count

        var frames = [iovec]()
        var offset = 0
        while inputLength - offset >= 4 {
            let length = Int(UInt32(bigEndian: (input + offset).loadUnaligned(as: UInt32.self)))
            guard length <= Self.maxFrameSize else {
                logger.error("QEMU sent a frame of \(length) bytes to the bridged network")
                closeOnQueue()
                return
            }
            guard inputLength - offset - 4 >= length else { break }

            frames.append(iovec(iov_base: input + offset + 4, iov_len: length))
            offset += 4 + length
        }

        sendToInterface(&frames)

        memmove(input, input + offset, inputLength - offset)
        inputLength -= offset
    }

    private func sendToInterface(_ frames: inout [iovec]) {
        guard let interface, !frames.isEmpty else { return }

        /// The interface can't take frames larger than its packets, so they're dropped, as the network would drop them.
        frames.removeAll { $0.iov_len > maxPacketSize }
        guard !frames.isEmpty else { return }

        let status = frames.withUnsafeMutableBufferPointer { frames -> vmnet_return_t in
            guard let base = frames.baseAddress else { return .VMNET_SUCCESS }

            var packets = (0..<frames.count).map { index in
                vmpktdesc(vm_pkt_size: frames[index].iov_len, vm_pkt_iov: base + index, vm_pkt_iovcnt: 1, vm_flags: 0)
            }
            var count = Int32(packets.count)

            return vmnet_write(interface, &packets, &count)
        }

        if status != .VMNET_SUCCESS {
            logInterfaceFailure("Couldn’t send to the bridged interface: \(Self.describe(status))")
        }
    }

    // MARK: - Sending to QEMU

    /// Passes the packets that the interface has received to QEMU.
    private func receiveFromInterface(_ eventInterface: interface_ref) {
        guard let interface, interface == eventInterface, let packetBuffer else { return }

        let batchSize = Self.readBatchSize
        let maxPacketSize = maxPacketSize

        while true {
            var buffers = (0..<batchSize).map { index in
                iovec(iov_base: packetBuffer + index * maxPacketSize, iov_len: maxPacketSize)
            }
            var count = Int32(batchSize)

            let status = buffers.withUnsafeMutableBufferPointer { buffers -> vmnet_return_t in
                guard let base = buffers.baseAddress else { return .VMNET_SUCCESS }

                var packets = (0..<batchSize).map { index in
                    vmpktdesc(vm_pkt_size: maxPacketSize, vm_pkt_iov: base + index, vm_pkt_iovcnt: 1, vm_flags: 0)
                }

                let status = vmnet_read(interface, &packets, &count)
                guard status == .VMNET_SUCCESS else { return status }

                for index in 0..<Int(count) {
                    if let packet = base[index].iov_base {
                        enqueueForQEMU(packet, length: packets[index].vm_pkt_size)
                    }
                }
                return status
            }

            guard status == .VMNET_SUCCESS else {
                logInterfaceFailure("Couldn’t receive from the bridged interface: \(Self.describe(status))")
                break
            }

            /// vmnet gives fewer packets than were asked for once there are no more waiting.
            guard count == batchSize else { break }
        }

        flushOutput()
    }

    /// Frames are dropped until QEMU has connected, and while too much is waiting to be sent to it.
    private func enqueueForQEMU(_ packet: UnsafeRawPointer, length: Int) {
        guard qemu >= 0,
              length <= Self.maxFrameSize,
              outputLength + 4 + length <= Self.maxPendingOutput
        else { return }

        (output + outputLength).storeBytes(of: UInt32(length).bigEndian, as: UInt32.self)
        (output + outputLength + 4).copyMemory(from: packet, byteCount: length)
        outputLength += 4 + length
    }

    /// Writes as much of what's waiting as QEMU takes without waiting for it, and waits until it can take more if it's left over.
    private func flushOutput() {
        guard qemu >= 0 else { return }

        var written = 0
        while written < outputLength {
            let count = write(qemu, output + written, outputLength - written)
            if count >= 0 {
                written += count
            } else if errno == EAGAIN {
                break
            } else if errno != EINTR {
                logger.error("Couldn’t send to QEMU: \(String(cString: strerror(errno)), privacy: .public)")
                closeOnQueue()
                return
            }
        }

        memmove(output, output + written, outputLength - written)
        outputLength -= written

        guard let writeSource else { return }

        if outputLength > 0, isWriteSourceSuspended {
            writeSource.resume()
            isWriteSourceSuspended = false
        } else if outputLength == 0, !isWriteSourceSuspended {
            writeSource.suspend()
            isWriteSourceSuspended = true
        }
    }

    // MARK: - The Interface

    private func replaceInterface(with identifier: String?, completion: @escaping (Result<Void, Error>) -> Void) {
        guard !isClosed else {
            completion(.failure(Failure("The bridged network has stopped.")))
            return
        }

        generation += 1
        let generation = generation

        /// A new interface is only started once the previous one has stopped, since vmnet may not share an interface with
        /// two at once.
        stopInterface { [weak self] in
            guard let self else { return }

            guard generation == self.generation, !isClosed else {
                completion(.failure(CancellationError()))
                return
            }

            guard let identifier else {
                completion(.success(()))
                return
            }

            startInterface(identifier, generation: generation, completion: completion)
        }
    }

    private func startInterface(_ identifier: String, generation: Int, completion: @escaping (Result<Void, Error>) -> Void) {
        let description = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(description, vmnet_operation_mode_key, UInt64(operating_modes_t.VMNET_BRIDGED_MODE.rawValue))
        xpc_dictionary_set_string(description, vmnet_shared_interface_name_key, identifier)
        /// Windows uses the MAC address that its network device has, which is the one set in the virtual machine's settings.
        xpc_dictionary_set_bool(description, vmnet_allocate_mac_address_key, false)

        let started = StartedInterface()
        let queue = queue

        started.reference = vmnet_start_interface(description, queue) { [weak self] status, parameters in
            guard let interface = started.reference else { return }

            guard status == .VMNET_SUCCESS else {
                completion(.failure(Failure("Couldn’t bridge to the network interface “\(identifier)”: \(Self.describe(status)).")))
                return
            }

            guard let self, generation == self.generation, !isClosed else {
                _ = vmnet_stop_interface(interface, queue) { _ in }
                completion(.failure(CancellationError()))
                return
            }

            let maxPacketSize = Self.maxPacketSize(from: parameters)
            guard maxPacketSize > 0 else {
                _ = vmnet_stop_interface(interface, queue) { _ in }
                completion(.failure(Failure("Couldn’t bridge to the network interface “\(identifier)”: vmnet didn’t say how large its packets are.")))
                return
            }

            self.interface = interface
            self.interfaceIdentifier = identifier
            self.maxPacketSize = maxPacketSize
            self.packetBuffer = .allocate(byteCount: maxPacketSize * Self.readBatchSize, alignment: 16)
            self.didLogInterfaceFailure = false

            let callbackStatus = vmnet_interface_set_event_callback(interface, .VMNET_INTERFACE_PACKETS_AVAILABLE, queue) { [weak self] _, _ in
                self?.receiveFromInterface(interface)
            }
            guard callbackStatus == .VMNET_SUCCESS else {
                stopInterface { }
                completion(.failure(Failure("Couldn’t receive from the network interface “\(identifier)”: \(Self.describe(callbackStatus)).")))
                return
            }

            logger.info("Bridged to \(identifier, privacy: .public), packets of up to \(maxPacketSize) bytes")
            completion(.success(()))
        }

        if started.reference == nil {
            completion(.failure(Failure("Couldn’t bridge to the network interface “\(identifier)”. Check that Hypervisaur is allowed to use bridged networking.")))
        }
    }

    /// Stops the interface that the device is bridged to, if any, and calls `completion` on the queue once it has stopped.
    private func stopInterface(completion: @escaping () -> Void) {
        guard let interface else {
            completion()
            return
        }

        let identifier = interfaceIdentifier ?? "?"

        self.interface = nil
        interfaceIdentifier = nil
        packetBuffer?.deallocate()
        packetBuffer = nil
        maxPacketSize = 0

        _ = vmnet_interface_set_event_callback(interface, .VMNET_INTERFACE_PACKETS_AVAILABLE, nil, nil)

        let logger = logger
        let status = vmnet_stop_interface(interface, queue) { status in
            if status != .VMNET_SUCCESS {
                logger.error("Couldn’t stop bridging to \(identifier, privacy: .public): \(Self.describe(status), privacy: .public)")
            }
            completion()
        }

        if status != .VMNET_SUCCESS {
            logger.error("Couldn’t stop bridging to \(identifier, privacy: .public): \(Self.describe(status), privacy: .public)")
            completion()
        }
    }

    private static func maxPacketSize(from parameters: xpc_object_t?) -> Int {
        guard let parameters else { return 0 }
        return Int(xpc_dictionary_get_uint64(parameters, vmnet_max_packet_size_key))
    }

    private func logInterfaceFailure(_ message: String) {
        guard !didLogInterfaceFailure else { return }
        didLogInterfaceFailure = true
        logger.error("\(message, privacy: .public)")
    }

    private static func describe(_ status: vmnet_return_t) -> String {
        switch status {
        case .VMNET_SUCCESS: "it succeeded"
        case .VMNET_FAILURE: "vmnet failed"
        case .VMNET_MEM_FAILURE: "vmnet ran out of memory"
        case .VMNET_INVALID_ARGUMENT: "it isn’t an interface that can be bridged to"
        case .VMNET_SETUP_INCOMPLETE: "vmnet hasn’t finished setting up the interface"
        case .VMNET_INVALID_ACCESS: "Hypervisaur isn’t allowed to use bridged networking"
        case .VMNET_PACKET_TOO_BIG: "a packet was too large"
        case .VMNET_BUFFER_EXHAUSTED: "vmnet has no room for more packets"
        case .VMNET_TOO_MANY_PACKETS: "there were too many packets at once"
        case .VMNET_SHARING_SERVICE_BUSY: "the interface is already being shared"
        case .VMNET_NOT_AUTHORIZED: "Hypervisaur isn’t authorized to use bridged networking"
        @unknown default: "vmnet error \(status.rawValue)"
        }
    }

    // MARK: - Closing

    private func closeOnQueue() {
        guard !isClosed else { return }
        isClosed = true
        generation += 1

        stopListening()
        stopInterface { }

        qemu = -1
        if let writeSource {
            /// A suspended source can't finish being cancelled.
            if isWriteSourceSuspended {
                writeSource.resume()
                isWriteSourceSuspended = false
            }
            writeSource.cancel()
        }
        readSource?.cancel()
        writeSource = nil
        readSource = nil

        inputLength = 0
        outputLength = 0
    }
}

/// Holds the interface that vmnet returns when it's asked to start one, for the handler that it calls once it has started.
private final class StartedInterface: @unchecked Sendable {
    var reference: interface_ref?
}

/// Closes a descriptor once everything that uses it has finished with it.
private final class DescriptorCloser: @unchecked Sendable {
    private let descriptor: Int32
    private var users: Int
    private let lock = NSLock()

    init(descriptor: Int32, users: Int) {
        self.descriptor = descriptor
        self.users = users
    }

    func userFinished() {
        lock.lock()
        users -= 1
        let isLast = users == 0
        lock.unlock()

        if isLast {
            Darwin.close(descriptor)
        }
    }
}

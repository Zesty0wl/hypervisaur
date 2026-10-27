import Foundation
import Darwin

/// Finds the process that runs a virtual machine, and reads how much processor time and memory it has used.
///
/// Virtualization runs each virtual machine in an XPC service process of its own, and QEMU runs each one in its own process,
/// but neither says which process belongs to which virtual machine. The process that has files open in a virtual machine's
/// bundle, such as its disk images, is the one that runs it.
enum VMProcessInspector {
    struct Sample: Sendable {
        /// Processor time used since the process started, counting each core separately.
        var processorTime: Duration
        /// Memory used, as Activity Monitor shows it.
        var memoryFootprint: UInt64
        /// Bytes read from and written to disk since the process started.
        var diskBytes: UInt64
    }

    private static let virtualizationServiceName = "com.apple.Virtualization.VirtualMachine"
    private static let qemuNamePrefix = "qemu-system-"

    /// Processes that could be running a virtual machine.
    static func candidateProcesses() -> [pid_t] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }

        /// Room for processes that start between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }

        return pids.prefix(Int(count)).filter { pid in
            guard pid > 0, let name = executablePath(of: pid)?.split(separator: "/").last else { return false }
            return name == virtualizationServiceName || name.hasPrefix(qemuNamePrefix)
        }
    }

    /// The process among `candidates` that has a file open inside the bundle.
    static func process(forBundleAt bundleURL: URL, among candidates: [pid_t]) -> pid_t? {
        let bundlePath = canonicalPath(of: bundleURL)
        let prefix = bundlePath.hasSuffix("/") ? bundlePath : bundlePath + "/"
        return candidates.first { hasFileOpen(withPrefix: prefix, in: $0) }
    }

    /// The path as the system reports it for open files. Unlike `resolvingSymlinksInPath()`, this keeps the `/private`
    /// that paths such as `/var` and `/tmp` really start with.
    private static func canonicalPath(of url: URL) -> String {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path, let resolved = realpath(path, nil) else { return url.path(percentEncoded: false) }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }

    /// Whether the process still has a file open inside the bundle, which stops being true when it exits and its identifier is reused.
    static func isProcess(_ pid: pid_t, runningBundleAt bundleURL: URL) -> Bool {
        process(forBundleAt: bundleURL, among: [pid]) != nil
    }

    static func sample(_ pid: pid_t) -> Sample? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return nil }

        let ticks = info.ri_user_time + info.ri_system_time
        let nanoseconds = ticks * UInt64(timebase.numer) / UInt64(timebase.denom)
        return Sample(
            processorTime: .nanoseconds(Int64(clamping: nanoseconds)),
            memoryFootprint: info.ri_phys_footprint,
            diskBytes: info.ri_diskio_bytesread &+ info.ri_diskio_byteswritten
        )
    }

    /// Processor times are counted in ticks of the system clock, which aren't nanoseconds on Apple silicon.
    private static let timebase: mach_timebase_info_data_t = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return timebase
    }()

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func hasFileOpen(withPrefix prefix: String, in pid: pid_t) -> Bool {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return false }

        let stride = MemoryLayout<proc_fdinfo>.stride
        /// Room for files that are opened between the two calls.
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 16)
        let filled = descriptors.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return false }

        for descriptor in descriptors.prefix(Int(filled) / stride) where descriptor.proc_fdtype == PROX_FDTYPE_VNODE {
            var info = vnode_fdinfowithpath()
            let length = proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, Int32(MemoryLayout<vnode_fdinfowithpath>.size))
            guard length > 0 else { continue }

            let path = withUnsafeBytes(of: info.pvip.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if path.hasPrefix(prefix) { return true }
        }

        return false
    }
}

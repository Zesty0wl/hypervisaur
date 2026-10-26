import Foundation

/// Describes how QEMU is launched for a Windows virtual machine.
struct QEMULaunchConfiguration {
    struct RuntimePaths {
        var monitorSocket: URL
        var displaySocket: URL
        var tpmSocket: URL
        var agentSocket: URL

        /// Stands in for the sockets' locations, which are different each time QEMU starts.
        static let placeholder = RuntimePaths(
            monitorSocket: URL(fileURLWithPath: "/$RUNTIME/qmp.sock"),
            displaySocket: URL(fileURLWithPath: "/$RUNTIME/vnc.sock"),
            tpmSocket: URL(fileURLWithPath: "/$RUNTIME/tpm.sock"),
            agentSocket: URL(fileURLWithPath: "/$RUNTIME/agent.sock")
        )
    }

    enum DisplayAdapter: String, Codable, Equatable, Sendable {
        /// A framebuffer that the firmware and Windows can use without drivers, at a fixed size.
        case framebuffer
        /// A virtio GPU, which Windows can only use with its driver. Windows uses the size it has when Windows starts.
        case virtioGPU
    }

    var model: VBVirtualMachine
    var toolchain: QEMUToolchain
    var runtimePaths: RuntimePaths
    var installDiskURL: URL?
    var driversDiskURL: URL?
    var displayAdapter = DisplayAdapter.framebuffer
    /// The machine type, which is pinned to the version a saved session was saved with when restoring it.
    var machineType = Self.defaultMachineType
    /// Whether QEMU waits for a saved session's state to be loaded through its monitor instead of booting.
    ///
    /// QEMU starts with the same devices as when it boots, even though the sound device was unplugged before the state was
    /// saved. QEMU adds a USB hub when a device takes the last free port, so the devices only end up on the same ports as
    /// when the state was saved if the sound device is plugged in at first, and unplugged before the state is loaded.
    var restoresSavedState = false

    /// QEMU's current version of the machine type.
    static let defaultMachineType = "virt"

    /// The size of the virtio GPU's display when Windows starts.
    static let virtioGPUDisplaySizeRange = (width: 640...7680, height: 480...4320)

    /// The port that the SPICE agent in the guest looks for.
    static let spiceAgentPortName = "com.redhat.spice.0"

    /// The port that the Hypervisaur agent in the guest looks for, which runs programs there for the Mac.
    static let guestAgentPortName = "hypervisaur.agent"

    func arguments() throws -> [String] {
        let configuration = model.configuration
        let hardware = configuration.hardware

        var arguments = [
            "-name", "\(model.name.qemuOptionEscaped),debug-threads=on",
            /// A virtual machine must not outlive the app, for example if it crashes. swtpm exits by itself when QEMU does.
            "-run-with", "exit-with-parent=on",
            "-nodefaults",
            "-machine", machineType,
            "-accel", "hvf",
            "-cpu", "host",
            "-smp", "\(hardware.cpuCount)",
            "-m", "\(hardware.memorySize / .storageMegabyte)M",
            "-rtc", "base=localtime",
            /// Skips the firmware's countdown before it boots.
            "-boot", "menu=on,splash-time=0",
            "-drive", "if=pflash,format=raw,readonly=on,file=\(toolchain.firmwareCodeURL.path.qemuOptionEscaped)",
            "-drive", "if=pflash,format=raw,file=\(model.windowsEFIVariablesURL.path.qemuOptionEscaped)",
            "-device", displayDeviceArgument,
            "-device", "qemu-xhci,id=xhci",
            "-device", "usb-kbd,bus=xhci.0",
            "-device", "usb-tablet,bus=xhci.0",
            "-chardev", "socket,id=tpmchr,path=\(runtimePaths.tpmSocket.path.qemuOptionEscaped)",
            "-tpmdev", "emulator,id=tpm0,chardev=tpmchr",
            /// The physical presence interface is a RAM region that isn't aligned to the host page size, which the Hypervisor framework rejects.
            "-device", "tpm-tis-device,tpmdev=tpm0,ppi=off",
        ]

        arguments += try storageArguments()
        arguments += try networkArguments()
        arguments += audioArguments()

        /// The installer disk comes after the boot disk so that Windows Setup lists the boot disk first, and the firmware
        /// only boots from it while the boot disk is empty. It's writable because Windows Setup doesn't recognize
        /// the installer on a disk that rejects writes.
        if let installDiskURL {
            arguments += [
                "-drive", "if=none,id=installer,format=raw,file=\(installDiskURL.path.qemuOptionEscaped),cache=writeback",
                "-device", "nvme,drive=installer,serial=VBINSTALLER,bootindex=1",
            ]
        }

        /// Hypervisaur replaces the drivers disk while Windows is shut down. When Windows resumes with Fast Startup, it assumes
        /// that its disks haven't changed, and goes on using what it remembers of them. It checks removable disks again, so the
        /// drivers disk is a removable USB drive. It's read-only, since Windows only reads it, so that nothing can be written over it.
        if let driversDiskURL {
            arguments += [
                "-drive", "if=none,id=drivers,format=raw,file=\(driversDiskURL.path.qemuOptionEscaped),readonly=on",
                "-device", "usb-storage,bus=xhci.0,drive=drivers,removable=on",
            ]
        }

        /// QEMU empties the status file when it starts. See ``WindowsGuestStatus``.
        arguments += [
            "-device", "virtio-serial-pci,id=vbserial",
            "-chardev", "file,id=vbstatus,path=\(model.windowsGuestStatusURL.path.qemuOptionEscaped)",
            "-device", "virtserialport,bus=vbserial.0,chardev=vbstatus,name=\(WindowsGuestStatus.portName)",
            /// Hypervisaur connects to the agent's port through this socket once QEMU has started.
            "-chardev", "socket,id=vbagent,path=\(runtimePaths.agentSocket.path.qemuOptionEscaped),server=on,wait=off",
            "-device", "virtserialport,bus=vbserial.0,chardev=vbagent,name=\(Self.guestAgentPortName)",
            "-pidfile", model.qemuPIDFileURL.path,
        ]

        /// The SPICE agent in the guest shares its clipboard through this port, which QEMU relays to the display connection.
        if model.configuration.clipboardSharingEnabled {
            arguments += [
                "-chardev", "qemu-vdagent,id=vdagent,clipboard=on",
                "-device", "virtserialport,bus=vbserial.0,chardev=vdagent,name=\(Self.spiceAgentPortName)",
            ]
        }

        arguments += [
            "-display", "none",
            "-vnc", "unix:\(runtimePaths.displaySocket.path.qemuOptionEscaped)",
            "-qmp", "unix:\(runtimePaths.monitorSocket.path.qemuOptionEscaped),server=on,wait=off",
            /// The guest starts once the display is connected, so that nothing that's shown during boot is missed.
            "-S",
        ]

        if restoresSavedState {
            arguments += ["-incoming", "defer"]
        }

        return arguments
    }

    /// QEMU's arguments for booting the virtual machine, without anything that's allowed to change between runs: where the
    /// virtual machine and QEMU's sockets are, and its name. A saved session can only be restored with the same arguments.
    func comparableArguments() throws -> [String] {
        var configuration = self
        configuration.runtimePaths = .placeholder
        configuration.machineType = Self.defaultMachineType
        configuration.restoresSavedState = false

        let bundlePath = model.bundleURL.path
        var arguments = try configuration.arguments().map { argument in
            argument
                .replacingOccurrences(of: bundlePath.qemuOptionEscaped, with: "$BUNDLE")
                .replacingOccurrences(of: bundlePath, with: "$BUNDLE")
        }

        if let index = arguments.firstIndex(of: "-name"), arguments.indices.contains(index + 1) {
            arguments[index + 1] = "$NAME"
        }

        return arguments
    }

    private var displayDeviceArgument: String {
        switch displayAdapter {
        case .framebuffer:
            return "ramfb"
        case .virtioGPU:
            let display = model.configuration.hardware.displayDevices.first ?? .windowsDisplay
            let widthRange = Self.virtioGPUDisplaySizeRange.width
            let heightRange = Self.virtioGPUDisplaySizeRange.height
            let width = min(max(display.width, widthRange.lowerBound), widthRange.upperBound)
            let height = min(max(display.height, heightRange.lowerBound), heightRange.upperBound)
            return "virtio-gpu-pci,xres=\(width),yres=\(height)"
        }
    }

    /// The firmware boots from the devices with a boot index, in order, and doesn't try to boot from anything else,
    /// such as the network or the drivers disk.
    private func storageArguments() throws -> [String] {
        var arguments = [String]()

        let devices = model.configuration.hardware.storageDevices
            .filter(\.isEnabled)
            .sorted { $0.isBootVolume && !$1.isBootVolume }

        for (index, device) in devices.enumerated() {
            if case .managedImage(let image) = device.backing, image.format != .raw {
                throw Failure("The disk image “\(device.displayName)” uses the \(image.format.displayName) format, which Windows virtual machines can’t use. Use a raw image instead.")
            }

            let url = model.diskImageURL(for: device)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw Failure("The disk image “\(device.displayName)” doesn’t exist at \(url.path).")
            }

            let driveID = "disk\(index)"
            var drive = "if=none,id=\(driveID),format=raw,file=\(url.path.qemuOptionEscaped),cache=writeback,discard=unmap,detect-zeroes=unmap"
            if device.isReadOnly { drive += ",readonly=on" }

            arguments += ["-drive", drive]

            let bootIndex = index == 0 && device.isBootVolume ? ",bootindex=0" : ""

            if device.isUSBMassStorageDevice {
                arguments += ["-device", "usb-storage,bus=xhci.0,drive=\(driveID),removable=on\(bootIndex)"]
            } else {
                arguments += ["-device", "nvme,drive=\(driveID),serial=\(Self.serialNumber(for: device))\(bootIndex)"]
            }
        }

        return arguments
    }

    private func networkArguments() throws -> [String] {
        var arguments = [String]()

        for (index, device) in model.configuration.hardware.networkDevices.enumerated() {
            guard device.kind == .NAT else {
                throw Failure("Windows virtual machines only support NAT networking. Change the network device “\(device.name)” to NAT in the virtual machine’s settings.")
            }

            let netdevID = "net\(index)"
            arguments += [
                "-netdev", "user,id=\(netdevID)",
                "-device", "virtio-net-pci,netdev=\(netdevID),mac=\(device.macAddress.lowercased())",
            ]
        }

        return arguments
    }

    /// Whether the virtual machine has a sound device.
    static func hasSoundDevice(_ model: VBVirtualMachine) -> Bool {
        model.configuration.hardware.soundDevices.contains(where: \.enableOutput)
    }

    /// The sound device's properties for plugging it in with QEMU's `device_add` command. It can't be saved with a session,
    /// so it's unplugged before saving, and plugged in again when the guest resumes.
    static var soundDeviceProperties: [String: Any] {
        ["driver": "usb-audio", "id": soundDeviceID, "bus": "xhci.0", "audiodev": "audio0"]
    }

    static let soundDeviceID = "sound0"

    private func audioArguments() -> [String] {
        guard Self.hasSoundDevice(model) else { return [] }

        return [
            "-audiodev", "coreaudio,id=audio0",
            "-device", "usb-audio,id=\(Self.soundDeviceID),bus=xhci.0,audiodev=audio0",
        ]
    }

    /// NVMe serial numbers are limited to 20 characters.
    private static func serialNumber(for device: VBStorageDevice) -> String {
        let characters = device.id.uppercased().filter { $0.isLetter || $0.isNumber }
        return "VB" + String(characters.prefix(18))
    }
}

private extension String {
    /// Commas separate options in QEMU arguments, so they're escaped by doubling them.
    var qemuOptionEscaped: String {
        replacingOccurrences(of: ",", with: ",,")
    }
}

import Foundation
import Virtualization

/// The object that's executing a virtual machine, which depends on the engine used for its guest type.
public enum VMRuntime {
    case virtualization(VZVirtualMachine)
    case qemu(QEMUVirtualMachine)
}

public extension VMRuntime {
    var virtualMachine: VZVirtualMachine? {
        guard case .virtualization(let vm) = self else { return nil }
        return vm
    }

    var qemuMachine: QEMUVirtualMachine? {
        guard case .qemu(let machine) = self else { return nil }
        return machine
    }
}

/// Lifecycle shared by the engines that can run a virtual machine for ``VMController``.
@MainActor
protocol VMEngineInstance: AnyObject {
    var options: VMSessionOptions { get set }
    var virtualMachineModel: VBVirtualMachine { get }
    var effectiveModel: VBVirtualMachine { get }
    var isRecoveryBoot: Bool { get }
    var isGuestAppConnectedPublisher: Published<Bool>.Publisher { get }

    /// The runtime along with whether it's currently paused, or `nil` if nothing is running.
    var currentRuntime: (runtime: VMRuntime, isPaused: Bool)? { get }

    var activeBridgeInterfaceIdentifiers: Set<String> { get }
    var hasBridgedNetworkAttachments: Bool { get }

    func startVM() async throws
    func pause() async throws
    func resume() async throws
    func stop() async throws
    func forceStop() async throws
    func reconnectNetwork() throws
    func changeBridgeInterface(to interfaceIdentifier: String) throws
    func stopGuestCommunication() async
}

extension VMInstance: VMEngineInstance {
    var isGuestAppConnectedPublisher: Published<Bool>.Publisher { $isGuestAppConnected }

    var currentRuntime: (runtime: VMRuntime, isPaused: Bool)? {
        guard let vm = try? virtualMachine else { return nil }

        switch vm.state {
        case .running: return (.virtualization(vm), false)
        case .paused: return (.virtualization(vm), true)
        default: return nil
        }
    }
}

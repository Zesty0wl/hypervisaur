import Foundation
import Combine
import VirtualWormhole
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

    /// The connection to the Hypervisaur agent in the guest, while the virtual machine runs.
    var guestAgentConnection: GuestAgentConnection? { get }

    /// What the agent in the guest says about itself, or `nil` while it isn't connected.
    var guestAgentInfoPublisher: AnyPublisher<GuestAgentInfo?, Never> { get }

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

/// What an engine does to save a virtual machine's session and restore it, for ``VMController``.
/// See ``SavedSessionStorage`` for how the saved session is stored.
@MainActor
protocol VMSessionSavingInstance: VMEngineInstance {
    /// What's known about whether the session can be saved from how the virtual machine is actually running.
    var runtimeSaveEligibility: SavedSessionEligibility { get }

    /// Pauses the virtual machine if it's running.
    /// - Returns: `true` if the virtual machine was running, `false` if it was already paused.
    func pauseForSaving() async throws -> Bool
    /// Describes everything that has to be captured for the virtual machine's session. Called while the virtual machine is paused.
    func makeSavedSessionCapturePlan(wasPausedBeforeSave: Bool) async throws -> SavedSessionCapturePlan
    /// Writes the paused virtual machine's memory and device state to the file.
    func saveMachineState(to url: URL) async throws
    /// Stops the virtual machine once its session has been saved and releases it.
    func tearDownAfterSave() async throws
    /// Releases a virtual machine that's no longer needed, without reporting that it stopped.
    func releaseStoppedVirtualMachine() async
    /// Starts the virtual machine from a saved session and leaves it paused.
    /// - Parameter onConstructed: Called once the virtual machine exists, before its state is restored.
    func restoreSession(_ preparation: SavedSessionRestorePreparation, onConstructed: (VMRuntime) -> Void) async throws
    /// Resumes a virtual machine whose state was restored.
    func resumeRestoredSession() async throws
    /// Reconnects what was disconnected for saving, when a virtual machine whose session was saved couldn't be stopped
    /// and carries on instead.
    func restartGuestCommunication() async
}

extension VMInstance: VMSessionSavingInstance { }

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

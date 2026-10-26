import Foundation
import Testing
@testable import VirtualCore

@MainActor
struct WindowsDisplayResolutionTests {
    @Test func commandSwitchesToTheResolutionAndReportsHowItWent() {
        let command = WindowsDisplayResolution.command(width: 3840, height: 2160)
        let lines = command.components(separatedBy: "\n")

        #expect(lines.contains("$wanted = '3840x2160'"))
        #expect(command.contains("exit [Hypervisaur.Display]::Switch(3840, 2160)"))

        for outcome in [WindowsDisplayResolution.Outcome.switched, .alreadySet, .nobodySignedIn, .didNotSwitch] {
            #expect(command.contains("exit \(outcome.rawValue)"))
        }
    }

    /// PowerShell only ends a here-string at a line that starts with its closing quote.
    @Test func hereStringsEndAtTheStartOfALine() {
        let lines = WindowsDisplayResolution.command(width: 1920, height: 1200).components(separatedBy: "\n")

        #expect(lines.contains("$switch = @'"))
        #expect(lines.contains("'@"))
        #expect(lines.contains("Add-Type -TypeDefinition @\""))
        #expect(lines.contains("\"@"))
    }

    @Test func resolutionsArentOfferedBeyondWhatTheVirtioGPUSupports() {
        let size = QEMULaunchConfiguration.virtioGPUDisplaySize(for: VBDisplayDevice(width: 10_000, height: 100))

        #expect(size.width == QEMULaunchConfiguration.virtioGPUDisplaySizeRange.width.upperBound)
        #expect(size.height == QEMULaunchConfiguration.virtioGPUDisplaySizeRange.height.lowerBound)
    }
}

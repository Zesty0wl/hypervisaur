//
//  RestoreImageDownloadView.swift
//  VirtualUI
//
//  Created by Guilherme Rambo on 20/07/22.
//

import SwiftUI
import VirtualCore
import Combine

struct RestoreImageDownloadView: View {
    @EnvironmentObject var viewModel: VMInstallationViewModel
    @State private var downloadState = DownloadState.idle

    private var progress: Double? {
        switch downloadState {
        case .idle, .preCheck: 0
        case .failed: nil
        case .downloading(let progress): progress?.fractionCompleted ?? 0
        case .done: 1
        }
    }

    private var status: Text {
        switch downloadState {
        case .idle: Text("Preparing Download")
        case .preCheck(let message): Text(message)
        case .downloading(let progress): progress.map { Text(Self.description(of: $0)) } ?? Text("Downloading")
        case .done: Text("Done!")
        case .failed(let message): Text(message)
        }
    }

    private var style: VirtualBuddyMonoStyle {
        switch downloadState {
        case .idle, .downloading, .preCheck: .default
        case .failed: .failure
        case .done: .success
        }
    }

    var body: some View {
        VirtualBuddyMonoProgressView(
            progress: progress,
            status: status,
            style: style
        )
        .onReceive(viewModel.$downloadState) { downloadState = $0 }
    }

    /// Such as "1.2 GB of 4.1 GB", then "52.3 MB/s, 1 min, 5 sec left" on the next line.
    private static func description(of progress: DownloadProgress) -> String {
        let completed = progress.completedBytes.formatted(.byteCount(style: .file))
        let amount = progress.totalBytes.map { "\(completed) of \($0.formatted(.byteCount(style: .file)))" } ?? completed

        guard let bytesPerSecond = progress.bytesPerSecond else { return amount }

        let speed = "\(Int64(bytesPerSecond).formatted(.byteCount(style: .file)))/s"

        guard let remaining = progress.estimatedTimeRemaining else { return "\(amount)\n\(speed)" }

        let timeLeft = Duration.seconds(remaining.rounded()).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)
        )

        return "\(amount)\n\(speed), \(timeLeft) left"
    }
}

#if DEBUG
#Preview {
    VMInstallationWizard.preview(step: .download)
}
#endif

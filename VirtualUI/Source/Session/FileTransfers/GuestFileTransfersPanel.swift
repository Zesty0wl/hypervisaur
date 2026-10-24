import SwiftUI
import VirtualCore

/// What a virtual machine's window shows about copying files: where dropped files go while they're dragged over it, and the
/// copies in progress.
struct GuestFileTransferOverlays: View {
    @ObservedObject var center: GuestFileTransferCenter
    var guestName: String

    var body: some View {
        ZStack(alignment: .bottom) {
            if let target = center.dropTarget {
                GuestFileDropHighlight(target: target, guestName: guestName)
            }

            if !center.transfers.isEmpty {
                GuestFileTransfersPanel(center: center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.snappy, value: center.dropTarget)
    }
}

/// Shows the copies of files to and from a virtual machine at the bottom of its window, with their progress and speed.
struct GuestFileTransfersPanel: View {
    @ObservedObject var center: GuestFileTransferCenter

    var body: some View {
        VStack(spacing: 8) {
            ForEach(center.transfers) { transfer in
                GuestFileTransferRow(transfer: transfer) {
                    center.dismiss(transfer)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: 440)
        .padding(14)
    }
}

private struct GuestFileTransferRow: View {
    @ObservedObject var transfer: GuestFileTransfer
    var dismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            icon
                .font(.system(size: 22))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 5) {
                Text(transfer.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if transfer.state == .running || transfer.state == .finished {
                    ProgressView(value: transfer.fractionCompleted ?? 0)
                        .progressViewStyle(.linear)
                        .opacity(transfer.fractionCompleted == nil ? 0.4 : 1)
                }

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                if transfer.state == .running {
                    transfer.cancel()
                } else {
                    dismiss()
                }
            } label: {
                Image(systemName: transfer.state == .running ? "xmark.circle.fill" : "xmark")
                    .font(.system(size: transfer.state == .running ? 16 : 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(transfer.state == .running ? "Stop Copying" : "Dismiss")
            .accessibilityLabel(transfer.state == .running ? "Stop Copying" : "Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.12))
        }
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .animation(.snappy, value: transfer.state)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var icon: some View {
        switch transfer.state {
        case .running:
            Image(systemName: transfer.isToGuest ? "arrow.down.doc" : "arrow.up.doc")
                .foregroundStyle(Color.accentColor)
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
        case .cancelled:
            Image(systemName: "xmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    private var detail: String {
        switch transfer.state {
        case .finished:
            let size = transfer.totalBytes.map { "\($0.formatted(.byteCount(style: .file))) copied" } ?? "Copied"
            return transfer.isToGuest ? "\(size) to the desktop" : size
        case .cancelled:
            return "Stopped"
        case .failed(let message):
            return message
        case .running:
            guard let total = transfer.totalBytes else { return "Preparing…" }

            var parts = ["\(transfer.completedBytes.formatted(.byteCount(style: .file))) of \(total.formatted(.byteCount(style: .file)))"]
            if let speed = transfer.bytesPerSecond, speed > 0 {
                parts.append("\(Int64(speed).formatted(.byteCount(style: .file)))/s")
            }
            if let remaining = transfer.timeRemaining, remaining >= .seconds(1) {
                parts.append("about \(remaining.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide, maximumUnitCount: 1))) left")
            }
            return parts.joined(separator: " · ")
        }
    }
}

/// Shows that files dragged over a virtual machine's display can be dropped to copy them to it, or why they can't.
struct GuestFileDropHighlight: View {
    var target: GuestFileTransferCenter.DropTarget
    var guestName: String

    var body: some View {
        ZStack {
            if case .available = target {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(4)
            }

            Label {
                switch target {
                case .available: Text("Copy to the Desktop of “\(guestName)”")
                case .unavailable(let message): Text(message)
                }
            } icon: {
                switch target {
                case .available: Image(systemName: "arrow.down.doc.fill")
                case .unavailable: Image(systemName: "exclamationmark.triangle.fill")
                }
            }
            .font(.callout.weight(.medium))
            .multilineTextAlignment(.leading)
            .frame(maxWidth: 380)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

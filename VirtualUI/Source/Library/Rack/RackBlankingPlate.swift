import SwiftUI

/// The plate covering the empty space below the last unit, with vents across it. Clicking it installs a new unit: a new
/// virtual machine.
struct RackBlankingPlate: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            RackBlankingPlateFace()
        }
        .buttonStyle(RackBlankingPlateButtonStyle())
        .help("Create a new virtual machine (⌘N).")
        .accessibilityLabel("New Virtual Machine")
    }
}

private struct RackBlankingPlateButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .environment(\.rackBlankingPlateIsPressed, configuration.isPressed)
    }
}

private extension EnvironmentValues {
    @Entry var rackBlankingPlateIsPressed = false
}

private struct RackBlankingPlateFace: View {
    @Environment(\.rackBlankingPlateIsPressed)
    private var isPressed

    @State private var isHovered = false

    private var isLit: Bool { isHovered || isPressed }

    var body: some View {
        HStack(spacing: 0) {
            RackEar()

            RackVents()
                .padding(.vertical, 14)
                .padding(.horizontal, 18)
                .overlay { legend }

            RackEar()
        }
        .frame(height: LibraryItemView.height)
        .background {
            /// A plate is plainer than a unit, and sits a little further back.
            RackFaceplate()
                .overlay { Color.black.opacity(0.22) }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(RackPalette.teal.opacity(isLit ? 0.55 : 0), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
        .scaleEffect(isPressed ? 0.995 : 1)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(isPressed ? .linear(duration: 0) : .snappy, value: isPressed)
        .animation(.snappy, value: isHovered)
    }

    /// The legend is stamped on a strip in the middle of the vents.
    private var legend: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .bold))
            Text("Install new unit")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .textCase(.uppercase)
                .tracking(1.2)
        }
        .foregroundStyle(isLit ? RackPalette.teal : RackPalette.secondaryInk)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(RackPalette.unitBottom)
                .overlay {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                }
        }
    }
}

/// Rows of slots punched through a plate, staggered from one row to the next.
private struct RackVents: View {
    private static let slot = CGSize(width: 16, height: 3)
    private static let spacing = CGSize(width: 6, height: 6)

    var body: some View {
        Canvas { context, size in
            let pitch = CGSize(width: Self.slot.width + Self.spacing.width, height: Self.slot.height + Self.spacing.height)
            let rows = max(Int((size.height + Self.spacing.height) / pitch.height), 1)
            let top = (size.height - (CGFloat(rows) * pitch.height - Self.spacing.height)) / 2

            var slots = Path()
            var highlights = Path()

            for row in 0..<rows {
                let y = top + CGFloat(row) * pitch.height
                var x = row.isMultiple(of: 2) ? 0 : pitch.width / 2

                while x + Self.slot.width <= size.width {
                    let rect = CGRect(origin: CGPoint(x: x, y: y), size: Self.slot)
                    slots.addRoundedRect(in: rect, cornerSize: CGSize(width: 1.5, height: 1.5))
                    /// The lower lip of each slot catches the light.
                    highlights.addRect(CGRect(x: rect.minX + 1, y: rect.maxY, width: rect.width - 2, height: 0.5))
                    x += pitch.width
                }
            }

            context.fill(highlights, with: .color(.white.opacity(0.06)))
            context.fill(slots, with: .color(RackPalette.railHole))
        }
        .accessibilityHidden(true)
    }
}

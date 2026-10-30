import SwiftUI

extension EnvironmentValues {
    /// Whether the rack's lights and displays move. They're still while nobody can see them.
    @Entry var rackIsAnimated = true
}

/// The colors of the library's equipment rack, which looks the same in light and dark mode, the way hardware does.
enum RackPalette {
    static let caseBackground = Color(red: 0.090, green: 0.110, blue: 0.114)
    static let rail = Color(red: 0.150, green: 0.178, blue: 0.184)
    static let railHole = Color(red: 0.055, green: 0.067, blue: 0.071)
    static let unitTop = Color(red: 0.157, green: 0.188, blue: 0.196)
    static let unitBottom = Color(red: 0.125, green: 0.153, blue: 0.165)
    static let ink = Color(red: 0.780, green: 0.816, blue: 0.808)
    static let secondaryInk = Color(red: 0.486, green: 0.537, blue: 0.529)
    static let screw = Color(red: 0.282, green: 0.322, blue: 0.329)
    static let lampOff = Color(red: 0.216, green: 0.255, blue: 0.263)

    static let green = Color(red: 0.275, green: 0.878, blue: 0.478)
    static let teal = Color(red: 0.247, green: 0.839, blue: 0.776)
    static let amber = Color(red: 1.000, green: 0.702, blue: 0.251)
    static let blue = Color(red: 0.353, green: 0.659, blue: 1.000)

    static let labelFont = Font.system(size: 9.5, weight: .medium, design: .monospaced)
}

/// An indicator light on a rack unit.
struct RackLight: View {
    enum Signal: Equatable {
        case off
        case steady(Color)
        /// Fades in and out, for something that's waiting.
        case pulse(Color)
        /// Switches on and off, for something that's changing state.
        case blink(Color)
        /// Flickers irregularly, more often the busier it is, like a disk light. `intensity` goes from 0 to 1.
        case flicker(Color, intensity: Double)
    }

    var signal: Signal
    /// Keeps lights that flicker at the same time from flickering in step.
    var seed: Int = 0

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    @Environment(\.rackIsAnimated)
    private var isAnimated

    var body: some View {
        ZStack {
            Circle().fill(RackPalette.lampOff)

            light

            /// The reflection on the lens.
            Circle()
                .fill(.white.opacity(0.35))
                .frame(width: 2.5, height: 2.5)
                .offset(x: -1.2, y: -1.2)
        }
        .frame(width: RackLamp.diameter, height: RackLamp.diameter)
        .overlay { Circle().strokeBorder(.black.opacity(0.4), lineWidth: 0.5) }
    }

    @ViewBuilder
    private var light: some View {
        let isMoving = isAnimated && !reduceMotion

        switch signal {
        case .off:
            EmptyView()
        case .steady(let color):
            RackLamp(color: color)
        case .pulse(let color):
            RackLamp(color: color, motion: isMoving ? .pulse : nil)
        case .blink(let color):
            RackLamp(color: color, motion: isMoving ? .blink : nil)
        case .flicker(let color, let intensity):
            RackLamp(color: color, motion: isMoving ? .flicker(intensity: intensity, seed: seed) : nil)
        }
    }
}

extension RackLight.Signal {
    /// Below this, a disk light stays off, so that the occasional log write doesn't make it flicker.
    static let diskActivityThreshold: Double = 64 * 1024
    /// At this rate and above, a disk light flickers as much as it can.
    static let busyDiskRate: Double = 200 * 1024 * 1024

    /// A disk light, which flickers more the more is read and written each second.
    static func disk(bytesPerSecond rate: Double?) -> Self {
        guard let rate, rate >= diskActivityThreshold else { return .off }
        let intensity = log10(rate / diskActivityThreshold) / log10(busyDiskRate / diskActivityThreshold)
        return .flicker(RackPalette.amber, intensity: intensity)
    }
}

/// A light with its legend underneath, as printed on the front of a unit.
struct RackLabeledLight: View {
    var legend: String
    var signal: RackLight.Signal
    var seed: Int = 0

    var body: some View {
        VStack(spacing: 5) {
            RackLight(signal: signal, seed: seed)
            Text(legend)
                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                .foregroundStyle(RackPalette.secondaryInk)
        }
        .frame(width: 28)
    }
}

/// A row of segments that light up from the left, like a level meter. The last few segments light amber.
struct RackMeter: View {
    var title: String
    var reading: String
    /// How much of the meter is lit, from 0 to 1, or `nil` when there's nothing to measure.
    var fraction: Double?
    var segments: Int
    var segmentHeight: CGFloat = 12
    /// Shows a chevron after the reading, for a meter that opens something when clicked.
    var showsDisclosure = false

    private static let warningSegments = 3

    private var litSegments: Int {
        guard let fraction, fraction > 0.004 else { return 0 }
        return min(Int((fraction * Double(segments)).rounded(.up)), segments)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer(minLength: 4)
                Text(reading)
                    .foregroundStyle(fraction == nil ? RackPalette.secondaryInk : RackPalette.ink)

                if showsDisclosure {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7, weight: .bold))
                }
            }
            .font(RackPalette.labelFont)
            .textCase(.uppercase)
            .foregroundStyle(RackPalette.secondaryInk)
            .monospacedDigit()
            .lineLimit(1)

            RackMeterSegments(
                lit: litSegments,
                count: segments,
                warningCount: Self.warningSegments,
                height: segmentHeight
            )
        }
        .fixedSize()
    }
}

extension View {
    /// Shapes the view like a unit in the rack, with the shadow it casts on the rack behind it. The shadow comes from the
    /// unit's shape rather than what's on it, so it doesn't have to be worked out again whenever a light or meter changes.
    func rackUnitShape() -> some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)

        return clipShape(shape)
            .background {
                /// Half-transparent black behind the unit's edge is what the shadow from the unit itself would be there.
                shape
                    .fill(.black.opacity(0.5))
                    .shadow(color: .black, radius: 2, y: 1)
            }
    }
}

/// The brushed front of a unit, lit from above.
struct RackFaceplate: View {
    var body: some View {
        LinearGradient(colors: [RackPalette.unitTop, RackPalette.unitBottom], startPoint: .top, endPoint: .bottom)
            .overlay(alignment: .top) {
                Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(.black.opacity(0.4)).frame(height: 1)
            }
    }
}

/// One of the mounting ears at each end of a unit, with its two screws.
struct RackEar: View {
    var body: some View {
        VStack {
            screw
            Spacer(minLength: 0)
            screw
        }
        .padding(.vertical, 12)
        .frame(width: 22)
        .frame(maxHeight: .infinity)
        .background(.black.opacity(0.18))
    }

    private var screw: some View {
        Circle()
            .fill(RadialGradient(colors: [Color(white: 0.5), RackPalette.screw], center: UnitPoint(x: 0.35, y: 0.35), startRadius: 0, endRadius: 4))
            .overlay {
                Capsule()
                    .fill(.black.opacity(0.45))
                    .frame(width: 5, height: 1)
                    .rotationEffect(.degrees(-35))
            }
            .frame(width: 7, height: 7)
    }
}

/// The vertical rails that units are mounted on, which show through wherever there's no unit.
struct RackRails: View {
    static let width: CGFloat = 22
    /// The distance between the mounting holes, three to a unit.
    var holePitch: CGFloat

    var body: some View {
        HStack {
            rail
            Spacer(minLength: 0)
            rail
        }
    }

    private var rail: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(RackPalette.rail))
            context.fill(Path(CGRect(x: 0, y: 0, width: 1, height: size.height)), with: .color(.white.opacity(0.06)))

            let hole = CGSize(width: 7, height: 7)
            var y = (holePitch - hole.height) / 2
            while y < size.height {
                let rect = CGRect(x: (size.width - hole.width) / 2, y: y, width: hole.width, height: hole.height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(RackPalette.railHole))
                y += holePitch
            }
        }
        .frame(width: Self.width)
    }
}

/// The power button on the front of a unit. Clicking it does the unit's main action; holding it down while the virtual
/// machine runs shuts it down, as holding a power button does.
struct RackPowerButton: View {
    var isOn: Bool
    /// Whether holding the button shuts the virtual machine down.
    var canShutDown: Bool
    var primaryAction: () -> Void
    var shutDown: () -> Void

    static let holdDuration = Duration.seconds(1.2)
    private static let size = CGSize(width: 38, height: 38)

    @State private var isPressed = false
    @State private var holdProgress: CGFloat = 0
    @State private var holdTask: Task<Void, Never>?
    @State private var didShutDown = false

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color(white: 0.24), Color(white: 0.1)], center: UnitPoint(x: 0.4, y: 0.35), startRadius: 0, endRadius: 24))
                .overlay { Circle().strokeBorder(isOn ? RackPalette.green.opacity(0.5) : .white.opacity(0.08), lineWidth: 1) }
                .shadow(color: isOn ? RackPalette.green.opacity(0.25) : .clear, radius: 6)

            Circle()
                .trim(from: 0, to: holdProgress)
                .stroke(RackPalette.amber, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(1)

            Image(systemName: "power")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isOn ? RackPalette.green : RackPalette.secondaryInk)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .scaleEffect(isPressed ? 0.94 : 1)
        .animation(.snappy(duration: 0.15), value: isPressed)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressBegan() }
                .onEnded { value in
                    /// As with other buttons, letting go outside of it cancels the click.
                    pressEnded(inside: CGRect(origin: .zero, size: Self.size).contains(value.location))
                }
        )
        .help(canShutDown ? "Click to show the virtual machine. Hold to shut it down." : "Start the virtual machine.")
        .accessibilityElement()
        .accessibilityLabel("Power")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { primaryAction() }
        .accessibilityAction(named: "Shut Down") {
            if canShutDown { shutDown() }
        }
    }

    private func pressBegan() {
        guard !isPressed else { return }
        isPressed = true
        didShutDown = false

        guard canShutDown else { return }

        withAnimation(.linear(duration: Self.holdDuration / .seconds(1))) { holdProgress = 1 }
        holdTask = Task { @MainActor in
            try? await Task.sleep(for: Self.holdDuration)
            guard !Task.isCancelled, isPressed else { return }
            didShutDown = true
            shutDown()
        }
    }

    private func pressEnded(inside: Bool) {
        isPressed = false
        holdTask?.cancel()
        holdTask = nil
        withAnimation(.easeOut(duration: 0.2)) { holdProgress = 0 }

        if inside, !didShutDown { primaryAction() }
    }
}

/// A square key on the front of a unit, with its legend printed underneath.
struct RackKeyButtonStyle: ButtonStyle {
    var legend: String

    func makeBody(configuration: Configuration) -> some View {
        RackKey(label: configuration.label, legend: legend, isPressed: configuration.isPressed)
    }
}

private struct RackKey<Label: View>: View {
    var label: Label
    var legend: String
    var isPressed: Bool

    @Environment(\.isEnabled)
    private var isEnabled

    @State private var isHovered = false

    private static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 4, style: .continuous) }

    var body: some View {
        VStack(spacing: 5) {
            label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isHovered && isEnabled ? RackPalette.teal : RackPalette.ink)
                .frame(width: 40, height: 28)
                .background { keycap }
                .offset(y: isPressed ? 1 : 0)

            Text(legend)
                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                .foregroundStyle(RackPalette.secondaryInk)
        }
        .opacity(isEnabled ? 1 : 0.5)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.snappy(duration: 0.12), value: isPressed)
        .animation(.snappy, value: isHovered)
    }

    /// A keycap that sits proud of the panel, and sinks into it while it's pressed.
    private var keycap: some View {
        Self.shape
            .fill(LinearGradient(
                colors: isPressed ? [Color(white: 0.13), Color(white: 0.09)] : [Color(white: 0.25), Color(white: 0.13)],
                startPoint: .top,
                endPoint: .bottom
            ))
            .overlay(alignment: .top) {
                /// The light catching the top edge of the cap.
                Self.shape
                    .strokeBorder(LinearGradient(colors: [.white.opacity(isPressed ? 0.04 : 0.16), .clear], startPoint: .top, endPoint: .center), lineWidth: 1)
            }
            .overlay { Self.shape.strokeBorder(.black.opacity(0.5), lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.6), radius: isPressed ? 0.5 : 1.5, y: isPressed ? 0 : 1.5)
    }
}

/// A part of a unit's front that does something when it's clicked: it brightens while the pointer is over it and dims
/// while it's pressed.
struct RackPanelButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RackPanelButton(label: configuration.label, isPressed: configuration.isPressed)
    }
}

private struct RackPanelButton<Label: View>: View {
    var label: Label
    var isPressed: Bool

    @State private var isHovered = false

    var body: some View {
        label
            .brightness(isPressed ? -0.04 : isHovered ? 0.06 : 0)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .animation(.snappy(duration: 0.15), value: isHovered)
    }
}

extension View {
    /// Gives the window that contains the view the appearance, so that its title bar and toolbar suit what the view draws.
    func windowAppearance(_ name: NSAppearance.Name) -> some View {
        background { WindowAppearanceSetter(name: name) }
    }
}

private struct WindowAppearanceSetter: NSViewRepresentable {
    var name: NSAppearance.Name

    func makeNSView(context: Context) -> SetterView {
        let view = SetterView()
        view.name = name
        return view
    }

    func updateNSView(_ nsView: SetterView, context: Context) {
        nsView.name = name
        nsView.apply()
    }

    final class SetterView: NSView {
        var name: NSAppearance.Name = .aqua

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            guard let window, window.appearance?.name != name else { return }
            window.appearance = NSAppearance(named: name)
        }
    }
}

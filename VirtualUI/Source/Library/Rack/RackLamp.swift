import SwiftUI
import QuartzCore

/// The lit part of a ``RackLight``: the lamp and the glow around it. It pulses, blinks and flickers with Core Animation,
/// which plays an animation by itself once it's been given one, so a moving light costs nothing until what it shows changes.
struct RackLamp: View {
    enum Motion: Equatable {
        /// Fades in and out.
        case pulse
        /// Switches on and off.
        case blink
        /// Flickers irregularly, on for more of the time the higher `intensity` is, from 0 to 1. Lamps with different
        /// seeds flicker differently.
        case flicker(intensity: Double, seed: Int)
    }

    var color: Color
    /// How the lamp moves, or `nil` for one that stays lit.
    var motion: Motion?

    static let diameter: CGFloat = 9
    /// How far the glow spreads, as the standard deviation of the blur it looks like.
    static let glowSpread: CGFloat = 3
    /// Past three standard deviations, there's nothing left of the glow to see.
    static let glowRadius = diameter / 2 + glowSpread * 3

    var body: some View {
        /// The glow spills out around the lamp without taking up any space in the layout.
        RackLampRepresentable(color: color, motion: motion)
            .frame(width: Self.glowRadius * 2, height: Self.glowRadius * 2)
            .padding(-(Self.glowRadius - Self.diameter / 2))
    }
}

private struct RackLampRepresentable: NSViewRepresentable {
    var color: Color
    var motion: RackLamp.Motion?

    func makeNSView(context: Context) -> RackLampView {
        RackLampView()
    }

    func updateNSView(_ view: RackLampView, context: Context) {
        view.show(color: NSColor(color), motion: motion)
    }
}

/// Draws a ``RackLamp`` with layers, and moves it with Core Animation.
private final class RackLampView: NSView {
    /// The lamp and its glow, which go dim together.
    private let light = CALayer()
    private let glow = CAGradientLayer()
    private let lamp = CALayer()

    private var color: NSColor?
    private var motion: RackLamp.Motion?

    /// How bright the glow is compared with the lamp.
    private static let glowStrength: CGFloat = 0.6
    private static let glowSteps = 8

    private static let pulsePeriod: TimeInterval = 1.6
    private static let pulseDimmest: Float = 0.2
    private static let blinkInterval: TimeInterval = 0.45
    private static let blinkDimmest: Float = 0.15
    private static let flickerInterval: TimeInterval = 0.08
    private static let flickerDimmest: Float = 0.12
    /// How many on or off steps a flicker goes through before it repeats, which is long enough not to notice.
    private static let flickerSteps = 128

    private static let animationKey = "motion"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true

        glow.type = .radial
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        lamp.cornerRadius = RackLamp.diameter / 2

        light.addSublayer(glow)
        light.addSublayer(lamp)
        layer?.addSublayer(light)
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    /// The lamp is only something to look at; clicks and hovering go to what it's on.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        light.frame = bounds
        glow.frame = bounds
        lamp.frame = CGRect(
            x: bounds.midX - RackLamp.diameter / 2,
            y: bounds.midY - RackLamp.diameter / 2,
            width: RackLamp.diameter,
            height: RackLamp.diameter
        )
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()

        let scale = window?.backingScaleFactor ?? 2
        for layer in [light, glow, lamp] {
            layer.contentsScale = scale
        }
    }

    /// Animations stop when a view leaves its window, so they start again when it's back in one.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        animate()
    }

    func show(color: NSColor, motion: RackLamp.Motion?) {
        if color != self.color {
            self.color = color
            paint(color)
        }

        if motion != self.motion {
            self.motion = motion
            animate()
        }
    }

    private func paint(_ color: NSColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        lamp.backgroundColor = color.cgColor

        /// The glow fades the way the lamp would if it were blurred.
        let lampRadius = RackLamp.diameter / 2
        let locations = (0...Self.glowSteps).map { CGFloat($0) / CGFloat(Self.glowSteps) }
        glow.locations = locations.map { NSNumber(value: Double($0)) }
        glow.colors = locations.map { location in
            let distance = location * RackLamp.glowRadius
            let strength = erfc((distance - lampRadius) / (RackLamp.glowSpread * 2.squareRoot())) / 2
            return color.withAlphaComponent(Self.glowStrength * strength).cgColor
        }

        CATransaction.commit()
    }

    private func animate() {
        light.removeAnimation(forKey: Self.animationKey)

        guard let motion, window != nil else { return }

        let animation: CAAnimation
        let period: TimeInterval

        switch motion {
        case .pulse:
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = Self.pulseDimmest
            fade.duration = Self.pulsePeriod / 2
            fade.autoreverses = true
            /// Eases in and out the way a cosine does.
            fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.37, 0, 0.63, 1)
            animation = fade
            period = Self.pulsePeriod
        case .blink:
            animation = Self.steps([1, Self.blinkDimmest], every: Self.blinkInterval)
            period = Self.blinkInterval * 2
        case .flicker(let intensity, let seed):
            let brightness = (0..<Self.flickerSteps).map { step in
                Self.isLit(step: step, seed: seed, intensity: intensity) ? 1 : Self.flickerDimmest
            }
            animation = Self.steps(brightness, every: Self.flickerInterval)
            period = Self.flickerInterval * Double(Self.flickerSteps)
        }

        animation.repeatCount = .infinity
        /// Starting where it would be had it been going since a fixed time keeps lights that do the same thing in step,
        /// and lets a flickering light that gets busier carry on from where it was.
        animation.beginTime = light.convertTime(CACurrentMediaTime(), from: nil)
            - Date.now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)

        light.add(animation, forKey: Self.animationKey)
    }

    /// Goes from one brightness to the next, holding each for the interval.
    private static func steps(_ brightness: [Float], every interval: TimeInterval) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = brightness
        animation.calculationMode = .discrete
        /// Discrete steps need a time for the end of the last one, as well as the start of each.
        animation.keyTimes = (0...brightness.count).map { NSNumber(value: Double($0) / Double(brightness.count)) }
        animation.duration = interval * Double(brightness.count)
        return animation
    }

    /// Whether a flickering light is on for a step. Busier lights are on for more of the steps.
    private static func isLit(step: Int, seed: Int, intensity: Double) -> Bool {
        var value = UInt64(bitPattern: Int64(step &* 31 &+ seed))
        value ^= value >> 33
        value &*= 0xff51afd7ed558ccd
        value ^= value >> 33
        let dutyCycle = 0.25 + 0.6 * min(max(intensity, 0), 1)
        return Double(value % 1000) / 1000 < dutyCycle
    }
}

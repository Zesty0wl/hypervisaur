import SwiftUI
import QuartzCore

/// The segments of a ``RackMeter``. When the meter changes, segments light up or go out one after another with
/// Core Animation, which plays the change by itself, so a meter costs nothing between one reading and the next.
struct RackMeterSegments: View {
    /// How many segments are lit.
    var lit: Int
    var count: Int
    /// How many segments at the end light amber.
    var warningCount: Int
    var height: CGFloat

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    @Environment(\.rackIsAnimated)
    private var isAnimated

    static let segmentWidth: CGFloat = 6
    static let spacing: CGFloat = 2
    static let glowRadius: CGFloat = 2
    /// The glow fades out over about three times its radius.
    static let glowMargin = glowRadius * 3

    var body: some View {
        let width = CGFloat(count) * Self.segmentWidth + CGFloat(max(count - 1, 0)) * Self.spacing

        /// The glow spills out around the segments without taking up any space in the layout.
        RackMeterSegmentsRepresentable(
            layout: RackMeterSegmentsView.Layout(count: count, warningCount: warningCount, height: height),
            lit: lit,
            animates: isAnimated && !reduceMotion
        )
        .frame(width: width + Self.glowMargin * 2, height: height + Self.glowMargin * 2)
        .padding(-Self.glowMargin)
    }
}

private struct RackMeterSegmentsRepresentable: NSViewRepresentable {
    var layout: RackMeterSegmentsView.Layout
    var lit: Int
    var animates: Bool

    func makeNSView(context: Context) -> RackMeterSegmentsView {
        RackMeterSegmentsView()
    }

    func updateNSView(_ view: RackMeterSegmentsView, context: Context) {
        view.show(lit: lit, layout: layout, animated: animates)
    }
}

/// Draws a ``RackMeterSegments`` with a layer for each segment.
private final class RackMeterSegmentsView: NSView {
    struct Layout: Equatable {
        var count: Int
        var warningCount: Int
        var height: CGFloat
    }

    private var layout: Layout?
    private var segments = [CALayer]()
    private var lit = 0

    /// About how long it takes a meter to reach a new reading.
    private static let changeDuration: TimeInterval = 0.4
    private static let cornerRadius: CGFloat = 1
    private static let glowOpacity: Float = 0.55

    private static let green = NSColor(RackPalette.green).cgColor
    private static let amber = NSColor(RackPalette.amber).cgColor
    private static let unlit = NSColor(RackPalette.lampOff).cgColor

    private static let backgroundKey = "background"
    private static let glowKey = "glow"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        clipsToBounds = false
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    /// The meter is only something to look at; clicks go to what it's on.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()

        let scale = window?.backingScaleFactor ?? 2
        for segment in segments {
            segment.contentsScale = scale
        }
    }

    func show(lit: Int, layout: Layout, animated: Bool) {
        if layout != self.layout {
            self.layout = layout
            build(layout)
            self.lit = lit
            paint(lit: lit)
            return
        }

        guard lit != self.lit else { return }

        /// A meter that's still changing carries on from what it shows, rather than jumping to where it was going.
        let shown = animated && window != nil ? shownLit : self.lit
        self.lit = lit
        paint(lit: lit)

        if animated, window != nil {
            animateChange(from: shown, to: lit)
        }
    }

    private func build(_ layout: Layout) {
        segments.forEach { $0.removeFromSuperlayer() }

        let scale = window?.backingScaleFactor ?? 2
        segments = (0..<layout.count).map { index in
            let segment = CALayer()
            segment.frame = CGRect(
                x: RackMeterSegments.glowMargin + CGFloat(index) * (RackMeterSegments.segmentWidth + RackMeterSegments.spacing),
                y: RackMeterSegments.glowMargin,
                width: RackMeterSegments.segmentWidth,
                height: layout.height
            )
            segment.cornerRadius = Self.cornerRadius
            segment.cornerCurve = .continuous
            segment.shadowColor = Self.color(ofSegment: index, in: layout)
            segment.shadowRadius = RackMeterSegments.glowRadius
            segment.shadowOffset = .zero
            /// With its shape given, the glow doesn't have to be worked out from what's drawn.
            segment.shadowPath = CGPath(
                roundedRect: segment.bounds,
                cornerWidth: Self.cornerRadius,
                cornerHeight: Self.cornerRadius,
                transform: nil
            )
            segment.contentsScale = scale
            /// Later segments go on top of the glow from earlier ones, as they would in a row of lamps.
            layer?.addSublayer(segment)
            return segment
        }
    }

    private static func color(ofSegment index: Int, in layout: Layout) -> CGColor {
        index >= layout.count - layout.warningCount ? amber : green
    }

    private func paint(lit: Int) {
        guard let layout else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, segment) in segments.enumerated() {
            segment.removeAnimation(forKey: Self.backgroundKey)
            segment.removeAnimation(forKey: Self.glowKey)
            let isLit = index < lit
            segment.backgroundColor = isLit ? Self.color(ofSegment: index, in: layout) : Self.unlit
            segment.shadowOpacity = isLit ? Self.glowOpacity : 0
        }
        CATransaction.commit()
    }

    /// How many segments are lit on screen, which during a change is fewer or more than the reading.
    private var shownLit: Int {
        segments.prefix { segment in
            (segment.presentation() ?? segment).shadowOpacity > 0
        }.count
    }

    /// Holds the segments between the old and new readings as they were until the meter gets to them, quickly at first
    /// and then more slowly, the way a needle settles.
    private func animateChange(from old: Int, to new: Int) {
        guard let layout, old != new else { return }

        let rising = new > old
        let changing = rising ? Array(old..<new) : Array((new..<old).reversed())
        let now = convertToLayerTime(CACurrentMediaTime())

        for (order, index) in changing.enumerated() {
            /// How far through the change the meter is when it gets to this segment: a rising meter lights a segment
            /// as it leaves the one before, and a falling one turns a segment off as it gets below it.
            let progress = Double(rising ? order : order + 1) / Double(changing.count)
            let delay = Self.changeDuration * (1 - cbrt(1 - progress))
            guard delay > 0 else { continue }

            let wasLit = !rising
            let background = Self.hold(
                "backgroundColor",
                at: wasLit ? Self.color(ofSegment: index, in: layout) : Self.unlit,
                for: delay,
                from: now
            )
            let glow = Self.hold("shadowOpacity", at: wasLit ? Self.glowOpacity : 0, for: delay, from: now)

            segments[index].add(background, forKey: Self.backgroundKey)
            segments[index].add(glow, forKey: Self.glowKey)
        }
    }

    /// Keeps a property at a value for a while, after which it shows what it's been set to.
    private static func hold(_ keyPath: String, at value: Any, for duration: TimeInterval, from beginTime: CFTimeInterval) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = value
        animation.toValue = value
        animation.duration = duration
        animation.beginTime = beginTime
        return animation
    }

    private func convertToLayerTime(_ time: CFTimeInterval) -> CFTimeInterval {
        layer?.convertTime(time, from: nil) ?? time
    }
}

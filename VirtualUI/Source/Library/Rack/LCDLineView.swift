import SwiftUI
import QuartzCore

/// Shows the cells of an ``LCDLine``.
struct LCDLineRepresentable: NSViewRepresentable {
    var characters: [Character]
    var isBacklit: Bool
    var overflow: LCDLineView.Overflow

    func makeNSView(context: Context) -> LCDLineView {
        LCDLineView()
    }

    func updateNSView(_ view: LCDLineView, context: Context) {
        view.show(characters, isBacklit: isBacklit, overflow: overflow)
    }
}

/// Draws the cells of an ``LCDLine`` into a layer. Text that's too long for the line scrolls with Core Animation, which
/// moves it along by itself, so a scrolling line costs nothing until its text changes.
final class LCDLineView: NSView {
    /// What happens to text that's too long for the line.
    enum Overflow: Equatable {
        /// It shifts along one character at a time, and comes round again after a gap.
        case scroll
        /// Its start shows, as it does before it scrolls.
        case hold
        /// It's cut short with an ellipsis.
        case truncate
    }

    /// What's drawn into the strip, so that it's only drawn again when that changes.
    private struct Drawing: Equatable {
        var cells: [Character]
        var isBacklit: Bool
        var scale: CGFloat
    }

    /// Shows the part of the strip that's in the line.
    private let viewport = CALayer()
    /// The cells, which for a scrolling line are its text, a gap and its start again, so that it can come round.
    private let strip = CALayer()

    private var characters = [Character]()
    private var isBacklit = true
    private var overflow = Overflow.scroll
    private var drawing: Drawing?

    /// How long each character stays in place while a line scrolls.
    private static let scrollInterval: TimeInterval = 0.3
    /// How many steps the start of the text stays in place before it scrolls again.
    private static let pauseSteps = 7
    /// The blank cells between the end of the text and its start coming round again.
    private static let gapCells = 3
    /// The room below the dots for the shadow they cast.
    private static let shadowRoom: CGFloat = 1

    private static let scrollKey = "scroll"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        clipsToBounds = false

        viewport.masksToBounds = true
        viewport.addSublayer(strip)
        layer?.addSublayer(viewport)
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    /// The line is only something to read; clicks go to what it's on.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ characters: [Character], isBacklit: Bool, overflow: Overflow) {
        guard characters != self.characters || isBacklit != self.isBacklit || overflow != self.overflow else { return }

        self.characters = characters
        self.isBacklit = isBacklit
        self.overflow = overflow
        update()
    }

    override func layout() {
        super.layout()
        update()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        update()
    }

    /// Animations stop when a view leaves its window, so scrolling starts again when it's back in one.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        update()
    }

    private func update() {
        let columns = LCDMetrics.columns(fitting: bounds.width)
        let scale = window?.backingScaleFactor ?? 2

        var cells: [Character]
        var loopLength: Int?

        if characters.count <= columns {
            cells = characters
        } else {
            switch overflow {
            case .scroll:
                let loop = characters + Array(repeating: " ", count: Self.gapCells)
                cells = loop + loop.prefix(columns)
                loopLength = loop.count
            case .hold:
                cells = Array(characters.prefix(columns))
            case .truncate:
                cells = Array(characters.prefix(columns - 1)) + ["…"]
            }
        }
        /// Cells without a character still show their unlit dots.
        if cells.count < columns {
            cells += Array(repeating: " ", count: columns - cells.count)
        }

        let drawing = Drawing(cells: cells, isBacklit: isBacklit, scale: scale)
        let height = LCDMetrics.lineHeight + Self.shadowRoom

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        /// The line shows whole cells, and none of the one after the last, which may partly fit.
        viewport.frame = CGRect(x: 0, y: bounds.height - height, width: CGFloat(columns) * LCDMetrics.advance, height: height)

        if drawing != self.drawing {
            let image = Self.image(of: cells, isBacklit: isBacklit, height: height, scale: scale)
            strip.contents = image
            strip.contentsScale = scale

            /// The image is a whole number of pixels, a little bigger than the cells, and the strip is exactly its size
            /// so that it isn't stretched. Its top is the top of the line.
            let size = CGSize(width: CGFloat(image?.width ?? 0) / scale, height: CGFloat(image?.height ?? 0) / scale)
            strip.frame = CGRect(x: 0, y: height - size.height, width: size.width, height: size.height)
        }

        CATransaction.commit()

        /// Scrolling starts from the beginning whenever what's scrolling changes, and carries on when only the backlight does.
        if let loopLength, window != nil {
            if drawing.cells != self.drawing?.cells || strip.animation(forKey: Self.scrollKey) == nil {
                scroll(loopLength: loopLength)
            }
        } else {
            strip.removeAnimation(forKey: Self.scrollKey)
        }

        self.drawing = drawing
    }

    private func scroll(loopLength: Int) {
        let steps = Self.pauseSteps + loopLength
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        /// The start of the text stays in place for a few steps, then it shifts a cell at a time until it's back.
        animation.values = (0..<steps).map { step in
            -CGFloat(max(0, step - Self.pauseSteps)) * LCDMetrics.advance
        }
        animation.calculationMode = .discrete
        /// Discrete steps need a time for the end of the last one, as well as the start of each.
        animation.keyTimes = (0...steps).map { NSNumber(value: Double($0) / Double(steps)) }
        animation.duration = Self.scrollInterval * Double(steps)
        animation.repeatCount = .infinity
        animation.beginTime = strip.convertTime(CACurrentMediaTime(), from: nil)

        strip.add(animation, forKey: Self.scrollKey)
    }

    private static func image(of cells: [Character], isBacklit: Bool, height: CGFloat, scale: CGFloat) -> CGImage? {
        let size = CGSize(width: CGFloat(cells.count) * LCDMetrics.advance, height: height)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: Int((size.width * scale).rounded(.up)),
                height: Int((size.height * scale).rounded(.up)),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ),
              let ink = NSColor(LCDPalette.ink).usingColorSpace(.sRGB)
        else { return nil }

        context.scaleBy(x: scale, y: scale)
        /// The glyphs' rows go down from the top of the image, which is a whole number of pixels and so may be a little
        /// taller than the line.
        context.translateBy(x: 0, y: CGFloat(context.height) / scale)
        context.scaleBy(x: 1, y: -1)

        let unlit = CGMutablePath()
        let lit = CGMutablePath()

        for (column, character) in cells.enumerated() {
            let glyph = LCDFont.glyph(for: character)
            let originX = CGFloat(column) * LCDMetrics.advance

            for row in 0..<LCDMetrics.glyphRows {
                for dot in 0..<LCDMetrics.glyphColumns {
                    let rect = CGRect(
                        x: originX + CGFloat(dot) * LCDMetrics.pitch,
                        y: CGFloat(row) * LCDMetrics.pitch,
                        width: LCDMetrics.dotSize,
                        height: LCDMetrics.dotSize
                    )
                    if glyph[row] & (1 << (LCDMetrics.glyphColumns - 1 - dot)) != 0 {
                        lit.addRect(rect)
                    } else {
                        unlit.addRect(rect)
                    }
                }
            }
        }

        func fill(_ path: CGPath, opacity: CGFloat) {
            context.addPath(path)
            context.setFillColor(ink.withAlphaComponent(opacity).cgColor)
            context.fillPath()
        }

        fill(unlit, opacity: 0.045)
        /// Lit dots cast a faint shadow on the backlight behind them.
        context.saveGState()
        context.translateBy(x: 0.5, y: 0.6)
        fill(lit, opacity: isBacklit ? 0.18 : 0.1)
        context.restoreGState()
        fill(lit, opacity: isBacklit ? 0.88 : 0.72)

        return context.makeImage()
    }
}

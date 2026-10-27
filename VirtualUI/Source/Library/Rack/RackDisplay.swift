import SwiftUI

extension EnvironmentValues {
    /// Whether the character LCD that contains the view has its backlight on.
    @Entry var lcdIsBacklit = true
}

/// The measurements of a character LCD: cells of 5 × 7 dots, a dot apart.
enum LCDMetrics {
    /// The distance from one dot to the next.
    static let pitch: CGFloat = 1.8
    static let dotSize: CGFloat = 1.5
    static let glyphColumns = 5
    static let glyphRows = 7
    /// The width of a cell, including the dot's worth of space after it.
    static let advance = CGFloat(glyphColumns + 1) * pitch
    static let lineHeight = CGFloat(glyphRows) * pitch
    static let lineSpacing = 3 * pitch

    /// How many cells fit across the width.
    static func columns(fitting width: CGFloat) -> Int {
        max(1, Int((width + pitch) / advance))
    }
}

/// The colors of a yellow-green character LCD, which looks the same in light and dark mode, the way hardware does.
enum LCDPalette {
    static let backlitCenter = Color(red: 0.820, green: 0.906, blue: 0.333)
    static let backlitEdge = Color(red: 0.718, green: 0.827, blue: 0.247)
    static let unlitCenter = Color(red: 0.522, green: 0.569, blue: 0.392)
    static let unlitEdge = Color(red: 0.435, green: 0.475, blue: 0.325)
    static let ink = Color(red: 0.063, green: 0.078, blue: 0.031)
}

/// A backlit character LCD set into a bezel, like those on the front of old equipment, holding lines of ``LCDLine``.
struct LCDPanel<Content: View>: View {
    var isBacklit: Bool
    @ViewBuilder var content: Content

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 3, style: .continuous) }

    var body: some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { glass }
            .overlay {
                /// The glass sits below the bezel, which shades its edges.
                shape
                    .strokeBorder(.black.opacity(0.5), lineWidth: 2)
                    .blur(radius: 1.5)
            }
            .clipShape(shape)
            .padding(.horizontal, 3)
            .padding(.vertical, 6)
            .background { bezel }
            .environment(\.lcdIsBacklit, isBacklit)
            .animation(.easeInOut(duration: 0.5), value: isBacklit)
    }

    /// The black frame the glass sits in, with a ridge moulded along the top and the bottom.
    private var bezel: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(LinearGradient(colors: [Color(white: 0.07), Color(white: 0.03)], startPoint: .top, endPoint: .bottom))
            .overlay {
                VStack {
                    ridge
                    Spacer(minLength: 0)
                    ridge
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
            }
    }

    private var ridge: some View {
        VStack(spacing: 0) {
            Rectangle().fill(.white.opacity(0.13)).frame(height: 0.5)
            Rectangle().fill(.black.opacity(0.6)).frame(height: 1)
        }
    }

    private var glass: some View {
        ZStack {
            RadialGradient(
                colors: isBacklit ? [LCDPalette.backlitCenter, LCDPalette.backlitEdge] : [LCDPalette.unlitCenter, LCDPalette.unlitEdge],
                center: .center,
                startRadius: 0,
                endRadius: 160
            )

            /// The reflection on the glass.
            LinearGradient(colors: [.white.opacity(0.14), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.45))
        }
    }
}

/// A line of a character LCD. Text that's too long for it shifts along one character at a time, the way these displays scroll.
struct LCDLine: View {
    var text: String

    @Environment(\.lcdIsBacklit)
    private var isBacklit

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    @State private var scrollStart = Date.now

    /// How long each character stays in place while a line scrolls.
    private static let scrollInterval: TimeInterval = 0.3
    /// How many steps the start of the text stays in place before it scrolls again.
    private static let pauseSteps = 7
    /// The blank cells between the end of the text and its start coming round again.
    private static let gapCells = 3

    var body: some View {
        GeometryReader { geometry in
            let columns = LCDMetrics.columns(fitting: geometry.size.width)
            let characters = LCDFont.characters(in: text)

            if characters.count <= columns {
                cells(characters)
            } else if reduceMotion {
                cells(Array(characters.prefix(columns - 1)) + ["…"])
            } else {
                TimelineView(.periodic(from: scrollStart, by: Self.scrollInterval)) { context in
                    cells(Self.window(of: characters, columns: columns, elapsed: context.date.timeIntervalSince(scrollStart)))
                }
            }
        }
        .frame(height: LCDMetrics.lineHeight)
        .onChange(of: text) { scrollStart = .now }
        .accessibilityElement()
        .accessibilityLabel(text)
    }

    /// The characters showing a number of steps into scrolling the text, which comes round again after a gap.
    private static func window(of characters: [Character], columns: Int, elapsed: TimeInterval) -> [Character] {
        let loop = characters + Array(repeating: " ", count: gapCells)
        let step = Int(max(elapsed, 0) / scrollInterval)
        let offset = max(0, step % (pauseSteps + loop.count) - pauseSteps)
        return (0..<columns).map { loop[(offset + $0) % loop.count] }
    }

    private func cells(_ characters: [Character]) -> some View {
        Canvas { context, size in
            let columns = LCDMetrics.columns(fitting: size.width)
            var unlit = Path()
            var lit = Path()

            for column in 0..<columns {
                let glyph = column < characters.count ? LCDFont.glyph(for: characters[column]) : LCDFont.blank
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

            context.fill(unlit, with: .color(LCDPalette.ink.opacity(0.045)))
            /// Lit dots cast a faint shadow on the backlight behind them.
            context.fill(lit.offsetBy(dx: 0.5, dy: 0.6), with: .color(LCDPalette.ink.opacity(isBacklit ? 0.18 : 0.1)))
            context.fill(lit, with: .color(LCDPalette.ink.opacity(isBacklit ? 0.88 : 0.72)))
        }
    }
}

/// A 5 × 7 dot font for character LCDs, covering printable ASCII and the punctuation the library uses.
enum LCDFont {
    static let blank = [UInt8](repeating: 0, count: LCDMetrics.glyphRows)

    /// The characters to show for the text: accents are dropped, as on displays without them, and anything else
    /// without a glyph shows as a question mark.
    static func characters(in text: String) -> [Character] {
        let folded = text.applyingTransform(.stripDiacritics, reverse: false) ?? text

        return folded.map { character in
            if glyphs[character] != nil { return character }

            switch character {
            case "‘", "’", "′": return "'"
            case "“", "”", "″": return "\""
            case "—", "−": return "-"
            default: return "?"
            }
        }
    }

    static func glyph(for character: Character) -> [UInt8] {
        glyphs[character] ?? glyphs["?"] ?? blank
    }

    /// Each row is a bit mask, with the leftmost dot in the highest of its five bits.
    private static let glyphs: [Character: [UInt8]] = patterns.mapValues { rows in
        rows.map { row in row.reduce(UInt8(0)) { ($0 << 1) | ($1 == "#" ? 1 : 0) } }
    }

    private static let patterns: [Character: [String]] = [
        " ": [".....", ".....", ".....", ".....", ".....", ".....", "....."],
        "!": ["..#..", "..#..", "..#..", "..#..", "..#..", ".....", "..#.."],
        "\"": [".#.#.", ".#.#.", ".#.#.", ".....", ".....", ".....", "....."],
        "#": [".#.#.", ".#.#.", "#####", ".#.#.", "#####", ".#.#.", ".#.#."],
        "$": ["..#..", ".####", "#.#..", ".###.", "..#.#", "####.", "..#.."],
        "%": ["##...", "##..#", "...#.", "..#..", ".#...", "#..##", "...##"],
        "&": [".##..", "#..#.", "#.#..", ".#...", "#.#.#", "#..#.", ".##.#"],
        "'": ["..#..", "..#..", ".#...", ".....", ".....", ".....", "....."],
        "(": ["...#.", "..#..", ".#...", ".#...", ".#...", "..#..", "...#."],
        ")": [".#...", "..#..", "...#.", "...#.", "...#.", "..#..", ".#..."],
        "*": [".....", "..#..", "#.#.#", ".###.", "#.#.#", "..#..", "....."],
        "+": [".....", "..#..", "..#..", "#####", "..#..", "..#..", "....."],
        ",": [".....", ".....", ".....", ".....", ".##..", "..#..", ".#..."],
        "-": [".....", ".....", ".....", "#####", ".....", ".....", "....."],
        ".": [".....", ".....", ".....", ".....", ".....", ".##..", ".##.."],
        "/": [".....", "....#", "...#.", "..#..", ".#...", "#....", "....."],
        "0": [".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###."],
        "1": ["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."],
        "2": [".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"],
        "3": ["#####", "...#.", "..#..", "...#.", "....#", "#...#", ".###."],
        "4": ["...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."],
        "5": ["#####", "#....", "####.", "....#", "....#", "#...#", ".###."],
        "6": ["..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###."],
        "7": ["#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."],
        "8": [".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."],
        "9": [".###.", "#...#", "#...#", ".####", "....#", "...#.", ".##.."],
        ":": [".....", ".##..", ".##..", ".....", ".##..", ".##..", "....."],
        ";": [".....", ".##..", ".##..", ".....", ".##..", "..#..", ".#..."],
        "<": ["...#.", "..#..", ".#...", "#....", ".#...", "..#..", "...#."],
        "=": [".....", ".....", "#####", ".....", "#####", ".....", "....."],
        ">": [".#...", "..#..", "...#.", "....#", "...#.", "..#..", ".#..."],
        "?": [".###.", "#...#", "....#", "...#.", "..#..", ".....", "..#.."],
        "@": [".###.", "#...#", "....#", ".##.#", "#.#.#", "#.#.#", ".###."],
        "A": [".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
        "B": ["####.", "#...#", "#...#", "####.", "#...#", "#...#", "####."],
        "C": [".###.", "#...#", "#....", "#....", "#....", "#...#", ".###."],
        "D": ["###..", "#..#.", "#...#", "#...#", "#...#", "#..#.", "###.."],
        "E": ["#####", "#....", "#....", "####.", "#....", "#....", "#####"],
        "F": ["#####", "#....", "#....", "####.", "#....", "#....", "#...."],
        "G": [".###.", "#...#", "#....", "#.###", "#...#", "#...#", ".####"],
        "H": ["#...#", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
        "I": [".###.", "..#..", "..#..", "..#..", "..#..", "..#..", ".###."],
        "J": ["..###", "...#.", "...#.", "...#.", "...#.", "#..#.", ".##.."],
        "K": ["#...#", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "#...#"],
        "L": ["#....", "#....", "#....", "#....", "#....", "#....", "#####"],
        "M": ["#...#", "##.##", "#.#.#", "#.#.#", "#...#", "#...#", "#...#"],
        "N": ["#...#", "#...#", "##..#", "#.#.#", "#..##", "#...#", "#...#"],
        "O": [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
        "P": ["####.", "#...#", "#...#", "####.", "#....", "#....", "#...."],
        "Q": [".###.", "#...#", "#...#", "#...#", "#.#.#", "#..#.", ".##.#"],
        "R": ["####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#"],
        "S": [".####", "#....", "#....", ".###.", "....#", "....#", "####."],
        "T": ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."],
        "U": ["#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
        "V": ["#...#", "#...#", "#...#", "#...#", "#...#", ".#.#.", "..#.."],
        "W": ["#...#", "#...#", "#...#", "#.#.#", "#.#.#", "#.#.#", ".#.#."],
        "X": ["#...#", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "#...#"],
        "Y": ["#...#", "#...#", "#...#", ".#.#.", "..#..", "..#..", "..#.."],
        "Z": ["#####", "....#", "...#.", "..#..", ".#...", "#....", "#####"],
        "[": [".###.", ".#...", ".#...", ".#...", ".#...", ".#...", ".###."],
        "\\": [".....", "#....", ".#...", "..#..", "...#.", "....#", "....."],
        "]": [".###.", "...#.", "...#.", "...#.", "...#.", "...#.", ".###."],
        "^": ["..#..", ".#.#.", "#...#", ".....", ".....", ".....", "....."],
        "_": [".....", ".....", ".....", ".....", ".....", ".....", "#####"],
        "`": [".#...", "..#..", "...#.", ".....", ".....", ".....", "....."],
        "a": [".....", ".....", ".###.", "....#", ".####", "#...#", ".####"],
        "b": ["#....", "#....", "#.##.", "##..#", "#...#", "#...#", "####."],
        "c": [".....", ".....", ".###.", "#....", "#....", "#...#", ".###."],
        "d": ["....#", "....#", ".##.#", "#..##", "#...#", "#...#", ".####"],
        "e": [".....", ".....", ".###.", "#...#", "#####", "#....", ".###."],
        "f": ["..##.", ".#..#", ".#...", "###..", ".#...", ".#...", ".#..."],
        "g": [".....", ".####", "#...#", "#...#", ".####", "....#", ".###."],
        "h": ["#....", "#....", "#.##.", "##..#", "#...#", "#...#", "#...#"],
        "i": ["..#..", ".....", ".##..", "..#..", "..#..", "..#..", ".###."],
        "j": ["...#.", ".....", "..##.", "...#.", "...#.", "#..#.", ".##.."],
        "k": ["#....", "#....", "#..#.", "#.#..", "##...", "#.#..", "#..#."],
        "l": [".##..", "..#..", "..#..", "..#..", "..#..", "..#..", ".###."],
        "m": [".....", ".....", "##.#.", "#.#.#", "#.#.#", "#...#", "#...#"],
        "n": [".....", ".....", "#.##.", "##..#", "#...#", "#...#", "#...#"],
        "o": [".....", ".....", ".###.", "#...#", "#...#", "#...#", ".###."],
        "p": [".....", ".....", "####.", "#...#", "####.", "#....", "#...."],
        "q": [".....", ".....", ".##.#", "#..##", ".####", "....#", "....#"],
        "r": [".....", ".....", "#.##.", "##..#", "#....", "#....", "#...."],
        "s": [".....", ".....", ".###.", "#....", ".###.", "....#", "####."],
        "t": [".#...", ".#...", "###..", ".#...", ".#...", ".#..#", "..##."],
        "u": [".....", ".....", "#...#", "#...#", "#...#", "#..##", ".##.#"],
        "v": [".....", ".....", "#...#", "#...#", "#...#", ".#.#.", "..#.."],
        "w": [".....", ".....", "#...#", "#...#", "#.#.#", "#.#.#", ".#.#."],
        "x": [".....", ".....", "#...#", ".#.#.", "..#..", ".#.#.", "#...#"],
        "y": [".....", ".....", "#...#", "#...#", ".####", "....#", ".###."],
        "z": [".....", ".....", "#####", "...#.", "..#..", ".#...", "#####"],
        "{": ["...#.", "..#..", "..#..", ".#...", "..#..", "..#..", "...#."],
        "|": ["..#..", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."],
        "}": [".#...", "..#..", "..#..", "...#.", "..#..", "..#..", ".#..."],
        "~": [".....", ".....", ".#...", "#.#.#", "...#.", ".....", "....."],
        "·": [".....", ".....", ".....", "..#..", ".....", ".....", "....."],
        "…": [".....", ".....", ".....", ".....", ".....", ".....", "#.#.#"],
        "–": [".....", ".....", ".....", ".###.", ".....", ".....", "....."],
        "×": [".....", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "....."],
        "°": [".##..", "#..#.", "#..#.", ".##..", ".....", ".....", "....."],
    ]
}

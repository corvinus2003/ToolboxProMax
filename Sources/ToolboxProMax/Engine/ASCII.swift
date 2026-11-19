import AppKit
import CoreImage
import CoreText

/// Turns pictures into text art: character ramps, block shades or braille dots, mono or in color.
enum ASCII {
    static let charsets: [(String, String)] = [
        ("classic", "Classic"), ("dense", "Detailed"), ("blocks", "Blocks"), ("braille", "Braille"), ("binary", "Binary"),
    ]

    static func ramp(_ id: String) -> [Character] {
        switch id {
        case "dense": Array(" .'`^\",:;Il!i><~+_-?][}{1)(|/tfjrxnuvczXYUJCLQ0OZmwqpdbkhao*#MW&8%B@$")
        case "blocks": Array(" ░▒▓█")
        case "binary": Array(" 01")
        default: Array(" .:-=+*#%@")
        }
    }

    struct Grid {
        var lines: [[Character]]
        var colors: [[SIMD3<Float>]]
        var columns: Int { lines.first?.count ?? 0 }
    }

    /// Characters are about twice as tall as they are wide, so each row covers two "widths" of picture.
    static func grid(_ image: CIImage, columns: Int, charset: String, invert: Bool, darkBackground: Bool) -> Grid? {
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return nil }
        let cols = max(4, columns)
        let rows = max(1, Int((CGFloat(cols) * e.height / e.width / 2).rounded()))
        let braille = charset == "braille"
        let sw = braille ? cols * 2 : cols, sh = braille ? rows * 4 : rows
        guard let bmp = Bitmap(image, width: sw, height: sh) else { return nil }

        func pixel(_ x: Int, _ y: Int) -> SIMD3<Float> {
            let i = (y * sw + x) * 4
            return SIMD3(Float(bmp.pixels[i]), Float(bmp.pixels[i + 1]), Float(bmp.pixels[i + 2])) / 255
        }
        func ink(_ c: SIMD3<Float>) -> Float {
            var l = c.x * 0.2126 + c.y * 0.7152 + c.z * 0.0722
            if !darkBackground { l = 1 - l }
            return invert ? 1 - l : l
        }

        var lines: [[Character]] = [], colors: [[SIMD3<Float>]] = []
        let chars = ramp(charset)
        for r in 0..<rows {
            var line: [Character] = [], lineColors: [SIMD3<Float>] = []
            for c in 0..<cols {
                if braille {
                    // dot order in a braille cell: 1 4 / 2 5 / 3 6 / 7 8
                    let bits: [(Int, Int, UInt32)] = [(0, 0, 0x01), (0, 1, 0x02), (0, 2, 0x04), (1, 0, 0x08),
                                                      (1, 1, 0x10), (1, 2, 0x20), (0, 3, 0x40), (1, 3, 0x80)]
                    var code: UInt32 = 0, sum = SIMD3<Float>.zero
                    for (dx, dy, bit) in bits {
                        let p = pixel(c * 2 + dx, r * 4 + dy)
                        sum += p
                        if ink(p) > 0.5 { code |= bit }
                    }
                    line.append(Character(UnicodeScalar(0x2800 + code)!))
                    lineColors.append(sum / 8)
                } else {
                    let p = pixel(c, r)
                    let idx = min(chars.count - 1, Int(ink(p) * Float(chars.count)))
                    line.append(chars[max(0, idx)])
                    lineColors.append(p)
                }
            }
            lines.append(line)
            colors.append(lineColors)
        }
        return Grid(lines: lines, colors: colors)
    }

    static func text(_ grid: Grid) -> String {
        grid.lines.map { String($0).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
            .joined(separator: "\n")
    }

    /// Draws the grid back into an image the same width as the source.
    static func render(_ image: CIImage, columns: Int, charset: String, invert: Bool, color: Bool, darkBackground: Bool) -> CIImage {
        guard let grid = grid(image, columns: columns, charset: charset, invert: invert, darkBackground: darkBackground) else {
            return image
        }
        let cols = grid.columns, rows = grid.lines.count
        let cellW = max(1, image.extent.width / CGFloat(cols))
        let cellH = cellW * 2
        let width = Int((cellW * CGFloat(cols)).rounded()), height = Int((cellH * CGFloat(rows)).rounded())
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CI.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }

        let bg = darkBackground ? CGColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1) : CGColor(red: 0.98, green: 0.98, blue: 0.97, alpha: 1)
        let fg = darkBackground ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.08, alpha: 1)
        ctx.setFillColor(bg)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Size the font so one character is exactly one cell wide.
        let probe = NSFont.monospacedSystemFont(ofSize: 100, weight: .medium)
        let advance = ("M" as NSString).size(withAttributes: [.font: probe]).width / 100
        let font = NSFont.monospacedSystemFont(ofSize: cellW / max(0.1, advance), weight: .medium)
        let perChar = charset == "braille" // braille glyphs come from a fallback font with other widths
        let descent = font.descender

        for (r, line) in grid.lines.enumerated() {
            let baseline = CGFloat(height) - CGFloat(r + 1) * cellH + (cellH - font.ascender + descent) / 2 - descent
            if perChar {
                for (c, ch) in line.enumerated() where ch != "\u{2800}" {
                    let col = color ? nsColor(grid.colors[r][c]) : fg
                    let ln = CTLineCreateWithAttributedString(NSAttributedString(string: String(ch), attributes: [.font: font, .foregroundColor: col]))
                    ctx.textPosition = CGPoint(x: CGFloat(c) * cellW, y: baseline)
                    CTLineDraw(ln, ctx)
                }
            } else {
                let s = NSMutableAttributedString(string: String(line), attributes: [.font: font, .foregroundColor: fg])
                if color {
                    var offset = 0
                    for (c, ch) in line.enumerated() {
                        let len = String(ch).utf16.count
                        s.addAttribute(.foregroundColor, value: nsColor(grid.colors[r][c]), range: NSRange(location: offset, length: len))
                        offset += len
                    }
                }
                ctx.textPosition = CGPoint(x: 0, y: baseline)
                CTLineDraw(CTLineCreateWithAttributedString(s), ctx)
            }
        }
        guard let cg = ctx.makeImage() else { return image }
        return CIImage(cgImage: cg)
    }

    private static func nsColor(_ c: SIMD3<Float>) -> NSColor {
        // lift dark colors a little so they stay visible on the dark background
        NSColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
    }
}

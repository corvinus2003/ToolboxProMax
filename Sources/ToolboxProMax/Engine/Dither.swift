import CoreImage
import simd

/// Retro dithering: error diffusion (Floyd–Steinberg, Atkinson), ordered Bayer patterns or a plain threshold,
/// mapped onto a small palette. Runs on the CPU, on a downscaled copy when "pixel size" is above 1.
enum Dither {
    static let algorithms: [(String, String)] = [
        ("floyd", "Floyd–Steinberg"), ("atkinson", "Atkinson"), ("bayer4", "Bayer 4×4"),
        ("bayer8", "Bayer 8×8"), ("noise", "Noise"), ("threshold", "Threshold"),
    ]

    static let palettes: [(String, String)] = [
        ("mono", "1-bit"), ("gray4", "4 grays"), ("gameboy", "Handheld green"), ("cga", "CGA"),
        ("amber", "Amber screen"), ("sunset", "Sunset"), ("rgb", "Color levels"),
    ]

    private static func hex(_ v: UInt32) -> SIMD3<Float> {
        SIMD3(Float((v >> 16) & 0xFF), Float((v >> 8) & 0xFF), Float(v & 0xFF)) / 255
    }

    static func palette(_ id: String) -> [SIMD3<Float>]? {
        switch id {
        case "mono": [hex(0x000000), hex(0xFFFFFF)]
        case "gray4": [hex(0x000000), hex(0x555555), hex(0xAAAAAA), hex(0xFFFFFF)]
        case "gameboy": [hex(0x0F380F), hex(0x306230), hex(0x8BAC0F), hex(0x9BBC0F)]
        case "cga": [hex(0x000000), hex(0x55FFFF), hex(0xFF55FF), hex(0xFFFFFF)]
        case "amber": [hex(0x1A0F00), hex(0xFFB000)]
        case "sunset": [hex(0x2B0F54), hex(0xAB1F65), hex(0xFF4F69), hex(0xFF8142), hex(0xFFDA45), hex(0xFFF7F8)]
        default: nil
        }
    }

    static let bayer4: [Float] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5].map { ($0 + 0.5) / 16 }
    static let bayer8: [Float] = [
        0, 32, 8, 40, 2, 34, 10, 42, 48, 16, 56, 24, 50, 18, 58, 26,
        12, 44, 4, 36, 14, 46, 6, 38, 60, 28, 52, 20, 62, 30, 54, 22,
        3, 35, 11, 43, 1, 33, 9, 41, 51, 19, 59, 27, 49, 17, 57, 25,
        15, 47, 7, 39, 13, 45, 5, 37, 63, 31, 55, 23, 61, 29, 53, 21,
    ].map { ($0 + 0.5) / 64 }

    static func apply(_ image: CIImage, algorithm: String, palette paletteID: String, levels: Int,
                      pixelSize: Double, strength: Double, scale: CGFloat) -> CIImage {
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1 else { return image }
        let p = max(1, (CGFloat(pixelSize) * scale).rounded())
        let w = max(1, Int((extent.width / p).rounded())), h = max(1, Int((extent.height / p).rounded()))
        guard var bmp = Bitmap(image, width: w, height: h) else { return image }

        let colors = palette(paletteID)
        let lv = Float(max(2, levels))
        @inline(__always) func nearest(_ c: SIMD3<Float>) -> SIMD3<Float> {
            guard let colors else {
                return (c * (lv - 1)).rounded(.toNearestOrAwayFromZero) / (lv - 1)
            }
            var best = colors[0], bestD = Float.greatestFiniteMagnitude
            for col in colors {
                let d = c - col
                // weight green higher, like the eye does
                let dist = d.x * d.x * 0.3 + d.y * d.y * 0.59 + d.z * d.z * 0.11
                if dist < bestD { bestD = dist; best = col }
            }
            return best
        }
        // How far ordered patterns push a color: about one palette step.
        let steps = Float(colors.map { $0.count - 1 } ?? Int(lv - 1))
        let spread = Float(strength) / max(1, steps)

        var buf = [SIMD3<Float>](repeating: .zero, count: w * h)
        bmp.pixels.withUnsafeBufferPointer { px in
            for i in 0..<(w * h) {
                let a = Float(px[i * 4 + 3]) / 255
                var c = SIMD3(Float(px[i * 4]), Float(px[i * 4 + 1]), Float(px[i * 4 + 2])) / 255
                if a > 0 { c /= a } // un-premultiply
                buf[i] = c
            }
        }

        switch algorithm {
        case "floyd", "atkinson":
            let atk = algorithm == "atkinson"
            let k = Float(strength)
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * w + x
                    let old = simd_clamp(buf[i], .zero, .one)
                    let new = nearest(old)
                    buf[i] = new
                    let err = (old - new) * k
                    @inline(__always) func push(_ dx: Int, _ dy: Int, _ f: Float) {
                        let nx = x + dx, ny = y + dy
                        if nx >= 0, nx < w, ny < h { buf[ny * w + nx] += err * f }
                    }
                    if atk {
                        push(1, 0, 1 / 8); push(2, 0, 1 / 8); push(-1, 1, 1 / 8)
                        push(0, 1, 1 / 8); push(1, 1, 1 / 8); push(0, 2, 1 / 8)
                    } else {
                        push(1, 0, 7 / 16); push(-1, 1, 3 / 16); push(0, 1, 5 / 16); push(1, 1, 1 / 16)
                    }
                }
            }
        case "bayer4", "bayer8", "noise":
            var rng = SplitMix(seed: 42)
            for y in 0..<h {
                for x in 0..<w {
                    let t: Float = switch algorithm {
                    case "bayer4": bayer4[(y & 3) * 4 + (x & 3)]
                    case "bayer8": bayer8[(y & 7) * 8 + (x & 7)]
                    default: rng.nextFloat()
                    }
                    let i = y * w + x
                    buf[i] = nearest(simd_clamp(buf[i] + SIMD3(repeating: (t - 0.5) * spread), .zero, .one))
                }
            }
        default:
            for i in buf.indices { buf[i] = nearest(simd_clamp(buf[i], .zero, .one)) }
        }

        bmp.pixels.withUnsafeMutableBufferPointer { px in
            for i in 0..<(w * h) {
                let c = simd_clamp(buf[i], .zero, .one) * 255
                px[i * 4] = UInt8(c.x.rounded()); px[i * 4 + 1] = UInt8(c.y.rounded())
                px[i * 4 + 2] = UInt8(c.z.rounded()); px[i * 4 + 3] = 255
            }
        }
        guard let small = bmp.ciImage() else { return image }
        let up = small.samplingNearest()
            .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(w), y: extent.height / CGFloat(h)))
        return CI.normalized(up).cropped(to: CGRect(origin: .zero, size: extent.size))
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func nextFloat() -> Float { Float(next() >> 40) / Float(1 << 24) }
}

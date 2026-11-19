import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

enum CI {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                                             .cacheIntermediates: false])

    static func cgImage(_ image: CIImage) -> CGImage? {
        let extent = image.extent.integral
        guard !extent.isInfinite, extent.width > 0, extent.height > 0 else { return nil }
        return context.createCGImage(image, from: extent, format: .RGBA8, colorSpace: sRGB)
    }

    /// Move an image so its extent starts at (0, 0).
    static func normalized(_ image: CIImage) -> CIImage {
        let e = image.extent
        guard e.origin != .zero, !e.isInfinite else { return image }
        return image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
    }

    /// Render down to an NSImage no bigger than `maxDimension` for the UI.
    static func thumbnail(_ image: CIImage, maxDimension: CGFloat) -> NSImage? {
        var img = normalized(image)
        let longest = max(img.extent.width, img.extent.height)
        if longest > maxDimension {
            let s = maxDimension / longest
            img = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }
        guard let cg = cgImage(img) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

enum ImageOps {
    static let readableTypes: [UTType] = [.image, .heic, .jpeg, .png, .tiff, .webP, .gif, .bmp, .rawImage]

    /// Loads an image with its orientation applied. In previews it reads a downsampled copy straight
    /// from the file, which is far faster than decoding the whole photo.
    static func load(_ url: URL, maxDimension: CGFloat?) throws -> NamedImage {
        let name = url.deletingPathExtension().lastPathComponent
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ToolError("Can't open \(url.lastPathComponent)")
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        var w = (props[kCGImagePropertyPixelWidth] as? CGFloat) ?? 0
        var h = (props[kCGImagePropertyPixelHeight] as? CGFloat) ?? 0
        if let o = props[kCGImagePropertyOrientation] as? UInt32, (5...8).contains(o) { swap(&w, &h) }

        if let maxDimension, max(w, h) > maxDimension {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else {
                throw ToolError("Can't read \(url.lastPathComponent)")
            }
            return NamedImage(name: name, image: CIImage(cgImage: cg), scale: CGFloat(cg.width) / max(w, 1))
        }
        guard let img = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw ToolError("Can't read \(url.lastPathComponent)")
        }
        return NamedImage(name: name, image: CI.normalized(img))
    }

    static func imageFiles(in urls: [URL]) -> [URL] {
        var result: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                result += items.filter { isImage($0) }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            } else if isImage(url) {
                result.append(url)
            }
        }
        return result
    }

    static func isImage(_ url: URL) -> Bool {
        (UTType(filenameExtension: url.pathExtension)?.conforms(to: .image)) ?? false
    }

    // MARK: Transforms (all take the working scale so pixel sizes match the final render)

    static func resize(_ img: CIImage, mode: String, percent: Double, width: Double, height: Double, scale: CGFloat) -> CIImage {
        let w = img.extent.width, h = img.extent.height
        guard w > 0, h > 0 else { return img }
        let tw = CGFloat(width) * scale, th = CGFloat(height) * scale
        var sx: CGFloat, sy: CGFloat
        switch mode {
        case "width": sx = tw / w; sy = sx
        case "height": sy = th / h; sx = sy
        case "fit": let s = min(tw / w, th / h); sx = s; sy = s
        case "fill": let s = max(tw / w, th / h); sx = s; sy = s
        case "exact": sx = tw / w; sy = th / h
        default: sx = CGFloat(percent / 100); sy = sx
        }
        guard sx > 0, sy > 0 else { return img }
        var out = img.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: sy,
            kCIInputAspectRatioKey: sx / sy,
        ])
        out = CI.normalized(out)
        let outW = (w * sx).rounded(), outH = (h * sy).rounded()
        if mode == "fill" {
            let cropX = ((out.extent.width - tw) / 2).rounded(), cropY = ((out.extent.height - th) / 2).rounded()
            out = CI.normalized(out.cropped(to: CGRect(x: max(0, cropX), y: max(0, cropY), width: min(tw, out.extent.width), height: min(th, out.extent.height))))
        } else {
            out = out.cropped(to: CGRect(x: 0, y: 0, width: outW, height: outH))
        }
        return out
    }

    static func crop(_ img: CIImage, aspect: String, left: Double, right: Double, top: Double, bottom: Double) -> CIImage {
        let e = img.extent
        var rect: CGRect
        if aspect == "free" {
            let l = e.width * left / 100, r = e.width * right / 100
            let t = e.height * top / 100, b = e.height * bottom / 100
            rect = CGRect(x: l, y: b, width: max(1, e.width - l - r), height: max(1, e.height - t - b))
        } else {
            let parts = aspect.split(separator: ":").compactMap { Double($0) }
            let ratio = parts.count == 2 && parts[1] > 0 ? CGFloat(parts[0] / parts[1]) : 1
            var w = e.width, h = e.width / ratio
            if h > e.height { h = e.height; w = h * ratio }
            rect = CGRect(x: (e.width - w) / 2, y: (e.height - h) / 2, width: w, height: h)
        }
        return CI.normalized(img.cropped(to: rect.integral.intersection(e)))
    }

    static func rotate(_ img: CIImage, degrees: Int, flipH: Bool, flipV: Bool) -> CIImage {
        var out = img
        switch degrees {
        case 90: out = out.oriented(.right)
        case 180: out = out.oriented(.down)
        case 270: out = out.oriented(.left)
        default: break
        }
        out = CI.normalized(out)
        if flipH { out = CI.normalized(out.oriented(.upMirrored)) }
        if flipV { out = CI.normalized(out.oriented(.downMirrored)) }
        return out
    }

    static func adjust(_ img: CIImage, exposure: Double, contrast: Double, saturation: Double, warmth: Double) -> CIImage {
        var out = img
        if exposure != 0 { out = out.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: exposure]) }
        if contrast != 1 || saturation != 1 {
            out = out.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: contrast, kCIInputSaturationKey: saturation,
            ])
        }
        if warmth != 0 {
            out = out.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 6500 - warmth * 25, y: 0),
            ])
        }
        return out.cropped(to: img.extent)
    }

    // MARK: Writing

    static func write(_ img: CIImage, to url: URL, format: String, quality: Double) throws {
        guard let cg = CI.cgImage(img) else { throw ToolError("Nothing to save") }
        let type: UTType = switch format {
        case "png": .png
        case "heic": .heic
        case "tiff": .tiff
        default: .jpeg
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ToolError("Can't write \(format.uppercased()) on this Mac")
        }
        let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, cg, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ToolError("Couldn't save \(url.lastPathComponent)") }
    }

    static func jpegData(_ cg: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}

/// RGBA8 pixel buffer helpers shared by Dither and ASCII.
struct Bitmap {
    var width: Int
    var height: Int
    var pixels: [UInt8]

    /// Draws the image into a width × height RGBA buffer (resampling it).
    init?(_ image: CIImage, width: Int, height: Int) {
        guard width > 0, height > 0, let cg = CI.cgImage(image) else { return nil }
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
        let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CI.sRGB,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        if !ok { return nil }
    }

    func ciImage() -> CIImage? {
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data),
              let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                               space: CI.sRGB, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return CIImage(cgImage: cg)
    }
}

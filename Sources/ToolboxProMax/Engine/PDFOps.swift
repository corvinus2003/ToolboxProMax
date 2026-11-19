import AppKit
import CoreText
import PDFKit

/// PDFs go through PDFKit and Quartz: pages stay vector, text stays selectable.
enum PDFOps {
    static func load(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw ToolError("Can't open \(url.lastPathComponent)") }
        if doc.isLocked { throw ToolError("\(url.lastPathComponent) is password-protected") }
        return doc
    }

    static func copy(_ doc: PDFDocument) -> PDFDocument {
        doc.dataRepresentation().flatMap { PDFDocument(data: $0) } ?? PDFDocument()
    }

    static func merge(_ docs: [PDFDocument]) -> PDFDocument {
        let out = PDFDocument()
        for doc in docs {
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i)?.copy() as? PDFPage { out.insert(page, at: out.pageCount) }
            }
        }
        return out
    }

    /// "1-3, 5, 8-" → [0, 1, 2, 4, 7, 8, ...]. Empty means every page.
    static func parsePages(_ spec: String, count: Int) -> [Int] {
        let trimmed = spec.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return Array(0..<count) }
        var result: [Int] = []
        for part in trimmed.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let p = part.trimmingCharacters(in: .whitespaces).lowercased()
            if p == "odd" { result += stride(from: 0, to: count, by: 2); continue }
            if p == "even" { result += stride(from: 1, to: count, by: 2); continue }
            let bits = p.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            if bits.count == 2 {
                let a = Int(bits[0]) ?? 1, b = Int(bits[1]) ?? count
                if a <= b { result += (max(1, a)...min(count, max(1, b))).map { $0 - 1 } }
                else { result += stride(from: min(count, a), through: max(1, b), by: -1).map { $0 - 1 } }
            } else if let n = Int(p), n >= 1, n <= count {
                result.append(n - 1)
            }
        }
        return result
    }

    static func pick(_ doc: PDFDocument, spec: String, rotate: Int, reverse: Bool) -> PDFDocument {
        let out = PDFDocument()
        var idx = parsePages(spec, count: doc.pageCount)
        if reverse { idx.reverse() }
        for i in idx {
            guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
            page.rotation = (page.rotation + rotate) % 360
            out.insert(page, at: out.pageCount)
        }
        return out
    }

    /// Redraws every page into a new PDF with something drawn on top. The page itself stays vector.
    static func overlay(_ doc: PDFDocument, _ draw: (CGContext, CGSize, Int, Int) -> Void) throws -> PDFDocument {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw ToolError("Can't create the PDF") }
        let count = doc.pageCount
        for i in 0..<count {
            guard let page = doc.page(at: i) else { continue }
            let box = page.bounds(for: .cropBox)
            let rotated = page.rotation % 180 != 0
            let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
            var media = CGRect(origin: .zero, size: size)
            let info = [kCGPDFContextMediaBox as String: NSData(bytes: &media, length: MemoryLayout<CGRect>.size)] as CFDictionary
            ctx.beginPDFPage(info)
            ctx.saveGState()
            page.transform(ctx, for: .cropBox)
            page.draw(with: .cropBox, to: ctx)
            ctx.restoreGState()
            ctx.saveGState()
            draw(ctx, size, i, count)
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        guard let out = PDFDocument(data: data as Data) else { throw ToolError("Can't create the PDF") }
        return out
    }

    static func drawText(_ text: String, in ctx: CGContext, at point: CGPoint, size: CGFloat, color: NSColor,
                         weight: NSFont.Weight = .regular, anchor: CGPoint = CGPoint(x: 0.5, y: 0.5), angle: CGFloat = 0) {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        ctx.saveGState()
        ctx.translateBy(x: point.x, y: point.y)
        ctx.rotate(by: angle * .pi / 180)
        ctx.textPosition = CGPoint(x: -bounds.width * anchor.x - bounds.minX, y: -bounds.height * anchor.y - bounds.minY)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    static func watermark(_ doc: PDFDocument, text: String, size: Double, opacity: Double, angle: Double, color: String) throws -> PDFDocument {
        let base: NSColor = switch color {
        case "red": .systemRed
        case "blue": .systemBlue
        case "black": .black
        default: .gray
        }
        return try overlay(doc) { ctx, page, _, _ in
            let pt = page.width * CGFloat(size) / 100
            drawText(text, in: ctx, at: CGPoint(x: page.width / 2, y: page.height / 2), size: pt,
                     color: base.withAlphaComponent(opacity), weight: .bold, angle: CGFloat(angle))
        }
    }

    static func pageNumbers(_ doc: PDFDocument, position: String, format: String, size: Double, first: Int) throws -> PDFDocument {
        try overlay(doc) { ctx, page, i, count in
            let label = format.replacingOccurrences(of: "{n}", with: "\(i + first)")
                .replacingOccurrences(of: "{total}", with: "\(count + first - 1)")
            let margin = max(18, page.width * 0.05)
            let x: CGFloat = position.hasSuffix("left") ? margin : position.hasSuffix("right") ? page.width - margin : page.width / 2
            let y: CGFloat = position.hasPrefix("top") ? page.height - margin * 0.8 : margin * 0.8
            let ax: CGFloat = position.hasSuffix("left") ? 0 : position.hasSuffix("right") ? 1 : 0.5
            drawText(label, in: ctx, at: CGPoint(x: x, y: y), size: CGFloat(size), color: .darkGray, anchor: CGPoint(x: ax, y: 0.5))
        }
    }

    static func fromImages(_ images: [NamedImage], pageSize: String, margin: Double) throws -> PDFDocument {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw ToolError("Can't create the PDF") }
        for item in images {
            guard let cg = CI.cgImage(item.image) else { continue }
            // Embedding JPEG data keeps the file small; Quartz stores it as-is.
            let embedded = ImageOps.jpegData(cg, quality: 0.85)
                .flatMap { CGDataProvider(data: $0 as CFData) }
                .flatMap { CGImage(jpegDataProviderSource: $0, decode: nil, shouldInterpolate: true, intent: .defaultIntent) } ?? cg
            let imgSize = CGSize(width: cg.width, height: cg.height)
            var page: CGSize
            switch pageSize {
            case "a4": page = CGSize(width: 595, height: 842)
            case "letter": page = CGSize(width: 612, height: 792)
            default: page = CGSize(width: imgSize.width * 72 / 150, height: imgSize.height * 72 / 150) // 150 dpi
            }
            if pageSize != "fit", imgSize.width > imgSize.height { page = CGSize(width: page.height, height: page.width) }
            let m = pageSize == "fit" ? 0 : CGFloat(margin)
            let area = CGRect(origin: .zero, size: page).insetBy(dx: m, dy: m)
            let s = min(area.width / imgSize.width, area.height / imgSize.height)
            let drawSize = CGSize(width: imgSize.width * s, height: imgSize.height * s)
            let rect = CGRect(x: area.midX - drawSize.width / 2, y: area.midY - drawSize.height / 2, width: drawSize.width, height: drawSize.height)
            var media = CGRect(origin: .zero, size: page)
            ctx.beginPDFPage([kCGPDFContextMediaBox as String: NSData(bytes: &media, length: MemoryLayout<CGRect>.size)] as CFDictionary)
            ctx.interpolationQuality = .high
            ctx.draw(embedded, in: rect)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        guard let doc = PDFDocument(data: data as Data), doc.pageCount > 0 else { throw ToolError("No images to put in the PDF") }
        return doc
    }

    static func toImages(_ doc: PDFDocument, name: String, dpi: Double, limit: Int? = nil) -> [NamedImage] {
        var out: [NamedImage] = []
        let n = min(doc.pageCount, limit ?? doc.pageCount)
        for i in 0..<n {
            guard let page = doc.page(at: i) else { continue }
            let box = page.bounds(for: .cropBox)
            let rotated = page.rotation % 180 != 0
            let pts = rotated ? CGSize(width: box.height, height: box.width) : box.size
            let s = CGFloat(dpi) / 72
            let w = Int(pts.width * s), h = Int(pts.height * s)
            guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                    space: CI.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            ctx.setFillColor(.white)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.scaleBy(x: s, y: s)
            page.transform(ctx, for: .cropBox)
            page.draw(with: .cropBox, to: ctx)
            if let cg = ctx.makeImage() {
                out.append(NamedImage(name: "\(name) page \(i + 1)", image: CIImage(cgImage: cg)))
            }
        }
        return out
    }

    static func write(_ doc: PDFDocument, to url: URL, password: String, compact: Bool) throws {
        var options: [PDFDocumentWriteOption: Any] = [:]
        if !password.isEmpty {
            options[.userPasswordOption] = password
            options[.ownerPasswordOption] = password
        }
        if compact {
            options[.saveImagesAsJPEGOption] = true
            options[.optimizeImagesForScreenOption] = true
        }
        guard doc.write(to: url, withOptions: options) else { throw ToolError("Couldn't save \(url.lastPathComponent)") }
    }
}

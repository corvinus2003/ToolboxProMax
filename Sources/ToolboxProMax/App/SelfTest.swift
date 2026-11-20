import AVFoundation
import AppKit
import PDFKit

/// `ToolboxProMax --selftest <folder>` makes sample media, runs every node on it and writes the results.
/// Add `--download <url>` to try the Download node too.
enum SelfTest {
    static func run(_ args: [String]) async -> Int32 {
        let dir = URL(fileURLWithPath: args.first { !$0.hasPrefix("-") } ?? NSTemporaryDirectory() + "tpm-selftest")
        let downloadURL = args.firstIndex(of: "--download").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        let samples = dir.appendingPathComponent("samples"), out = dir.appendingPathComponent("out")
        try? FileManager.default.removeItem(at: dir)
        try! FileManager.default.createDirectory(at: samples, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var failures = 0

        func step(_ name: String, _ body: () async throws -> String) async {
            let t0 = Date()
            do {
                let detail = try await body()
                print(String(format: "  ✓ %@ (%.2fs) %@", name, Date().timeIntervalSince(t0), detail))
            } catch {
                failures += 1
                print("  ✗ \(name): \(error.localizedDescription)")
            }
        }

        print("Making samples in \(samples.path)")
        let photo = samples.appendingPathComponent("photo.png")
        let silent = samples.appendingPathComponent("silent.mp4")
        let tone = samples.appendingPathComponent("tone.wav")
        let movie = samples.appendingPathComponent("movie.mp4")
        let folder = samples.appendingPathComponent("batch")
        let doc = samples.appendingPathComponent("doc.pdf")
        await step("sample photo") { try makePhoto(photo, text: "Toolbox Studio", hue: 0.62); return "" }
        await step("sample batch") {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (i, h) in [0.0, 0.33, 0.8].enumerated() { try makePhoto(folder.appendingPathComponent("p\(i + 1).png"), text: "Page \(i + 1)", hue: h) }
            return ""
        }
        await step("sample video") { try await makeVideo(silent); return "" }
        await step("sample tone") { try makeTone(tone); return "" }
        await step("join picture + sound") { try await VideoOps.merge(video: silent, audio: tone, to: movie); return "" }
        await step("sample PDF") {
            let imgs = try ImageOps.imageFiles(in: [folder]).map { try ImageOps.load($0, maxDimension: nil) }
            try PDFOps.write(try PDFOps.fromImages(imgs, pageSize: "a4", margin: 36), to: doc, password: "", compact: false)
            return ""
        }

        let target = ExportTarget(folder: out)
        func files(_ url: URL) -> [String: ParamValue] { ["file": .files([url.path])] }

        // name, chain of (kind, params), extra wiring
        let chains: [(String, [(String, [String: ParamValue])])] = [
            ("dither png", [("image", files(photo)), ("resize", ["percent": .number(50)]), ("dither", ["palette": .text("gameboy")]),
                            ("exportImage", ["format": .text("png"), "name": .text("dither")])]),
            ("ascii jpeg", [("image", files(photo)), ("ascii", [:]), ("exportImage", ["name": .text("ascii")])]),
            ("braille", [("image", files(photo)), ("ascii", ["charset": .text("braille"), "color": .bool(false)]), ("exportImage", ["name": .text("braille"), "format": .text("png")])]),
            ("crop rotate adjust heic", [("image", files(photo)), ("crop", ["aspect": .text("16:9")]), ("rotate", [:]),
                                         ("adjust", ["saturation": .number(1.6)]), ("exportImage", ["format": .text("heic"), "name": .text("cra")])]),
            ("resize exact", [("image", files(photo)), ("resize", ["mode": .text("fill"), "width": .number(500), "height": .number(500)]), ("exportImage", ["name": .text("fill500")])]),
            ("ocr", [("image", files(photo)), ("ocr", [:]), ("exportText", ["name": .text("ocr")])]),
            ("ascii text", [("image", files(photo)), ("asciiText", [:]), ("exportText", ["name": .text("ascii")])]),
            ("video dither h264", [("video", files(movie)), ("resize", ["percent": .number(50)]), ("dither", [:]), ("exportVideo", ["name": .text("dither")])]),
            ("video ascii hevc", [("video", files(movie)), ("ascii", ["columns": .number(80)]), ("exportVideo", ["format": .text("hevc"), "name": .text("ascii-hevc")])]),
            ("video prores", [("video", files(movie)), ("trimVideo", ["start": .number(1), "end": .number(2)]), ("exportVideo", ["format": .text("prores"), "name": .text("prores")])]),
            ("video gif", [("video", files(movie)), ("crop", [:]), ("exportVideo", ["format": .text("gif"), "width": .number(240), "name": .text("clip")])]),
            ("video passthrough", [("video", files(movie)), ("exportVideo", ["format": .text("original"), "name": .text("copy")])]),
            ("grab frame", [("video", files(movie)), ("frame", ["time": .number(1.5)]), ("exportImage", ["name": .text("frame")])]),
            ("extract → m4a", [("video", files(movie)), ("trimVideo", ["start": .number(0.5)]), ("extractAudio", [:]), ("fade", [:]),
                               ("normalize", [:]), ("exportAudio", ["name": .text("extracted")])]),
            ("audio wav", [("audio", files(tone)), ("trimAudio", ["start": .number(0.5), "end": .number(2)]), ("mono", [:]), ("exportAudio", ["format": .text("wav"), "name": .text("mono")])]),
            ("audio aiff", [("audio", files(tone)), ("exportAudio", ["format": .text("aiff"), "name": .text("tone")])]),
            ("audio alac", [("audio", files(tone)), ("exportAudio", ["format": .text("alac"), "name": .text("tone-alac")])]),
            ("photos → pdf", [("images", ["files": .files([folder.path])]), ("imagesToPDF", [:]), ("watermark", [:]), ("pageNumbers", ["format": .text("{n} / {total}")]),
                              ("exportPDF", ["password": .text("cojo"), "compact": .bool(true), "name": .text("album")])]),
            ("pick pages → images", [("pdf", files(doc)), ("pages", ["pages": .text("3-1")]), ("pdfToImages", ["dpi": .number(100)]), ("exportImage", ["name": .text("pages")])]),
            ("pdf ocr", [("pdf", files(doc)), ("ocr", [:]), ("exportText", ["name": .text("pdf-ocr")])]),
            ("lift subject", [("image", files(photo)), ("lift", ["background": .text("white")]), ("exportImage", ["name": .text("lift")])]),
            ("text", [("text", [:]), ("exportText", ["name": .text("hello")])]),
        ]

        var all: [(String, Graph)] = chains.map { name, chain in
            var g = Graph()
            var prev: UUID?
            for (i, link) in chain.enumerated() {
                let n = Node(kind: link.0, position: CGPoint(x: i * 260, y: 0), params: link.1)
                g.nodes.append(n)
                if let prev { g.edges.append(Edge(from: prev, to: n.id, toPort: 0)) }
                prev = n.id
            }
            return (name, g)
        }
        // merge needs two inputs
        do {
            var g = Graph()
            let a = Node(kind: "pdf", position: .zero, params: files(doc)), b = Node(kind: "pdf", position: .zero, params: files(doc))
            let m = Node(kind: "merge", position: .zero), e = Node(kind: "exportPDF", position: .zero, params: ["name": .text("merged")])
            g.nodes = [a, b, m, e]
            g.edges = [Edge(from: a.id, to: m.id, toPort: 0), Edge(from: b.id, to: m.id, toPort: 1), Edge(from: m.id, to: e.id, toPort: 0)]
            all.append(("merge", g))
        }
        if let downloadURL {
            for mode in ["video", "audio"] {
                var g = Graph()
                let d = Node(kind: "download", position: .zero, params: ["url": .text(downloadURL), "mode": .text(mode), "quality": .text("480")])
                let e = Node(kind: mode == "video" ? "exportVideo" : "exportAudio", position: .zero, params: ["format": .text(mode == "video" ? "original" : "m4a")])
                g.nodes = [d, e]
                g.edges = [Edge(from: d.id, to: e.id, toPort: 0)]
                all.append(("download \(mode)", g))
            }
        }

        print("Rendering into \(out.path)")
        let evaluator = Evaluator()
        for (name, g) in all {
            await step(name) {
                let exportNode = g.nodes.last!
                let kind = NodeKind.named(exportNode.kind)!
                let v = try await evaluator.value(of: exportNode.id, in: g, preview: false, maxDimension: 0)
                let urls = try await kind.export!(v, Params(values: exportNode.params, kind: kind), target)
                let sizes = urls.map { url -> String in
                    let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                    return "\(url.lastPathComponent) \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"
                }
                if case .text(let s) = v { return sizes.joined(separator: ", ") + " “\(s.prefix(40).replacingOccurrences(of: "\n", with: " "))”" }
                return sizes.joined(separator: ", ")
            }
        }

        print("Previews")
        let previewEval = Evaluator()
        for (name, g) in all {
            await step("preview \(name)") {
                var kinds: [String] = []
                for n in g.nodes {
                    let v = try await previewEval.value(of: n.id, in: g, preview: true, maxDimension: 900)
                    let p = try await PreviewPayload.make(v, maxDimension: 300, fraction: 0.3)
                    kinds.append(p.info)
                }
                return kinds.last ?? ""
            }
        }

        print(failures == 0 ? "All good." : "\(failures) failed.")
        return failures == 0 ? 0 : 1
    }

    static func makePhoto(_ url: URL, text: String, hue: Double) throws {
        let w = 1600, h = 1000
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CI.sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let c1 = NSColor(hue: hue, saturation: 0.7, brightness: 0.95, alpha: 1).cgColor
        let c2 = NSColor(hue: (hue + 0.15).truncatingRemainder(dividingBy: 1), saturation: 0.8, brightness: 0.35, alpha: 1).cgColor
        let grad = CGGradient(colorsSpace: CI.sRGB, colors: [c1, c2] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: w, y: h), options: [])
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.fillEllipse(in: CGRect(x: 980, y: 260, width: 420, height: 420))
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.85).cgColor)
        ctx.fill(CGRect(x: 160, y: 180, width: 520, height: 300))
        PDFOps.drawText(text, in: ctx, at: CGPoint(x: 800, y: 820), size: 120, color: .white, weight: .bold)
        let img = CIImage(cgImage: ctx.makeImage()!)
        try ImageOps.write(img, to: url, format: "png", quality: 1)
    }

    static func makeTone(_ url: URL) throws {
        let rate = 48000.0, seconds = 3.0
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(rate * seconds))!
        buf.frameLength = buf.frameCapacity
        for i in 0..<Int(buf.frameLength) {
            let t = Double(i) / rate
            let f = 220 + 440 * t / seconds // rising sweep
            let s = Float(sin(2 * .pi * f * t) * 0.3)
            buf.floatChannelData![0][i] = s
            buf.floatChannelData![1][i] = s * 0.8
        }
        try AudioOps.write(AudioClip(buffer: buf, name: "tone"), format: "wav", to: url)
    }

    static func makeVideo(_ url: URL) async throws {
        let w = 640, h = 360, fps: Int32 = 30, frames = 90
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for f in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            guard let pb else { throw ToolError("no pixel buffer") }
            CVPixelBufferLockBaseAddress(pb, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CI.sRGB,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            let p = Double(f) / Double(frames)
            ctx.setFillColor(NSColor(hue: 0.55 + p * 0.3, saturation: 0.6, brightness: 0.5, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: CGRect(x: 40 + p * 440, y: 110, width: 140, height: 140))
            PDFOps.drawText("Studio \(f)", in: ctx, at: CGPoint(x: 320, y: 50), size: 36, color: .white, weight: .semibold)
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? ToolError("video writer failed") }
    }
}

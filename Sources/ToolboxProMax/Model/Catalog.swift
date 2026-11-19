import CoreImage
import PDFKit
import UniformTypeIdentifiers

/// Every node in the library.
enum Catalog {
    static let all: [NodeKind] = inputs + image + video + audio + pdf + text + export
    static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func of(_ category: Category) -> [NodeKind] { all.filter { $0.category == category } }

    // MARK: Helpers

    static func input(_ inputs: [Value?], _ i: Int = 0) throws -> Value {
        guard inputs.indices.contains(i), let v = inputs[i] else { throw ToolError("Connect something to this node") }
        return v
    }

    /// Runs a frame effect on a still, on every still in a batch, or on every frame of a video.
    static func visual(_ v: Value, _ fx: @escaping FrameEffect) throws -> Value {
        switch v {
        case .image(var i):
            i.image = CI.normalized(fx(i.image, i.scale))
            return .image(i)
        case .images(let list):
            return .images(list.map { var i = $0; i.image = CI.normalized(fx(i.image, i.scale)); return i })
        case .video(var c):
            c.effects.append(fx)
            return .video(c)
        default:
            throw ToolError("This node works on pictures")
        }
    }

    static func stills(_ v: Value) throws -> [NamedImage] {
        switch v {
        case .image(let i): return [i]
        case .images(let l): return l
        default: throw ToolError("This node needs images")
        }
    }

    static func file(_ p: Params, _ what: String) throws -> URL {
        guard let url = p.files("file").first else { throw ToolError("Choose \(what)") }
        guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError("\(url.lastPathComponent) has moved or been deleted") }
        return url
    }

    static let visualPort = PortSpec(label: "Picture", accepts: [.image, .images, .video])
    static func port(_ t: PortType, _ label: String? = nil, optional: Bool = false) -> PortSpec {
        PortSpec(label: label ?? t.label, accepts: [t], optional: optional)
    }

    static func baseName(_ p: Params, _ v: Value) -> String {
        let custom = p.string("name").trimmingCharacters(in: .whitespaces)
        return custom.isEmpty ? v.name : custom
    }

    static let nameParam = ParamSpec.field("name", "File name", placeholder: "Same as the source")

    // MARK: Inputs

    static let inputs: [NodeKind] = baseInputs + downloadInputs

    static let baseInputs: [NodeKind] = [
        NodeKind(id: "image", title: "Image", symbol: "photo", category: .input,
                 summary: "A photo or picture from your Mac. iPhone HEIC works too.",
                 output: .image, params: [.files("file", "Image", types: ImageOps.readableTypes)]) { _, p, ctx in
            .image(try ImageOps.load(try file(p, "an image"), maxDimension: ctx.preview ? ctx.maxDimension : nil))
        },
        NodeKind(id: "images", title: "Several Images", symbol: "photo.stack", category: .input,
                 summary: "A batch of pictures, or a whole folder of them. Every node after it runs on each one.",
                 output: .images, params: [.files("files", "Images or folders", types: ImageOps.readableTypes + [.folder], multiple: true)]) { _, p, ctx in
            var urls = ImageOps.imageFiles(in: p.files("files"))
            guard !urls.isEmpty else { throw ToolError("Choose some images or a folder") }
            if ctx.preview { urls = Array(urls.prefix(24)) }
            return .images(try urls.map { try ImageOps.load($0, maxDimension: ctx.preview ? ctx.maxDimension / 2 : nil) })
        },
        NodeKind(id: "video", title: "Video", symbol: "film", category: .input,
                 summary: "A movie file: MP4, MOV, M4V…",
                 output: .video, params: [.files("file", "Video", types: VideoOps.readableTypes)]) { _, p, _ in
            let url = try file(p, "a video")
            return .video(VideoClip(url: url, name: url.deletingPathExtension().lastPathComponent))
        },
        NodeKind(id: "audio", title: "Audio", symbol: "waveform", category: .input,
                 summary: "A song, a voice memo or any sound file.",
                 output: .audio, params: [.files("file", "Sound", types: AudioOps.readableTypes)]) { _, p, _ in
            .audio(try await AudioOps.load(try file(p, "a sound file")))
        },
        NodeKind(id: "pdf", title: "PDF", symbol: "doc.richtext", category: .input,
                 summary: "A PDF document.",
                 output: .pdf, params: [.files("file", "PDF", types: [.pdf])]) { _, p, _ in
            let url = try file(p, "a PDF")
            return .pdf(try PDFOps.load(url), name: url.deletingPathExtension().lastPathComponent)
        },
        NodeKind(id: "text", title: "Text", symbol: "text.alignleft", category: .input,
                 summary: "Words you type or paste.",
                 output: .text, params: [.textArea("text", "Text", "Hello from \(Edition.appName)")]) { _, p, _ in
            .text(p.string("text"))
        },
    ]

    #if APPSTORE
    static let downloadInputs: [NodeKind] = []
    #else
    static let downloadInputs: [NodeKind] = [
        NodeKind(id: "download", title: "Download", symbol: "arrow.down.circle", category: .input,
                 summary: "Video or sound from YouTube, Vimeo, SoundCloud and a thousand other sites.",
                 output: .video, dynamicOutput: { $0.string("mode") == "audio" ? .audio : .video }, live: false,
                 params: [
                     .field("url", "Link", placeholder: "https://www.youtube.com/watch?v=…"),
                     .choice("mode", "Get", [("video", "Video with sound"), ("audio", "Sound only")], "video"),
                     .choice("quality", "Quality", [("1080", "1080p"), ("720", "720p"), ("480", "480p")], "1080",
                             visible: { $0.string("mode") == "video" }),
                 ]) { _, p, ctx in
            let url = p.string("url"), audioOnly = p.string("mode") == "audio", quality = p.string("quality")
            let result: Downloader.Result
            if let hit = await Downloader.shared.cached(url: url, audioOnly: audioOnly, quality: quality) {
                result = hit
            } else if ctx.preview {
                throw ToolError(url.isEmpty ? "Paste a link" : "Press Download to fetch it")
            } else {
                result = try await Downloader.shared.download(url: url, audioOnly: audioOnly, quality: quality, progress: ctx.progress)
            }
            if audioOnly {
                var clip = try await AudioOps.load(result.file)
                clip.name = result.title
                return .audio(clip)
            }
            return .video(VideoClip(url: result.file, name: result.title))
        },
    ]
    #endif

    // MARK: Image

    static let image: [NodeKind] = [
        NodeKind(id: "resize", title: "Resize", symbol: "arrow.up.left.and.arrow.down.right", category: .image,
                 summary: "Make it bigger or smaller.",
                 inputs: [visualPort], output: .visual,
                 params: [
                     .choice("mode", "Size by", [("percent", "Percentage"), ("width", "Width"), ("height", "Height"),
                                                  ("fit", "Fit inside a box"), ("fill", "Fill a box (crop)"), ("exact", "Exact size")], "percent"),
                     .slider("percent", "Scale", 5...400, unit: "%", 50, visible: { $0.string("mode") == "percent" }),
                     .slider("width", "Width", 16...7680, unit: "px", 1920, visible: { ["width", "fit", "fill", "exact"].contains($0.string("mode")) }),
                     .slider("height", "Height", 16...4320, unit: "px", 1080, visible: { ["height", "fit", "fill", "exact"].contains($0.string("mode")) }),
                 ]) { inputs, p, _ in
            let mode = p.string("mode"), pct = p.number("percent"), w = p.number("width"), h = p.number("height")
            return try visual(try input(inputs)) { ImageOps.resize($0, mode: mode, percent: pct, width: w, height: h, scale: $1) }
        },
        NodeKind(id: "crop", title: "Crop", symbol: "crop", category: .image,
                 summary: "Cut to a shape like square or 16:9, or trim the edges.",
                 inputs: [visualPort], output: .visual,
                 params: [
                     .choice("aspect", "Shape", [("1:1", "Square"), ("4:5", "4:5 portrait"), ("4:3", "4:3"), ("3:2", "3:2"),
                                                  ("16:9", "16:9 wide"), ("9:16", "9:16 story"), ("free", "Trim edges")], "1:1"),
                     .slider("left", "Left", 0...45, unit: "%", 0, visible: { $0.string("aspect") == "free" }),
                     .slider("right", "Right", 0...45, unit: "%", 0, visible: { $0.string("aspect") == "free" }),
                     .slider("top", "Top", 0...45, unit: "%", 0, visible: { $0.string("aspect") == "free" }),
                     .slider("bottom", "Bottom", 0...45, unit: "%", 0, visible: { $0.string("aspect") == "free" }),
                 ]) { inputs, p, _ in
            let a = p.string("aspect"), l = p.number("left"), r = p.number("right"), t = p.number("top"), b = p.number("bottom")
            return try visual(try input(inputs)) { img, _ in ImageOps.crop(img, aspect: a, left: l, right: r, top: t, bottom: b) }
        },
        NodeKind(id: "rotate", title: "Rotate & Flip", symbol: "rotate.right", category: .image,
                 summary: "Turn it a quarter at a time, or mirror it.",
                 inputs: [visualPort], output: .visual,
                 params: [
                     .choice("angle", "Rotate", [("0", "None"), ("90", "90° right"), ("180", "180°"), ("270", "90° left")], "90"),
                     .toggle("flipH", "Mirror left–right", false),
                     .toggle("flipV", "Flip upside down", false),
                 ]) { inputs, p, _ in
            let a = Int(p.string("angle")) ?? 0, h = p.bool("flipH"), v = p.bool("flipV")
            return try visual(try input(inputs)) { img, _ in ImageOps.rotate(img, degrees: a, flipH: h, flipV: v) }
        },
        NodeKind(id: "adjust", title: "Adjust", symbol: "slider.horizontal.3", category: .image,
                 summary: "Brightness, contrast, color and warmth.",
                 inputs: [visualPort], output: .visual,
                 params: [
                     .slider("exposure", "Exposure", -2...2, step: 0.05, unit: "EV", 0),
                     .slider("contrast", "Contrast", 0.5...1.8, step: 0.01, 1),
                     .slider("saturation", "Saturation", 0...2, step: 0.01, 1),
                     .slider("warmth", "Warmth", -100...100, unit: "", 0),
                 ]) { inputs, p, _ in
            let e = p.number("exposure"), c = p.number("contrast"), s = p.number("saturation"), w = p.number("warmth")
            return try visual(try input(inputs)) { img, _ in ImageOps.adjust(img, exposure: e, contrast: c, saturation: s, warmth: w) }
        },
        NodeKind(id: "dither", title: "Dither", symbol: "circle.grid.3x3.fill", category: .image,
                 summary: "Retro pixel look: few colors, clever dot patterns.",
                 inputs: [visualPort], output: .visual,
                 params: [
                     .choice("algorithm", "Pattern", Dither.algorithms, "atkinson"),
                     .choice("palette", "Colors", Dither.palettes, "mono"),
                     .slider("levels", "Levels per channel", 2...8, 3, visible: { $0.string("palette") == "rgb" }),
                     .slider("pixel", "Pixel size", 1...16, unit: "px", 2),
                     .slider("strength", "Strength", 0...1, step: 0.01, 1, visible: { $0.string("algorithm") != "threshold" }),
                 ]) { inputs, p, _ in
            let a = p.string("algorithm"), pal = p.string("palette"), lv = p.int("levels"), px = p.number("pixel"), st = p.number("strength")
            return try visual(try input(inputs)) { Dither.apply($0, algorithm: a, palette: pal, levels: lv, pixelSize: px, strength: st, scale: $1) }
        },
        NodeKind(id: "ascii", title: "ASCII Art", symbol: "character.textbox", category: .image,
                 summary: "Redraw the picture out of letters, blocks or braille dots.",
                 inputs: [visualPort], output: .visual,
                 params: [
                     .slider("columns", "Columns", 20...300, 120),
                     .choice("charset", "Characters", ASCII.charsets, "classic"),
                     .toggle("color", "In color", true),
                     .toggle("dark", "Dark background", true),
                     .toggle("invert", "Invert", false),
                 ]) { inputs, p, _ in
            let cols = p.int("columns"), cs = p.string("charset"), col = p.bool("color"), dark = p.bool("dark"), inv = p.bool("invert")
            return try visual(try input(inputs)) { img, _ in ASCII.render(img, columns: cols, charset: cs, invert: inv, color: col, darkBackground: dark) }
        },
        NodeKind(id: "lift", title: "Lift Subject", symbol: "person.crop.rectangle.badge.plus", category: .image,
                 summary: "Cut the person, pet or thing out of the background. On-device, like on iPhone.",
                 inputs: [visualPort], output: .visual,
                 params: [
                     .choice("background", "Background", [("clear", "Transparent"), ("white", "White"), ("black", "Black"), ("blur", "Blurred")], "clear"),
                     .toggle("crop", "Crop to the subject", false),
                 ]) { inputs, p, _ in
            let bg = p.string("background"), crop = p.bool("crop")
            return try visual(try input(inputs)) { img, _ in (try? VisionOps.liftSubject(img, background: bg, cropToSubject: crop)) ?? img }
        },
    ]

    // MARK: Video

    static let video: [NodeKind] = [
        NodeKind(id: "trimVideo", title: "Trim Video", symbol: "timeline.selection", category: .video,
                 summary: "Keep only part of the clip.",
                 inputs: [port(.video)], output: .video,
                 params: [
                     .slider("start", "Start", 0...3600, step: 0.1, unit: "s", 0),
                     .slider("end", "End (0 = to the end)", 0...3600, step: 0.1, unit: "s", 0),
                 ]) { inputs, p, _ in
            guard case .video(var c) = try input(inputs) else { throw ToolError("Needs a video") }
            let base = c.start
            c.start = base + p.number("start")
            if p.number("end") > 0 { c.end = min(c.end ?? .infinity, base + p.number("end")) }
            return .video(c)
        },
        NodeKind(id: "frame", title: "Grab Frame", symbol: "camera.viewfinder", category: .video,
                 summary: "Take one still picture out of the video.",
                 inputs: [port(.video)], output: .image,
                 params: [.slider("time", "At", 0...3600, step: 0.1, unit: "s", 1)]) { inputs, p, ctx in
            guard case .video(let c) = try input(inputs) else { throw ToolError("Needs a video") }
            var f = try await VideoOps.frame(c, fraction: 0, seconds: p.number("time"), maxDimension: ctx.preview ? ctx.maxDimension : nil)
            f.name = "\(c.name) frame"
            return .image(f)
        },
    ]

    // MARK: Audio

    static let audio: [NodeKind] = [
        NodeKind(id: "extractAudio", title: "Extract Audio", symbol: "waveform.badge.plus", category: .audio,
                 summary: "Take the sound out of a video.",
                 inputs: [port(.video)], output: .audio) { inputs, _, _ in
            guard case .video(let c) = try input(inputs) else { throw ToolError("Needs a video") }
            var clip = try await AudioOps.load(c.url, start: c.start, end: c.end)
            clip.name = c.name // keep the video's title, not the file name (downloads are all "merged.mp4")
            return .audio(clip)
        },
        NodeKind(id: "trimAudio", title: "Trim Audio", symbol: "scissors", category: .audio,
                 summary: "Keep only part of the sound.",
                 inputs: [port(.audio)], output: .audio,
                 params: [
                     .slider("start", "Start", 0...3600, step: 0.1, unit: "s", 0),
                     .slider("end", "End (0 = to the end)", 0...3600, step: 0.1, unit: "s", 0),
                 ]) { inputs, p, _ in
            guard case .audio(let a) = try input(inputs) else { throw ToolError("Needs sound") }
            return .audio(AudioOps.trim(a, start: p.number("start"), end: p.number("end")))
        },
        NodeKind(id: "fade", title: "Fade", symbol: "speaker.wave.2", category: .audio,
                 summary: "Fade in at the start and out at the end.",
                 inputs: [port(.audio)], output: .audio,
                 params: [
                     .slider("in", "Fade in", 0...20, step: 0.1, unit: "s", 1),
                     .slider("out", "Fade out", 0...20, step: 0.1, unit: "s", 2),
                 ]) { inputs, p, _ in
            guard case .audio(let a) = try input(inputs) else { throw ToolError("Needs sound") }
            return .audio(AudioOps.fade(a, fadeIn: p.number("in"), fadeOut: p.number("out")))
        },
        NodeKind(id: "normalize", title: "Normalize", symbol: "chart.bar.xaxis", category: .audio,
                 summary: "Make the loudest moment hit a set level.",
                 inputs: [port(.audio)], output: .audio,
                 params: [.slider("peak", "Loudest peak", -12...0, step: 0.1, unit: "dB", -1)]) { inputs, p, _ in
            guard case .audio(let a) = try input(inputs) else { throw ToolError("Needs sound") }
            return .audio(AudioOps.normalize(a, peakDB: p.number("peak")))
        },
        NodeKind(id: "mono", title: "Mix to Mono", symbol: "speaker", category: .audio,
                 summary: "Fold stereo down to one channel.",
                 inputs: [port(.audio)], output: .audio) { inputs, _, _ in
            guard case .audio(let a) = try input(inputs) else { throw ToolError("Needs sound") }
            return .audio(AudioOps.toMono(a))
        },
    ]

    // MARK: PDF

    static let pdf: [NodeKind] = [
        NodeKind(id: "merge", title: "Merge PDFs", symbol: "doc.on.doc", category: .pdf,
                 summary: "Put several PDFs one after another.",
                 inputs: [port(.pdf, "First"), port(.pdf, "Second", optional: true), port(.pdf, "Third", optional: true), port(.pdf, "Fourth", optional: true)],
                 output: .pdf) { inputs, _, _ in
            var docs: [PDFDocument] = []
            var name = "merged"
            for v in inputs {
                guard case .pdf(let d, let n)? = v else { continue }
                if docs.isEmpty { name = "\(n) merged" }
                docs.append(d)
            }
            guard !docs.isEmpty else { throw ToolError("Connect at least one PDF") }
            return .pdf(PDFOps.merge(docs), name: name)
        },
        NodeKind(id: "pages", title: "Pick Pages", symbol: "list.number", category: .pdf,
                 summary: "Choose, reorder or turn pages.",
                 inputs: [port(.pdf)], output: .pdf,
                 params: [
                     .field("pages", "Pages", placeholder: "e.g. 1-3, 5, 8-  or  odd / even"),
                     .choice("rotate", "Turn", [("0", "Don't turn"), ("90", "90° right"), ("180", "180°"), ("270", "90° left")], "0"),
                     .toggle("reverse", "Reverse order", false),
                 ]) { inputs, p, _ in
            guard case .pdf(let d, let n) = try input(inputs) else { throw ToolError("Needs a PDF") }
            let out = PDFOps.pick(d, spec: p.string("pages"), rotate: Int(p.string("rotate")) ?? 0, reverse: p.bool("reverse"))
            guard out.pageCount > 0 else { throw ToolError("No pages match “\(p.string("pages"))”") }
            return .pdf(out, name: n)
        },
        NodeKind(id: "watermark", title: "Watermark", symbol: "seal", category: .pdf,
                 summary: "Stamp a word across every page.",
                 inputs: [port(.pdf)], output: .pdf,
                 params: [
                     .field("text", "Text", placeholder: "DRAFT", "DRAFT"),
                     .slider("size", "Size", 4...40, unit: "%", 14),
                     .slider("opacity", "Opacity", 0.05...1, step: 0.01, 0.18),
                     .slider("angle", "Angle", -90...90, unit: "°", 45),
                     .choice("color", "Color", [("gray", "Gray"), ("red", "Red"), ("blue", "Blue"), ("black", "Black")], "gray"),
                 ]) { inputs, p, _ in
            guard case .pdf(let d, let n) = try input(inputs) else { throw ToolError("Needs a PDF") }
            return .pdf(try PDFOps.watermark(d, text: p.string("text"), size: p.number("size"), opacity: p.number("opacity"),
                                             angle: p.number("angle"), color: p.string("color")), name: n)
        },
        NodeKind(id: "pageNumbers", title: "Page Numbers", symbol: "number", category: .pdf,
                 summary: "Number every page.",
                 inputs: [port(.pdf)], output: .pdf,
                 params: [
                     .choice("position", "Where", [("bottom-center", "Bottom middle"), ("bottom-right", "Bottom right"),
                                                   ("bottom-left", "Bottom left"), ("top-right", "Top right")], "bottom-center"),
                     .choice("format", "Style", [("{n}", "1"), ("{n} / {total}", "1 / 12"), ("Page {n}", "Page 1"), ("– {n} –", "– 1 –")], "{n}"),
                     .slider("size", "Size", 6...24, unit: "pt", 10),
                     .slider("first", "Start at", 0...500, 1),
                 ]) { inputs, p, _ in
            guard case .pdf(let d, let n) = try input(inputs) else { throw ToolError("Needs a PDF") }
            return .pdf(try PDFOps.pageNumbers(d, position: p.string("position"), format: p.string("format"),
                                               size: p.number("size"), first: p.int("first")), name: n)
        },
        NodeKind(id: "imagesToPDF", title: "Images to PDF", symbol: "doc.badge.plus", category: .pdf,
                 summary: "One picture per page.",
                 inputs: [PortSpec(label: "Images", accepts: [.image, .images])], output: .pdf,
                 params: [
                     .choice("page", "Page size", [("fit", "Same as the picture"), ("a4", "A4"), ("letter", "US Letter")], "a4"),
                     .slider("margin", "Margin", 0...72, unit: "pt", 24, visible: { $0.string("page") != "fit" }),
                 ]) { inputs, p, _ in
            let v = try input(inputs)
            return .pdf(try PDFOps.fromImages(try stills(v), pageSize: p.string("page"), margin: p.number("margin")), name: v.name)
        },
        NodeKind(id: "pdfToImages", title: "PDF to Images", symbol: "photo.on.rectangle", category: .pdf,
                 summary: "Turn each page into a picture.",
                 inputs: [port(.pdf)], output: .images,
                 params: [.slider("dpi", "Sharpness", 72...600, unit: "dpi", 200)]) { inputs, p, ctx in
            guard case .pdf(let d, let n) = try input(inputs) else { throw ToolError("Needs a PDF") }
            let imgs = PDFOps.toImages(d, name: n, dpi: ctx.preview ? 72 : p.number("dpi"), limit: ctx.preview ? 8 : nil)
                .map { var i = $0; if ctx.preview { i.scale = 72 / p.number("dpi") }; return i }
            return .images(imgs)
        },
    ]

    // MARK: Text

    static let text: [NodeKind] = [
        NodeKind(id: "ocr", title: "Read Text", symbol: "text.viewfinder", category: .text,
                 summary: "Live Text: copy out the words in a photo, a screenshot or a scanned PDF.",
                 inputs: [PortSpec(label: "Picture or PDF", accepts: [.image, .images, .pdf])], output: .text,
                 params: [.toggle("fast", "Fast mode when rendering", false)]) { inputs, p, ctx in
            let v = try input(inputs)
            var pages: [NamedImage]
            if case .pdf(let d, let n) = v {
                pages = PDFOps.toImages(d, name: n, dpi: ctx.preview ? 110 : 220, limit: ctx.preview ? 2 : nil)
            } else {
                pages = try stills(v)
            }
            // Live previews use the quick model; Render uses the accurate one unless "Fast" is on.
            let fast = p.bool("fast") || ctx.preview
            let texts = try pages.map { try VisionOps.recognizeText($0.image, fast: fast) }
            return .text(texts.joined(separator: "\n\n"))
        },
        NodeKind(id: "asciiText", title: "ASCII to Text", symbol: "textformat.abc", category: .text,
                 summary: "The picture as plain text art you can paste anywhere.",
                 inputs: [PortSpec(label: "Image", accepts: [.image])], output: .text,
                 params: [
                     .slider("columns", "Columns", 20...200, 80),
                     .choice("charset", "Characters", ASCII.charsets, "classic"),
                     .toggle("dark", "For dark backgrounds", false),
                 ]) { inputs, p, _ in
            guard case .image(let i) = try input(inputs) else { throw ToolError("Needs an image") }
            guard let g = ASCII.grid(i.image, columns: p.int("columns"), charset: p.string("charset"), invert: false,
                                     darkBackground: p.bool("dark")) else { throw ToolError("Image is empty") }
            return .text(ASCII.text(g))
        },
    ]

    // MARK: Export

    static let export: [NodeKind] = [
        NodeKind(id: "exportImage", title: "Export Image", symbol: "square.and.arrow.down", category: .export,
                 summary: "Save as JPEG, HEIC, PNG or TIFF.",
                 inputs: [PortSpec(label: "Images", accepts: [.image, .images])],
                 params: [
                     .choice("format", "Format", [("jpeg", "JPEG"), ("heic", "HEIC"), ("png", "PNG"), ("tiff", "TIFF")], "jpeg"),
                     .slider("quality", "Quality", 0.3...1, step: 0.01, 0.88, visible: { ["jpeg", "heic"].contains($0.string("format")) }),
                     nameParam,
                 ], evaluate: { inputs, _, _ in try input(inputs) },
                 export: { v, p, target in
                     let f = p.string("format"), ext = f == "jpeg" ? "jpg" : f
                     let list = try stills(v)
                     let custom = !p.string("name").trimmingCharacters(in: .whitespaces).isEmpty
                     var urls: [URL] = []
                     for (i, img) in list.enumerated() {
                         try Task.checkCancellation()
                         let base = custom ? (list.count > 1 ? "\(p.string("name")) \(i + 1)" : p.string("name")) : img.name
                         let url = target.uniqueURL(base, ext: ext)
                         try ImageOps.write(img.image, to: url, format: f, quality: p.number("quality"))
                         urls.append(url)
                         target.progress(Double(i + 1) / Double(list.count))
                     }
                     return urls
                 }),
        NodeKind(id: "exportVideo", title: "Export Video", symbol: "square.and.arrow.down.on.square", category: .export,
                 summary: "Save as MP4 (H.264 or HEVC), ProRes or GIF.",
                 inputs: [port(.video)],
                 params: [
                     .choice("format", "Format", VideoOps.formats, "h264"),
                     .slider("fps", "Frames per second", 5...30, 12, visible: { $0.string("format") == "gif" }),
                     .slider("width", "Width", 120...1280, unit: "px", 480, visible: { $0.string("format") == "gif" }),
                     nameParam,
                 ], evaluate: { inputs, _, _ in try input(inputs) },
                 export: { v, p, target in
                     guard case .video(let clip) = v else { throw ToolError("Needs a video") }
                     let f = p.string("format"), base = baseName(p, v)
                     if f == "gif" {
                         let url = target.uniqueURL(base, ext: "gif")
                         try await VideoOps.gif(clip, fps: p.number("fps"), width: p.number("width"), to: url, progress: target.progress)
                         return [url]
                     }
                     let ext = f == "prores" ? "mov" : (f == "original" && clip.url.pathExtension.lowercased() == "mov" ? "mov" : "mp4")
                     let url = target.uniqueURL(base, ext: ext)
                     try await VideoOps.export(clip, format: f, to: url, progress: target.progress)
                     return [url]
                 }),
        NodeKind(id: "exportAudio", title: "Export Audio", symbol: "square.and.arrow.down.badge.clock", category: .export,
                 summary: "Save as M4A, Apple Lossless, WAV or AIFF.",
                 inputs: [port(.audio)],
                 params: [.choice("format", "Format", AudioOps.formats, "m4a"), nameParam],
                 evaluate: { inputs, _, _ in try input(inputs) },
                 export: { v, p, target in
                     guard case .audio(let clip) = v else { throw ToolError("Needs sound") }
                     let f = p.string("format")
                     let url = target.uniqueURL(baseName(p, v), ext: f == "alac" ? "m4a" : (f == "aiff" ? "aif" : f))
                     try AudioOps.write(clip, format: f, to: url)
                     return [url]
                 }),
        NodeKind(id: "exportPDF", title: "Export PDF", symbol: "arrow.down.doc", category: .export,
                 summary: "Save the PDF, with a password or made smaller if you like.",
                 inputs: [port(.pdf)],
                 params: [
                     .secure("password", "Password", placeholder: "None"),
                     .toggle("compact", "Make it smaller (compress images)", false),
                     nameParam,
                 ], evaluate: { inputs, _, _ in try input(inputs) },
                 export: { v, p, target in
                     guard case .pdf(let d, _) = v else { throw ToolError("Needs a PDF") }
                     let url = target.uniqueURL(baseName(p, v), ext: "pdf")
                     try PDFOps.write(d, to: url, password: p.string("password"), compact: p.bool("compact"))
                     return [url]
                 }),
        NodeKind(id: "exportText", title: "Export Text", symbol: "doc.plaintext", category: .export,
                 summary: "Save as a plain .txt file.",
                 inputs: [port(.text)],
                 params: [nameParam],
                 evaluate: { inputs, _, _ in try input(inputs) },
                 export: { v, p, target in
                     guard case .text(let s) = v else { throw ToolError("Needs text") }
                     let url = target.uniqueURL(baseName(p, v), ext: "txt")
                     try s.write(to: url, atomically: true, encoding: .utf8)
                     return [url]
                 }),
    ]
}


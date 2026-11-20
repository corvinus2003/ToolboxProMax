// Builds the Toolbox Pro Max trailer from the screen recordings.
// usage: trailer <"01 Recordings" folder> <icon.png> <lang ro|en> <out.mp4>
// Writes <out.mp4>.video.mp4 (no sound); add music with mux.
import AVFoundation
import AppKit
import CoreImage
import CoreText

let args = CommandLine.arguments
let recDir = args[1], iconPath = args[2], lang = args[3], outPath = args[4]
let W = 1920, H = 1080, FPS: Int32 = 30
let ro = lang == "ro"
let takes = ["a": "Take A - Photo, Dither, ASCII, Export.mov",
             "b": "Take B - YouTube download, audio workflow, Render.mov",
             "c": "Take C - Astronaut, Lift Subject.mov"]

struct Zoom { var s: CGFloat; var x: CGFloat; var y: CGFloat }
let none = Zoom(s: 1, x: 0.5, y: 0.5)
struct Seg {
    let src: String; let start: Double; let end: Double; let speed: Double
    let caption: String; var sub: String = ""; var z0 = none; var z1 = none
    var outDur: Double { (end - start) / speed }
}

func T(_ r: String, _ e: String) -> String { ro ? r : e }

let segs: [Seg] = [
    Seg(src: "a", start: 7.0, end: 13.5, speed: 1, caption: T("Trage orice înăuntru.", "Drop anything in."),
        sub: T("Poze, video, sunet, PDF-uri.", "Photos, video, sound, PDFs.")),
    Seg(src: "a", start: 15.0, end: 21.0, speed: 1, caption: T("Alegi o unealtă. Se leagă singură.", "Pick a tool. It wires itself in."),
        z0: none, z1: Zoom(s: 1.25, x: 0.42, y: 0.40)),
    Seg(src: "a", start: 26.0, end: 49.0, speed: 3, caption: T("Fiecare schimbare se vede live.", "Every change previews live."),
        z0: Zoom(s: 1.3, x: 0.6, y: 0.38), z1: Zoom(s: 1.5, x: 0.66, y: 0.36)),
    Seg(src: "a", start: 53.0, end: 58.0, speed: 1.2, caption: T("Mai adaugi unelte…", "Drag in more tools…")),
    Seg(src: "a", start: 73.3, end: 76.0, speed: 0.6, caption: T("…și legi orice de orice.", "…and wire anything to anything."),
        z0: Zoom(s: 1.5, x: 0.4, y: 0.45), z1: Zoom(s: 1.65, x: 0.4, y: 0.47)),
    Seg(src: "a", start: 79.5, end: 89.5, speed: 1.5, caption: T("Pui un Export. Apeși ⌘R. Gata.", "Add an Export. Press ⌘R. Done.")),
    Seg(src: "b", start: 15.5, end: 23.5, speed: 1.6, caption: T("Lipești un link de YouTube.", "Paste a YouTube link."),
        z0: Zoom(s: 1.2, x: 0.55, y: 0.4), z1: Zoom(s: 1.35, x: 0.62, y: 0.38)),
    Seg(src: "b", start: 23.5, end: 48.5, speed: 5, caption: T("Imaginea și sunetul vin împreună.", "Picture and sound arrive together."),
        sub: T("Fără ffmpeg.", "No ffmpeg required."), z0: Zoom(s: 1.35, x: 0.62, y: 0.38), z1: Zoom(s: 1.35, x: 0.62, y: 0.38)),
    Seg(src: "b", start: 48.5, end: 56.5, speed: 1.6, caption: T("Îl poți derula imediat.", "Scrub through it right away."),
        z0: Zoom(s: 1.35, x: 0.62, y: 0.38), z1: Zoom(s: 1.2, x: 0.6, y: 0.4)),
    Seg(src: "b", start: 77.0, end: 81.0, speed: 1, caption: T("Scoți sunetul din clip…", "Pull the sound out…")),
    Seg(src: "b", start: 97.2, end: 99.6, speed: 0.6, caption: T("Scoți sunetul din clip…", "Pull the sound out…"),
        z0: Zoom(s: 1.55, x: 0.35, y: 0.5), z1: Zoom(s: 1.7, x: 0.35, y: 0.52)),
    Seg(src: "b", start: 102.0, end: 118.5, speed: 2.75, caption: T("…îl faci mono și îl exporți.", "…make it mono, export it.")),
    Seg(src: "b", start: 119.0, end: 126.0, speed: 1.4, caption: T("Render: totul, dintr-o dată.", "Render everything at once.")),
    Seg(src: "c", start: 8.5, end: 13.5, speed: 1, caption: T("Decupezi subiectul. Direct pe Mac.", "Lift the subject out. On-device.")),
    Seg(src: "c", start: 28.0, end: 36.0, speed: 1.6, caption: T("Decupezi subiectul. Direct pe Mac.", "Lift the subject out. On-device."),
        z0: Zoom(s: 1.2, x: 0.6, y: 0.4), z1: Zoom(s: 1.4, x: 0.68, y: 0.36)),
]

let titleDur = 3.6, endDur = 6.0
let mainDur = segs.reduce(0) { $0 + $1.outDur }
let total = titleDur + mainDur + endDur
print(String(format: "Trailer length: %.1f s", total))

// MARK: Drawing helpers

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
let ci = CIContext(options: [.workingColorSpace: sRGB, .cacheIntermediates: false])

func cgContext(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

/// A line of text as an image (with its size).
func textImage(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, tracking: CGFloat = 0) -> CIImage {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let attr = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .kern: tracking])
    let line = CTLineCreateWithAttributedString(attr)
    let b = CTLineGetBoundsWithOptions(line, [])
    let w = Int(ceil(b.width)) + 8, h = Int(ceil(font.ascender - font.descender)) + 8
    let ctx = cgContext(w, h)
    ctx.textPosition = CGPoint(x: 4 - b.minX, y: 4 - font.descender)
    CTLineDraw(line, ctx)
    return CIImage(cgImage: ctx.makeImage()!)
}

func place(_ img: CIImage, centerX: CGFloat, topY: CGFloat) -> CIImage {
    // topY in top-left coordinates
    let e = img.extent
    return img.transformed(by: CGAffineTransform(translationX: centerX - e.width / 2, y: CGFloat(H) - topY - e.height))
}

func fade(_ img: CIImage, _ a: CGFloat) -> CIImage {
    if a >= 0.999 { return img }
    return img.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: max(0, a))])
}

func ease(_ t: Double) -> Double { let x = min(1, max(0, t)); return x * x * (3 - 2 * x) }

// Background: dark gradient in the icon's colours with a slowly drifting glow.
func background(_ t: Double) -> CIImage {
    let rect = CGRect(x: 0, y: 0, width: W, height: H)
    let base = CIFilter(name: "CILinearGradient", parameters: [
        "inputPoint0": CIVector(x: 0, y: CGFloat(H)), "inputPoint1": CIVector(x: CGFloat(W), y: 0),
        "inputColor0": CIColor(red: 0.05, green: 0.04, blue: 0.13), "inputColor1": CIColor(red: 0.16, green: 0.06, blue: 0.20),
    ])!.outputImage!.cropped(to: rect)
    let gx = CGFloat(W) * (0.5 + 0.18 * sin(t * 0.25)), gy = CGFloat(H) * (0.45 + 0.1 * cos(t * 0.2))
    let glow = CIFilter(name: "CIRadialGradient", parameters: [
        "inputCenter": CIVector(x: gx, y: gy), "inputRadius0": 0, "inputRadius1": 900,
        "inputColor0": CIColor(red: 0.55, green: 0.22, blue: 0.75, alpha: 0.55), "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
    ])!.outputImage!.cropped(to: rect)
    let warm = CIFilter(name: "CIRadialGradient", parameters: [
        "inputCenter": CIVector(x: CGFloat(W) * 0.9, y: CGFloat(H) * 0.1), "inputRadius0": 0, "inputRadius1": 700,
        "inputColor0": CIColor(red: 1.0, green: 0.5, blue: 0.25, alpha: 0.28), "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
    ])!.outputImage!.cropped(to: rect)
    return warm.composited(over: glow.composited(over: base))
}

// Window frame on the canvas
var srcSize = CGSize(width: 2980, height: 2090)
let firstTrack = AVURLAsset(url: URL(fileURLWithPath: "\(recDir)/\(takes["a"]!)")).tracks(withMediaType: .video).first!
srcSize = firstTrack.naturalSize
let inset: CGFloat = srcSize.width * 0.004
let srcAspect = (srcSize.width - 2 * inset) / (srcSize.height - 2 * inset)
let winH: CGFloat = 880, winW = (winH * srcAspect).rounded()
let winRect = CGRect(x: ((CGFloat(W) - winW) / 2).rounded(), y: 40, width: winW, height: winH) // CI coords (bottom 40)
let radius: CGFloat = 18

func roundedMask(_ r: CGRect, _ rad: CGFloat) -> CIImage {
    let ctx = cgContext(W, H)
    ctx.setFillColor(.white)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil))
    ctx.fillPath()
    return CIImage(cgImage: ctx.makeImage()!)
}
let mask = roundedMask(winRect, radius)
let shadow: CIImage = {
    let ctx = cgContext(W, H)
    ctx.setFillColor(CGColor(gray: 0, alpha: 0.6))
    ctx.addPath(CGPath(roundedRect: winRect.offsetBy(dx: 0, dy: -18), cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.fillPath()
    return CIImage(cgImage: ctx.makeImage()!).applyingGaussianBlur(sigma: 30).cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
}()
let rim: CIImage = {
    let ctx = cgContext(W, H)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.16)); ctx.setLineWidth(1.5)
    ctx.addPath(CGPath(roundedRect: winRect.insetBy(dx: 0.75, dy: 0.75), cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.strokePath()
    return CIImage(cgImage: ctx.makeImage()!)
}()

/// Source frame → window on the canvas, with zoom and an entrance/exit transform.
func windowLayer(_ frame: CIImage, zoom z: Zoom, alpha: CGFloat, lift: CGFloat, scale: CGFloat) -> CIImage {
    let sw = (srcSize.width - 2 * inset) / z.s, sh = (srcSize.height - 2 * inset) / z.s
    var cx = inset + (srcSize.width - 2 * inset) * z.x, cy = inset + (srcSize.height - 2 * inset) * (1 - z.y)
    cx = min(max(cx, inset + sw / 2), srcSize.width - inset - sw / 2)
    cy = min(max(cy, inset + sh / 2), srcSize.height - inset - sh / 2)
    let crop = CGRect(x: cx - sw / 2, y: cy - sh / 2, width: sw, height: sh)
    let k = winRect.width / crop.width
    var img = frame.cropped(to: crop)
        .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        .transformed(by: CGAffineTransform(scaleX: k, y: k))
        .transformed(by: CGAffineTransform(translationX: winRect.minX, y: winRect.minY))
    img = img.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask])
    var layer = rim.composited(over: img).composited(over: shadow)
    if scale != 1 || lift != 0 {
        let c = CGPoint(x: winRect.midX, y: winRect.midY)
        layer = layer.transformed(by: CGAffineTransform(translationX: -c.x, y: -c.y)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: c.x, y: c.y - lift)))
    }
    return fade(layer, alpha)
}

// Captions (cached)
var captionCache: [String: CIImage] = [:]
func captionImage(_ text: String, _ sub: String) -> CIImage {
    let key = text + "|" + sub
    if let c = captionCache[key] { return c }
    let main = textImage(text, size: 54, weight: .semibold, color: .white, tracking: -0.6)
    var img = place(main, centerX: CGFloat(W) / 2, topY: sub.isEmpty ? 50 : 26)
    if !sub.isEmpty {
        let s = place(textImage(sub, size: 28, weight: .medium, color: NSColor(white: 1, alpha: 0.62)), centerX: CGFloat(W) / 2, topY: 100)
        img = s.composited(over: img)
    }
    captionCache[key] = img
    return img
}

// Caption timeline: merge consecutive identical captions so they don't blink.
struct Cap { var start: Double; var end: Double; var text: String; var sub: String }
var caps: [Cap] = []
do {
    var t = titleDur
    for s in segs {
        if let last = caps.last, last.text == s.caption { caps[caps.count - 1].end = t + s.outDur }
        else { caps.append(Cap(start: t, end: t + s.outDur, text: s.caption, sub: s.sub)) }
        t += s.outDur
    }
}
func captionsLayer(_ t: Double) -> CIImage? {
    guard let c = caps.first(where: { t >= $0.start && t < $0.end }) else { return nil }
    let a = min(ease((t - c.start) / 0.35), ease((c.end - t) / 0.3))
    let rise = CGFloat((1 - ease((t - c.start) / 0.35)) * 14)
    return fade(captionImage(c.text, c.sub).transformed(by: CGAffineTransform(translationX: 0, y: -rise)), CGFloat(a))
}

// Title + end cards
let icon = CIImage(contentsOf: URL(fileURLWithPath: iconPath))!
func iconLayer(size: CGFloat, centerY topY: CGFloat, scale: CGFloat) -> CIImage {
    let k = size * scale / icon.extent.width
    let img = icon.transformed(by: CGAffineTransform(scaleX: k, y: k))
    return place(img, centerX: CGFloat(W) / 2, topY: topY - (size * scale - size) / 2)
}
let titleText = textImage("Toolbox Pro Max", size: 104, weight: .bold, color: .white, tracking: -2)
let titleSub = textImage(T("Toolbox-ul lui Cojo. Dar Pro. Și Max.", "Cojo's Toolbox. But Pro. And Max."), size: 38, weight: .medium, color: NSColor(white: 1, alpha: 0.7))

func titleCard(_ t: Double) -> CIImage {
    let a1 = ease(t / 0.6), a2 = ease((t - 0.5) / 0.6), a3 = ease((t - 1.0) / 0.6)
    let s = CGFloat(0.86 + 0.14 * ease(t / 0.9))
    var out = fade(iconLayer(size: 250, centerY: 250, scale: s), CGFloat(a1))
    out = fade(place(titleText, centerX: CGFloat(W) / 2, topY: 545 + CGFloat(1 - a2) * 16), CGFloat(a2)).composited(over: out)
    out = fade(place(titleSub, centerX: CGFloat(W) / 2, topY: 680 + CGFloat(1 - a3) * 12), CGFloat(a3)).composited(over: out)
    return out
}

let endLines: [(CIImage, CGFloat, Double)] = [
    (textImage(T("2,3 MB. Nativ. Făcut pentru Mac.", "2.3 MB. Native. Made of Mac."), size: 76, weight: .bold, color: .white, tracking: -1.2), 470, 0.5),
    (textImage(T("Gratuit și open source (MIT) · macOS 26 · Apple Silicon", "Free and open source (MIT) · macOS 26 · Apple Silicon"), size: 32, weight: .medium, color: NSColor(white: 1, alpha: 0.72)), 585, 0.9),
    (textImage("github.com/corvinus2003/ToolboxProMax", size: 40, weight: .semibold, color: NSColor(red: 0.62, green: 0.75, blue: 1, alpha: 1)), 670, 1.3),
    (textImage(T("Inspirat de Toolbox-ul lui Cojo · Construit cu Claude Code", "Inspired by Cojo's Toolbox · Built with Claude Code"), size: 24, weight: .regular, color: NSColor(white: 1, alpha: 0.45)), 960, 1.8),
]
func endCard(_ t: Double) -> CIImage {
    var out = fade(iconLayer(size: 170, centerY: 230, scale: CGFloat(0.9 + 0.1 * ease(t / 0.8))), CGFloat(ease(t / 0.6)))
    for (img, y, d) in endLines {
        let a = ease((t - d) / 0.6)
        out = fade(place(img, centerX: CGFloat(W) / 2, topY: y + CGFloat(1 - a) * 14), CGFloat(a)).composited(over: out)
    }
    return out
}

// MARK: Frame reader

final class Reader {
    let reader: AVAssetReader
    let output: AVAssetReaderTrackOutput
    var current: CMSampleBuffer?
    var next: CMSampleBuffer?
    init(_ url: URL, from: Double, to: Double) {
        let asset = AVURLAsset(url: url)
        reader = try! AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: max(0, from - 0.2), preferredTimescale: 600),
                                       end: CMTime(seconds: to + 0.3, preferredTimescale: 600))
        output = AVAssetReaderTrackOutput(track: asset.tracks(withMediaType: .video).first!,
                                          outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()
        current = output.copyNextSampleBuffer()
        next = output.copyNextSampleBuffer()
    }
    func frame(at t: Double) -> CIImage? {
        while let n = next, CMSampleBufferGetPresentationTimeStamp(n).seconds <= t {
            current = n
            next = output.copyNextSampleBuffer()
        }
        guard let c = current, let pb = CMSampleBufferGetImageBuffer(c) else { return nil }
        return CIImage(cvPixelBuffer: pb)
    }
}

// MARK: Writer

let videoURL = URL(fileURLWithPath: outPath + ".video.mp4")
try? FileManager.default.removeItem(at: videoURL)
let writer = try! AVAssetWriter(outputURL: videoURL, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: W, AVVideoHeightKey: H,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 14_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H,
])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

var frameIndex = 0
func emit(_ img: CIImage) {
    while !input.isReadyForMoreMediaData { usleep(2000) }
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
    ci.render(img.cropped(to: CGRect(x: 0, y: 0, width: W, height: H)), to: pb!, bounds: CGRect(x: 0, y: 0, width: W, height: H), colorSpace: sRGB)
    adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(frameIndex), timescale: FPS))
    frameIndex += 1
}

let dt = 1.0 / Double(FPS)
// Title
for k in 0..<Int(titleDur * Double(FPS)) {
    let t = Double(k) * dt
    emit(titleCard(t).composited(over: background(t)))
}
// Segments
var tl = titleDur
var titleFrame = titleCard(titleDur)
for (si, s) in segs.enumerated() {
    let r = Reader(URL(fileURLWithPath: "\(recDir)/\(takes[s.src]!)"), from: s.start, to: s.end)
    let n = Int((s.outDur * Double(FPS)).rounded())
    for k in 0..<n {
        let local = Double(k) * dt, t = tl + local
        let p = CGFloat(ease(local / max(0.01, s.outDur)))
        let z = Zoom(s: s.z0.s + (s.z1.s - s.z0.s) * p, x: s.z0.x + (s.z1.x - s.z0.x) * p, y: s.z0.y + (s.z1.y - s.z0.y) * p)
        guard let f = r.frame(at: s.start + local * s.speed) else { continue }
        var alpha: CGFloat = 1, lift: CGFloat = 0, scale: CGFloat = 1
        if si == 0 { // window rises in while the title leaves
            let a = ease(local / 0.7)
            alpha = CGFloat(a); lift = CGFloat(1 - a) * -60; scale = CGFloat(0.96 + 0.04 * a)
        }
        if si == segs.count - 1 { // and fades away before the end card
            let a = ease((s.outDur - local) / 0.6)
            alpha = CGFloat(a); scale = CGFloat(0.97 + 0.03 * a)
        }
        var img = windowLayer(f, zoom: z, alpha: alpha, lift: lift, scale: scale).composited(over: background(t))
        if si == 0 && local < 0.6 { img = fade(titleFrame, CGFloat(1 - ease(local / 0.5))).composited(over: img) }
        if let c = captionsLayer(t) { img = c.composited(over: img) }
        emit(img)
    }
    tl += s.outDur
    print("segment \(si + 1)/\(segs.count) done")
}
// End card, fading to black at the very end
for k in 0..<Int(endDur * Double(FPS)) {
    let t = Double(k) * dt
    var img = endCard(t).composited(over: background(tl + t))
    let out = ease((endDur - t) / 0.8)
    img = fade(img, CGFloat(out)).composited(over: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: W, height: H)))
    emit(img)
}
input.markAsFinished()
let sem = DispatchSemaphore(value: 0)
writer.finishWriting { sem.signal() }
sem.wait()
print("video:", writer.status == .completed ? "ok" : "failed \(String(describing: writer.error))", frameIndex, "frames")
print(String(format: "TOTAL %.3f", Double(frameIndex) / Double(FPS)))

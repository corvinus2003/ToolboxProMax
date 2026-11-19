import AVFoundation
import AppKit
// sheet <movie> <out.jpg> <step>
let a = CommandLine.arguments
let asset = AVURLAsset(url: URL(fileURLWithPath: a[1]))
let dur = CMTimeGetSeconds(asset.duration)
let step = Double(a[3])!
let gen = AVAssetImageGenerator(asset: asset)
gen.maximumSize = CGSize(width: 480, height: 480)
gen.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600); gen.requestedTimeToleranceAfter = gen.requestedTimeToleranceBefore
var times: [Double] = []; var t = 0.5; while t < dur { times.append(t); t += step }
let cols = 5, tw = 480, th = 263
let rows = (times.count + cols - 1) / cols
let W = cols * tw, H = rows * (th + 22)
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
for (i, t) in times.enumerated() {
  let c = i % cols, r = i / cols
  let y = H - (r + 1) * (th + 22)
  if let cg = try? gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil) {
    ctx.draw(cg, in: CGRect(x: c * tw, y: y, width: tw, height: th))
  }
  (String(format: "%.1f s", t) as NSString).draw(at: CGPoint(x: c * tw + 6, y: y + th + 3), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 15), .foregroundColor: NSColor.black])
}
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .jpeg, properties: [.compressionFactor: 0.6])!.write(to: URL(fileURLWithPath: a[2]))

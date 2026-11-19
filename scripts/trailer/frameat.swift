import AVFoundation
import AppKit
// frameat <movie> <outdir> <t1> <t2> ...
let args = CommandLine.arguments
let asset = AVURLAsset(url: URL(fileURLWithPath: args[1]))
let gen = AVAssetImageGenerator(asset: asset)
gen.maximumSize = CGSize(width: 1400, height: 1400)
gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
for t in args.dropFirst(3) {
  let time = CMTime(seconds: Double(t)!, preferredTimescale: 600)
  if let cg = try? gen.copyCGImage(at: time, actualTime: nil) {
    let rep = NSBitmapImageRep(cgImage: cg)
    let out = "\(args[2])/\((args[1] as NSString).lastPathComponent)-\(t).jpg"
    try! rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])!.write(to: URL(fileURLWithPath: out))
    print(out)
  }
}

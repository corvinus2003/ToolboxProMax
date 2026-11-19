// shrink <in.mp4> <out.mp4> : 1280x720 H.264 at ~2.4 Mbps, audio re-encoded AAC 160k
import AVFoundation
let a = CommandLine.arguments
let asset = AVURLAsset(url: URL(fileURLWithPath: a[1]))
let out = URL(fileURLWithPath: a[2]); try? FileManager.default.removeItem(at: out)
let reader = try! AVAssetReader(asset: asset)
let vt = asset.tracks(withMediaType: .video)[0], at = asset.tracks(withMediaType: .audio)[0]
let vo = AVAssetReaderTrackOutput(track: vt, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
let ao = AVAssetReaderTrackOutput(track: at, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
reader.add(vo); reader.add(ao)
let writer = try! AVAssetWriter(outputURL: out, fileType: .mp4)
let vi = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1280, AVVideoHeightKey: 720,
    AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_400_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel]])
let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 160_000])
vi.expectsMediaDataInRealTime = false; ai.expectsMediaDataInRealTime = false
writer.add(vi); writer.add(ai)
reader.startReading(); writer.startWriting(); writer.startSession(atSourceTime: .zero)
let g = DispatchGroup()
for (inp, outp, q) in [(vi, vo, DispatchQueue(label: "v")), (ai, ao, DispatchQueue(label: "a"))] {
    g.enter()
    var done = false
    inp.requestMediaDataWhenReady(on: q) {
        while !done && inp.isReadyForMoreMediaData {
            if let sb = outp.copyNextSampleBuffer() { inp.append(sb) } else { done = true; inp.markAsFinished(); g.leave() }
        }
    }
}
g.wait()
let s = DispatchSemaphore(value: 0); writer.finishWriting { s.signal() }; s.wait()
print(writer.status == .completed ? "ok" : "failed \(String(describing: writer.error))")

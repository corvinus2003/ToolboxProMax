// mux <video.mp4> <music.m4a> <out.mp4>
import AVFoundation
let a = CommandLine.arguments
let sem = DispatchSemaphore(value: 0)
Task.detached {
    let v = AVURLAsset(url: URL(fileURLWithPath: a[1])), m = AVURLAsset(url: URL(fileURLWithPath: a[2]))
    let comp = AVMutableComposition()
    let vd = try await v.load(.duration)
    let vt = try await v.loadTracks(withMediaType: .video).first!
    let ct = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
    try ct.insertTimeRange(CMTimeRange(start: .zero, duration: vd), of: vt, at: .zero)
    let at = try await m.loadTracks(withMediaType: .audio).first!
    let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
    let md = try await m.load(.duration)
    try ca.insertTimeRange(CMTimeRange(start: .zero, duration: min(md, vd)), of: at, at: .zero)
    let out = URL(fileURLWithPath: a[3]); try? FileManager.default.removeItem(at: out)
    let s = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough)!
    try await s.export(to: out, as: .mp4)
    print("muxed", a[3])
    sem.signal()
}
sem.wait()

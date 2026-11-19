import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Video goes through AVFoundation: Apple's own encoders (H.264 / HEVC on the media engine, ProRes),
/// with our frame effects plugged in as a Core Image video composition. No ffmpeg anywhere.
enum VideoOps {
    static let readableTypes: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie, .video, .appleProtectedMPEG4Video]

    static let formats: [(String, String)] = [
        ("h264", "MP4 · H.264"), ("hevc", "MP4 · HEVC"), ("prores", "MOV · ProRes 422"),
        ("gif", "GIF"), ("original", "Original (no re-encode)"),
    ]

    static func info(_ url: URL) async throws -> (duration: Double, size: CGSize) {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ToolError("\(url.lastPathComponent) has no picture")
        }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let r = CGRect(origin: .zero, size: natural).applying(transform)
        return (duration, CGSize(width: abs(r.width), height: abs(r.height)))
    }

    static func range(_ clip: VideoClip, duration: Double) -> (start: Double, end: Double) {
        let s = min(max(0, clip.start), duration)
        let e = min(clip.end ?? duration, duration)
        return (s, max(s, e))
    }

    /// One frame for previews, with the clip's effects applied.
    /// `seconds` picks an exact moment (from the clip's start); otherwise `fraction` of the way through.
    /// A nil `maxDimension` gives the full-size frame.
    static func frame(_ clip: VideoClip, fraction: Double, seconds: Double? = nil, maxDimension: CGFloat?) async throws -> NamedImage {
        let (duration, size) = try await info(clip.url)
        let (s, e) = range(clip, duration: duration)
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: clip.url))
        gen.appliesPreferredTrackTransform = true
        if let maxDimension { gen.maximumSize = CGSize(width: maxDimension, height: maxDimension) }
        let tolerance = seconds == nil ? 0.1 : 0
        gen.requestedTimeToleranceBefore = CMTime(seconds: tolerance, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: tolerance, preferredTimescale: 600)
        let t = seconds.map { min(e - 0.01, s + max(0, $0)) } ?? (s + (e - s) * min(max(fraction, 0), 0.999))
        let cg = try await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
        let scale = CGFloat(cg.width) / max(1, size.width)
        var img = CIImage(cgImage: cg)
        for fx in clip.effects { img = CI.normalized(fx(img, scale)) }
        return NamedImage(name: clip.name, image: img, scale: scale)
    }

    static func export(_ clip: VideoClip, format: String, to url: URL, progress: @escaping (Double) -> Void) async throws {
        let asset = AVURLAsset(url: clip.url)
        let (duration, _) = try await info(clip.url)
        let (s, e) = range(clip, duration: duration)

        var preset: String
        var fileType: AVFileType = .mp4
        switch format {
        case "hevc": preset = AVAssetExportPresetHEVCHighestQuality
        case "prores": preset = AVAssetExportPresetAppleProRes422LPCM; fileType = .mov
        case "original":
            preset = clip.effects.isEmpty ? AVAssetExportPresetPassthrough : AVAssetExportPresetHighestQuality
            if url.pathExtension.lowercased() == "mov" { fileType = .mov }
        default: preset = AVAssetExportPresetHighestQuality
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ToolError("This Mac can't export \(format.uppercased())")
        }
        if s > 0 || e < duration {
            session.timeRange = CMTimeRange(start: CMTime(seconds: s, preferredTimescale: 600),
                                            end: CMTime(seconds: e, preferredTimescale: 600))
        }
        if !clip.effects.isEmpty {
            let effects = clip.effects
            let composition = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
                var img = CI.normalized(request.sourceImage)
                for fx in effects { img = CI.normalized(fx(img, 1)) }
                request.finish(with: img.cropped(to: CGRect(origin: .zero, size: request.renderSize)), context: CI.context)
            }
            // Work out the output size by running the effects once on a blank frame.
            var probe = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: composition.renderSize))
            for fx in effects { probe = CI.normalized(fx(probe, 1)) }
            let w = max(2, floor(probe.extent.width / 2) * 2), h = max(2, floor(probe.extent.height / 2) * 2)
            composition.renderSize = CGSize(width: w, height: h)
            session.videoComposition = composition
        }

        let watcher = Task {
            for await state in session.states(updateInterval: 0.2) {
                if case .exporting(let p) = state { progress(p.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        try await session.export(to: url, as: fileType)
        progress(1)
    }

    static func gif(_ clip: VideoClip, fps: Double, width: Double, to url: URL, progress: @escaping (Double) -> Void) async throws {
        let asset = AVURLAsset(url: clip.url)
        let (duration, size) = try await info(clip.url)
        let (s, e) = range(clip, duration: duration)
        let step = 1 / max(1, fps)
        var times: [CMTime] = []
        var t = s
        while t < e, times.count < 900 {
            times.append(CMTime(seconds: t, preferredTimescale: 600))
            t += step
        }
        guard !times.isEmpty else { throw ToolError("The clip is empty") }

        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: width, height: width * 4)
        gen.requestedTimeToleranceBefore = CMTime(seconds: step / 2, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: step / 2, preferredTimescale: 600)

        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, times.count, nil) else {
            throw ToolError("Can't write a GIF here")
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: step,
                                                          kCGImagePropertyGIFUnclampedDelayTime: step]] as CFDictionary
        var done = 0
        for await result in gen.images(for: times) {
            try Task.checkCancellation()
            guard let cg = try? result.image else { continue }
            var img = CIImage(cgImage: cg)
            let scale = CGFloat(cg.width) / max(1, size.width)
            for fx in clip.effects { img = CI.normalized(fx(img, scale)) }
            if let out = CI.cgImage(img) { CGImageDestinationAddImage(dest, out, frameProps) }
            done += 1
            progress(Double(done) / Double(times.count))
        }
        guard CGImageDestinationFinalize(dest) else { throw ToolError("Couldn't finish the GIF") }
    }

    /// Joins a picture-only file and a sound-only file into one clean MP4, without re-encoding.
    ///
    /// YouTube's split (DASH) downloads are fragmented MP4s, and AVFoundation reads their timestamps
    /// stretched (twice as long, half the frame rate). yt-dlp normally has ffmpeg fix that up. Here every
    /// track's real length is worked out from its frame count (frames ÷ fps, or AAC packets × 1024 ÷ rate),
    /// and the picture samples are rewritten with corrected times.
    static func merge(video: URL, audio: URL?, to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        struct Source {
            let reader: AVAssetReader
            let output: AVAssetReaderTrackOutput
            let input: AVAssetWriterInput
            let factor: Double
        }
        var sources: [Source] = []
        for (file, type) in [(video, AVMediaType.video), (audio, .audio)] {
            guard let file else { continue }
            let asset = AVURLAsset(url: file)
            guard let track = try await asset.loadTracks(withMediaType: type).first else { continue }
            let format = try await track.load(.formatDescriptions).first
            // Only picture needs fixing: for AAC passed through, AVAssetWriter rebuilds the timing from the
            // packet count itself, so retiming sound too would halve it.
            let factor = type == .video ? try await stretch(of: track, in: asset, format: format) : 1
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            reader.add(output)
            let input = AVAssetWriterInput(mediaType: type, outputSettings: nil, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = false
            if type == .video { input.transform = try await track.load(.preferredTransform) }
            guard writer.canAdd(input) else { throw ToolError("Can't put this \(type.rawValue) in an MP4") }
            writer.add(input)
            sources.append(Source(reader: reader, output: output, input: input, factor: factor))
        }
        guard !sources.isEmpty else { throw ToolError("The download has no picture or sound") }

        guard writer.startWriting() else { throw writer.error ?? ToolError("Can't write the video") }
        writer.startSession(atSourceTime: .zero)
        for s in sources where !s.reader.startReading() { throw s.reader.error ?? ToolError("Can't read the download") }

        await withTaskGroup(of: Void.self) { group in
            for (i, s) in sources.enumerated() {
                group.addTask {
                    let queue = DispatchQueue(label: "remux.\(i)")
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        var done = false
                        s.input.requestMediaDataWhenReady(on: queue) {
                            while !done, s.input.isReadyForMoreMediaData {
                                guard let sb = s.output.copyNextSampleBuffer() else {
                                    done = true
                                    s.input.markAsFinished()
                                    cont.resume()
                                    return
                                }
                                if let fixed = retime(sb, by: s.factor) { s.input.append(fixed) }
                            }
                        }
                    }
                }
            }
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ToolError("Couldn't finish the video") }
    }

    /// How much a track's timestamps overstate its real length (1 when they're right).
    private static func stretch(of track: AVAssetTrack, in asset: AVAsset, format: CMFormatDescription?) async throws -> Double {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil) // compressed: nothing is decoded
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { return 1 }
        var count = 0
        var first = Double.infinity, last = -Double.infinity, lastDuration = 0.0
        while let sb = output.copyNextSampleBuffer() {
            count += CMSampleBufferGetNumSamples(sb)
            let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            let dur = CMSampleBufferGetDuration(sb).seconds
            if pts.isFinite {
                first = min(first, pts)
                if pts > last { last = pts; lastDuration = dur.isFinite ? dur : 0 }
            }
        }
        let span = last + lastDuration - first
        guard count > 0, span.isFinite, span > 0 else { return 1 }
        var real: Double?
        if track.mediaType == .audio, let format, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
           asbd.mSampleRate > 0 {
            let perPacket = asbd.mFramesPerPacket > 0 ? Double(asbd.mFramesPerPacket) : 1
            real = Double(count) * perPacket / asbd.mSampleRate
        } else if track.mediaType == .video {
            let fps = Double(try await track.load(.nominalFrameRate))
            if fps > 0 { real = Double(count) / fps }
        }
        guard let real, real > 0 else { return 1 }
        let factor = span / real
        return abs(factor - 1) < 0.04 ? 1 : factor
    }

    private static func retime(_ sb: CMSampleBuffer, by factor: Double) -> CMSampleBuffer? {
        guard factor != 1 else { return sb }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return sb }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count)
        func scale(_ t: CMTime) -> CMTime { t.isValid ? CMTimeMultiplyByFloat64(t, multiplier: 1 / factor) : t }
        for i in timings.indices {
            timings[i].presentationTimeStamp = scale(timings[i].presentationTimeStamp)
            timings[i].decodeTimeStamp = scale(timings[i].decodeTimeStamp)
            timings[i].duration = scale(timings[i].duration)
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: count,
                                              sampleTimingArray: &timings, sampleBufferOut: &out)
        return out
    }
}

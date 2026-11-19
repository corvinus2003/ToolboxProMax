import AVFoundation
import UniformTypeIdentifiers

/// Sound is held as a plain float buffer, so trims, fades and gain are just arithmetic.
enum AudioOps {
    static let readableTypes: [UTType] = [.audio, .mp3, .wav, .aiff, .mpeg4Audio, .movie]

    static let formats: [(String, String)] = [
        ("m4a", "M4A · AAC"), ("alac", "M4A · Apple Lossless"), ("wav", "WAV"), ("aiff", "AIFF"),
    ]

    /// Decodes the sound of any file AVFoundation can open (songs, voice memos, the audio track of videos).
    static func load(_ url: URL, start: Double = 0, end: Double? = nil) async throws -> AudioClip {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ToolError("\(url.lastPathComponent) has no sound")
        }
        let reader = try AVAssetReader(asset: asset)
        if start > 0 || end != nil {
            let duration = try await asset.load(.duration).seconds
            let e = min(end ?? duration, duration)
            reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                           end: CMTime(seconds: max(start, e), preferredTimescale: 600))
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ToolError("Can't read \(url.lastPathComponent)") }

        var samples: [Float] = []
        var channels = 2, rate = 44100.0
        while let sb = output.copyNextSampleBuffer() {
            if let fmt = CMSampleBufferGetFormatDescription(sb),
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee {
                channels = Int(asbd.mChannelsPerFrame)
                rate = asbd.mSampleRate
            }
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / 4)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            samples += chunk
            try Task.checkCancellation()
        }
        if reader.status == .failed { throw reader.error ?? ToolError("Can't read \(url.lastPathComponent)") }

        channels = max(1, min(channels, 8))
        let frames = samples.count / channels
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels)),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, frames)))
        else { throw ToolError("Unsupported sound format") }
        buffer.frameLength = AVAudioFrameCount(frames)
        for c in 0..<channels {
            let dst = buffer.floatChannelData![c]
            for f in 0..<frames { dst[f] = samples[f * channels + c] }
        }
        return AudioClip(buffer: buffer, name: url.deletingPathExtension().lastPathComponent)
    }

    static func copy(_ clip: AudioClip, from: Int = 0, count: Int? = nil) -> AudioClip {
        let src = clip.buffer
        let start = min(max(0, from), Int(src.frameLength))
        let n = min(count ?? Int(src.frameLength) - start, Int(src.frameLength) - start)
        let out = AVAudioPCMBuffer(pcmFormat: src.format, frameCapacity: AVAudioFrameCount(max(1, n)))!
        out.frameLength = AVAudioFrameCount(max(0, n))
        for c in 0..<Int(src.format.channelCount) {
            out.floatChannelData![c].update(from: src.floatChannelData![c].advanced(by: start), count: max(0, n))
        }
        return AudioClip(buffer: out, name: clip.name)
    }

    static func trim(_ clip: AudioClip, start: Double, end: Double) -> AudioClip {
        let rate = clip.buffer.format.sampleRate
        let s = Int(start * rate)
        let e = end > 0 ? Int(end * rate) : Int(clip.buffer.frameLength)
        return copy(clip, from: s, count: max(0, e - s))
    }

    static func fade(_ clip: AudioClip, fadeIn: Double, fadeOut: Double) -> AudioClip {
        let out = copy(clip)
        let n = Int(out.buffer.frameLength), rate = out.buffer.format.sampleRate
        let fi = min(n, Int(fadeIn * rate)), fo = min(n, Int(fadeOut * rate))
        for c in 0..<Int(out.buffer.format.channelCount) {
            let d = out.buffer.floatChannelData![c]
            // equal-power curves sound smoother than straight lines
            for i in 0..<fi { d[i] *= sin(Float(i) / Float(fi) * .pi / 2) }
            for i in 0..<fo { d[n - 1 - i] *= sin(Float(i) / Float(fo) * .pi / 2) }
        }
        return out
    }

    static func peak(_ clip: AudioClip) -> Float {
        var p: Float = 0
        for c in 0..<Int(clip.buffer.format.channelCount) {
            let d = clip.buffer.floatChannelData![c]
            for i in 0..<Int(clip.buffer.frameLength) { p = max(p, abs(d[i])) }
        }
        return p
    }

    static func normalize(_ clip: AudioClip, peakDB: Double) -> AudioClip {
        let p = peak(clip)
        guard p > 0 else { return clip }
        return gain(clip, by: Float(pow(10, peakDB / 20)) / p)
    }

    static func gain(_ clip: AudioClip, by g: Float) -> AudioClip {
        let out = copy(clip)
        for c in 0..<Int(out.buffer.format.channelCount) {
            let d = out.buffer.floatChannelData![c]
            for i in 0..<Int(out.buffer.frameLength) { d[i] = max(-1, min(1, d[i] * g)) }
        }
        return out
    }

    static func toMono(_ clip: AudioClip) -> AudioClip {
        let src = clip.buffer, ch = Int(src.format.channelCount)
        guard ch > 1, let fmt = AVAudioFormat(standardFormatWithSampleRate: src.format.sampleRate, channels: 1),
              let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: max(1, src.frameLength)) else { return clip }
        out.frameLength = src.frameLength
        let d = out.floatChannelData![0]
        for i in 0..<Int(src.frameLength) {
            var s: Float = 0
            for c in 0..<ch { s += src.floatChannelData![c][i] }
            d[i] = s / Float(ch)
        }
        return AudioClip(buffer: out, name: clip.name)
    }

    /// Peaks per bin, for drawing the waveform.
    static func waveform(_ clip: AudioClip, bins: Int) -> [Float] {
        let n = Int(clip.buffer.frameLength), ch = Int(clip.buffer.format.channelCount)
        guard n > 0, bins > 0 else { return [] }
        let per = max(1, n / bins)
        var out = [Float](repeating: 0, count: bins)
        for b in 0..<bins {
            let s = b * per, e = min(n, s + per)
            guard s < e else { break }
            var p: Float = 0
            for c in 0..<ch {
                let d = clip.buffer.floatChannelData![c]
                var i = s
                while i < e { p = max(p, abs(d[i])); i += max(1, per / 64) }
            }
            out[b] = p
        }
        return out
    }

    static func write(_ clip: AudioClip, format: String, to url: URL) throws {
        let rate = clip.buffer.format.sampleRate
        let ch = clip.buffer.format.channelCount
        var settings: [String: Any] = [AVSampleRateKey: rate, AVNumberOfChannelsKey: ch]
        switch format {
        case "alac":
            settings[AVFormatIDKey] = kAudioFormatAppleLossless
            settings[AVEncoderBitDepthHintKey] = 24
        case "wav":
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 24
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = false
        case "aiff":
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 24
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = true
        default:
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVSampleRateKey] = min(rate, 48000)
            settings[AVEncoderBitRateKey] = ch > 1 ? 256_000 : 128_000
        }
        var buffer = clip.buffer
        if format == "m4a", rate > 48000 { buffer = try resample(clip.buffer, to: 48000) }
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    static func resample(_ buffer: AVAudioPCMBuffer, to rate: Double) throws -> AVAudioPCMBuffer {
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: buffer.format.channelCount),
              let conv = AVAudioConverter(from: buffer.format, to: fmt),
              let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * rate / buffer.format.sampleRate) + 1024)
        else { throw ToolError("Can't change the sample rate") }
        var fed = false
        var error: NSError?
        conv.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        return out
    }
}

// Synthesises a soft electronic bed for the trailer: music <seconds> <out.m4a>
import AVFoundation
import Foundation

let total = Double(CommandLine.arguments[1])!
let outPath = CommandLine.arguments[2]
let sr = 48000.0
let N = Int(total * sr)
var L = [Float](repeating: 0, count: N), R = [Float](repeating: 0, count: N)

let bpm = 100.0, beat = 60 / bpm
let dropBeat = 6.0           // title ends at 3.6 s = beat 6
let endBeat = floor((total - 6.0) / beat) // end card
func midi(_ m: Double) -> Double { 440 * pow(2, (m - 69) / 12) }

// Band-limited saw wavetable (soft: 7 harmonics, rolled off)
let tableSize = 4096
let saw: [Float] = (0..<tableSize).map { i in
    let x = Double(i) / Double(tableSize) * 2 * .pi
    var s = 0.0
    for h in 1...7 { s += sin(Double(h) * x) / Double(h) * pow(0.82, Double(h - 1)) }
    return Float(s * 0.55)
}
@inline(__always) func tab(_ phase: Double) -> Float {
    let p = phase - floor(phase)
    return saw[Int(p * Double(tableSize)) & (tableSize - 1)]
}

let chords: [[Double]] = [[53, 57, 60, 64], [55, 59, 62, 64], [57, 60, 64, 67], [52, 55, 59, 62]] // Fmaj7 G6 Am7 Em7
let basses: [Double] = [41, 43, 45, 40]
let chordBeats = 8.0
func chordIndex(_ b: Double) -> Int { Int(floor(b / chordBeats)) % chords.count }

struct Seeded: RandomNumberGenerator { // fixed seed: every render sounds exactly the same
    var state: UInt64 = 0x5EED_2026
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
var rng = Seeded()
func noise() -> Float { Float.random(in: -1...1, using: &rng) }

// --- Pad (with sidechain ducking from the kick) ---
var phases = [Double](repeating: 0, count: 48)
for i in 0..<N {
    let t = Double(i) / sr, b = t / beat
    let ci = chordIndex(b)
    let next = chordIndex(b + 0.5)
    let local = (b.truncatingRemainder(dividingBy: chordBeats)) / chordBeats
    // crossfade into the next chord over the last half beat
    let xf = local > (chordBeats - 0.5) / chordBeats ? (local - (chordBeats - 0.5) / chordBeats) * chordBeats * 2 : 0
    var l: Float = 0, r: Float = 0
    for (set, w) in [(ci, 1 - xf), (next, xf)] where w > 0.001 {
        for (n, m) in chords[set].enumerated() {
            let f = midi(m)
            for d in 0..<3 {
                let idx = (set * 4 + n) * 3 + d
                let det = [0.0, 0.07, -0.07][d]
                phases[idx] += f * pow(2, det / 12) / sr
                let v = tab(phases[idx]) * Float(w)
                if d == 1 { l += v } else if d == 2 { r += v } else { l += v * 0.7; r += v * 0.7 }
            }
        }
    }
    var g = 0.032 * min(1, t / 1.5)                          // fade in
    if b >= dropBeat && b < endBeat {                         // duck under the kick
        let since = (b - floor(b)) * beat
        g *= 1 - 0.45 * exp(-since * 9)
    }
    let tail = max(0, total - t)
    g *= min(1, tail / 4)                                     // fade out
    let trem = 1 + 0.08 * sin(t * 2 * .pi * 0.23)
    L[i] += l * Float(g * trem); R[i] += r * Float(g * trem)
}

// --- Bass: eighth-note pulses ---
var bphase = 0.0
for i in 0..<N {
    let t = Double(i) / sr, b = t / beat
    guard b >= dropBeat && b < endBeat else { continue }
    let f = midi(basses[chordIndex(b)])
    bphase += f / sr
    let e8 = (b * 2 - floor(b * 2)) * beat / 2               // time inside the eighth
    let env = (1 - exp(-e8 * 300)) * exp(-e8 * 5)
    let v = sin(2 * .pi * bphase) + 0.25 * sin(4 * .pi * bphase)
    let since = (b - floor(b)) * beat
    let duck = 1 - 0.6 * exp(-since * 10)
    let s = Float(v * env * duck * 0.16)
    L[i] += s; R[i] += s
}

// --- One-shot helpers ---
func add(_ at: Double, _ len: Double, pan: Float = 0, _ f: (Double) -> Float) {
    let s0 = Int(at * sr), n = Int(len * sr)
    for k in 0..<n where s0 + k < N && s0 + k >= 0 {
        let v = f(Double(k) / sr)
        L[s0 + k] += v * (1 - max(0, pan)); R[s0 + k] += v * (1 + min(0, pan))
    }
}

var b = dropBeat
while b < endBeat {
    let t0 = b * beat
    // kick
    add(t0, 0.4) { t in
        let ph = 2 * Double.pi * (48 * t + 3.2 * (1 - exp(-t * 28)))
        return Float(sin(ph) * exp(-t * 7.5) * 0.5)
    }
    // hats on the off-beat, from the second phrase
    if b >= dropBeat + 8 {
        var prev: Float = 0
        add(t0 + beat / 2, 0.09, pan: 0.25) { t in
            let n = noise(); let hp = n - prev; prev = n
            return hp * Float(exp(-t * 55) * 0.05)
        }
    }
    // claps on 2 and 4, from the third phrase
    let inBar = Int(b - dropBeat) % 4
    if b >= dropBeat + 16 && (inBar == 1 || inBar == 3) {
        var lp: Float = 0
        add(t0, 0.35, pan: -0.1) { t in
            lp += (noise() - lp) * 0.35
            let burst = t < 0.03 ? 1.0 : exp(-(t - 0.03) * 14)
            return lp * Float(burst * 0.16)
        }
    }
    b += 1
}

// --- Pluck arpeggio with a ping-pong delay, from the second phrase to the end ---
var pl = [Float](repeating: 0, count: N), pr = [Float](repeating: 0, count: N)
let pattern = [0, 1, 2, 3, 2, 1, 3, 2]
var e = (dropBeat + 8) * 2
while e / 2 < endBeat + 6 {
    let beatPos = e / 2
    let t0 = beatPos * beat
    if t0 > total - 1 { break }
    let notes = chords[chordIndex(beatPos)]
    let m = notes[pattern[Int(e) % pattern.count]] + 12
    let f = midi(m)
    let s0 = Int(t0 * sr), n = Int(0.5 * sr)
    for k in 0..<n where s0 + k < N {
        let t = Double(k) / sr
        let v = (sin(2 * .pi * f * t) * exp(-t * 7) + 0.3 * sin(4 * .pi * f * t) * exp(-t * 14)) * 0.07
        pl[s0 + k] += Float(v); pr[s0 + k] += Float(v)
    }
    e += 1
}
let dL = Int(beat * 0.75 * sr), dR = Int(beat * 0.5 * sr)
for i in 0..<N {
    if i >= dL { pl[i] += pr[i - dL] * 0.0 + pl[i - dL] * 0.32 }
    if i >= dR { pr[i] += pr[i - dR] * 0.28 }
    let fade = Float(min(1, max(0, total - Double(i) / sr) / 4))
    L[i] += pl[i] * 0.9 * fade; R[i] += pr[i] * 0.9 * fade
}

// --- Riser into the drop, and a soft impact ---
var rl: Float = 0
add(0.4, dropBeat * beat - 0.4) { t in
    let p = t / (dropBeat * beat - 0.4)
    rl += (noise() - rl) * Float(0.02 + 0.5 * p * p)
    return rl * Float(p * p * 0.22)
}
add(dropBeat * beat, 2.5) { t in noise() * Float(exp(-t * 2.2) * 0.04) }

// --- Master: gentle saturation, normalise to -1 dBFS ---
var peak: Float = 0
for i in 0..<N {
    L[i] = tanh(L[i] * 1.3) / 1.3; R[i] = tanh(R[i] * 1.3) / 1.3
    peak = max(peak, abs(L[i]), abs(R[i]))
}
let gain = pow(10, -1 / 20) / max(peak, 0.0001)
let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(N))!
buf.frameLength = AVAudioFrameCount(N)
for i in 0..<N { buf.floatChannelData![0][i] = L[i] * gain; buf.floatChannelData![1][i] = R[i] * gain }
let url = URL(fileURLWithPath: outPath)
try? FileManager.default.removeItem(at: url)
// .wav → 24-bit PCM (lossless), anything else → AAC 256 kbps
let settings: [String: Any] = outPath.lowercased().hasSuffix(".wav")
    ? [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 24,
       AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
    : [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sr, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000]
let file = try! AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
try! file.write(from: buf)
file.close()
print("music ok", total, "s, peak gain", gain)

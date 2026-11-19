import SwiftUI

extension PortType {
    var color: Color {
        switch self {
        case .image: Color(red: 0.19, green: 0.69, blue: 0.85)
        case .images: .indigo
        case .video: .purple
        case .audio: .orange
        case .pdf: .red
        case .text: .green
        case .visual: .cyan
        }
    }
}

/// The rounded, colored icon squares from System Settings.
struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 26

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(color.gradient)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
            }
            .overlay(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            .frame(width: size, height: size)
    }
}

/// Shows through transparent parts of images.
struct Checkerboard: View {
    var square: CGFloat = 8
    var body: some View {
        Canvas { ctx, size in
            let cols = Int(size.width / square) + 1, rows = Int(size.height / square) + 1
            for r in 0..<rows {
                for c in 0..<cols where (r + c) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: CGFloat(c) * square, y: CGFloat(r) * square, width: square, height: square)),
                             with: .color(.primary.opacity(0.06)))
                }
            }
        }
    }
}

struct WaveformShape: View {
    let samples: [Float]
    var color: Color = .orange
    var progress: Double? = nil

    var body: some View {
        Canvas { ctx, size in
            guard !samples.isEmpty else { return }
            let bar = size.width / CGFloat(samples.count)
            let mid = size.height / 2
            for (i, s) in samples.enumerated() {
                let h = max(1, CGFloat(min(1, s)) * size.height * 0.95)
                let rect = CGRect(x: CGFloat(i) * bar, y: mid - h / 2, width: max(1, bar * 0.62), height: h)
                let played = progress.map { CGFloat(i) / CGFloat(samples.count) < $0 } ?? true
                ctx.fill(Path(roundedRect: rect, cornerRadius: bar * 0.3), with: .color(played ? color : color.opacity(0.35)))
            }
        }
    }
}

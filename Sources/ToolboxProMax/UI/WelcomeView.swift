import SwiftUI

struct WelcomeView: View {
    @Environment(GraphStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                AppGlyph(size: 88)
                    .padding(.bottom, 6)
                Text("Welcome to\n\(Edition.appName)")
                    .font(.system(size: 34, weight: .bold))
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 44)
            .padding(.bottom, 30)

            VStack(alignment: .leading, spacing: 22) {
                Feature(symbol: "point.3.connected.trianglepath.dotted", color: .blue,
                        title: "Wire it like a pro",
                        text: "Drop in photos, videos, sound or PDFs, then connect tools into a chain. Every change previews live.")
                Feature(symbol: "laptopcomputer", color: .purple,
                        title: "Made of Mac",
                        text: "Core Image, AVFoundation, Vision and PDFKit do the work, on your Mac. Nothing is uploaded, no ffmpeg required.")
                #if APPSTORE
                Feature(symbol: "person.crop.rectangle.badge.plus", color: .pink,
                        title: "Smart, on-device",
                        text: "Cut a subject out of a photo or copy the text out of a scan. Apple's own models, right on your Mac.")
                #else
                Feature(symbol: "arrow.down.circle", color: .pink,
                        title: "YouTube, without the sketchy sites",
                        text: "Paste a link into a Download node. Picture and sound arrive together, ready to edit.")
                #endif
                Feature(symbol: "command", color: .orange,
                        title: "⌘R and done",
                        text: "Render runs everything at full size and saves every Export node's file.")
            }
            .padding(.horizontal, 54)

            Spacer(minLength: 28)

            Button {
                UserDefaults.standard.set(true, forKey: "welcomeSeen")
                dismiss()
            } label: {
                Text("Continue").font(.headline).frame(maxWidth: 280).padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.extraLarge)
            .keyboardShortcut(.defaultAction)

            Text(Edition.isAppStore ? "Inspired by Cojo's Toolbox." : "Started life as Toolbox Pro Max, a joke on Cojo's Toolbox. Now out of the box.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 14)
                .padding(.bottom, 26)
        }
        .frame(width: 560, height: 680)
    }
}

private struct Feature: View {
    let symbol: String
    let color: Color
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(color.gradient)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The app icon, drawn in SwiftUI so the welcome screen doesn't depend on the bundle.
struct AppGlyph: View {
    var size: CGFloat = 64

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.12, blue: 0.42), Color(red: 0.55, green: 0.2, blue: 0.75),
                                          Color(red: 1.0, green: 0.55, blue: 0.3)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: size * 0.04, y: size * 0.02)
            }
            .overlay(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 1))
            .frame(width: size, height: size)
            .shadow(color: .purple.opacity(0.35), radius: size * 0.18, y: size * 0.08)
    }
}

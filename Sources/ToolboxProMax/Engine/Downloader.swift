import CryptoKit
import Foundation

/// Fetches videos and sound from YouTube, Vimeo, SoundCloud & co. through yt-dlp.
/// yt-dlp downloads itself the first time (checked against the checksum its release publishes)
/// and refreshes weekly, because those sites change often. Picture and sound come down separately
/// and are joined with AVFoundation, so no ffmpeg is needed.
actor Downloader {
    static let shared = Downloader()

    struct Result {
        let file: URL
        let title: String
        let audioOnly: Bool
    }

    private let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Toolbox Pro Max", isDirectory: true)
    private let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Toolbox Pro Max/Downloads", isDirectory: true)

    private var bundled: URL { support.appendingPathComponent("bin/yt-dlp") }

    // MARK: Cache

    nonisolated static func key(url: String, audioOnly: Bool, quality: String) -> String {
        let digest = SHA256.hash(data: Data("\(url.trimmingCharacters(in: .whitespacesAndNewlines))|\(audioOnly)|\(quality)".utf8))
        return digest.prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    /// A finished download for these settings, if there is one.
    func cached(url: String, audioOnly: Bool, quality: String) -> Result? {
        let dir = caches.appendingPathComponent(Self.key(url: url, audioOnly: audioOnly, quality: quality))
        let marker = dir.appendingPathComponent("result.json")
        guard let data = try? Data(contentsOf: marker),
              let info = try? JSONDecoder().decode([String: String].self, from: data),
              let file = info["file"], let title = info["title"],
              FileManager.default.fileExists(atPath: dir.appendingPathComponent(file).path) else { return nil }
        return Result(file: dir.appendingPathComponent(file), title: title, audioOnly: audioOnly)
    }

    // MARK: yt-dlp itself

    func executable(progress: @escaping (Double, String) -> Void) async throws -> URL {
        for path in ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp"] where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: bundled.path)
        let age = (attrs?[.modificationDate] as? Date).map { Date().timeIntervalSince($0) } ?? .infinity
        if FileManager.default.isExecutableFile(atPath: bundled.path), age < 7 * 86400 { return bundled }
        do {
            progress(0, "Getting yt-dlp…")
            try await install()
        } catch where FileManager.default.isExecutableFile(atPath: bundled.path) {
            // offline or GitHub hiccup: the copy we have still works
        }
        return bundled
    }

    private func install() async throws {
        let base = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/"
        let (sums, _) = try await URLSession.shared.data(from: URL(string: base + "SHA2-256SUMS")!)
        guard let line = String(decoding: sums, as: UTF8.self).split(separator: "\n").first(where: { $0.hasSuffix(" yt-dlp_macos") }),
              let expected = line.split(separator: " ").first.map(String.init) else {
            throw ToolError("Couldn't verify yt-dlp")
        }
        let (tmp, response) = try await URLSession.shared.download(from: URL(string: base + "yt-dlp_macos")!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ToolError("Couldn't download yt-dlp") }
        let actual = SHA256.hash(data: try Data(contentsOf: tmp)).map { String(format: "%02x", $0) }.joined()
        guard actual == expected.lowercased() else { throw ToolError("yt-dlp download didn't match its checksum") }
        try FileManager.default.createDirectory(at: bundled.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: bundled)
        try FileManager.default.moveItem(at: tmp, to: bundled)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundled.path)
    }

    // MARK: Downloading

    func download(url: String, audioOnly: Bool, quality: String, progress: @escaping (Double, String) -> Void) async throws -> Result {
        let link = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: link), parsed.scheme?.hasPrefix("http") == true else {
            throw ToolError("Paste a web link first")
        }
        if let hit = cached(url: link, audioOnly: audioOnly, quality: quality) { return hit }
        let exe = try await executable(progress: progress)
        let dir = caches.appendingPathComponent(Self.key(url: link, audioOnly: audioOnly, quality: quality))
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let title = (try? await run(exe, ["--no-playlist", "--skip-download", "--print", "%(title)s", link], progress: nil))?
            .trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first.map(String.init) ?? "download"

        let final: URL
        if audioOnly {
            progress(0, "Downloading sound…")
            _ = try await run(exe, ["--no-playlist", "-f", "ba[ext=m4a]/ba[acodec^=mp4a]/ba", "-o", dir.path + "/audio.%(ext)s", link]) {
                progress($0, "Downloading sound…")
            }
            guard let file = find("audio", in: dir) else { throw ToolError("yt-dlp didn't return any sound") }
            final = file
        } else {
            let height = Int(quality) ?? 1080
            do {
                progress(0, "Downloading picture…")
                _ = try await run(exe, ["--no-playlist", "-f", "bv*[ext=mp4][vcodec^=avc1][height<=\(height)]/bv*[ext=mp4][height<=\(height)]",
                                        "-o", dir.path + "/video.%(ext)s", link]) { progress($0 * 0.8, "Downloading picture…") }
                progress(0.8, "Downloading sound…")
                _ = try await run(exe, ["--no-playlist", "-f", "ba[ext=m4a]/ba[acodec^=mp4a]",
                                        "-o", dir.path + "/audio.%(ext)s", link]) { progress(0.8 + $0 * 0.15, "Downloading sound…") }
                guard let v = find("video", in: dir) else { throw ToolError("No picture") }
                progress(0.96, "Putting picture and sound together…")
                let merged = dir.appendingPathComponent("merged.mp4")
                try await VideoOps.merge(video: v, audio: find("audio", in: dir), to: merged)
                final = merged
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Some sites only offer one combined file.
                progress(0, "Downloading…")
                _ = try await run(exe, ["--no-playlist", "-f", "b[ext=mp4]/b", "-o", dir.path + "/single.%(ext)s", link]) {
                    progress($0, "Downloading…")
                }
                guard let s = find("single", in: dir) else { throw ToolError("yt-dlp didn't return a video") }
                final = s
            }
        }
        let info = ["file": final.lastPathComponent, "title": title]
        try JSONEncoder().encode(info).write(to: dir.appendingPathComponent("result.json"))
        progress(1, "Done")
        return Result(file: final, title: title, audioOnly: audioOnly)
    }

    private func find(_ prefix: String, in dir: URL) -> URL? {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .first { $0.lastPathComponent.hasPrefix(prefix + ".") && !$0.pathExtension.hasSuffix("part") }
    }

    /// Runs yt-dlp, reporting the download percentage it prints.
    private func run(_ exe: URL, _ args: [String], progress: ((Double) -> Void)?) async throws -> String {
        let process = Process()
        process.executableURL = exe
        process.arguments = ["--newline", "--no-warnings", "--no-mtime", "--progress-template", "download:%(progress._percent_str)s"] + args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        final class Box: @unchecked Sendable { var text = ""; var errors = "" }
        let box = Box()
        out.fileHandleForReading.readabilityHandler = { h in
            let chunk = String(decoding: h.availableData, as: UTF8.self)
            box.text += chunk
            for line in chunk.split(separator: "\n") {
                let s = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")
                if let v = Double(s) { progress?(v / 100) }
            }
        }
        err.fileHandleForReading.readabilityHandler = { h in box.errors += String(decoding: h.availableData, as: UTF8.self) }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in cont.resume() }
                do { try process.run() } catch { cont.resume(throwing: error) }
            }
        } onCancel: {
            process.terminate()
        }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        box.text += String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        box.errors += String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else {
            let msg = box.errors.split(separator: "\n").last(where: { $0.contains("ERROR") }).map(String.init) ?? "yt-dlp failed"
            throw ToolError(msg.replacingOccurrences(of: "ERROR: ", with: ""))
        }
        return box.text
    }
}

import Foundation

/// The same code builds two editions:
/// - the full edition (GitHub, `scripts/build-app.sh`), with the Download node and yt-dlp;
/// - the App Store edition (`AppStore/`, compiled with the `APPSTORE` flag), sandboxed and without downloading,
///   because the Mac App Store doesn't allow apps that fetch from YouTube or run downloaded programs.
enum Edition {
    #if APPSTORE
    static let isAppStore = true
    #else
    static let isAppStore = false
    #endif

    static var hasDownload: Bool { !isAppStore }

    /// The name shown to people (set per edition in Info.plist).
    static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Toolbox Studio"
    }
}

/// Sandboxed apps may only touch files the person handed them. To still open a saved graph after a relaunch,
/// the App Store edition keeps a security-scoped bookmark for every file or folder it was given.
/// In the full edition these calls do nothing.
enum FileAccess {
    private static let key = "securityScopedBookmarks"

    static func remember(_ urls: [URL]) {
        #if APPSTORE
        var store = UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:]
        for url in urls {
            _ = url.startAccessingSecurityScopedResource()
            if let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
                store[url.path] = data
            }
        }
        UserDefaults.standard.set(store, forKey: key)
        #endif
    }

    /// Call once at launch: reopens access to everything remembered.
    static func restoreAll() {
        #if APPSTORE
        var store = UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:]
        for (path, data) in store {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil,
                                     bookmarkDataIsStale: &stale) else {
                store[path] = nil // the file is gone
                continue
            }
            _ = url.startAccessingSecurityScopedResource()
            if stale, let fresh = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
                store[path] = nil
                store[url.path] = fresh
            }
        }
        UserDefaults.standard.set(store, forKey: key)
        #endif
    }
}

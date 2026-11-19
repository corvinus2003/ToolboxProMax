import SwiftUI

struct ToolboxProMaxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = GraphStore.shared

    var body: some Scene {
        Window("Toolbox Pro Max", id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: 1000, minHeight: 620)
        }
        .defaultSize(width: 1440, height: 880)
        .windowToolbarStyle(.unified)
        .commands { AppCommands(store: store) }

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
}

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    static func showAbout() {
        let credits = NSMutableAttributedString(
            string: "Designed in Berlin. Built natively for the Mac.\nInspired by Cojo's Toolbox.\n\nNo ffmpeg was harmed in the making of this app.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        let style = NSMutableParagraphStyle(); style.alignment = .center
        credits.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Toolbox Pro Max",
            .applicationVersion: version,
            .version: "",
            .credits: credits,
        ])
    }
}

struct AppCommands: Commands {
    let store: GraphStore

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Toolbox Pro Max") { AppInfo.showAbout() }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Graph") { store.clear() }
                .keyboardShortcut("n")
            Menu("Add Workflow") {
                ForEach(Workflow.all) { w in Button(w.title) { store.insert(w) } }
            }
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { store.undo() }
                .keyboardShortcut("z")
            Button("Redo") { store.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandMenu("Graph") {
            Button("Render") { store.startRender() }
                .keyboardShortcut("r")
            Button("Cancel Render") { store.cancelRender() }
                .keyboardShortcut(".")
            Divider()
            Button("Duplicate Node") { if let s = store.selection { store.duplicate(s) } }
                .keyboardShortcut("d")
            Button("Delete Node") { if let s = store.selection { store.remove(s) } }
                .keyboardShortcut(.delete)
            Divider()
            Button("Zoom In") { store.zoom(by: 1.25) }
                .keyboardShortcut("+")
            Button("Zoom Out") { store.zoom(by: 1 / 1.25) }
                .keyboardShortcut("-")
            Button("Actual Size") { store.actualSize() }
                .keyboardShortcut("0")
            Button("Zoom to Fit") { store.zoomToFit() }
                .keyboardShortcut("9")
            Divider()
            Button("Show Inspector") { NotificationCenter.default.post(name: .toggleInspector, object: nil) }
                .keyboardShortcut("i", modifiers: [.command, .option])
        }
        CommandGroup(replacing: .help) {
            Button("Welcome to Toolbox Pro Max") { store.showWelcome = true }
            Button("Check for Updates…") {
                let alert = NSAlert()
                alert.messageText = "You're on the latest Pro Max."
                alert.informativeText = "Toolbox Pro Max \(AppInfo.version) is as Pro and as Max as it gets. For now."
                alert.runModal()
            }
        }
    }
}

struct SettingsView: View {
    @Environment(GraphStore.self) private var store
    @AppStorage("revealAfterRender") private var reveal = false

    var body: some View {
        Form {
            Section("Rendering") {
                LabeledContent("Save files to") {
                    HStack {
                        Text(store.outputFolder.path(percentEncoded: false)).lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                        Button("Change…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
                            panel.prompt = "Use This Folder"
                            if panel.runModal() == .OK, let url = panel.url { store.outputFolder = url }
                        }
                    }
                }
                Toggle("Show files in Finder after rendering", isOn: $reveal)
            }
            Section("Downloads") {
                LabeledContent("Engine", value: "yt-dlp, updated weekly")
                Button("Empty Download Cache") {
                    let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Toolbox Pro Max/Downloads")
                    try? FileManager.default.removeItem(at: dir)
                }
            }
            Section {
                Button("Show Welcome Screen") { store.showWelcome = true }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 360)
    }
}

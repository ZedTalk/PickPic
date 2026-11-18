import AppKit
import SwiftUI

@main
enum Main {
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest"), i + 1 < args.count {
            exit(SelfTest.run(in: URL(fileURLWithPath: args[i + 1])) ? 0 : 1)
        }
        PhotoRaterApp.main()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        debugSnapshotIfAsked()
    }

    /// Debug aid: `--snapshot out.png [--keys "c>z"]` presses those keys
    /// (< and > are the arrows), saves a picture of the window, and quits.
    private func debugSnapshotIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let out = URL(fileURLWithPath: args[i + 1])
        let keys = args.firstIndex(of: "--keys").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            for c in keys {
                switch c {
                case "<": Library.current?.handle(.left)
                case ">": Library.current?.handle(.right)
                default: Library.current?.handle(.char(c))
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                if let view = NSApp.windows.first(where: { $0.isVisible })?.contentView,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: out)
                }
                exit(0)
            }
        }
    }
}

struct PhotoRaterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var lib = Library()

    var body: some Scene {
        Window("Picull", id: "main") {
            ContentView()
                .environmentObject(lib)
                .environmentObject(lib.zoom)
                .onAppear {
                    // `--open <folder>` on the command line opens that folder.
                    let args = CommandLine.arguments
                    if let i = args.firstIndex(of: "--open"), i + 1 < args.count {
                        lib.open(URL(fileURLWithPath: args[i + 1]))
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") { lib.chooseFolder() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { lib.undo() }.keyboardShortcut("z")
            }
            CommandMenu("Review") {
                Button("Compare Side by Side (C)") { lib.toggleCompare() }
                Button("Pick Winner From Burst (W)") { lib.startShowdown() }
                Divider()
                Button("Finish…") { if !lib.items.isEmpty { lib.showFinish = true } }
                    .keyboardShortcut(.return, modifiers: .command)
                Divider()
                Button("Show Keys (?)") { lib.showHelp = true }
            }
        }
        Settings { SettingsView() }
    }
}

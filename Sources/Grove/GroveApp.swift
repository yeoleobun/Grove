import AppKit
import GroveCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        NSApplication.shared.setActivationPolicy(.regular)
        applyAppIcon()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func applyAppIcon() {
        if let iconName = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
           let iconURL = Bundle.main.url(forResource: iconName, withExtension: iconName.hasSuffix(".icns") ? nil : "icns"),
           let iconImage = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = iconImage
        }
    }

    static func quitCompletely() {
        NSApplication.shared.terminate(nil)
    }
}

// Typealias binds directly to `SwiftUI.State<Value>` property wrapper struct,
// avoiding the SwiftUIMacros plugin requirement when building with CommandLineTools.
typealias LocalState<Value> = SwiftUI.State<Value>

@main
struct GroveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @LocalState private var viewModel = AppViewModel()

    var body: some Scene {
        Window("Grove", id: "main") {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 680, minHeight: 480)
        }
        .defaultSize(width: 920, height: 700)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Scan Folder…") {
                    viewModel.promptAddFolder()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("Rescan Repositories") {
                    viewModel.startScan()
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(viewModel.isScanning)
            }
        }

        Settings {
            SettingsView(viewModel: viewModel)
        }
    }
}

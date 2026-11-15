import AppKit
import GroveCore
import SwiftUI

extension Notification.Name {
    static let groveOpenDashboardRequested = Notification.Name("dev.grove.openDashboardRequested")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    private var allowFullTermination = false
    private var windowCloseObserver: NSObjectProtocol?
    private var windowKeyObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        activateRegularApp()

        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                // Wait one runloop turn for `window.isVisible` to settle after closing
                try? await Task.sleep(for: .milliseconds(40))
                self?.updateActivationPolicyForVisibleWindows()
            }
        }

        windowKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let obj = note.object as? NSWindow
            Task { @MainActor [weak self] in
                guard let window = obj, Self.isStandardAppWindow(window) else { return }
                self?.ensureRegularDockIconVisible()
                self?.upgradeWindowWidthForSplitLayoutIfNeeded(window)
            }
        }
    }

    private var didCheckInitialSplitWidth = false

    private func upgradeWindowWidthForSplitLayoutIfNeeded(_ window: NSWindow) {
        guard !didCheckInitialSplitWidth else { return }
        didCheckInitialSplitWidth = true
        let udKey = "grove.splitLayoutWindowUpgraded.v1"
        guard !UserDefaults.standard.bool(forKey: udKey) else { return }
        UserDefaults.standard.set(true, forKey: udKey)

        if window.frame.width < 1100 {
            var frame = window.frame
            let targetWidth: CGFloat = 1180
            let delta = targetWidth - frame.width
            frame.origin.x = max(20, frame.origin.x - delta / 2.0)
            frame.size.width = targetWidth
            if frame.height < 680 {
                frame.size.height = 720
            }
            if let screenFrame = window.screen?.visibleFrame {
                frame.size.width = min(frame.size.width, screenFrame.width - 40)
                if frame.maxX > screenFrame.maxX {
                    frame.origin.x = max(screenFrame.minX + 20, screenFrame.maxX - frame.width - 20)
                }
            }
            window.setFrame(frame, display: true, animate: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Never exit when closing the Dashboard window — keep the Menu Bar Indicator alive!
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            Self.openDashboard()
        } else {
            activateRegularApp()
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Allow full quit when explicitly requested ("Quit Grove" in Menu Bar Indicator or ⌥⌘Q)
        // or when macOS itself is logging out / restarting / shutting down (`'why?'` AEQuitReason).
        if allowFullTermination {
            return .terminateNow
        }
        if let quitReason = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: 0x7768793F)?.typeCodeValue,
           quitReason != 0 {
            return .terminateNow
        }

        // Otherwise (e.g. ⌘Q or Dock -> Quit while using the Dashboard), close Dashboard windows
        // and leave the Menu Bar Indicator running quietly in the top bar!
        Self.hideDashboardKeepIndicator()
        return .terminateCancel
    }

    // MARK: - Window & Dock Policy Helpers

    private static func isStandardAppWindow(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled) && window.styleMask.contains(.closable) && !(window is NSPanel)
    }

    private var hasVisibleStandardWindows: Bool {
        NSApplication.shared.windows.contains { window in
            window.isVisible && Self.isStandardAppWindow(window)
        }
    }

    private func applyAppIcon() {
        if let iconName = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
           let iconURL = Bundle.main.url(forResource: iconName, withExtension: iconName.hasSuffix(".icns") ? nil : "icns"),
           let iconImage = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = iconImage
        }
    }

    private func ensureRegularDockIconVisible() {
        if NSApplication.shared.activationPolicy() != .regular {
            NSApplication.shared.setActivationPolicy(.regular)
            applyAppIcon()
        }
    }

    func activateRegularApp() {
        NSApplication.shared.setActivationPolicy(.regular)
        applyAppIcon()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func updateActivationPolicyForVisibleWindows() {
        guard !allowFullTermination else { return }
        if !hasVisibleStandardWindows {
            // Hide Dock icon so only the Menu Bar Tree Indicator remains
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }

    static func openDashboard() {
        shared?.activateRegularApp()
        NotificationCenter.default.post(name: .groveOpenDashboardRequested, object: nil)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            NSApplication.shared.activate(ignoringOtherApps: true)
            for window in NSApplication.shared.windows where isStandardAppWindow(window) && window.isVisible {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    static func hideDashboardKeepIndicator() {
        for window in NSApplication.shared.windows where isStandardAppWindow(window) {
            window.close()
        }
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    static func quitCompletely() {
        shared?.allowFullTermination = true
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
                .frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: 1180, height: 720)
        .commands {
            SidebarCommands()

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

            CommandGroup(replacing: .appTermination) {
                Button("Close Dashboard") {
                    AppDelegate.hideDashboardKeepIndicator()
                }
                .keyboardShortcut("q", modifiers: [.command])

                Divider()

                Button("Quit Grove Completely") {
                    AppDelegate.quitCompletely()
                }
                .keyboardShortcut("q", modifiers: [.command, .option])
            }
        }

        // macOS Menu Bar Indicator: Minimal flat Tree template icon (no counter)
        MenuBarExtra {
            MenuBarIndicatorMenu(viewModel: viewModel)
        } label: {
            MenuBarIndicatorLabel()
        }

        Settings {
            SettingsView(viewModel: viewModel)
        }
    }
}

private struct MenuBarIndicatorLabel: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: MenuBarTreeImage.makeTemplateImage(pointSize: 18))
            .accessibilityLabel("Grove")
            .onReceive(NotificationCenter.default.publisher(for: .groveOpenDashboardRequested)) { _ in
                openWindow(id: "main")
            }
    }
}

private struct MenuBarIndicatorMenu: View {
    @Bindable var viewModel: AppViewModel
    @Environment(\.openWindow) private var openWindow

    private func showMainWindow() {
        AppDelegate.shared?.activateRegularApp()
        openWindow(id: "main")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    var body: some View {
        Button("Open Dashboard") {
            showMainWindow()
        }

        if case let .updateAvailable(release) = viewModel.updateState {
            Button("Update to v\(release.version)") {
                viewModel.installAvailableUpdate(release)
            }
        } else if case let .updating(ver) = viewModel.updateState {
            Button("Updating to v\(ver)…") {}
                .disabled(true)
        } else {
            Button("Check for Updates…") {
                viewModel.checkForUpdates(manual: true)
                showMainWindow()
            }
        }

        SettingsLink {
            Text("Settings…")
        }

        Divider()

        Button("Quit Grove") {
            AppDelegate.quitCompletely()
        }
        .keyboardShortcut("q")
    }
}

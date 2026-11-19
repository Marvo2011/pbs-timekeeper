import AppKit
import SwiftUI
import TimekeeperCore

@main
struct PBSTimekeeperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environment(model)
        } label: {
            Image(systemName: model.menuBarSymbol)
        }

        Window("Browse Backups", id: BrowserView.windowID) {
            BrowserView(model: model)
                .environment(model)
        }
        .defaultSize(width: 1000, height: 640)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Notifier.requestAuthorization()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Mounts.unmountAll()
    }
}

extension NSApplication {
    /// The app has no Dock icon, its windows have to be brought to the front explicitly.
    @MainActor
    static func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
    }
}

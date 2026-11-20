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
            Image(nsImage: model.menuBarImage)
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
    private var termSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Notifier.requestAuthorization()
        // quit cleanly on SIGTERM (kill, logout scripts), so the backup is stopped as well
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        termSource = source
    }

    func applicationWillTerminate(_ notification: Notification) {
        // a running backup would otherwise go on without the app and keep the group locked
        RunningClient.stopLeftover()
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

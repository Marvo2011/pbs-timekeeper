import AppKit
import SwiftUI
import TimekeeperCore

struct MenuContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.isBackingUp {
            Text("Backing up… \(model.elapsedText())")
            if let progress = model.progress {
                Text("\(progress.processed) read · \(progress.uploaded) uploaded")
            } else if !model.progressLine.isEmpty {
                Text(model.progressLine.prefix(60))
            }
        } else {
            Text("Latest backup: \(Format.relative(model.state.lastSuccess))")
            if let next = model.nextBackup {
                Text("Next backup: \(next <= Date() ? "now" : Format.relative(next))")
            }
        }
        if let problem = model.setupProblem {
            Text("⚠︎ \(problem)")
        } else if model.lastFailed, let error = model.state.lastError {
            Text("⚠︎ Last backup failed: \(error.prefix(80))")
        } else if let warning = model.state.lastWarning {
            Text("⚠︎ \(warning.prefix(100))")
        }
        if !model.hasFullDiskAccess {
            Button("⚠︎ No Full Disk Access – protected folders are skipped…") {
                FullDiskAccess.openSettings()
            }
        }

        Divider()

        if model.isBackingUp {
            Button("Stop Backup") { model.stopBackup() }
        } else {
            Button("Back Up Now") { model.backUpNow() }
                .disabled(model.setupProblem != nil)
        }
        Button("Browse Backups…") {
            openWindow(id: BrowserView.windowID)
            NSApplication.bringToFront()
        }
        .disabled(model.clientURL == nil || !model.config.server.isComplete)

        Divider()

        if let log = model.state.lastLog {
            Button("Show Last Log") {
                NSWorkspace.shared.open(URL(fileURLWithPath: log))
            }
        }
        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",")
        Button("Quit PBS Timekeeper") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

enum FullDiskAccess {
    static func openSettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }
}

enum Format {
    static func relative(_ date: Date?) -> String {
        guard let date else { return "never" }
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) {
            return "Today, \(time)"
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday, \(time)"
        }
        if calendar.isDateInTomorrow(date) {
            return "Tomorrow, \(time)"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func bytes(_ value: UInt64?) -> String {
        guard let value else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }
}

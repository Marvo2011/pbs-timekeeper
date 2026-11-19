import AppKit
import Foundation
import Observation
import ServiceManagement
import TimekeeperCore

/// Configuration, backup runs and the schedule. Lives as long as the app.
@MainActor
@Observable
final class AppModel {
    var config: AppConfig {
        didSet {
            guard config != oldValue else { return }
            do {
                try JSONStore<AppConfig>(url: Paths.config).save(config)
            } catch {
                configError = error.localizedDescription
            }
        }
    }

    private(set) var state: BackupState {
        didSet { try? JSONStore<BackupState>(url: Paths.state).save(state) }
    }

    private(set) var isBackingUp = false
    private(set) var backupStarted: Date?
    private(set) var progressLine = ""
    var configError: String?
    /// Bumped after every backup, so an open browser reloads its snapshots.
    private(set) var backupGeneration = 0

    private var backupTask: Task<Void, Never>?
    private var schedulerTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?

    init() {
        config = JSONStore<AppConfig>(url: Paths.config).load() ?? AppConfig()
        state = JSONStore<BackupState>(url: Paths.state).load() ?? BackupState()
        Mounts.unmountAll()
        startScheduler()
    }

    // MARK: Status

    var clientURL: URL? {
        ClientLocator.locate(override: config.clientPath)
    }

    var builder: CommandBuilder {
        CommandBuilder(config: config, secrets: Keychain.secrets)
    }

    /// Why a backup cannot run, nil if everything is set up.
    var setupProblem: String? {
        if clientURL == nil {
            return "proxmox-backup-client was not found."
        }
        if !config.server.isComplete {
            return "The server is not configured."
        }
        if config.enabledFolders.isEmpty {
            return "No folders are selected for backup."
        }
        return nil
    }

    var nextBackup: Date? {
        guard config.automaticBackups, setupProblem == nil else { return nil }
        return Schedule.nextBackup(state: state, intervalMinutes: config.intervalMinutes)
    }

    var lastFailed: Bool {
        guard let error = state.lastError, !error.isEmpty else { return false }
        return (state.lastAttempt ?? .distantPast) > (state.lastSuccess ?? .distantPast)
    }

    var menuBarSymbol: String {
        if isBackingUp {
            return "arrow.triangle.2.circlepath"
        }
        if lastFailed || setupProblem != nil {
            return "exclamationmark.arrow.circlepath"
        }
        return "clock.arrow.circlepath"
    }

    // MARK: Scheduler

    private func startScheduler() {
        schedulerTask = Task { [weak self] in
            // let the menu bar settle and the network come up after login
            try? await Task.sleep(for: .seconds(30))
            while !Task.isCancelled {
                self?.backupIfDue()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // the network needs a moment after waking up
                try? await Task.sleep(for: .seconds(60))
                self?.backupIfDue()
            }
        }
    }

    private func backupIfDue() {
        guard config.automaticBackups, !isBackingUp, setupProblem == nil,
            Schedule.isDue(state: state, intervalMinutes: config.intervalMinutes)
        else {
            return
        }
        backUpNow()
    }

    // MARK: Backup

    func backUpNow() {
        guard !isBackingUp else { return }
        isBackingUp = true
        backupStarted = Date()
        progressLine = "Preparing…"
        backupTask = Task { [weak self] in
            await self?.runBackup()
        }
    }

    func stopBackup() {
        backupTask?.cancel()
        progressLine = "Stopping…"
    }

    private func runBackup() async {
        let started = Date()
        let logFile = Logs.newLogFile(prefix: "backup")
        var warnings: [String] = []
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Backup to Proxmox Backup Server")
        defer {
            ProcessInfo.processInfo.endActivity(activity)
            isBackingUp = false
            backupStarted = nil
            progressLine = ""
            backupTask = nil
            backupGeneration += 1
        }

        do {
            if let problem = setupProblem {
                throw ClientError(problem)
            }
            guard let client = clientURL else { throw ClientError("proxmox-backup-client was not found.") }

            // folders on disks that are not connected are skipped
            var folders: [BackupFolder] = []
            for folder in config.enabledFolders {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue {
                    folders.append(folder)
                } else {
                    warnings.append("Skipped \(folder.path), it is not available.")
                }
            }
            if folders.isEmpty {
                throw ClientError("None of the folders is available.")
            }

            let builder = self.builder
            try await ClientRunner.check(
                executable: client, invocation: builder.backup(folders: folders), logFile: logFile
            ) { line in
                Task { @MainActor [weak self] in
                    self?.progressLine = line
                }
            }

            if let prune = builder.prune() {
                progressLine = "Removing old backups…"
                let result = try await ClientRunner.run(executable: client, invocation: prune, logFile: logFile)
                if !result.succeeded {
                    warnings.append("Removing old backups failed: \(result.errorMessage)")
                }
            }

            state.lastSuccess = started
            state.lastAttempt = started
            state.lastError = nil
        } catch {
            state.lastAttempt = started
            state.lastError = Task.isCancelled ? "The backup was stopped." : Self.describe(error)
            if !Task.isCancelled {
                Notifier.post(title: "Backup failed", body: state.lastError ?? "")
            }
        }
        state.lastWarning = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
        state.lastLog = logFile.path
        Logs.prune(prefix: "backup")
    }

    static func describe(_ error: Error) -> String {
        let message = error.localizedDescription
        // reading protected folders (Desktop, Documents, Mail, …) needs Full Disk Access
        if message.contains("Operation not permitted") || message.contains("EPERM") {
            return message + " — grant PBS Timekeeper Full Disk Access in System Settings."
        }
        return message
    }

    // MARK: Folders

    func addFolder(_ url: URL) throws {
        let path = FolderValidation.canonical(url.path)
        if let problem = FolderValidation.validate(path, existing: config.folders.map(\.path)) {
            throw problem
        }
        let name = ArchiveNames.unique(
            forPath: path, existing: Set(config.folders.map(\.archiveName)))
        config.folders.append(BackupFolder(path: path, archiveName: name))
    }

    func removeFolders(_ ids: Set<BackupFolder.ID>) {
        config.folders.removeAll { ids.contains($0.id) }
    }

    // MARK: Login item

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                configError = "Login item: \(error.localizedDescription)"
            }
        }
    }
}

enum Logs {
    static func newLogFile(prefix: String) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return Paths.logs.appending(path: "\(prefix)-\(formatter.string(from: Date())).log")
    }

    /// Keeps the newest logs.
    static func prune(prefix: String, keep: Int = 100) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: Paths.logs.path) else { return }
        let logs = files.filter { $0.hasPrefix(prefix + "-") }.sorted(by: >)
        for name in logs.dropFirst(keep) {
            try? fm.removeItem(at: Paths.logs.appending(path: name))
        }
    }
}

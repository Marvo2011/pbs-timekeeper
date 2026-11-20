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
    private(set) var progress: BackupProgress?
    /// The folder the running backup is reading.
    private(set) var currentFolder: String?
    private var spinnerFrame = 0
    private var spinnerTask: Task<Void, Never>?
    var configError: String?
    /// Bumped after every backup, so an open browser reloads its snapshots.
    private(set) var backupGeneration = 0
    /// Checked at start and whenever the menu or settings open, it can change at any time.
    private(set) var hasFullDiskAccess = Paths.hasFullDiskAccess
    /// Version reported by the client in use, nil while unknown.
    private(set) var clientVersion: String?
    private var clientVersionPath: String?

    /// Asks the client for its version when it changed (another path in the settings).
    func refreshClientVersion() {
        guard let client = clientURL else {
            clientVersion = nil
            clientVersionPath = nil
            return
        }
        guard client.path != clientVersionPath else { return }
        clientVersionPath = client.path
        clientVersion = nil
        Task {
            let version = await Versions.client(executable: client)
            if clientVersionPath == client.path {
                clientVersion = version
            }
        }
    }

    var clientIsBundled: Bool {
        guard let client = clientURL,
            let bundled = Bundle.main.url(forAuxiliaryExecutable: ClientLocator.executableName)
        else {
            return false
        }
        return client.standardizedFileURL == bundled.standardizedFileURL
    }

    func refreshPermissions() {
        hasFullDiskAccess = Paths.hasFullDiskAccess
    }

    private var backupTask: Task<Void, Never>?
    private var schedulerTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?

    init() {
        config = JSONStore<AppConfig>(url: Paths.config).load() ?? AppConfig()
        state = JSONStore<BackupState>(url: Paths.state).load() ?? BackupState()
        Mounts.unmountAll()
        RunningClient.stopLeftover()
        refreshClientVersion()
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

    var menuBarImage: NSImage {
        if isBackingUp {
            return MenuBarIcon.spinner[spinnerFrame % MenuBarIcon.spinner.count]
        }
        if lastFailed || setupProblem != nil {
            return MenuBarIcon.symbol("exclamationmark.arrow.circlepath")
        }
        return MenuBarIcon.symbol("clock.arrow.circlepath")
    }

    /// "Backing up… 12 min" for the menu.
    func elapsedText(now: Date = Date()) -> String {
        guard let started = backupStarted else { return "" }
        let minutes = Int(now.timeIntervalSince(started) / 60)
        return minutes < 1 ? "less than a minute" : minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }

    private func animateSpinner() {
        spinnerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: MenuBarIcon.frameInterval)
                guard let self, self.isBackingUp else { return }
                self.spinnerFrame += 1
            }
        }
    }

    // MARK: Scheduler

    private func startScheduler() {
        schedulerTask = Task { [weak self] in
            // let the menu bar settle and the network come up after login
            try? await Task.sleep(for: .seconds(30))
            while !Task.isCancelled {
                self?.refreshPermissions()
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
        progress = nil
        currentFolder = nil
        animateSpinner()
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
            progress = nil
            currentFolder = nil
            spinnerTask?.cancel()
            spinnerTask = nil
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
            let skipped = Counter()
            defer { RunningClient.clear() }
            try await ClientRunner.check(
                executable: client, invocation: builder.backup(folders: folders), logFile: logFile,
                onStart: RunningClient.record
            ) { line in
                if SkippedEntries.isSkipped(line) {
                    skipped.increment()
                }
                if SkippedEntries.isWarning(line) {
                    return
                }
                Task { @MainActor [weak self] in
                    self?.progressLine = line
                    if let progress = BackupProgress(line: line) {
                        self?.progress = progress
                    } else if let folder = BackupProgress.folder(line: line) {
                        self?.currentFolder = folder
                    }
                }
            }
            let skippedCount = skipped.value
            if skippedCount > 0 {
                warnings.append(
                    "\(skippedCount) item\(skippedCount == 1 ? " was" : "s were") skipped because macOS denied access"
                        + (hasFullDiskAccess ? ", see the log." : ". Grant PBS Timekeeper Full Disk Access to include them."))
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
            state.failures = nil
        } catch {
            state.lastAttempt = started
            state.failures = (state.failures ?? 0) + 1
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

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.withLock { count += 1 }
    }

    var value: Int {
        lock.withLock { count }
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

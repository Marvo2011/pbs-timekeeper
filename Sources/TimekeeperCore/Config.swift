import Foundation

/// Connection to the Proxmox Backup Server. The password lives in the Keychain.
public struct ServerSettings: Codable, Equatable, Sendable {
    public var host = ""
    public var port = 8007
    public var datastore = ""
    /// Namespace inside the datastore, empty for the root namespace.
    public var namespace = ""
    /// `user@realm` or an API token `user@realm!token`.
    public var authID = ""
    /// SHA-256 fingerprint of the server certificate. Needed for self-signed certificates,
    /// the client cannot ask for confirmation as it runs without a terminal.
    public var fingerprint = ""

    public init() {}

    public var isComplete: Bool {
        !host.trimmed.isEmpty && !datastore.trimmed.isEmpty && !authID.trimmed.isEmpty
    }
}

/// A folder that is backed up as its own pxar archive in every snapshot.
public struct BackupFolder: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var path: String
    /// Archive name without extension (`<archiveName>.pxar`). It is assigned once, so the
    /// archive keeps its name in all snapshots even if folders are added or removed.
    public var archiveName: String
    public var enabled: Bool

    public init(id: UUID = UUID(), path: String, archiveName: String, enabled: Bool = true) {
        self.id = id
        self.path = path
        self.archiveName = archiveName
        self.enabled = enabled
    }

    public var displayName: String {
        FileManager.default.displayName(atPath: path)
    }
}

/// How many snapshots `prune` keeps per period, 0 disables a period. The defaults follow
/// the common scheme: hourly for a day, daily for a month, weekly for a year.
/// Pruning by the app after each backup. Off by default: retention is usually set up on the
/// server (prune jobs), which also works with the `DatastoreBackup` role.
public struct Retention: Codable, Equatable, Sendable {
    public var enabled = false
    public var hourly = 24
    public var daily = 30
    public var weekly = 52
    public var monthly = 0
    public var yearly = 0

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Retention()
        // configs written before the switch existed get the default (off)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        hourly = try c.decodeIfPresent(Int.self, forKey: .hourly) ?? defaults.hourly
        daily = try c.decodeIfPresent(Int.self, forKey: .daily) ?? defaults.daily
        weekly = try c.decodeIfPresent(Int.self, forKey: .weekly) ?? defaults.weekly
        monthly = try c.decodeIfPresent(Int.self, forKey: .monthly) ?? defaults.monthly
        yearly = try c.decodeIfPresent(Int.self, forKey: .yearly) ?? defaults.yearly
    }

    /// Without any keep option there is nothing to prune (and the server would refuse).
    public var isEmpty: Bool {
        hourly <= 0 && daily <= 0 && weekly <= 0 && monthly <= 0 && yearly <= 0
    }

    /// Whether the app prunes after each backup.
    public var isActive: Bool { enabled && !isEmpty }
}

/// How the client finds out what changed since the previous backup.
public enum ChangeDetectionMode: String, Codable, CaseIterable, Sendable {
    /// Split archives (`.mpxar` + `.ppxar`), unchanged files are reused from the previous
    /// snapshot without reading them.
    case metadata
    /// One `.pxar` per folder, every file is read completely on every backup.
    case legacy

    public var title: String {
        switch self {
        case .metadata: "Metadata (recommended)"
        case .legacy: "Legacy"
        }
    }
}

public struct AppConfig: Codable, Equatable, Sendable {
    public var server = ServerSettings()
    /// Backup ID of the snapshot group `host/<backupID>`.
    public var backupID: String
    public var folders: [BackupFolder] = []
    /// Exclude patterns passed to every archive (`--exclude`), relative to the folder.
    public var excludes: [String] = AppConfig.defaultExcludes
    public var automaticBackups = true
    public var intervalMinutes = 60
    public var retention = Retention()
    public var changeDetection = ChangeDetectionMode.metadata
    /// Optional encryption key file (`proxmox-backup-client key create`).
    public var keyfile = ""
    /// Path of proxmox-backup-client, empty to use the bundled one.
    public var clientPath = ""

    public static let defaultExcludes = [
        ".DS_Store",
        ".Trash",
        ".Trashes",
        ".fseventsd",
        ".Spotlight-V100",
        ".TemporaryItems",
        ".DocumentRevisions-V100",
    ]

    public static let intervalChoices = [60, 120, 240, 360, 720, 1440]

    public init(backupID: String = AppConfig.defaultBackupID()) {
        self.backupID = backupID
    }

    /// Host name of the Mac reduced to the characters allowed in a backup ID.
    public static func defaultBackupID(hostName: String = ProcessInfo.processInfo.hostName) -> String {
        var name = hostName
        if let dot = name.firstIndex(of: ".") {
            name = String(name[..<dot])
        }
        let id = ArchiveNames.sanitize(name)
        return id == ArchiveNames.fallback ? "mac" : id
    }

    public var enabledFolders: [BackupFolder] {
        folders.filter(\.enabled)
    }

    public var archivePaths: [String: String] {
        Dictionary(folders.map { ($0.archiveName, $0.path) }, uniquingKeysWith: { first, _ in first })
    }

    // Decoding tolerates missing keys, so config files of older versions keep working.
    private enum CodingKeys: String, CodingKey {
        case server, backupID, folders, excludes, automaticBackups, intervalMinutes, retention,
            changeDetection, keyfile, clientPath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppConfig()
        server = try c.decodeIfPresent(ServerSettings.self, forKey: .server) ?? defaults.server
        backupID = try c.decodeIfPresent(String.self, forKey: .backupID) ?? defaults.backupID
        folders = try c.decodeIfPresent([BackupFolder].self, forKey: .folders) ?? []
        excludes = try c.decodeIfPresent([String].self, forKey: .excludes) ?? defaults.excludes
        automaticBackups =
            try c.decodeIfPresent(Bool.self, forKey: .automaticBackups) ?? defaults.automaticBackups
        intervalMinutes =
            try c.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? defaults.intervalMinutes
        retention = try c.decodeIfPresent(Retention.self, forKey: .retention) ?? defaults.retention
        // an unknown mode (e.g. written by a newer version) falls back to the default
        changeDetection =
            (try? c.decodeIfPresent(ChangeDetectionMode.self, forKey: .changeDetection))
            .flatMap { $0 } ?? defaults.changeDetection
        keyfile = try c.decodeIfPresent(String.self, forKey: .keyfile) ?? ""
        clientPath = try c.decodeIfPresent(String.self, forKey: .clientPath) ?? ""
    }
}

/// Outcome of the backup runs, shown in the menu and used for scheduling.
public struct BackupState: Codable, Equatable, Sendable {
    public var lastSuccess: Date?
    public var lastAttempt: Date?
    public var lastError: String?
    /// Problems that did not fail the backup, e.g. a missing folder or a failed prune.
    public var lastWarning: String?
    public var lastLog: String?
    /// Failed attempts since the last successful backup, for the retry backoff.
    public var failures: Int?

    public init() {}
}

/// JSON files in Application Support.
public struct JSONStore<Value: Codable> {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Value.self, from: data)
    }

    public func save(_ value: Value) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

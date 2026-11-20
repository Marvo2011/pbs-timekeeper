import Foundation
import Testing

@testable import TimekeeperCore

@Suite struct ArchiveNameTests {
    @Test func sanitizes() {
        #expect(ArchiveNames.sanitize("Documents") == "Documents")
        #expect(ArchiveNames.sanitize("Mein Ordner (alt)") == "Mein-Ordner-alt")
        #expect(ArchiveNames.sanitize("Übersicht_2026") == "Ubersicht_2026")
        #expect(ArchiveNames.sanitize(".config") == "config")
        #expect(ArchiveNames.sanitize("---") == ArchiveNames.fallback)
        #expect(ArchiveNames.sanitize("写真") != ArchiveNames.fallback)
        #expect(ArchiveNames.sanitize(String(repeating: "a", count: 100)).count == 60)
    }

    @Test func unique() {
        #expect(ArchiveNames.unique(forPath: "/Users/a/Documents", existing: []) == "Documents")
        #expect(
            ArchiveNames.unique(forPath: "/Volumes/X/Documents", existing: ["Documents", "Documents-2"])
                == "Documents-3")
    }

    @Test func backupID() {
        #expect(AppConfig.defaultBackupID(hostName: "Marvins-MacBook-Pro.local") == "Marvins-MacBook-Pro")
        #expect(AppConfig.defaultBackupID(hostName: "") == "mac")
    }
}

@Suite struct FolderValidationTests {
    let tmp: URL

    init() throws {
        tmp = FileManager.default.temporaryDirectory.appending(path: "tk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp.appending(path: "a/b"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: tmp.appending(path: "file").path, contents: Data())
    }

    func path(_ p: String) -> String {
        FolderValidation.canonical(tmp.appending(path: p).path)
    }

    @Test func refusesVolumesAndSystem() {
        #expect(FolderValidation.validate("/", existing: []) == .volume("/"))
        #expect(FolderValidation.validate("/Volumes", existing: []) == .systemLocation("/Volumes"))
        #expect(FolderValidation.validate("/System/Library", existing: []) == .systemLocation("/System/Library"))
        #expect(FolderValidation.validate(path("a"), existing: [], isVolume: { _ in true }) == .volume(path("a")))
    }

    @Test func refusesFilesAndOverlaps() {
        #expect(FolderValidation.validate(path("file"), existing: []) == .notADirectory(path("file")))
        #expect(FolderValidation.validate(path("a"), existing: []) == nil)
        #expect(FolderValidation.validate(path("a"), existing: [path("a")]) == .alreadyAdded(path("a")))
        #expect(FolderValidation.validate(path("a/b"), existing: [path("a")]) == .nested(path("a/b"), in: path("a")))
        #expect(FolderValidation.validate(path("a"), existing: [path("a/b")]) == .contains(path("a"), other: path("a/b")))
    }
}

@Suite struct CommandTests {
    var config: AppConfig {
        var config = AppConfig(backupID: "mac")
        config.server.host = "pbs.example.com"
        config.server.datastore = "store"
        config.server.authID = "me@pbs!token"
        config.server.fingerprint = "aa:bb"
        config.excludes = [".DS_Store", " "]
        return config
    }

    func builder(_ config: AppConfig) -> CommandBuilder {
        CommandBuilder(
            config: config, secrets: Secrets(password: "secret"),
            baseEnvironment: ["HOME": "/Users/me", "PBS_REPOSITORY": "x", "PBS_PASSWORD": "old"])
    }

    @Test func backup() {
        let folders = [BackupFolder(path: "/Users/me/My Docs", archiveName: "My-Docs")]
        let inv = builder(config).backup(folders: folders)
        #expect(
            inv.arguments == [
                "backup", "My-Docs.pxar:/Users/me/My Docs",
                "--server", "pbs.example.com", "--port", "8007", "--datastore", "store",
                "--auth-id", "me@pbs!token",
                "--backup-type", "host", "--backup-id", "mac",
                "--change-detection-mode", "metadata",
                "--exclude", ".DS_Store",
            ])
        #expect(inv.environment == ["HOME": "/Users/me", "PBS_PASSWORD": "secret", "PBS_FINGERPRINT": "aa:bb"])
    }

    @Test func namespaceAndKeyfile() {
        var config = config
        config.server.namespace = "macs"
        config.keyfile = "/k.json"
        let args = builder(config).mount(snapshot: "host/mac/2026-01-01T00:00:00Z", archive: "a", target: URL(fileURLWithPath: "/m")).arguments
        #expect(args.starts(with: ["mount", "host/mac/2026-01-01T00:00:00Z", "a.pxar", "/m"]))
        #expect(args.contains("--ns") && args.contains("macs"))
        #expect(args.suffix(2) == ["--keyfile", "/k.json"])
    }

    @Test func prune() {
        var config = config
        config.retention = Retention()
        config.retention.weekly = 0
        let args = builder(config).prune()?.arguments ?? []
        #expect(args.starts(with: ["prune", "host/mac", "--keep-hourly", "24", "--keep-daily", "30", "--server"]))
        #expect(!args.contains("--keep-weekly"))
        config.retention = Retention()
        config.retention.hourly = 0
        config.retention.daily = 0
        config.retention.weekly = 0
        #expect(builder(config).prune() == nil)
    }

    @Test func restorePatterns() {
        let args = builder(config).restore(
            snapshot: "s", archive: "a", relativePath: ["Fotos [alt]", "*.jpg"],
            target: URL(fileURLWithPath: "/t")
        ).arguments
        #expect(args.suffix(4) == ["--pattern", "/Fotos \\[alt\\]/\\*.jpg", "--pattern", "/Fotos \\[alt\\]/\\*.jpg/**"])
        let whole = builder(config).restore(snapshot: "s", archive: "a", relativePath: [], target: URL(fileURLWithPath: "/t")).arguments
        #expect(!whole.contains("--pattern"))
    }
}

@Suite struct SnapshotTests {
    @Test func parses() throws {
        let json = """
            [
              {"backup-type":"host","backup-id":"mac","backup-time":1763546400,
               "files":[{"filename":"index.json.blob","crypt-mode":"none","size":500},
                        {"filename":"Documents.mpxar.didx","crypt-mode":"none","size":10},
                        {"filename":"Documents.ppxar.didx","crypt-mode":"none","size":20},
                        {"filename":"Code.pxar.didx","crypt-mode":"none","size":30},
                        {"filename":"catalog.pcat1.didx","crypt-mode":"none","size":5}],
               "size":565,"owner":"me@pbs","protected":false},
              {"backup-type":"host","backup-id":"mac","backup-time":1763550000,"files":[]}
            ]
            """
        let list = try Snapshot.parseList(Data(json.utf8))
        #expect(list.map(\.backupTime) == [1763550000, 1763546400])
        #expect(list[1].archives == ["Documents", "Code"])
        #expect(list[1].path == "host/mac/2025-11-19T10:00:00Z")
    }
}

@Suite struct ScheduleTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func dueWithoutBackup() {
        #expect(Schedule.isDue(state: BackupState(), intervalMinutes: 60, now: now))
    }

    @Test func interval() {
        var state = BackupState()
        state.lastSuccess = now.addingTimeInterval(-30 * 60)
        state.lastAttempt = state.lastSuccess
        #expect(!Schedule.isDue(state: state, intervalMinutes: 60, now: now))
        #expect(Schedule.nextBackup(state: state, intervalMinutes: 60, now: now) == now.addingTimeInterval(30 * 60))
    }

    @Test func retryAfterFailure() {
        var state = BackupState()
        state.lastSuccess = now.addingTimeInterval(-24 * 3600)
        state.lastAttempt = now.addingTimeInterval(-5 * 60)
        state.lastError = "offline"
        #expect(Schedule.nextBackup(state: state, intervalMinutes: 60, now: now) == now.addingTimeInterval(10 * 60))
    }
}

@Suite struct ConfigTests {
    @Test func decodesOldConfig() throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"backupID":"x"}"#.utf8))
        #expect(config.backupID == "x")
        #expect(config.intervalMinutes == 60)
        #expect(config.excludes == AppConfig.defaultExcludes)
    }
}

@Suite struct RunnerTests {
    @Test func collectsOutput() async throws {
        let log = FileManager.default.temporaryDirectory.appending(path: "tk-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        let lines = LineSink()
        let result = try await ClientRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            invocation: ClientInvocation(
                arguments: ["-c", "echo one; echo two; echo 'Error: it broke' >&2; exit 3"],
                environment: [:]),
            logFile: log, onLine: { lines.add($0) })
        #expect(result.status == 3)
        #expect(result.stdout == "one\ntwo\n")
        #expect(result.errorMessage == "it broke")
        #expect(try String(contentsOf: log, encoding: .utf8).contains("exit status 3"))
        #expect(lines.all.contains("two"))
    }

    @Test func cancels() async throws {
        let task = Task {
            try await ClientRunner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                invocation: ClientInvocation(arguments: ["30"], environment: [:]))
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let result = try await task.value
        #expect(!result.succeeded)
    }
}

@Suite struct RestorerTests {
    @Test func uniqueNames() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "tk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(Restorer.uniqueName("a.txt", in: dir) == "a (restored).txt")
        FileManager.default.createFile(atPath: dir.appending(path: "a (restored).txt").path, contents: nil)
        #expect(Restorer.uniqueName("a.txt", in: dir) == "a (restored 2).txt")
        #expect(Restorer.uniqueName("Folder", in: dir) == "Folder (restored)")
    }
}

final class LineSink: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func add(_ line: String) {
        lock.withLock { lines.append(line) }
    }

    var all: [String] {
        lock.withLock { lines }
    }
}

@Suite struct SkippedEntriesTests {
    @Test func recognizesDeniedEntries() {
        #expect(SkippedEntries.isSkipped(#"failed to open file: "Accounts": operation not permitted (privacy protected, needs Full Disk Access)"#))
        #expect(SkippedEntries.isSkipped(#"failed to open file: ".pxarexclude": access denied"#))
        #expect(SkippedEntries.isSkipped(#"warning: failed to stat file: "Library/Mail": operation not permitted"#))
        #expect(!SkippedEntries.isSkipped("processed 11.427 GiB in 1m, uploaded 10.124 GiB"))
    }
}

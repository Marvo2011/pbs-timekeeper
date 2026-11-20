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
        state.failures = 3
        #expect(Schedule.nextBackup(state: state, intervalMinutes: 60, now: now) == now.addingTimeInterval(55 * 60))
        #expect(Schedule.retryDelay(failures: 20) == Schedule.maxRetryDelay)
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
    @Test func copiesAndResolvesConflicts() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "tk-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let source = dir.appending(path: "mount/Folder")
        try fm.createDirectory(at: source.appending(path: "sub"), withIntermediateDirectories: true)
        try "new".write(to: source.appending(path: "sub/file.txt"), atomically: true, encoding: .utf8)
        let target = dir.appending(path: "target")
        try fm.createDirectory(at: target.appending(path: "Folder"), withIntermediateDirectories: true)

        let kept = try Restorer.copy(source, into: target, name: "Folder", conflict: .keepBoth)
        #expect(kept.lastPathComponent == "Folder (restored)")
        #expect(try String(contentsOf: kept.appending(path: "sub/file.txt"), encoding: .utf8) == "new")
        #expect(fm.fileExists(atPath: target.appending(path: "Folder").path))

        let fresh = try Restorer.copy(
            source.appending(path: "sub/file.txt"), into: target.appending(path: "a/b"), name: "file.txt",
            conflict: .keepBoth)
        #expect(fresh.path.hasSuffix("target/a/b/file.txt"))
        #expect(throws: ClientError.self) {
            try Restorer.copy(dir.appending(path: "missing"), into: target, name: "x", conflict: .keepBoth)
        }
    }

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
        #expect(!SkippedEntries.isSkipped(#"failed to open file: "Library/x/.pxarexclude": access denied"#))
        #expect(SkippedEntries.isSkipped(#"failed to open file: "Library/x/a": access denied"#))
        #expect(SkippedEntries.isWarning(#"skipping online-only file: "a""#))
        #expect(!SkippedEntries.isWarning("processed 1 GiB in 1m, uploaded 1 GiB"))
        #expect(SkippedEntries.isSkipped(#"warning: failed to stat file: "Library/Mail": operation not permitted"#))
        #expect(!SkippedEntries.isSkipped("processed 11.427 GiB in 1m, uploaded 10.124 GiB"))
    }
}

@Suite struct RunningClientTests {
    @Test func recognizesClientProcesses() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "tk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appending(path: ClientLocator.executableName)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: fake)

        let client = Process()
        client.executableURL = fake
        client.arguments = ["30"]
        try client.run()
        let other = Process()
        other.executableURL = URL(fileURLWithPath: "/bin/sleep")
        other.arguments = ["30"]
        try other.run()
        defer {
            client.terminate()
            other.terminate()
        }
        #expect(RunningClient.isClient(client.processIdentifier))
        #expect(!RunningClient.isClient(other.processIdentifier))
        client.interrupt()
        client.waitUntilExit()
        #expect(!RunningClient.isClient(client.processIdentifier))
    }
}

@Suite struct ProgressTests {
    @Test func parsesProgressLines() {
        let progress = BackupProgress(line: "processed 182.652 GiB in 20m, uploaded 142.96 GiB")
        #expect(progress?.processed.hasPrefix("182") == true)
        #expect(progress?.processed.hasSuffix(" GiB") == true)
        #expect(progress?.uploaded.hasSuffix(" GiB") == true)
        #expect(BackupProgress(line: "processed 11 MiB in 1m, uploaded 0 B") == BackupProgress(processed: "11 MiB", uploaded: "0 B"))
        #expect(BackupProgress(line: "skipping online-only file: \"x\"") == nil)
    }
}

@Suite struct EncryptionKeyTests {
    @Test func readsKeyInfoAndMovesAside() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "tk-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let key = dir.appending(path: "encryption-key.json")
        try #"{"kdf":null,"created":"2026-11-20T11:09:34+01:00","modified":"2026-11-20T11:09:34+01:00","data":"x","fingerprint":"33:67:2c:2a:ef:ef:c4:f1:4b:c6"}"#
            .write(to: key, atomically: true, encoding: .utf8)
        let info = try #require(EncryptionKey.info(at: key.path))
        #expect(!info.passwordProtected)
        #expect(info.shortFingerprint == "33:67:2c:2a:ef:ef:c4:f1")

        let protected = dir.appending(path: "p.json")
        try #"{"kdf":{"Scrypt":{"n":65536,"r":8,"p":1,"salt":"aa"}},"data":"x","fingerprint":"aa:bb"}"#
            .write(to: protected, atomically: true, encoding: .utf8)
        #expect(EncryptionKey.info(at: protected.path)?.passwordProtected == true)
        #expect(EncryptionKey.info(at: dir.appending(path: "missing").path) == nil)

        let now = Date(timeIntervalSince1970: 1_795_169_374)
        let moved = try #require(try EncryptionKey.moveAside(key, now: now))
        #expect(!fm.fileExists(atPath: key.path))
        #expect(moved.lastPathComponent.hasPrefix("encryption-key-2026"))
        #expect(try EncryptionKey.moveAside(key) == nil)
    }

    @Test func commands() {
        let builder = CommandBuilder(config: AppConfig(backupID: "mac"), secrets: Secrets(), baseEnvironment: [:])
        #expect(builder.createKey(at: URL(fileURLWithPath: "/k.json")).arguments == ["key", "create", "/k.json", "--kdf", "none"])
        #expect(builder.paperKey(at: "/k.json", subject: "S").arguments == ["key", "paperkey", "/k.json", "--output-format", "html", "--subject", "S"])
    }
}

@Suite struct VersionTests {
    @Test func parsesClientVersion() {
        #expect(Versions.parseClient("client version: 4.2.10+20261120\n") == "4.2.10+20261120")
        #expect(Versions.parseClient("garbage") == nil)
    }
}

import AppKit
import Foundation
import Observation
import TimekeeperCore

/// State of the backup browser: the snapshots on the timeline, the folder shown and the
/// FUSE-T mounts behind it. The folder shown stays the same when moving along the timeline,
/// so one folder can be compared across snapshots.
@MainActor
@Observable
final class BrowserModel {
    struct Location: Equatable {
        var archive: String
        var path: [String]
    }

    struct Entry: Identifiable, Hashable {
        var id: String { name }
        var name: String
        var isDirectory: Bool
        var isSymlink = false
        var size: UInt64?
        var modified: Date?
        /// For the top level: the original folder of the archive.
        var originalPath: String?
        var isHidden: Bool { name.hasPrefix(".") }
    }

    let app: AppModel
    private(set) var snapshots: [Snapshot] = []
    private(set) var loadingSnapshots = false
    var selectedID: Snapshot.ID? {
        didSet {
            if selectedID != oldValue {
                Task { await showLocation() }
            }
        }
    }
    private(set) var location: Location?
    private(set) var entries: [Entry] = []
    private(set) var loadingEntries = false
    var error: String?
    var showHidden = false
    private(set) var busyMessage: String?
    var lastRestored: URL?

    /// Mount points by snapshot path and archive.
    private var mounts: [String: URL] = [:]
    /// Increased with each navigation, so results of outdated loads are dropped.
    private var generation = 0

    init(app: AppModel) {
        self.app = app
    }

    var selected: Snapshot? {
        snapshots.first { $0.id == selectedID }
    }

    var visibleEntries: [Entry] {
        showHidden ? entries : entries.filter { !$0.isHidden }
    }

    // MARK: Snapshots

    func reload() async {
        guard let client = app.clientURL else {
            error = "proxmox-backup-client was not found."
            return
        }
        loadingSnapshots = true
        defer { loadingSnapshots = false }
        do {
            let result = try await ClientRunner.check(
                executable: client, invocation: app.builder.listSnapshots(),
                logFile: Logs.newLogFile(prefix: "browse"))
            Logs.prune(prefix: "browse", keep: 20)
            let list = try Snapshot.parseList(Data(result.stdout.utf8))
            // whoever looked at the newest backup gets the one just finished
            let showedNewest = selectedID != nil && selectedID == snapshots.first?.id
            snapshots = list
            if showedNewest || selectedID == nil || !list.contains(where: { $0.id == selectedID }) {
                selectedID = list.first?.id
            }
            if list.isEmpty {
                error = "There are no backups of this Mac yet."
            } else if error == "There are no backups of this Mac yet." {
                error = nil
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Moves along the timeline, positive offsets go back in time.
    func step(_ offset: Int) {
        guard let index = snapshots.firstIndex(where: { $0.id == selectedID }) else { return }
        let next = index + offset
        if snapshots.indices.contains(next) {
            selectedID = snapshots[next].id
        }
    }

    // MARK: Navigation

    func open(_ entry: Entry) {
        if let location {
            guard entry.isDirectory else {
                if let url = url(for: entry) {
                    NSWorkspace.shared.open(url)
                }
                return
            }
            self.location = Location(archive: location.archive, path: location.path + [entry.name])
        } else {
            location = Location(archive: entry.name, path: [])
        }
        Task { await showLocation() }
    }

    /// `depth` -1 is the list of folders, 0 the root of the archive.
    func navigate(toDepth depth: Int) {
        guard let current = location else { return }
        location = depth < 0 ? nil : Location(archive: current.archive, path: Array(current.path.prefix(depth)))
        Task { await showLocation() }
    }

    func displayName(ofArchive archive: String) -> String {
        if let path = app.config.archivePaths[archive] {
            return FileManager.default.displayName(atPath: path)
        }
        return archive
    }

    private func showLocation() async {
        generation += 1
        let token = generation
        guard let snapshot = selected else {
            entries = []
            return
        }
        unmountOthers(keeping: snapshot)

        guard var location else {
            entries = snapshot.archives.map { archive in
                Entry(name: archive, isDirectory: true, originalPath: app.config.archivePaths[archive])
            }
            error = nil
            return
        }
        guard snapshot.archives.contains(location.archive) else {
            // the folder was not backed up in this snapshot
            entries = []
            error = "\(displayName(ofArchive: location.archive)) is not part of this backup."
            return
        }

        loadingEntries = true
        defer {
            if token == generation {
                loadingEntries = false
            }
        }
        do {
            let root = try await mountPoint(snapshot: snapshot, archive: location.archive)
            guard token == generation else { return }
            // stay in the deepest folder that exists in this snapshot
            while !location.path.isEmpty, !isDirectory(root.appending(path: location.path.joined(separator: "/"))) {
                location.path.removeLast()
            }
            self.location = location
            let dir = location.path.reduce(root) { $0.appending(path: $1) }
            let list = try await Task.detached { try Self.list(dir) }.value
            guard token == generation else { return }
            entries = list
            error = nil
        } catch {
            guard token == generation else { return }
            entries = []
            self.error = error.localizedDescription
        }
    }

    private nonisolated static func list(_ dir: URL) throws -> [Entry] {
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
        ]
        let urls = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys)
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory ?? false
            return Entry(
                name: url.lastPathComponent,
                isDirectory: isDirectory,
                isSymlink: values?.isSymbolicLink ?? false,
                size: isDirectory ? nil : values?.fileSize.map { UInt64($0) },
                modified: values?.contentModificationDate)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: Mounts

    private func key(_ snapshot: Snapshot, _ archive: String) -> String {
        "\(snapshot.path)|\(archive)"
    }

    private func mountPoint(snapshot: Snapshot, archive: String) async throws -> URL {
        if let url = mounts[key(snapshot, archive)], Mounts.isMountPoint(url) {
            return url
        }
        guard Paths.fuseInstalled else {
            throw ClientError("Browsing backups needs FUSE-T, install it from https://www.fuse-t.org.")
        }
        guard let client = app.clientURL else {
            throw ClientError("proxmox-backup-client was not found.")
        }
        busyMessage = "Opening \(displayName(ofArchive: archive))…"
        defer { busyMessage = nil }
        let url = try await Mounts.mount(
            executable: client, builder: app.builder, snapshot: snapshot, archive: archive,
            logFile: Logs.newLogFile(prefix: "browse"))
        mounts[key(snapshot, archive)] = url
        Logs.prune(prefix: "browse", keep: 20)
        return url
    }

    /// Only the mounts of the snapshot shown are kept, each one is a client process.
    private func unmountOthers(keeping snapshot: Snapshot) {
        let prefix = "\(snapshot.path)|"
        let stale = mounts.filter { !$0.key.hasPrefix(prefix) }
        for (key, url) in stale {
            mounts[key] = nil
            Task.detached { Mounts.unmount(url) }
        }
    }

    func close() {
        let urls = Array(mounts.values)
        mounts = [:]
        location = nil
        Task.detached { urls.forEach(Mounts.unmount) }
    }

    /// The entry inside the mounted archive.
    func url(for entry: Entry) -> URL? {
        guard let snapshot = selected, let location,
            let root = mounts[key(snapshot, location.archive)]
        else {
            return nil
        }
        return (location.path + [entry.name]).reduce(root) { $0.appending(path: $1) }
    }

    func showInFinder(_ entries: [Entry]) {
        let urls = entries.compactMap(url(for:))
        if urls.isEmpty, let snapshot = selected, let location,
            let root = mounts[key(snapshot, location.archive)]
        {
            NSWorkspace.shared.open(location.path.reduce(root) { $0.appending(path: $1) })
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    // MARK: Restore

    struct RestoreItem {
        var archive: String
        var relativePath: [String]
        var name: String
        /// Folder the item came from, nil if its archive is no longer configured.
        var originalDirectory: URL?
    }

    func restoreItems(_ selection: Set<Entry.ID>) -> [RestoreItem] {
        let chosen = entries.filter { selection.contains($0.id) }
        return chosen.map { entry in
            if let location {
                let original = app.config.archivePaths[location.archive].map { root in
                    location.path.reduce(URL(fileURLWithPath: root)) { $0.appending(path: $1) }
                }
                return RestoreItem(
                    archive: location.archive, relativePath: location.path + [entry.name],
                    name: entry.name, originalDirectory: original)
            }
            // a whole backed up folder
            let original = entry.originalPath.map(URL.init(fileURLWithPath:))
            return RestoreItem(
                archive: entry.name, relativePath: [],
                name: original?.lastPathComponent ?? entry.name,
                originalDirectory: original?.deletingLastPathComponent())
        }
    }

    /// Items whose name is already taken in the destination.
    func conflicts(_ items: [RestoreItem], destination: URL?) -> [String] {
        items.compactMap { item in
            guard let dir = destination ?? item.originalDirectory else { return nil }
            let path = dir.appending(path: item.name).path
            let exists = (try? FileManager.default.attributesOfItem(atPath: path)) != nil
            return exists ? item.name : nil
        }
    }

    /// Restores to `destination`, or to the original folders if nil, by copying from the
    /// mounted snapshot.
    func restore(_ items: [RestoreItem], to destination: URL?, conflict: ConflictResolution) async {
        guard let snapshot = selected else { return }
        var restored: [URL] = []
        for item in items {
            guard let dir = destination ?? item.originalDirectory else {
                error = "The original folder of \(item.name) is unknown, use Restore To…"
                continue
            }
            do {
                let root = try await mountPoint(snapshot: snapshot, archive: item.archive)
                let source = item.relativePath.reduce(root) { $0.appending(path: $1) }
                busyMessage = "Restoring \(item.name)…"
                let name = item.name
                let url = try await Task.detached {
                    try Restorer.copy(source, into: dir, name: name, conflict: conflict)
                }.value
                restored.append(url)
            } catch {
                self.error = "Restoring \(item.name) failed: \(error.localizedDescription)"
            }
        }
        busyMessage = nil
        if !restored.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(restored)
        }
    }
}

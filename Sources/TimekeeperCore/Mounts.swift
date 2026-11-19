import Foundation

/// Read-only FUSE-T mounts of archives, used to browse snapshots.
public enum Mounts {
    public static func directory(snapshot: Snapshot, archive: String) -> URL {
        Paths.mounts.appending(path: "\(snapshot.backupTime)-\(archive)", directoryHint: .isDirectory)
    }

    /// Something else is mounted on `url` if it lives on another device than its parent.
    public static func isMountPoint(_ url: URL) -> Bool {
        var own = stat()
        var parent = stat()
        guard stat(url.path, &own) == 0,
            stat(url.deletingLastPathComponent().path, &parent) == 0
        else {
            return false
        }
        return own.st_dev != parent.st_dev
    }

    public static func mount(
        executable: URL, builder: CommandBuilder, snapshot: Snapshot, archive: String,
        logFile: URL? = nil
    ) async throws -> URL {
        let target = directory(snapshot: snapshot, archive: archive)
        if isMountPoint(target) {
            return target
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) {
            try fm.removeItem(at: target)
        }
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        do {
            try await ClientRunner.check(
                executable: executable,
                invocation: builder.mount(snapshot: snapshot.path, archive: archive, target: target),
                logFile: logFile)
            // the client returns once its daemon is ready, give FUSE-T a moment otherwise
            for _ in 0..<50 where !isMountPoint(target) {
                try await Task.sleep(for: .milliseconds(100))
            }
            guard isMountPoint(target) else {
                throw ClientError("The archive \(archive) could not be mounted.")
            }
            return target
        } catch {
            try? fm.removeItem(at: target)
            throw error
        }
    }

    /// Unmounts and removes the mount point. The client's daemon exits on unmount.
    public static func unmount(_ url: URL) {
        if isMountPoint(url) {
            if run("/sbin/umount", [url.path]) != 0 {
                _ = run("/usr/sbin/diskutil", ["unmount", "force", url.path])
            }
        }
        if !isMountPoint(url) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Unmounts everything left over, e.g. after a crash.
    public static func unmountAll() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: Paths.mounts, includingPropertiesForKeys: nil)
        else {
            return
        }
        entries.forEach(unmount)
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

public enum ConflictResolution: Sendable {
    /// Keep the existing item and restore next to it under a new name.
    case keepBoth
    /// Move the existing item to the Trash.
    case replace
}

/// Restores with `proxmox-backup-client restore`, which (unlike copying from a FUSE-T mount)
/// brings back extended attributes, file flags and ownership.
public enum Restorer {
    public static func restore(
        executable: URL, builder: CommandBuilder, snapshot: Snapshot, archive: String,
        relativePath: [String], into directory: URL, name: String,
        conflict: ConflictResolution, logFile: URL? = nil
    ) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        // restore next to the destination, so the final move stays on the same volume
        let scratch = try fm.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: directory,
            create: true)
        defer { try? fm.removeItem(at: scratch) }

        let target = scratch.appending(path: "restore", directoryHint: .isDirectory)
        try await ClientRunner.check(
            executable: executable,
            invocation: builder.restore(
                snapshot: snapshot.path, archive: archive, relativePath: relativePath,
                target: target),
            logFile: logFile)

        var restored = target
        for component in relativePath {
            restored.append(path: component)
        }
        guard fm.fileExists(atPath: restored.path) || isSymlink(restored) else {
            throw ClientError("\(relativePath.last ?? archive) was not found in the backup.")
        }

        var destination = directory.appending(path: name)
        if fm.fileExists(atPath: destination.path) || isSymlink(destination) {
            switch conflict {
            case .replace:
                try fm.trashItem(at: destination, resultingItemURL: nil)
            case .keepBoth:
                destination = directory.appending(path: uniqueName(name, in: directory))
            }
        }
        try fm.moveItem(at: restored, to: destination)
        return destination
    }

    /// `Report (restored).pdf`, `Report (restored 2).pdf`, …
    public static func uniqueName(_ name: String, in directory: URL) -> String {
        let fm = FileManager.default
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var n = 1
        while true {
            let suffix = n == 1 ? "(restored)" : "(restored \(n))"
            let candidate = ext.isEmpty ? "\(base) \(suffix)" : "\(base) \(suffix).\(ext)"
            let url = directory.appending(path: candidate)
            if !fm.fileExists(atPath: url.path) && !isSymlink(url) {
                return candidate
            }
            n += 1
        }
    }

    static func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType)
            == .typeSymbolicLink
    }
}

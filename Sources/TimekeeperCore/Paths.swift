import Foundation

public enum Paths {
    static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    public static var appSupport: URL {
        home.appending(path: "Library/Application Support/PBSTimekeeper", directoryHint: .isDirectory)
    }

    public static var config: URL {
        appSupport.appending(path: "config.json")
    }

    public static var state: URL {
        appSupport.appending(path: "state.json")
    }

    /// Mount points of browsed snapshots. FUSE-T cannot mount on paths containing `:`, and a
    /// path without spaces keeps the client's command line simple.
    public static var mounts: URL {
        home.appending(path: "Library/Caches/PBSTimekeeper/Mounts", directoryHint: .isDirectory)
    }

    public static var logs: URL {
        home.appending(path: "Library/Logs/PBSTimekeeper", directoryHint: .isDirectory)
    }

    /// Whether the app (and so the client it starts) has Full Disk Access: the TCC database
    /// can only be read with it.
    public static var hasFullDiskAccess: Bool {
        let tccDB = home.appending(path: "Library/Application Support/com.apple.TCC/TCC.db")
        guard let handle = try? FileHandle(forReadingFrom: tccDB) else { return false }
        try? handle.close()
        return true
    }

    /// FUSE-T provides the libfuse3 the client loads for `mount`.
    public static var fuseInstalled: Bool {
        FileManager.default.fileExists(atPath: "/usr/local/lib/libfuse3.4.dylib")
            || FileManager.default.fileExists(atPath: "/usr/local/lib/libfuse3.dylib")
    }
}

public enum ClientLocator {
    public static let executableName = "proxmox-backup-client"

    /// The configured path, the copy in the app bundle or a Homebrew installation.
    public static func locate(override: String, bundle: Bundle = .main) -> URL? {
        var candidates: [String] = []
        if !override.trimmed.isEmpty {
            candidates.append((override.trimmed as NSString).expandingTildeInPath)
        }
        if let bundled = bundle.url(forAuxiliaryExecutable: executableName) {
            candidates.append(bundled.path)
        }
        candidates += [
            "/opt/homebrew/bin/\(executableName)",
            "/usr/local/bin/\(executableName)",
        ]
        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }
}

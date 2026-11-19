import Foundation

/// Archive names may only contain alphanumerics, `-` and `_` and must not start with `-`.
public enum ArchiveNames {
    public static let fallback = "folder"
    static let maxLength = 60

    public static func sanitize(_ name: String) -> String {
        let latin = name.applyingTransform(.toLatin, reverse: false) ?? name
        let plain = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
        var result = ""
        for scalar in plain.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) || scalar == "_" {
                result.unicodeScalars.append(scalar)
            } else if !result.isEmpty, !result.hasSuffix("-") {
                result.append("-")
            }
        }
        while result.hasSuffix("-") {
            result.removeLast()
        }
        if result.count > maxLength {
            result = String(result.prefix(maxLength))
            while result.hasSuffix("-") {
                result.removeLast()
            }
        }
        return result.isEmpty ? fallback : result
    }

    /// Name for a new folder, unique among the archives already in use.
    public static func unique(forPath path: String, existing: Set<String>) -> String {
        let base = sanitize((path as NSString).lastPathComponent)
        if !existing.contains(base) {
            return base
        }
        var n = 2
        while existing.contains("\(base)-\(n)") {
            n += 1
        }
        return "\(base)-\(n)"
    }
}

public enum FolderProblem: Error, Equatable, LocalizedError {
    case notADirectory(String)
    case volume(String)
    case systemLocation(String)
    case alreadyAdded(String)
    case nested(String, in: String)
    case contains(String, other: String)

    public var errorDescription: String? {
        switch self {
        case .notADirectory(let p):
            "\(p) is not a folder."
        case .volume(let p):
            "\(p) is a whole volume. PBS Timekeeper backs up folders only, choose folders on it instead."
        case .systemLocation(let p):
            "\(p) belongs to macOS and cannot be backed up."
        case .alreadyAdded(let p):
            "\(p) is already backed up."
        case .nested(let p, let parent):
            "\(p) is inside \(parent), which is already backed up."
        case .contains(let p, let child):
            "\(p) contains \(child), which is already backed up. Remove that folder first."
        }
    }
}

public enum FolderValidation {
    static let systemLocations = ["/System", "/dev", "/private/var/vm", "/cores"]

    /// Canonical form used for comparisons: absolute, symlinks resolved, no trailing slash.
    public static func canonical(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Checks that `path` is a folder that may be added next to `existing`. Volume roots (and
    /// so the whole disk) are refused, as are folders overlapping an existing one, since each
    /// folder is its own archive.
    public static func validate(
        _ path: String, existing: [String], isVolume: (String) -> Bool = FolderValidation.isVolume
    ) -> FolderProblem? {
        let path = canonical(path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue
        else {
            return .notADirectory(path)
        }
        if path == "/" || isVolume(path) {
            return .volume(path)
        }
        // /Volumes itself holds the mount points of all disks
        if path == "/Volumes"
            || systemLocations.contains(where: { path == $0 || path.hasPrefix($0 + "/") })
        {
            return .systemLocation(path)
        }
        for other in existing.map(canonical) {
            if other == path {
                return .alreadyAdded(path)
            }
            if path.hasPrefix(other + "/") {
                return .nested(path, in: other)
            }
            if other.hasPrefix(path + "/") {
                return .contains(path, other: other)
            }
        }
        return nil
    }

    public static func isVolume(_ path: String) -> Bool {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isVolumeKey])
        return values?.isVolume ?? false
    }
}

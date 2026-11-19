import Foundation

/// One entry of `snapshot list --output-format json`.
public struct Snapshot: Decodable, Identifiable, Hashable, Sendable {
    public struct File: Decodable, Hashable, Sendable {
        public var filename: String
        public var size: UInt64?
    }

    public var backupType: String
    public var backupID: String
    public var backupTime: Int64
    public var files: [File]
    public var size: UInt64?
    public var protected: Bool?
    public var comment: String?

    enum CodingKeys: String, CodingKey {
        case backupType = "backup-type"
        case backupID = "backup-id"
        case backupTime = "backup-time"
        case files, size, protected, comment
    }

    public var id: String { path }

    public var date: Date {
        Date(timeIntervalSince1970: TimeInterval(backupTime))
    }

    /// `host/<id>/<RFC 3339 time>`, as the client expects it.
    public var path: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return "\(backupType)/\(backupID)/\(formatter.string(from: date))"
    }

    /// Names (without extension) of the pxar archives. Split archives of the metadata change
    /// detection appear as `<name>.mpxar.didx` and `<name>.ppxar.didx`.
    public var archives: [String] {
        var names: [String] = []
        for file in files {
            var name = file.filename
            if name.hasSuffix(".didx") {
                name.removeLast(".didx".count)
            }
            for ext in [".pxar", ".mpxar"] where name.hasSuffix(ext) {
                let base = String(name.dropLast(ext.count))
                if !names.contains(base) {
                    names.append(base)
                }
            }
        }
        return names
    }

    /// Parses the client's output, newest snapshot first.
    public static func parseList(_ data: Data) throws -> [Snapshot] {
        try JSONDecoder().decode([Snapshot].self, from: data)
            .sorted { $0.backupTime > $1.backupTime }
    }
}

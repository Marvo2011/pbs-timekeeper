import Foundation

/// Client-side encryption keys (`proxmox-backup-client key …`).
///
/// Keys created by the app have no password (`--kdf none`), as Proxmox VE does it: the client
/// only accepts a key password on a terminal, and the app would have to keep the password in
/// the Keychain next to the key anyway. The protection against losing the key is the paper
/// key and a copy kept elsewhere.
public enum EncryptionKey {
    /// Where the app creates its key.
    public static var defaultLocation: URL {
        Paths.appSupport.appending(path: "encryption-key.json")
    }

    public struct Info: Equatable, Sendable {
        public var fingerprint: String
        /// Whether the key needs a password (scrypt/pbkdf2).
        public var passwordProtected: Bool
        public var created: String?

        /// The first 8 bytes, as the client shows them ("Encrypting backup with key fingerprint").
        public var shortFingerprint: String {
            fingerprint.split(separator: ":").prefix(8).joined(separator: ":")
        }
    }

    /// Reads fingerprint and protection of a key file without needing its password.
    public static func info(at path: String) -> Info? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let fingerprint = json["fingerprint"] as? String
        else {
            return nil
        }
        let kdf = json["kdf"]
        return Info(
            fingerprint: fingerprint,
            passwordProtected: kdf != nil && !(kdf is NSNull),
            created: json["created"] as? String)
    }

    /// Moves an existing key at `url` aside instead of overwriting it, backups made with it
    /// can only be restored with it. Returns the new location of the old key.
    @discardableResult
    public static func moveAside(_ url: URL, now: Date = Date()) throws -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = url.deletingPathExtension().lastPathComponent
        var target = url.deletingLastPathComponent()
            .appending(path: "\(base)-\(formatter.string(from: now)).json")
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = url.deletingLastPathComponent()
                .appending(path: "\(base)-\(formatter.string(from: now))-\(n).json")
            n += 1
        }
        try fm.moveItem(at: url, to: target)
        return target
    }

    /// Creates a new key without password at `url` (which must not exist).
    public static func create(at url: URL, executable: URL, builder: CommandBuilder) async throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await ClientRunner.check(executable: executable, invocation: builder.createKey(at: url))
        guard info(at: url.path) != nil else {
            throw ClientError("The key was not created.")
        }
    }

    /// The printable paper key (HTML with the key as text and as QR code).
    public static func paperKey(at path: String, subject: String, executable: URL, builder: CommandBuilder)
        async throws -> String
    {
        let result = try await ClientRunner.check(
            executable: executable, invocation: builder.paperKey(at: path, subject: subject))
        return result.stdout
    }
}

extension CommandBuilder {
    public func createKey(at url: URL) -> ClientInvocation {
        invocation(["key", "create", url.path, "--kdf", "none"])
    }

    public func paperKey(at path: String, subject: String) -> ClientInvocation {
        invocation([
            "key", "paperkey", (path as NSString).expandingTildeInPath,
            "--output-format", "html", "--subject", subject,
        ])
    }
}

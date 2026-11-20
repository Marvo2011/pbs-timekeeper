import Foundation

public enum Versions {
    /// Version of the app from its bundle, "dev" when run with `swift run`.
    public static func app(bundle: Bundle = .main) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// Version of the client release bundled at build time (Info.plist `PBSClientVersion`).
    public static func bundledClient(bundle: Bundle = .main) -> String? {
        bundle.object(forInfoDictionaryKey: "PBSClientVersion") as? String
    }

    /// Parses `proxmox-backup-client version`: `client version: 4.2.10+20261120`.
    public static func parseClient(_ output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "client version" {
                let version = parts[1].trimmingCharacters(in: .whitespaces)
                return version.isEmpty ? nil : version
            }
        }
        return nil
    }

    /// Asks the client for its version.
    public static func client(executable: URL) async -> String? {
        let invocation = ClientInvocation(arguments: ["version"], environment: ProcessInfo.processInfo.environment)
        guard let result = try? await ClientRunner.run(executable: executable, invocation: invocation),
            result.succeeded
        else {
            return nil
        }
        return parseClient(result.stdout)
    }
}

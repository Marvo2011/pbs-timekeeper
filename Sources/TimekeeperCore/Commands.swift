import Foundation

/// Arguments and environment for one proxmox-backup-client run.
public struct ClientInvocation: Equatable, Sendable {
    public var arguments: [String]
    public var environment: [String: String]
}

public struct Secrets: Equatable, Sendable {
    public var password: String?
    public var encryptionPassword: String?

    public init(password: String? = nil, encryptionPassword: String? = nil) {
        self.password = password
        self.encryptionPassword = encryptionPassword
    }
}

/// Builds the command lines. The repository is passed with separate options (`--server`,
/// `--port`, `--datastore`, `--auth-id`), so auth IDs with `@` and `!` need no quoting rules,
/// secrets go through the environment and never show up in the process list.
public struct CommandBuilder: Sendable {
    public var config: AppConfig
    public var secrets: Secrets
    /// Environment the client inherits, without variables that would override the options.
    public var baseEnvironment: [String: String]

    static let overriddenVariables: Set<String> = [
        "PBS_REPOSITORY", "PBS_PASSWORD", "PBS_PASSWORD_FILE", "PBS_PASSWORD_FD",
        "PBS_PASSWORD_CMD", "PBS_FINGERPRINT", "PBS_ENCRYPTION_PASSWORD",
        "PBS_ENCRYPTION_PASSWORD_FILE", "PBS_ENCRYPTION_PASSWORD_FD",
        "PBS_ENCRYPTION_PASSWORD_CMD", "PBS_NAMESPACE",
    ]

    public init(
        config: AppConfig, secrets: Secrets,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.config = config
        self.secrets = secrets
        self.baseEnvironment = baseEnvironment
    }

    /// The snapshot group of this Mac.
    public var group: String {
        "host/\(config.backupID)"
    }

    var connection: [String] {
        let server = config.server
        var args = [
            "--server", server.host.trimmed,
            "--port", String(server.port),
            "--datastore", server.datastore.trimmed,
            "--auth-id", server.authID.trimmed,
        ]
        if !server.namespace.trimmed.isEmpty {
            args += ["--ns", server.namespace.trimmed]
        }
        return args
    }

    var keyfile: [String] {
        let path = config.keyfile.trimmed
        return path.isEmpty ? [] : ["--keyfile", (path as NSString).expandingTildeInPath]
    }

    var environment: [String: String] {
        var env = baseEnvironment.filter { !Self.overriddenVariables.contains($0.key) }
        if let password = secrets.password, !password.isEmpty {
            env["PBS_PASSWORD"] = password
        }
        if let password = secrets.encryptionPassword, !password.isEmpty {
            env["PBS_ENCRYPTION_PASSWORD"] = password
        }
        let fingerprint = config.server.fingerprint.trimmed
        if !fingerprint.isEmpty {
            env["PBS_FINGERPRINT"] = fingerprint
        }
        return env
    }

    func invocation(_ arguments: [String]) -> ClientInvocation {
        ClientInvocation(arguments: arguments, environment: environment)
    }

    /// One snapshot with a pxar archive per folder. The metadata change detection (default)
    /// reuses unchanged files of the previous snapshot instead of reading them again.
    public func backup(folders: [BackupFolder]) -> ClientInvocation {
        var args = ["backup"]
        args += folders.map { "\($0.archiveName).pxar:\($0.path)" }
        args += connection
        args += ["--backup-type", "host", "--backup-id", config.backupID]
        args += ["--change-detection-mode", config.changeDetection.rawValue]
        args += keyfile
        for pattern in config.excludes where !pattern.trimmed.isEmpty {
            args += ["--exclude", pattern.trimmed]
        }
        return invocation(args)
    }

    /// Thins out the snapshots of this Mac, nil if client-side retention is off.
    public func prune() -> ClientInvocation? {
        let r = config.retention
        if !r.isActive {
            return nil
        }
        var args = ["prune", group]
        for (option, value) in [
            ("--keep-hourly", r.hourly), ("--keep-daily", r.daily), ("--keep-weekly", r.weekly),
            ("--keep-monthly", r.monthly), ("--keep-yearly", r.yearly),
        ] where value > 0 {
            args += [option, String(value)]
        }
        args += connection
        args += ["--quiet", "true"]
        return invocation(args)
    }

    public func listSnapshots() -> ClientInvocation {
        invocation(["snapshot", "list", group] + connection + ["--output-format", "json"])
    }

    /// Removes a snapshot from the server.
    public func forget(snapshot: String) -> ClientInvocation {
        invocation(["snapshot", "forget", snapshot] + connection)
    }

    /// Lists the groups of the datastore, used to test the connection settings.
    public func listGroups() -> ClientInvocation {
        invocation(["list"] + connection + ["--output-format", "json"])
    }

    /// Mounts an archive read-only. The client forks into the background once the mount is
    /// ready and runs until it is unmounted. `archive` is the name without extension, the
    /// client finds split archives (`.mpxar`/`.ppxar`) for `<name>.pxar` itself.
    public func mount(snapshot: String, archive: String, target: URL) -> ClientInvocation {
        invocation(["mount", snapshot, "\(archive).pxar", target.path] + connection + keyfile)
    }
}

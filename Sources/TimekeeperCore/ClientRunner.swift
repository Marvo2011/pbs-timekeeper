import Foundation

public struct ProcessResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public var succeeded: Bool { status == 0 }

    /// The client reports failures as `Error: …` on stderr, usually in the last line.
    public var errorMessage: String {
        let lines = stderr.split(whereSeparator: \.isNewline).map(String.init)
        let message = lines.last { $0.hasPrefix("Error:") } ?? lines.last ?? ""
        let text = message.hasPrefix("Error: ") ? String(message.dropFirst(7)) : message
        return text.isEmpty ? "proxmox-backup-client exited with status \(status)" : text
    }
}

/// Entries the client skipped because macOS denied access, reported in its output as
/// `failed to open file: …: access denied` / `operation not permitted`.
public enum SkippedEntries {
    public static func isSkipped(_ line: String) -> Bool {
        (line.contains("failed to open file:") || line.contains("failed to stat file:"))
            && (line.contains("access denied") || line.contains("operation not permitted"))
    }
}

public struct ClientError: Error, LocalizedError, Sendable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// Runs proxmox-backup-client and collects its output. Cancelling the task sends SIGINT,
/// which makes the client stop cleanly (an unfinished backup snapshot is discarded).
public enum ClientRunner {
    public static func run(
        executable: URL, invocation: ClientInvocation, logFile: URL? = nil,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = invocation.arguments
        process.environment = invocation.environment
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let collector = OutputCollector(logFile: logFile, onLine: onLine)
        collector.log("$ \(executable.lastPathComponent) \(invocation.arguments.joined(separator: " "))\n")
        stdout.fileHandleForReading.readabilityHandler = { handle in
            collector.append(handle.availableData, isError: false)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            collector.append(handle.availableData, isError: true)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { process in
                    // `mount` leaves a daemon behind that may still hold the pipes, so only
                    // what is already buffered is read instead of waiting for EOF
                    for (pipe, isError) in [(stdout, false), (stderr, true)] {
                        pipe.fileHandleForReading.readabilityHandler = nil
                        collector.append(drain(pipe.fileHandleForReading), isError: isError)
                    }
                    collector.log("exit status \(process.terminationStatus)\n")
                    continuation.resume(returning: collector.result(status: process.terminationStatus))
                }
                do {
                    try process.run()
                } catch {
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning {
                process.interrupt()
            }
        }
    }

    /// Runs the client and fails with its error message if it does not succeed.
    @discardableResult
    public static func check(
        executable: URL, invocation: ClientInvocation, logFile: URL? = nil,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        let result = try await run(
            executable: executable, invocation: invocation, logFile: logFile, onLine: onLine)
        guard result.succeeded else {
            throw ClientError(result.errorMessage)
        }
        return result
    }

    static func drain(_ handle: FileHandle) -> Data {
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                data.append(contentsOf: buffer[0..<n])
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
        return data
    }
}

/// Thread-safe sink for the output of both pipes.
final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var partialLine = ""
    private let logHandle: FileHandle?
    private let onLine: (@Sendable (String) -> Void)?
    /// Output kept in memory, the log file has all of it.
    private static let maxKept = 4 << 20

    init(logFile: URL?, onLine: (@Sendable (String) -> Void)?) {
        if let logFile {
            try? FileManager.default.createDirectory(
                at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: logFile.path) {
                FileManager.default.createFile(atPath: logFile.path, contents: nil)
            }
            logHandle = try? FileHandle(forWritingTo: logFile)
            _ = try? logHandle?.seekToEnd()
        } else {
            logHandle = nil
        }
        self.onLine = onLine
    }

    deinit {
        try? logHandle?.close()
    }

    func log(_ text: String) {
        lock.withLock {
            try? logHandle?.write(contentsOf: Data(text.utf8))
        }
    }

    func append(_ data: Data, isError: Bool) {
        guard !data.isEmpty else { return }
        var lines: [String] = []
        lock.withLock {
            if isError {
                if stderr.count < Self.maxKept { stderr.append(data) }
            } else {
                if stdout.count < Self.maxKept { stdout.append(data) }
            }
            try? logHandle?.write(contentsOf: data)
            partialLine += String(decoding: data, as: UTF8.self)
            var parts = partialLine.split(separator: "\n", omittingEmptySubsequences: false)
            partialLine = String(parts.removeLast())
            lines = parts.map(String.init).filter { !$0.isEmpty }
        }
        if let onLine {
            lines.forEach(onLine)
        }
    }

    func result(status: Int32) -> ProcessResult {
        lock.withLock {
            ProcessResult(
                status: status,
                stdout: String(decoding: stdout, as: UTF8.self),
                stderr: String(decoding: stderr, as: UTF8.self))
        }
    }
}

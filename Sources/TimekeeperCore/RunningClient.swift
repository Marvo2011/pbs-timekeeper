import Darwin
import Foundation

/// Remembers the PID of the running backup, so a client left behind by an app instance that
/// was killed can be stopped. Such a client keeps the server's lock on the backup group until
/// it ends, which makes every new backup fail with "unable to acquire backup group lock".
public enum RunningClient {
    static var pidFile: URL {
        Paths.appSupport.appending(path: "backup.pid")
    }

    public static func record(_ pid: Int32) {
        try? FileManager.default.createDirectory(at: Paths.appSupport, withIntermediateDirectories: true)
        try? String(pid).write(to: pidFile, atomically: true, encoding: .utf8)
    }

    public static func clear() {
        try? FileManager.default.removeItem(at: pidFile)
    }

    /// Stops the recorded client if it is still running: SIGINT first (the client aborts the
    /// snapshot cleanly), SIGKILL if it does not exit within `timeout`.
    public static func stopLeftover(timeout: TimeInterval = 10) {
        defer { clear() }
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
            let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1,
            isClient(pid)
        else {
            return
        }
        kill(pid, SIGINT)
        let deadline = Date().addingTimeInterval(timeout)
        while isClient(pid), Date() < deadline {
            usleep(100_000)
        }
        if isClient(pid) {
            kill(pid, SIGKILL)
        }
    }

    /// The PID belongs to a running proxmox-backup-client (and was not reused by another
    /// process).
    static func isClient(_ pid: Int32) -> Bool {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let path = String(decoding: bytes, as: UTF8.self)
        return (path as NSString).lastPathComponent == ClientLocator.executableName
    }
}

import Foundation

public enum Schedule {
    /// A failed backup is retried after this delay (or the interval, if that is shorter).
    public static let retryDelay: TimeInterval = 15 * 60

    /// When the next automatic backup is due. Without a successful backup it is due now.
    public static func nextBackup(state: BackupState, intervalMinutes: Int, now: Date = Date())
        -> Date
    {
        let interval = TimeInterval(max(intervalMinutes, 1) * 60)
        var due = state.lastSuccess.map { $0.addingTimeInterval(interval) } ?? now
        if let attempt = state.lastAttempt, state.lastError != nil,
            attempt > (state.lastSuccess ?? .distantPast)
        {
            due = max(due, attempt.addingTimeInterval(min(interval, retryDelay)))
        }
        return due
    }

    public static func isDue(state: BackupState, intervalMinutes: Int, now: Date = Date()) -> Bool {
        nextBackup(state: state, intervalMinutes: intervalMinutes, now: now) <= now
    }
}

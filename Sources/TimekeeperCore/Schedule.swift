import Foundation

public enum Schedule {
    /// A failed backup is retried after this delay, doubled with every further failure up to
    /// `maxRetryDelay`. Until a backup succeeds, each attempt reads and uploads everything
    /// again, so retrying too often is expensive.
    public static let retryDelay: TimeInterval = 15 * 60
    public static let maxRetryDelay: TimeInterval = 4 * 3600

    public static func retryDelay(failures: Int) -> TimeInterval {
        let exponent = min(max(failures, 1) - 1, 10)
        return min(retryDelay * pow(2, Double(exponent)), maxRetryDelay)
    }

    /// When the next automatic backup is due. Without a successful backup it is due now.
    public static func nextBackup(state: BackupState, intervalMinutes: Int, now: Date = Date())
        -> Date
    {
        let interval = TimeInterval(max(intervalMinutes, 1) * 60)
        var due = state.lastSuccess.map { $0.addingTimeInterval(interval) } ?? now
        if let attempt = state.lastAttempt, state.lastError != nil,
            attempt > (state.lastSuccess ?? .distantPast)
        {
            due = max(due, attempt.addingTimeInterval(retryDelay(failures: state.failures ?? 1)))
        }
        return due
    }

    public static func isDue(state: BackupState, intervalMinutes: Int, now: Date = Date()) -> Bool {
        nextBackup(state: state, intervalMinutes: intervalMinutes, now: now) <= now
    }
}

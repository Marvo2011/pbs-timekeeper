import Foundation

/// Progress of a running backup, from the client's line printed every minute:
/// `processed 182.652 GiB in 20m, uploaded 142.96 GiB`.
public struct BackupProgress: Equatable, Sendable {
    public var processed: String
    public var uploaded: String

    public init?(line: String) {
        guard let match = line.firstMatch(of: /^processed ([\d.]+ \w+) in .*, uploaded ([\d.]+ \w+)/)
        else {
            return nil
        }
        processed = Self.shorten(String(match.1))
        uploaded = Self.shorten(String(match.2))
    }

    public init(processed: String, uploaded: String) {
        self.processed = processed
        self.uploaded = uploaded
    }

    /// `182.652 GiB` → `182.7 GiB`
    static func shorten(_ amount: String) -> String {
        let parts = amount.split(separator: " ")
        guard parts.count == 2, let value = Double(parts[0]) else { return amount }
        return "\(value.formatted(.number.precision(.fractionLength(0...1)))) \(parts[1])"
    }
}

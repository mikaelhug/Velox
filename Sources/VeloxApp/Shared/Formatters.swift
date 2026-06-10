import Foundation

/// Shared display formatters for the dashboards. Main-actor isolated because the
/// underlying Foundation formatters are not thread-safe and every caller is a
/// SwiftUI view.
@MainActor
enum Format {
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        f.allowsNonnumericFormatting = false
        return f
    }()

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private static let duration: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        return f
    }()

    // Cache like the formatters above — `ISO8601DateFormatter` is expensive to build and
    // `age(iso:)` was allocating one per call (it runs per volume table row).
    private static let iso8601 = ISO8601DateFormatter()

    static func bytes(_ value: Int64) -> String { byteFormatter.string(fromByteCount: value) }
    static func bytes(_ value: UInt64) -> String { byteFormatter.string(fromByteCount: Int64(clamping: value)) }

    /// Relative age from a Unix epoch (e.g. "3 days ago").
    static func age(epoch: Int) -> String {
        guard epoch > 0 else { return "—" }
        let date = Date(timeIntervalSince1970: TimeInterval(epoch))
        return relative.localizedString(for: date, relativeTo: Date())
    }

    /// Relative age from an ISO-8601 string.
    static func age(iso: String?) -> String {
        guard let iso, let date = iso8601.date(from: iso) else { return "—" }
        return relative.localizedString(for: date, relativeTo: Date())
    }

    /// Elapsed time since `date` as a compact duration (e.g. "5m", "1h 3m") —
    /// used for engine uptime, which is a duration rather than a relative date.
    static func uptime(since date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        return duration.string(from: seconds) ?? "—"
    }

    /// Docker-style coarse duration — mirrors go-units `HumanDuration`, the function
    /// behind `docker ps`'s "Up 5 minutes" / "Up About an hour" / "Up 3 weeks", so the
    /// status badge reads exactly like Docker. Pure in `now` so a minute-tick
    /// `TimelineView` drives it; the sub-minute tier says "Less than a minute"
    /// (never seconds) so it's never stale between ticks.
    static func dockerUptime(since start: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(start))
        let minutes = Int(seconds / 60)
        let hours = Int((seconds / 3600).rounded())
        switch true {
        case seconds < 60:   return "Less than a minute"
        case minutes == 1:   return "About a minute"
        case minutes < 60:   return "\(minutes) minutes"
        case hours == 1:     return "About an hour"
        case hours < 48:     return "\(hours) hours"
        case hours < 24*7*2:   return "\(hours / 24) days"
        case hours < 24*30*2:  return "\(hours / 24 / 7) weeks"
        case hours < 24*365*2: return "\(hours / 24 / 30) months"
        default:               return "\(hours / 24 / 365) years"
        }
    }
}

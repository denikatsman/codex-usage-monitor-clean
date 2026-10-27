import Foundation

public struct UsageResponse: Decodable, Sendable {
    public let rateLimits: UsageBucket?
    public let rateLimitsByLimitId: [String: UsageBucket]?
    public let accountId: String?
    public let ordinaryUsageAllowed: Bool?
    public let rateLimitResetCredits: ResetCredits?

    func plan(for meter: String) -> String {
        let key = String(meter.dropLast(meter.hasSuffix("-primary") ? 8 : 10))
        return rateLimitsByLimitId?[key]?.planType ?? rateLimits?.planType ?? "Unknown"
    }

    public var credits: AccountCredits? { rateLimitsByLimitId?["codex"]?.credits ?? rateLimits?.credits }
    public var isUsingCredits: Bool {
        if let ordinaryUsageAllowed { return !ordinaryUsageAllowed }
        return rows.contains { ($0.window.usedPercent ?? 0) >= 100 && !$0.window.isAwaitingReset(at: Date()) }
    }

    public var rows: [UsageRow] {
        let buckets: [(String, UsageBucket)]
        if let all = rateLimitsByLimitId, !all.isEmpty {
            buckets = all.sorted {
                if $0.key == "codex" { return $1.key != "codex" }
                if $1.key == "codex" { return false }
                return $0.key < $1.key
            }
        } else if let bucket = rateLimits {
            buckets = [(bucket.limitId ?? "codex", bucket)]
        } else {
            buckets = []
        }
        return buckets.flatMap { key, bucket in
            [("primary", bucket.primary), ("secondary", bucket.secondary)].compactMap { slot, window in
                guard let window else { return nil }
                let label = window.windowLabel(fallback: slot == "primary" ? "Primary" : "Secondary")
                let name = bucket.limitName?.isEmpty == false ? bucket.limitName! : key
                return UsageRow(id: "\(key)-\(slot)",
                                title: key == "codex" ? label : "\(name) · \(label)",
                                window: window)
            }
        }
    }
}

public struct UsageBucket: Decodable, Sendable {
    public let planType: String?
    public let limitId: String?
    public let limitName: String?
    public let primary: UsageWindow?
    public let secondary: UsageWindow?
    public let credits: AccountCredits?
}

public struct UsageWindow: Decodable, Sendable {
    public let usedPercent: Double?
    public let windowDurationMins: Int?
    public let resetsAt: Double?

    public var remainingPercent: Double? {
        guard let usedPercent, usedPercent.isFinite else { return nil }
        return min(100, max(0, 100 - usedPercent))
    }

    public var resetDate: Date? {
        guard let resetsAt, resetsAt.isFinite, resetsAt > 0 else { return nil }
        return Date(timeIntervalSince1970: resetsAt)
    }

    public func isAwaitingReset(at now: Date) -> Bool {
        guard let resetDate else { return false }
        return now >= resetDate
    }

    public func windowLabel(fallback: String) -> String {
        switch windowDurationMins {
        case 10080: return "Weekly"
        case 1440: return "Daily"
        case let minutes? where minutes > 0 && minutes % 60 == 0:
            return "\(minutes / 60)-hour"
        case let minutes? where minutes > 0: return "\(minutes)-minute"
        default: return fallback
        }
    }
}

public struct UsageRow: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let window: UsageWindow
}

public enum CountdownFormat: String, CaseIterable, Sendable {
    case hours, days

    public static func load(from defaults: UserDefaults) -> Self {
        defaults.string(forKey: "countdownFormat").flatMap(Self.init(rawValue:)) ?? .hours
    }
}

public enum UsageFormatting {
    private static let dateLabels: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 128
        return cache
    }()
    public static func countdown(to reset: Date, from now: Date, format: CountdownFormat = .hours) -> String {
        let interval = reset.timeIntervalSince(now)
        guard interval.isFinite else { return "—" }
        let seconds = Int(min(Double(Int.max / 2), max(0, ceil(interval))))
        if format == .days {
            return String(format: "%ldd %02ldh %02ldm %02lds", seconds / 86400, (seconds / 3600) % 24, (seconds / 60) % 60, seconds % 60)
        }
        return String(format: "%02ldh %02ldm %02lds", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }

    public static func resetDate(_ date: Date, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let key = "\(date.timeIntervalSince1970)|\(timeZone.identifier)|\(timeZone.secondsFromGMT(for: date))" as NSString
        if let cached = dateLabels.object(forKey: key) { return cached as String }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE, d MMM yyyy · HH:mm:ss zzz"
        let label = formatter.string(from: date)
        dateLabels.setObject(label as NSString, forKey: key)
        return label
    }

    public static func percent(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1))) + "%"
    }
}

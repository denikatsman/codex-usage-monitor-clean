import Foundation

public struct AccountCredits: Decodable, Sendable {
    public let hasCredits: Bool?
    public let unlimited: Bool?
    public let balance: String?

    public var amount: Decimal? {
        guard let balance, let value = Decimal(string: balance, locale: Locale(identifier: "en_US_POSIX")),
              !value.isNaN, value >= 0 else { return nil }
        return value
    }

    enum CodingKeys: String, CodingKey { case hasCredits, unlimited, balance }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hasCredits = try c.decodeIfPresent(Bool.self, forKey: .hasCredits)
        unlimited = try c.decodeIfPresent(Bool.self, forKey: .unlimited)
        if let text = try? c.decode(String.self, forKey: .balance) { balance = text }
        else if let value = try? c.decode(Decimal.self, forKey: .balance) { balance = NSDecimalNumber(decimal: value).stringValue }
        else { balance = nil }
    }

    public static func format(_ amount: Decimal) -> String {
        amount.formatted(.number.precision(.fractionLength(0...2)))
    }
}

public struct ResetCredits: Decodable, Sendable {
    public let availableCount: Int?
    public let credits: [ResetCredit]?

    public func available(at now: Date) -> [ResetCredit] {
        (credits ?? []).filter { $0.status == "available" && ($0.expiry.date.map { $0 > now } ?? true) }
            .sorted { ($0.expiry.date ?? .distantFuture) < ($1.expiry.date ?? .distantFuture) }
    }
}

public struct ResetCredit: Decodable, Sendable, Identifiable {
    public let id: String
    public let status: String?
    public let title: String?
    public let expiresAt: ServiceExpiry?
    public var expiry: ServiceExpiry { expiresAt ?? .unknown }
}

public enum ServiceExpiry: Decodable, Sendable {
    case timestamp(Date), day(String), unknown
    public var date: Date? { if case .timestamp(let date) = self { return date }; return nil }
    public var label: String {
        switch self {
        case .timestamp(let date): return UsageFormatting.resetDate(date)
        case .day(let day): return "\(day) · time unavailable"
        case .unknown: return "Expiry unavailable"
        }
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let seconds = try? c.decode(Double.self), seconds.isFinite, seconds > 0 {
            self = .timestamp(Date(timeIntervalSince1970: seconds)); return
        }
        if let text = try? c.decode(String.self) {
            if text.count == 10, text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
                self = .day(text); return
            }
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: text) { self = .timestamp(date); return }
            f.formatOptions = [.withInternetDateTime]
            if let date = f.date(from: text) { self = .timestamp(date); return }
        }
        self = .unknown
    }
}

public struct CreditDebit: Identifiable, Sendable {
    public let id = UUID()
    public let amount: Decimal
    public let observedAt: Date
}

public struct CreditDebitTracker {
    private var account: String?
    private var previous: Decimal?
    public init() {}
    public mutating func observe(_ response: UsageResponse, at date: Date) -> CreditDebit? {
        let current = response.credits?.unlimited == true ? nil : response.credits?.amount
        defer { account = response.accountId; previous = current }
        guard let identity = response.accountId, !identity.isEmpty, account == identity,
              let previous, let current, current < previous,
              response.isUsingCredits else { return nil }
        return CreditDebit(amount: previous - current, observedAt: date)
    }
}

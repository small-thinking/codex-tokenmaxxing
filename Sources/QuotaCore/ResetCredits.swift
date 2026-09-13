import CoreFoundation
import Foundation

public struct UsageSnapshot: Equatable, Sendable {
    public let weekly: WeeklySnapshot
    public let resetCredits: ResetCreditBank?
    /// Opaque digest of the verified account identity; raw account data stays in memory.
    public let accountKey: String?

    public init(weekly: WeeklySnapshot, resetCredits: ResetCreditBank?, accountKey: String? = nil) {
        self.weekly = weekly
        self.resetCredits = resetCredits
        self.accountKey = accountKey
    }
}

public struct ResetCredit: Equatable, Sendable, Identifiable {
    public let id: String
    public let resetType: String
    public let status: String
    public let grantedAt: Date?
    public let expiresAt: Date?
    public let title: String?
    public let description: String?

    public init(id: String, resetType: String = "codexRateLimits", status: String = "available",
                grantedAt: Date?, expiresAt: Date?, title: String? = nil, description: String? = nil) {
        self.id = id
        self.resetType = resetType
        self.status = status
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.title = title
        self.description = description
    }

    /// Lifetime remaining, not a prediction of whether this credit can be redeemed.
    /// Missing, reversed, or future grant dates cannot establish a valid progress bar.
    public func remainingValidityFraction(at date: Date) -> Double? {
        guard let grantedAt, let expiresAt, grantedAt <= date else { return nil }
        let lifetime = expiresAt.timeIntervalSince(grantedAt)
        let remaining = expiresAt.timeIntervalSince(date)
        guard lifetime.isFinite, lifetime > 0, remaining.isFinite else { return nil }
        return min(1, max(0, remaining / lifetime))
    }

    public func isExpired(at date: Date) -> Bool {
        expiresAt.map { $0 <= date } ?? false
    }
}

public struct ResetCreditBank: Equatable, Sendable {
    /// Last server-reported count. Never reconstructed from potentially capped details.
    public let availableCount: Int
    /// nil means detail rows are unavailable; an empty list is a returned empty list.
    public let credits: [ResetCredit]?
    public let fetchedAt: Date

    public init(availableCount: Int, credits: [ResetCredit]?, fetchedAt: Date) {
        self.availableCount = availableCount
        self.credits = credits
        self.fetchedAt = fetchedAt
    }

    /// Expired-since-fetch credits stay visible so the UI can request a fresh count.
    public var availableCredits: [ResetCredit] {
        (credits ?? []).filter { $0.resetType == "codexRateLimits" && $0.status == "available" }
            .sorted {
                switch ($0.expiresAt, $1.expiresAt) {
                case let (left?, right?) where left != right: return left < right
                case (_?, nil): return true
                case (nil, _?): return false
                default: return $0.id < $1.id
                }
            }
    }

    public var hasIncompleteDetails: Bool {
        credits == nil || availableCredits.count < availableCount
    }
}

public enum UsageParser {
    /// Optional reset metadata must never make otherwise valid weekly usage unavailable.
    public static func parse(data: Data, at fetchedAt: Date) throws -> UsageSnapshot {
        let weekly = try QuotaParser.parse(data: data, at: fetchedAt)
        let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return UsageSnapshot(weekly: weekly,
                             resetCredits: parseBank(result?["rateLimitResetCredits"], at: fetchedAt))
    }

    private static func parseBank(_ value: Any?, at fetchedAt: Date) -> ResetCreditBank? {
        guard let bank = value as? [String: Any],
              let number = finiteNumber(bank["availableCount"]),
              let count = Int(exactly: number), count >= 0 else { return nil }
        var credits: [ResetCredit]?
        if let rows = bank["credits"] as? [Any] {
            var seen = Set<String>()
            credits = rows.compactMap { raw in
                guard let row = raw as? [String: Any],
                      let id = row["id"] as? String, !id.isEmpty,
                      let resetType = row["resetType"] as? String,
                      let status = row["status"] as? String,
                      seen.insert(id).inserted else { return nil }
                return ResetCredit(id: id, resetType: resetType, status: status,
                                   grantedAt: date(row["grantedAt"]), expiresAt: date(row["expiresAt"]),
                                   title: row["title"] as? String, description: row["description"] as? String)
            }
        }
        return ResetCreditBank(availableCount: count, credits: credits, fetchedAt: fetchedAt)
    }

    private static func date(_ value: Any?) -> Date? {
        guard let seconds = finiteNumber(value), seconds >= 0,
              seconds <= Date.distantFuture.timeIntervalSince1970 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func finiteNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
}

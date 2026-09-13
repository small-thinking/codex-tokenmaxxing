import CoreFoundation
import Foundation

public struct WeeklySnapshot: Codable, Equatable, Sendable {
    public let usedPercent: Double
    public let resetsAt: Date?
    public let windowDurationMins: Int
    public let fetchedAt: Date

    public init(usedPercent: Double, resetsAt: Date?, windowDurationMins: Int, fetchedAt: Date) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.windowDurationMins = windowDurationMins
        self.fetchedAt = fetchedAt
    }

    public var remainingPercent: Double {
        min(100, max(0, 100 - usedPercent))
    }

    /// The fraction of a complete quota window remaining until the next reset.
    /// An expired reset cannot describe the current window without a new fetch.
    public func remainingTimeFraction(at date: Date) -> Double? {
        guard let resetsAt, windowDurationMins > 0 else { return nil }
        let secondsRemaining = resetsAt.timeIntervalSince(date)
        guard secondsRemaining.isFinite, secondsRemaining > 0 else { return nil }
        return min(1, secondsRemaining / (Double(windowDurationMins) * 60))
    }

    /// Positive means less quota has been consumed than the whole-window uniform baseline.
    /// This is a percentage-point gap, not a recent usage rate.
    public func paceGap(at date: Date) -> Double? {
        guard !isStale(at: date), let time = remainingTimeFraction(at: date) else { return nil }
        return remainingPercent - time * 100
    }

    /// Required consumption from now to reset, in percentage points of the weekly allowance per hour.
    /// Missing/expired metadata and stale or future-dated readings do not establish a current target.
    public func requiredPacePerHour(at date: Date) -> Double? {
        guard usedPercent.isFinite, windowDurationMins > 0,
              date.timeIntervalSince1970.isFinite, fetchedAt.timeIntervalSince1970.isFinite,
              date >= fetchedAt, !isStale(at: date), let resetsAt else { return nil }
        let hours = resetsAt.timeIntervalSince(date) / 3_600
        guard hours.isFinite, hours > 0 else { return nil }
        let pace = remainingPercent / hours
        return pace.isFinite ? pace : nil
    }

    public func isStale(at date: Date, maxAge: TimeInterval = 600) -> Bool {
        if let resetsAt, resetsAt <= date { return true }
        return date.timeIntervalSince(fetchedAt) > maxAge
    }
}

public enum QuotaParserError: Error, LocalizedError, Equatable, Sendable {
    case malformedJSON
    case invalidResult
    case invalidRateLimitsMap
    case missingCodexBucket
    case missingRateLimits
    case invalidWindow(String)
    case missingWeeklyWindow
    case ambiguousWeeklyWindow
    case invalidField(String)

    public var errorDescription: String? {
        switch self {
        case .malformedJSON:
            return "Codex returned invalid quota JSON."
        case .invalidResult:
            return "Codex returned an unexpected quota result."
        case .invalidRateLimitsMap:
            return "Codex returned an invalid quota bucket map."
        case .missingCodexBucket:
            return "The quota result does not include a Codex bucket."
        case .missingRateLimits:
            return "Codex quota information is unavailable."
        case .invalidWindow(let name):
            return "The Codex \(name) quota window is invalid."
        case .missingWeeklyWindow:
            return "No quota window is identified as weekly (10,080 minutes)."
        case .ambiguousWeeklyWindow:
            return "More than one Codex quota window is identified as weekly."
        case .invalidField(let name):
            return "The weekly quota has an invalid \(name) field."
        }
    }
}

public enum QuotaParser {
    /// Parses the account/rateLimits/read result object, excluding its JSON-RPC envelope.
    public static func parse(data: Data, at fetchedAt: Date) throws -> WeeklySnapshot {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw QuotaParserError.malformedJSON
        }
        guard let result = object as? [String: Any] else {
            throw QuotaParserError.invalidResult
        }

        let bucket: [String: Any]
        if let rawMap = result["rateLimitsByLimitId"], !(rawMap is NSNull) {
            guard let map = rawMap as? [String: Any] else {
                throw QuotaParserError.invalidRateLimitsMap
            }
            if map.isEmpty {
                bucket = try legacyBucket(in: result)
            } else {
                guard let codex = map["codex"] as? [String: Any] else {
                    throw QuotaParserError.missingCodexBucket
                }
                bucket = codex
            }
        } else {
            bucket = try legacyBucket(in: result)
        }

        var weeklyWindows: [[String: Any]] = []
        for name in ["primary", "secondary"] {
            guard let rawWindow = bucket[name], !(rawWindow is NSNull) else { continue }
            guard let window = rawWindow as? [String: Any] else {
                throw QuotaParserError.invalidWindow(name)
            }
            // Missing duration metadata does not establish that a window is weekly.
            guard let rawDuration = window["windowDurationMins"], !(rawDuration is NSNull) else {
                continue
            }
            guard let durationNumber = finiteNumber(rawDuration),
                  let duration = Int(exactly: durationNumber), duration > 0 else {
                throw QuotaParserError.invalidWindow(name)
            }
            if duration == 10_080 { weeklyWindows.append(window) }
        }
        guard !weeklyWindows.isEmpty else { throw QuotaParserError.missingWeeklyWindow }
        guard weeklyWindows.count == 1 else { throw QuotaParserError.ambiguousWeeklyWindow }
        let weekly = weeklyWindows[0]
        guard let rawUsed = weekly["usedPercent"], let used = finiteNumber(rawUsed) else {
            throw QuotaParserError.invalidField("usedPercent")
        }
        let reset: Date?
        if let rawReset = weekly["resetsAt"], !(rawReset is NSNull) {
            guard let seconds = finiteNumber(rawReset) else {
                throw QuotaParserError.invalidField("resetsAt")
            }
            reset = Date(timeIntervalSince1970: seconds)
        } else {
            reset = nil
        }
        return WeeklySnapshot(
            usedPercent: used,
            resetsAt: reset,
            windowDurationMins: 10_080,
            fetchedAt: fetchedAt
        )
    }

    private static func legacyBucket(in result: [String: Any]) throws -> [String: Any] {
        guard let bucket = result["rateLimits"] as? [String: Any] else {
            throw QuotaParserError.missingRateLimits
        }
        return bucket
    }

    private static func finiteNumber(_ value: Any) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
}

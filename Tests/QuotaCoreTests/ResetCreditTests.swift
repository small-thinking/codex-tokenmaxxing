import Foundation
import QuotaCore

struct ResetCreditTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func parse(_ bank: String?) throws -> UsageSnapshot {
        let extra = bank.map { ",\"rateLimitResetCredits\":\($0)" } ?? ""
        return try UsageParser.parse(data: Data("""
        {"rateLimits":{"primary":{"usedPercent":23,"windowDurationMins":10080},
                       "credits":{"balance":"999","unlimited":true}}\(extra)}
        """.utf8), at: now)
    }

    func missingAndMalformedBanksPreserveWeeklyUsage() throws {
        for bank in [nil, "null", "[]", "false", "{}", "{\"availableCount\":-1}",
                     "{\"availableCount\":true}", "{\"availableCount\":\"3\"}",
                     "{\"availableCount\":3.5}", "{\"availableCount\":1e100}"] as [String?] {
            let usage = try parse(bank)
            try expect(usage.weekly.remainingPercent == 77)
            try expect(usage.resetCredits == nil, "An unavailable bank must not be shown as zero")
        }
    }

    func countsRemainAuthoritativeWithMissingOrPartialDetails() throws {
        for detail in ["", ",\"credits\":null", ",\"credits\":false"] {
            let bank = try parse("{\"availableCount\":3\(detail)}").resetCredits
            try expect(bank?.availableCount == 3)
            try expect(bank?.credits == nil)
            try expect(bank?.hasIncompleteDetails == true)
        }
        let empty = try parse("{\"availableCount\":3,\"credits\":[]}").resetCredits
        try expect(empty?.credits == [])
        try expect(empty?.availableCount == 3)
        try expect(empty?.hasIncompleteDetails == true)
        let zero = try parse("{\"availableCount\":0,\"credits\":[]}").resetCredits
        try expect(zero?.hasIncompleteDetails == false)

        let partial = try parse("""
        {"availableCount":3,"credits":[
          {"id":"one","resetType":"codexRateLimits","status":"available","grantedAt":1799999900,"expiresAt":1800000100},
          {"id":"one","resetType":"codexRateLimits","status":"available"},
          {"id":"used","resetType":"codexRateLimits","status":"used"},
          {"id":"other","resetType":"otherLimits","status":"available"},
          {"id":"unknown","resetType":"codexRateLimits","status":"futureStatus"},
          {"id":"missing-status","resetType":"codexRateLimits"},null,42]}
        """).resetCredits
        try expect(partial?.availableCount == 3)
        try expect(partial?.credits?.count == 4, "Valid statuses retained, duplicates and malformed rows excluded")
        try expect(partial?.availableCredits.map(\.id) == ["one"])
        try expect(partial?.hasIncompleteDetails == true)
        try expect(partial?.fetchedAt == now)
    }

    func earliestExpiryFirstAndUnknownDatesRemainUnknown() throws {
        let bank = try parse("""
        {"availableCount":5,"credits":[
          {"id":"unknown","resetType":"codexRateLimits","status":"available","grantedAt":1799999900,"expiresAt":null},
          {"id":"later","resetType":"codexRateLimits","status":"available","grantedAt":1799999900,"expiresAt":1800000500},
          {"id":"earlier","resetType":"codexRateLimits","status":"available","grantedAt":1799999900,"expiresAt":1800000100},
          {"id":"bad-dates","resetType":"codexRateLimits","status":"available","grantedAt":true,"expiresAt":"1800000050"},
          {"id":"bad-range","resetType":"codexRateLimits","status":"available","grantedAt":-1,"expiresAt":1e100}]}
        """).resetCredits!
        try expect(bank.availableCredits.map(\.id) == ["earlier", "later", "bad-dates", "bad-range", "unknown"])
        try expect(bank.availableCredits[0].remainingValidityFraction(at: now) == 0.5)
        for credit in bank.availableCredits.suffix(3) {
            try expect(credit.expiresAt == nil)
            try expect(credit.remainingValidityFraction(at: now) == nil)
            try expect(!credit.isExpired(at: now))
        }
        try expect(!bank.hasIncompleteDetails)
    }

    func expiryProgressRequiresValidLifetimeAndKeepsReportedCount() throws {
        let credit = ResetCredit(id: "one", grantedAt: now.addingTimeInterval(-100),
                                 expiresAt: now.addingTimeInterval(100))
        try expect(credit.remainingValidityFraction(at: now) == 0.5)
        try expect(credit.remainingValidityFraction(at: now.addingTimeInterval(-100)) == 1)
        try expect(credit.remainingValidityFraction(at: now.addingTimeInterval(-101)) == nil)
        try expect(credit.remainingValidityFraction(at: now.addingTimeInterval(100)) == 0)
        try expect(credit.remainingValidityFraction(at: now.addingTimeInterval(101)) == 0)
        try expect(!credit.isExpired(at: now.addingTimeInterval(99)))
        try expect(credit.isExpired(at: now.addingTimeInterval(100)))
        for (grant, expiry) in [(nil, now), (now, nil), (now, now),
                                (now, now.addingTimeInterval(-1)),
                                (now.addingTimeInterval(1), now.addingTimeInterval(2))] as [(Date?, Date?)] {
            let unknown = ResetCredit(id: "unknown", grantedAt: grant, expiresAt: expiry)
            try expect(unknown.remainingValidityFraction(at: now) == nil)
        }
        let bank = ResetCreditBank(availableCount: 3, credits: [credit], fetchedAt: now)
        try expect(bank.availableCredits.first?.isExpired(at: now.addingTimeInterval(101)) == true)
        try expect(bank.availableCount == 3, "Elapsed local time cannot invent a server-side count")
    }
}

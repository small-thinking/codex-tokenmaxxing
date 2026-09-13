import Foundation
import QuotaCore

struct QuotaSnapshotTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func parse(_ json: String) throws -> WeeklySnapshot {
        try QuotaParser.parse(data: Data(json.utf8), at: now)
    }

    func testWeeklyWindowMayBePrimary() throws {
        let snapshot = try parse("""
        {"rateLimits":{"primary":{"usedPercent":23.5,"windowDurationMins":10080,"resetsAt":1800302400},
                       "secondary":{"usedPercent":90,"windowDurationMins":300}}}
        """)
        try expect(snapshot.usedPercent == 23.5)
        try expect(snapshot.remainingPercent == 76.5)
        try expect(snapshot.windowDurationMins == 10_080)
        try expect(snapshot.fetchedAt == now)
        try expect(snapshot.resetsAt == now.addingTimeInterval(302_400))
        try expect(snapshot.remainingTimeFraction(at: now) == 0.5)
    }

    func testWeeklyWindowMayBeSecondaryAndMapTakesPrecedence() throws {
        let snapshot = try parse("""
        {"rateLimitsByLimitId":{
            "codex":{"primary":{"usedPercent":8,"windowDurationMins":300},
                     "secondary":{"usedPercent":40,"windowDurationMins":10080}},
            "other":{"primary":{"usedPercent":99,"windowDurationMins":10080}}},
         "rateLimits":{"primary":{"usedPercent":80,"windowDurationMins":10080}}}
        """)
        try expect(snapshot.usedPercent == 40)
        try expect(snapshot.resetsAt == nil)
        try expect(snapshot.remainingTimeFraction(at: now) == nil)
    }

    func testUnrelatedMapBucketDoesNotFallBackToLegacy() throws {
        try expectThrows(QuotaParserError.missingCodexBucket) { _ = try parse("""
        {"rateLimitsByLimitId":{"other":{"primary":{"usedPercent":99,"windowDurationMins":10080}}},
         "rateLimits":{"primary":{"usedPercent":10,"windowDurationMins":10080}}}
        """) }
    }

    func testEmptyOrNullMapAllowsLegacyFallback() throws {
        for map in ["{}", "null"] {
            let snapshot = try parse("""
            {"rateLimitsByLimitId":\(map),
             "rateLimits":{"secondary":{"usedPercent":10,"windowDurationMins":10080,"resetsAt":null}}}
            """)
            try expect(snapshot.remainingPercent == 90)
            try expect(snapshot.resetsAt == nil)
        }
    }

    func testMissingDurationDoesNotGuessAWeeklyWindow() throws {
        for metadata in ["", ",\"windowDurationMins\":null", ",\"windowDurationMins\":300"] {
            try expectThrows(QuotaParserError.missingWeeklyWindow) { _ = try parse("""
            {"rateLimits":{"secondary":{"usedPercent":10\(metadata)}}}
            """) }
        }
    }

    func testAmbiguousWeeklyWindowsAreRejected() throws {
        try expectThrows(QuotaParserError.ambiguousWeeklyWindow) { _ = try parse("""
        {"rateLimits":{"primary":{"usedPercent":10,"windowDurationMins":10080},
                       "secondary":{"usedPercent":20,"windowDurationMins":10080}}}
        """) }
    }

    func testRemainingPercentageClampsOutOfBoundsInput() throws {
        for (used, remaining) in [(-20.0, 100.0), (140.0, 0.0), (100.0, 0.0), (0.0, 100.0)] {
            let snapshot = try parse("""
            {"rateLimits":{"primary":{"usedPercent":\(used),"windowDurationMins":10080}}}
            """)
            try expect(snapshot.usedPercent == used)
            try expect(snapshot.remainingPercent == remaining)
        }
    }

    func testInvalidNumericValuesAreRejected() throws {
        for value in ["true", "\"40\"", "null", "1e400"] {
            try expectThrows { _ = try parse("""
            {"rateLimits":{"primary":{"usedPercent":\(value),"windowDurationMins":10080}}}
            """) }
        }
        for value in ["true", "\"10080\"", "10080.5", "0", "-10080", "1e400"] {
            try expectThrows { _ = try parse("""
            {"rateLimits":{"primary":{"usedPercent":40,"windowDurationMins":\(value)}}}
            """) }
        }
        for value in ["true", "\"1800000000\"", "1e400"] {
            try expectThrows { _ = try parse("""
            {"rateLimits":{"primary":{"usedPercent":40,"windowDurationMins":10080,"resetsAt":\(value)}}}
            """) }
        }
    }

    func testMalformedShapesAndJSONAreRejected() throws {
        for json in ["not json", "[]", "null", "{}", "{\"rateLimitsByLimitId\":[]}",
                     "{\"rateLimits\":{\"primary\":true}}",
                     "{\"rateLimits\":{\"primary\":{\"windowDurationMins\":10080}}}"] {
            try expectThrows { _ = try parse(json) }
        }
    }

    func testExpiryAndFreshnessBoundaries() throws {
        let snapshot = WeeklySnapshot(usedPercent: 30, resetsAt: now.addingTimeInterval(100),
                                      windowDurationMins: 10_080, fetchedAt: now)
        try expect(!snapshot.isStale(at: now.addingTimeInterval(99)))
        try expect(snapshot.isStale(at: now.addingTimeInterval(100)))
        try expect(snapshot.remainingTimeFraction(at: now.addingTimeInterval(100)) == nil)
        try expect(snapshot.remainingTimeFraction(at: now.addingTimeInterval(101)) == nil)

        let withoutReset = WeeklySnapshot(usedPercent: 30, resetsAt: nil,
                                          windowDurationMins: 10_080, fetchedAt: now)
        try expect(!withoutReset.isStale(at: now.addingTimeInterval(600)))
        try expect(withoutReset.isStale(at: now.addingTimeInterval(601)))
        try expect(withoutReset.isStale(at: now.addingTimeInterval(61), maxAge: 60))
        try expect(withoutReset.remainingTimeFraction(at: now) == nil)
    }

    func testTimeFractionClampsResetBeyondAFullWindow() throws {
        let snapshot = WeeklySnapshot(usedPercent: 10, resetsAt: now.addingTimeInterval(1_209_600),
                                      windowDurationMins: 10_080, fetchedAt: now)
        try expect(snapshot.remainingTimeFraction(at: now) == 1)
    }

    func testSnapshotCodableRoundTrip() throws {
        let snapshot = WeeklySnapshot(usedPercent: 12.5, resetsAt: now.addingTimeInterval(300),
                                      windowDurationMins: 10_080, fetchedAt: now)
        let encoded = try JSONEncoder().encode(snapshot)
        try expect(try JSONDecoder().decode(WeeklySnapshot.self, from: encoded) == snapshot)
    }
    func testRequiredPacePerHour() throws {
        func reading(remaining: Double, hours: Double, fetched: Date? = nil) -> WeeklySnapshot {
            WeeklySnapshot(usedPercent: 100 - remaining, resetsAt: now.addingTimeInterval(hours * 3600),
                           windowDurationMins: 10080, fetchedAt: fetched ?? now)
        }
        let initial = reading(remaining: 60, hours: 120)
        try expect(initial.requiredPacePerHour(at: now) == 0.5)
        try expect(initial.requiredPacePerHour(at: now.addingTimeInterval(300))! > 0.5,
                   "Unspent quota requires a faster pace as reset approaches")
        try expect(reading(remaining: 30, hours: 120).requiredPacePerHour(at: now) == 0.25)
        try expect(reading(remaining: 60, hours: 60).requiredPacePerHour(at: now) == 1)
        try expect(reading(remaining: 0, hours: 60).requiredPacePerHour(at: now) == 0)
        try expect(reading(remaining: 60, hours: 0).requiredPacePerHour(at: now) == nil)
        try expect(reading(remaining: 60, hours: -1).requiredPacePerHour(at: now) == nil)
        try expect(initial.requiredPacePerHour(at: now.addingTimeInterval(601)) == nil)
        try expect(initial.requiredPacePerHour(at: now.addingTimeInterval(-1)) == nil)
        try expect(reading(remaining: 60, hours: 1.0 / 3600).requiredPacePerHour(at: now) == 216000)
        let missing = WeeklySnapshot(usedPercent: 40, resetsAt: nil, windowDurationMins: 10080, fetchedAt: now)
        try expect(missing.requiredPacePerHour(at: now) == nil)
        try expect(reading(remaining: .nan, hours: 60).requiredPacePerHour(at: now) == nil)
    }

}

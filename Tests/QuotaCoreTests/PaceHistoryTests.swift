import Foundation
import QuotaCore

struct PaceHistoryTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000) // UTC hour boundary.
    private let keyA = String(repeating: "a", count: 64)
    private let keyB = String(repeating: "b", count: 64)

    private func usage(_ seconds: Double, _ used: Double = 10, key: String? = nil,
                       resetOffset: Double = 604_800) -> UsageSnapshot {
        UsageSnapshot(weekly: WeeklySnapshot(usedPercent: used,
                                             resetsAt: start.addingTimeInterval(resetOffset),
                                             windowDurationMins: 10_080,
                                             fetchedAt: start.addingTimeInterval(seconds)),
                      resetCredits: nil, accountKey: key ?? keyA)
    }

    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pace-history-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func immutableHalfHourlySamplesAndPersistence() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try QuotaHistoryStore(directory: directory, at: start)
        try await store.record(usage(30)) // Preserve actual observation time, not bucket boundary.
        let first = await store.pacePoints(accountKey: keyA, at: start.addingTimeInterval(30))
        try expect(first.count == 1 && first[0].date == start.addingTimeInterval(30))
        try expect(first[0].percentPerHour == usage(30).weekly.requiredPacePerHour(at: first[0].date))
        try await store.record(usage(30)) // Duplicate.
        for time in stride(from: 300.0, through: 1_800, by: 300) {
            try await store.record(usage(time, 20))
        }
        let points = await store.pacePoints(accountKey: keyA, at: start.addingTimeInterval(1_800))
        try expect(points.count == 2 && points[0] == first[0])
        try expect(points[1].connectsToPrevious && points[1].date == start.addingTimeInterval(1_800))
        try expect(points[1].percentPerHour == 80 / 167.5)
        let later = await store.pacePoints(accountKey: keyA, at: start.addingTimeInterval(20_000))
        try expect(later == points, "Advancing time must not recalculate or extrapolate saved targets")
        let past = await store.pacePoints(accountKey: keyA, at: start.addingTimeInterval(1_799))
        try expect(past == first, "Queries must never reveal future points")
        let reloaded = try QuotaHistoryStore(directory: directory, at: start.addingTimeInterval(1_900))
        let restored = await reloaded.pacePoints(accountKey: keyA, at: start.addingTimeInterval(1_900))
        try expect(restored == points && reloaded.loadWarning == nil)
        try await reloaded.record(usage(1_950, 30)) // Restart in same slot must not replace it.
        let unchanged = await reloaded.pacePoints(accountKey: keyA, at: start.addingTimeInterval(1_950))
        try expect(unchanged == points)
        let invisible = await reloaded.pacePoints(accountKey: keyA, at: start.addingTimeInterval(3_600), count: 1)
        try expect(invisible.isEmpty)
    }

    func continuityIncludesInterveningReadings() async throws {
        // Each disruption happens between the selected half-hour points.
        for disruption in ["gap", "correction", "reset", "session", "account", "restart"] {
            let directory = try fixture()
            defer { try? FileManager.default.removeItem(at: directory) }
            var store = try QuotaHistoryStore(directory: directory, at: start)
            try await store.record(usage(0))
            try await store.record(usage(300, 11))
            var resetOffset = 604_800.0
            if disruption == "gap" {
                try await store.record(usage(1_201, 12)) // >15m gap ends before next selected point.
                try await store.record(usage(1_500, 13))
            } else {
                if disruption == "session" { await store.breakContinuity() }
                if disruption == "restart" {
                    store = try QuotaHistoryStore(directory: directory, at: start.addingTimeInterval(600))
                }
                if disruption == "account" { try await store.record(usage(450, 80, key: keyB)) }
                if disruption == "reset" { resetOffset = 700_000 }
                try await store.record(usage(600, disruption == "correction" ? 9 : 12,
                                             resetOffset: resetOffset))
                try await store.record(usage(1_200, 13, resetOffset: resetOffset))
            }
            try await store.record(usage(1_800, 14, resetOffset: resetOffset))
            let points = await store.pacePoints(accountKey: keyA, at: start.addingTimeInterval(1_800))
            try expect(points.count == 2 && !points[1].connectsToPrevious,
                       "Must not join pace points across intermediate \(disruption)")
            let reloaded = try QuotaHistoryStore(directory: directory, at: start.addingTimeInterval(1_900))
            let restored = await reloaded.pacePoints(accountKey: keyA, at: start.addingTimeInterval(1_900))
            try expect(restored == points, "Continuity break must survive a reload")
            let otherAccount = await store.pacePoints(accountKey: keyB, at: start.addingTimeInterval(1_800))
            try expect(otherAccount.count == (disruption == "account" ? 1 : 0))
        }
    }

    func legacyHistoryDoesNotInventPaceAndWakeDoesNotBackfill() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try QuotaHistoryStore(directory: directory, at: start)
        try await store.record(usage(0))
        try await store.record(usage(300, 11))
        let file = directory.appendingPathComponent("quota-history.json")
        var archive = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        archive["version"] = 1
        archive["samples"] = (archive["samples"] as! [[String: Any]]).map { row in
            var legacy = row
            legacy.removeValue(forKey: "pacePercentPerHour")
            return legacy
        }
        try JSONSerialization.data(withJSONObject: archive).write(to: file)
        let legacy = try QuotaHistoryStore(directory: directory, at: start.addingTimeInterval(600))
        let bins = await legacy.bins(accountKey: keyA, at: start.addingTimeInterval(600), count: 1)
        let empty = await legacy.pacePoints(accountKey: keyA, at: start.addingTimeInterval(600))
        try expect(legacy.loadWarning == nil && bins[0].consumedPercent == 1 && empty.isEmpty)
        try await legacy.record(usage(600, 12))
        try await legacy.record(usage(10_800, 12))
        let points = await legacy.pacePoints(accountKey: keyA, at: start.addingTimeInterval(10_800))
        try expect(points.count == 2 && !points[1].connectsToPrevious,
                   "Wake must add only its actual reading, never fill sleeping half-hours")
        let nowVisible = await legacy.pacePoints(accountKey: keyA, at: start.addingTimeInterval(10_800), count: 1)
        try expect(nowVisible.count == 1 && !nowVisible[0].connectsToPrevious)
        let later = 9.0 * 86_400
        try await legacy.record(usage(later, 1, resetOffset: later + 604_800))
        let retained = await legacy.pacePoints(accountKey: keyA, at: start.addingTimeInterval(later), count: 192)
        try expect(retained.count == 1, "Pace and quota history share the eight-day retention bound")
    }

    func writeFailureKeepsImmutablePaceInMemory() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocked = directory.appendingPathComponent("blocked")
        try Data("blocked".utf8).write(to: blocked)
        let store = try QuotaHistoryStore(directory: blocked, at: start)
        _ = try await captureError { try await store.record(usage(0)) }
        let first = await store.pacePoints(accountKey: keyA, at: start)
        _ = try await captureError { try await store.record(usage(300, 20)) }
        let after = await store.pacePoints(accountKey: keyA, at: start.addingTimeInterval(300))
        try expect(first.count == 1 && after == first)
        try expect(try String(contentsOf: blocked, encoding: .utf8) == "blocked")
    }
}

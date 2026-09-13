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

    func legacyHistoryAndRecoveredPaceRetention() async throws {
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
        try expect(points.count == 7 && points.dropFirst().allSatisfy(\.connectsToPrevious),
                   "Matching wake endpoints recover missing half-hours after the first recorded pace")
        try expect(points.filter(\.isEstimated).count == 5)
        try expect(points.first?.date == start.addingTimeInterval(600),
                   "Legacy rows without recorded pace must not gain invented targets")
        let nowVisible = await legacy.pacePoints(accountKey: keyA, at: start.addingTimeInterval(10_800), count: 1)
        try expect(nowVisible.count == 1 && !nowVisible[0].connectsToPrevious)
        let later = 9.0 * 86_400
        try await legacy.record(usage(later, 1, resetOffset: later + 604_800))
        let retained = await legacy.pacePoints(accountKey: keyA, at: start.addingTimeInterval(later), count: 192)
        try expect(retained.count == 1, "Pace and quota history share the eight-day retention bound")
    }

    func matchingWakeRecoversEstimatesWithoutInventingUsage() async throws {
        for mode in ["wake", "restart", "gap"] {
            let directory = try fixture()
            defer { try? FileManager.default.removeItem(at: directory) }
            var store = try QuotaHistoryStore(directory: directory, at: start)
            try await store.record(usage(30))
            try await store.record(usage(300))
            let before = await store.pacePoints(accountKey: keyA, at: start.addingTimeInterval(300))
            if mode == "wake" { await store.pauseForSleep() }
            if mode == "restart" {
                store = try QuotaHistoryStore(directory: directory, at: start.addingTimeInterval(7_230))
            }
            try await store.record(usage(7_230))
            let points = await store.pacePoints(accountKey: keyA, at: start.addingTimeInterval(7_230))
            try expect(points.count == 5 && points[0] == before[0])
            try expect(points.map(\.isEstimated) == [false, true, true, true, false])
            try expect(points.dropFirst().allSatisfy { $0.connectsToPrevious && $0.estimatedConnection })
            for point in points where point.isEstimated {
                try expect(point.percentPerHour == 90 / (start.addingTimeInterval(604_800).timeIntervalSince(point.date) / 3_600))
            }
            try expect(zip(points, points.dropFirst()).allSatisfy { $1.percentPerHour > $0.percentPerHour })
            let bins = await store.bins(accountKey: keyA, at: start.addingTimeInterval(7_230), count: 3)
            try expect(bins[0].observedSeconds == 270 && bins[0].consumedPercent == 0)
            try expect(bins[1].consumedPercent == nil && bins[2].consumedPercent == nil,
                       "Recovered pace must not turn unobserved hourly activity into zeros")
            let archive = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("quota-history.json"))) as! [String: Any]
            try expect(archive["version"] as? Int == 3 && (archive["samples"] as? [Any])?.count == 3,
                       "Only real observations belong in quota history")
            let reloaded = try QuotaHistoryStore(directory: directory, at: start.addingTimeInterval(7_500))
            let restored = await reloaded.pacePoints(accountKey: keyA, at: start.addingTimeInterval(7_500))
            try expect(restored == points && reloaded.loadWarning == nil)
            let historical = await reloaded.pacePoints(accountKey: keyA, at: start.addingTimeInterval(7_200))
            try expect(historical == before, "Recovery is unavailable until its later observation exists")
            try await store.record(usage(7_500, 12))
            let unchanged = await store.pacePoints(accountKey: keyA, at: start.addingTimeInterval(7_500))
            try expect(unchanged == points, "Later consumption must never rewrite inferred or observed targets")
        }
    }

    func recoveryRejectsAmbiguousEndpointsAndHonorsSessionBreaks() async throws {
        for disruption in ["used", "reset", "account", "explicit", "legacy", "clock"] {
            let directory = try fixture()
            defer { try? FileManager.default.removeItem(at: directory) }
            var store = try QuotaHistoryStore(directory: directory, at: start)
            try await store.record(usage(0))
            if disruption == "explicit" { await store.breakContinuity() }
            if disruption == "clock" { try await store.record(usage(-1)) }
            if disruption == "account" { try await store.record(usage(300, key: keyB)) }
            if disruption == "legacy" {
                let file = directory.appendingPathComponent("quota-history.json")
                var archive = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
                archive["version"] = 1
                archive["samples"] = (archive["samples"] as! [[String: Any]]).map { row in
                    var row = row; row.removeValue(forKey: "pacePercentPerHour"); return row
                }
                try JSONSerialization.data(withJSONObject: archive).write(to: file)
                store = try QuotaHistoryStore(directory: directory, at: start.addingTimeInterval(3_600))
            }
            try await store.record(usage(3_600, disruption == "used" ? 11 : 10,
                                         resetOffset: disruption == "reset" ? 700_000 : 604_800))
            let points = await store.pacePoints(accountKey: keyA, at: start.addingTimeInterval(3_600))
            try expect(points.count == (disruption == "legacy" ? 1 : 2))
            try expect(points.allSatisfy { !$0.isEstimated && !$0.connectsToPrevious },
                       "No inference across \(disruption)")
        }
    }

    func recoveryPreservesVersionTwoAndHandlesShortSleep() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var store = try QuotaHistoryStore(directory: directory, at: start)
        try await store.record(usage(0))
        try await store.record(usage(300))
        let file = directory.appendingPathComponent("quota-history.json")
        var archive = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        let originalRows = archive["samples"] as! NSArray
        archive["version"] = 2
        archive.removeValue(forKey: "recoverySpans")
        try JSONSerialization.data(withJSONObject: archive).write(to: file)
        store = try QuotaHistoryStore(directory: directory, at: start.addingTimeInterval(600))
        try await store.record(usage(600)) // Restart within same slot: inferred segment, no extra point.
        for time in stride(from: 900.0, through: 1_800, by: 300) { try await store.record(usage(time)) }
        var points = await store.pacePoints(accountKey: keyA, at: start.addingTimeInterval(1_800))
        try expect(points.count == 2 && points[1].connectsToPrevious && points[1].estimatedConnection)
        try expect(points.allSatisfy { !$0.isEstimated })
        await store.pauseForSleep()
        try await store.record(usage(2_100))
        for time in stride(from: 2_400.0, through: 3_600, by: 300) { try await store.record(usage(time)) }
        points = await store.pacePoints(accountKey: keyA, at: start.addingTimeInterval(3_600))
        try expect(points.count == 3 && points[2].estimatedConnection,
                   "Even a short sleep must not masquerade as observed continuity")
        let bins = await store.bins(accountKey: keyA, at: start.addingTimeInterval(3_600), count: 2)
        try expect(bins[0].observedSeconds == 3_000, "Restart and short sleep each leave 300 seconds unobserved")
        archive = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        let retained = Array((archive["samples"] as! [Any]).prefix(2)) as NSArray
        try expect(retained == originalRows && archive["version"] as? Int == 3)
    }

    func recoveryNeverExtendsPastRetention() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try QuotaHistoryStore(directory: directory, at: start)
        let later = 9.0 * 86_400
        // Keep the same quota and reset to isolate the retention rule from reset detection.
        try await store.record(usage(0, resetOffset: 14 * 86_400))
        try await store.record(usage(later, resetOffset: 14 * 86_400))
        let points = await store.pacePoints(accountKey: keyA, at: start.addingTimeInterval(later), count: 192)
        try expect(points.count == 1 && !points[0].isEstimated && !points[0].connectsToPrevious)
        let file = directory.appendingPathComponent("quota-history.json")
        let archive = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        try expect((archive["recoverySpans"] as? [Any])?.isEmpty == true)
        let reloaded = try QuotaHistoryStore(directory: directory, at: start.addingTimeInterval(later))
        let restored = await reloaded.pacePoints(accountKey: keyA, at: start.addingTimeInterval(later), count: 192)
        try expect(restored == points && reloaded.loadWarning == nil)
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

import Foundation
import QuotaCore

struct QuotaHistoryTests {
    private let hour = Date(timeIntervalSince1970: 1_800_000_000)
    private let keyA = String(repeating: "a", count: 64)
    private let keyB = String(repeating: "b", count: 64)

    private func usage(_ seconds: Double, _ used: Double, key: String? = nil,
                       resetOffset: Double = 604_800) -> UsageSnapshot {
        UsageSnapshot(weekly: WeeklySnapshot(usedPercent: used,
                                             resetsAt: hour.addingTimeInterval(resetOffset),
                                             windowDurationMins: 10_080,
                                             fetchedAt: hour.addingTimeInterval(seconds)),
                      resetCredits: nil, accountKey: key ?? keyA)
    }

    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("quota-history-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func hourlyBoundaryAllocation() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try QuotaHistoryStore(directory: directory, at: hour)
        try await store.record(usage(3_550, 10))
        try await store.record(usage(3_650, 12))
        let bins = await store.bins(accountKey: keyA, at: hour.addingTimeInterval(3_650), count: 2)
        try expect(bins.count == 2)
        try expect(bins[0].consumedPercent == 1 && bins[1].consumedPercent == 1,
                   "A crossing interval must conserve usage across both hours")
        try expect(bins[0].observedSeconds == 50 && bins[1].observedSeconds == 50)
        try expect(bins[0].expectedSeconds == 3_600 && bins[1].expectedSeconds == 50)
        try expect(bins[1].coverageFraction == 1)
        let future = await store.bins(accountKey: keyA, at: hour.addingTimeInterval(7_200), count: 1)
        try expect(future[0].consumedPercent == nil && future[0].expectedSeconds == 0)
    }

    func gapsResetsAndCorrectionsRemainUnknown() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try QuotaHistoryStore(directory: directory, at: hour)
        try await store.record(usage(0, 10))
        try await store.record(usage(901, 20)) // More than fifteen minutes, unobserved.
        try await store.record(usage(1_000, 19)) // Server correction, unobserved.
        try await store.record(usage(1_100, 2, resetOffset: 700_000)) // Reset, unobserved.
        var bins = await store.bins(accountKey: keyA, at: hour.addingTimeInterval(1_100), count: 1)
        try expect(bins[0].consumedPercent == nil && bins[0].observedSeconds == 0)
        try await store.record(usage(1_200, 2, resetOffset: 700_000))
        bins = await store.bins(accountKey: keyA, at: hour.addingTimeInterval(1_200), count: 1)
        try expect(bins[0].consumedPercent == 0 && bins[0].observedSeconds == 100,
                   "Observed zero consumption must remain distinguishable from no samples")
        await store.breakContinuity()
        try await store.record(usage(1_300, 50, resetOffset: 700_000))
        let afterBreak = await store.bins(accountKey: keyA, at: hour.addingTimeInterval(1_300), count: 1)
        try expect(afterBreak[0].consumedPercent == 0 && afterBreak[0].observedSeconds == 100)
    }

    func accountScopingAndRestartContinuity() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try QuotaHistoryStore(directory: directory, at: hour)
        try await store.record(usage(0, 10))
        try await store.record(usage(100, 11))
        try await store.record(usage(200, 80, key: keyB))
        try await store.record(usage(300, 83, key: keyB))
        try await store.record(usage(400, 20)) // Returning to A must not bridge its inactive interval.
        let a = await store.bins(accountKey: keyA, at: hour.addingTimeInterval(400), count: 1)
        let b = await store.bins(accountKey: keyB, at: hour.addingTimeInterval(400), count: 1)
        try expect(a[0].consumedPercent == 1 && a[0].observedSeconds == 100)
        try expect(b[0].consumedPercent == 3 && b[0].observedSeconds == 100)
        let reloaded = try QuotaHistoryStore(directory: directory, at: hour.addingTimeInterval(500))
        try await reloaded.record(usage(500, 30)) // No interpolation across a restart.
        try await reloaded.record(usage(600, 32))
        let restored = await reloaded.bins(accountKey: keyA, at: hour.addingTimeInterval(600), count: 1)
        try expect(restored[0].consumedPercent == 3 && restored[0].observedSeconds == 200)
        let text = try String(contentsOf: directory.appendingPathComponent("quota-history.json"), encoding: .utf8)
        try expect(!text.contains("resetCredits") && !text.contains("email") && !text.contains("token"))
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("quota-history.json").path)
        try expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    func writeFailurePreservesObservedMemory() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("blocked-directory")
        // A regular file cannot be used as the history directory, even when tests run as root.
        try Data("blocked".utf8).write(to: path)
        let store = try QuotaHistoryStore(directory: path, at: hour)
        _ = try await captureError { try await store.record(usage(0, 10)) }
        _ = try await captureError { try await store.record(usage(100, 11)) }
        let bins = await store.bins(accountKey: keyA, at: hour.addingTimeInterval(100), count: 1)
        try expect(bins[0].consumedPercent == 1 && bins[0].observedSeconds == 100)
        try expect(try String(contentsOf: path, encoding: .utf8) == "blocked")
    }

    func persistenceValidationDeduplicationAndRetention() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("quota-history.json")
        try Data("invalid JSON".utf8).write(to: file)
        let store = try QuotaHistoryStore(directory: directory, at: hour)
        try expect(store.loadWarning != nil)
        try await store.record(usage(0, 10))
        try await store.record(usage(100, 11))
        try await store.record(usage(100, 11))
        try await store.record(usage(200, 12))
        var bins = await store.bins(accountKey: keyA, at: hour.addingTimeInterval(200), count: 1)
        try expect(bins[0].consumedPercent == 2 && bins[0].observedSeconds == 200)
        try await store.record(usage(150, 50)) // Clock reversal invalidates the next interval.
        try await store.record(usage(300, 60))
        try await store.record(usage(400, .nan))
        try await store.record(usage(500, 80))
        try await store.record(usage(600, 81, key: "raw-account-is-not-a-digest"))
        bins = await store.bins(accountKey: keyA, at: hour.addingTimeInterval(600), count: 1)
        try expect(bins[0].consumedPercent == 2 && bins[0].observedSeconds == 200)
        let later = 9.0 * 86_400
        try await store.record(usage(later, 1, resetOffset: later + 604_800))
        let stale = await store.bins(accountKey: keyA, at: hour.addingTimeInterval(600), count: 1)
        try expect(stale[0].consumedPercent == nil, "Records older than eight days must be pruned")
        let loaded = try QuotaHistoryStore(directory: directory, at: hour.addingTimeInterval(later))
        try expect(loaded.loadWarning == nil)
        // Valid JSON with invalid schema or invalid samples must not be trusted.
        try Data("{\"version\":2,\"samples\":[]}".utf8).write(to: file)
        let unsupported = try QuotaHistoryStore(directory: directory, at: hour)
        try expect(unsupported.loadWarning != nil)
    }
}

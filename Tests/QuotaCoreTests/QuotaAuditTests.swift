import Foundation
import QuotaCore

struct QuotaAuditTests {
    func appendDeduplicationPartialRecoveryAndPrivacy() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = QuotaAuditStore(directory: dir)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func reading(_ seconds: Double) -> UsageSnapshot {
            UsageSnapshot(weekly: WeeklySnapshot(usedPercent: 10,
                resetsAt: start.addingTimeInterval(604_800), windowDurationMins: 10_080,
                fetchedAt: start.addingTimeInterval(seconds)), resetCredits: nil,
                accountKey: String(repeating: "a", count: 64))
        }
        try await store.record(reading(0))
        try await store.record(reading(0))
        let first = try await store.exportCSVRows()
        try expect(first.split(separator: "\n").count == 1)
        let file = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)[0]
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        try expect(permissions?.intValue == 0o600)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{partial".utf8))
        try handle.close()
        let reloaded = QuotaAuditStore(directory: dir)
        try await reloaded.record(reading(300))
        let restored = try await reloaded.exportCSVRows()
        try expect(restored.split(separator: "\n").count == 2)
        try expect(restored.hasPrefix(first))
        try expect(restored.split(separator: "\n").allSatisfy {
            $0.split(separator: ",", omittingEmptySubsequences: false).count == 12
        })
        try expect(!restored.contains("resetCredits") && !restored.contains("partial"))
    }
}

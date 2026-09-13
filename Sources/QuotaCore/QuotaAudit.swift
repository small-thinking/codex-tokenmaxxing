import Foundation

/// Append-only quota evidence for longer comparisons. Separate from the eight-day UI history.
/// These account readings must not be assumed to cover every local token log's account.
public actor QuotaAuditStore {
    private let directory: URL
    private var previous: UsageSnapshot?
    private var lastPruneMonth: String?

    public init(directory: URL = QuotaHistoryStore.defaultDirectory.appendingPathComponent("quota-audit")) {
        self.directory = directory
    }

    public func record(_ usage: UsageSnapshot) throws {
        guard let key = usage.accountKey, key.count == 64,
              key.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              usage.weekly.usedPercent.isFinite, (0...100).contains(usage.weekly.usedPercent),
              usage.weekly.fetchedAt.timeIntervalSince1970.isFinite,
              let reset = usage.weekly.resetsAt, reset > usage.weekly.fetchedAt else { return }
        if previous?.accountKey == key, previous?.weekly == usage.weekly { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM"
        let month = formatter.string(from: usage.weekly.fetchedAt)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("quota-\(month).jsonl")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        var line = try encoder.encode(Reading(accountKey: key, weekly: usage.weekly))
        line.append(0x0a)
        if !FileManager.default.fileExists(atPath: file.path) {
            guard FileManager.default.createFile(atPath: file.path, contents: nil,
                                                  attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forUpdating: file)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            if try handle.read(upToCount: 1) != Data([0x0a]) {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data([0x0a]))
            }
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        previous = usage
        if lastPruneMonth != month {
            // Keep roughly four months, pruning only this ledger's monthly files.
            let cutoff = usage.weekly.fetchedAt.addingTimeInterval(-120 * 86_400)
            let oldest = "quota-" + formatter.string(from: cutoff) + ".jsonl"
            for item in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                where item.lastPathComponent.hasPrefix("quota-") && item.pathExtension == "jsonl"
                    && item.lastPathComponent < oldest {
                try FileManager.default.removeItem(at: item)
            }
            lastPruneMonth = month
        }
    }

    /// Raw readings allow an analyst to join timestamps, detect resets and quantify coverage.
    public func exportCSVRows() throws -> String {
        guard FileManager.default.fileExists(atPath: directory.path) else { return "" }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let formatter = ISO8601DateFormatter()
        var rows: [String] = []
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter({ $0.lastPathComponent.hasPrefix("quota-") && $0.pathExtension == "jsonl" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let data = try Data(contentsOf: file)
            for line in data.split(separator: 0x0a) {
                guard let reading = try? decoder.decode(Reading.self, from: Data(line)) else { continue }
                let reset = reading.weekly.resetsAt.map { formatter.string(from: $0) } ?? ""
                rows.append("quota,\(formatter.string(from: reading.weekly.fetchedAt)),,,,,,,,\(reading.weekly.usedPercent),\(reset),\(reading.accountKey)")
            }
        }
        return rows.joined(separator: "\n")
    }

    private struct Reading: Codable {
        let accountKey: String
        let weekly: WeeklySnapshot
    }
}

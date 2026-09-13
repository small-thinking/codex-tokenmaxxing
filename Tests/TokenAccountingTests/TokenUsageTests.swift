import Foundation
import TokenAccounting

struct TokenUsageTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func fixture() throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("token-accounting-\(UUID())")
        let logs = directory.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return (directory, logs)
    }

    private func line(_ type: String, _ payload: [String: Any], date: Date? = nil) throws -> Data {
        let format = ISO8601DateFormatter()
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let payloadText = String(decoding: payloadData, as: UTF8.self)
        return Data("{\"timestamp\":\"\(format.string(from: date ?? now))\",\"type\":\"\(type)\",\"payload\":\(payloadText)}\n".utf8)
    }

    private func context(model: String = "gpt-6-astra", turn: String = "turn-private") throws -> Data {
        try line("turn_context", ["model": model, "turn_id": turn, "prompt": "PRIVATE CONTENT NEVER CHECKPOINTED"])
    }

    private func record(_ id: String = "response-private", turn: String? = "turn-private", date: Date? = nil,
                        total: Any = 120) throws -> Data {
        var payload: [String: Any] = ["response_id": id,
            "usage": ["input_tokens": 100, "cached_input_tokens": 80, "cache_write_input_tokens": 5,
                      "output_tokens": 20, "reasoning_output_tokens": 8, "total_tokens": total],
            "thread_token_usage": ["total_tokens": 999999], "turn_token_usage": ["total_tokens": 88888]]
        if let turn { payload["turn_id"] = turn }
        return try line("token_usage_record", payload, date: date)
    }

    private func write(_ data: Data, to file: URL) throws {
        try data.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
    }
    private func append(_ data: Data, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
    }

    func modernCountersDeduplicateAndPreserveBreakdown() async throws {
        let (directory, logs) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = try line("event_msg", ["type": "token_count", "info": ["total_token_usage": ["total_tokens": 999999]]])
        let data = try context() + record() + legacy + record()
        try write(data, to: logs.appendingPathComponent("root.jsonl"))
        try write(try context() + record(), to: logs.appendingPathComponent("fork.jsonl"))
        let store = try TokenUsageStore(directory: directory, roots: [logs], at: now)
        let report = try await store.scan(at: now)
        try expect(report.bins.count == 1 && report.bins[0].counts.total == 120)
        try expect(report.bins[0].counts.input == 100 && report.bins[0].counts.cachedInput == 80)
        try expect(report.bins[0].counts.cacheWriteInput == 5 && report.bins[0].counts.output == 20)
        try expect(report.bins[0].counts.reasoningOutput == 8 && report.bins[0].responses == 1)
        try expect(report.latestScan.newRecords == 1 && report.latestScan.duplicates == 2)
        try expect(report.legacyFiles == 0 && !report.catchingUp)
        let csv = await store.exportCSV(at: now)
        try expect(csv.contains("gpt-6-astra,100,80,5,20,8,120,1"))
        let checkpoint = try String(contentsOf: directory.appendingPathComponent("token-usage.json"), encoding: .utf8)
        for secret in ["response-private", "turn-private", "PRIVATE CONTENT", logs.path] {
            try expect(!checkpoint.contains(secret), "Checkpoint must never retain identifiers or content")
        }
    }

    func restartAndUnchangedScanDoNotRewrite() async throws {
        let (directory, logs) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = logs.appendingPathComponent("one.jsonl")
        try write(try context() + record(), to: log)
        var store = try TokenUsageStore(directory: directory, roots: [logs], at: now)
        _ = try await store.scan(at: now)
        let checkpoint = directory.appendingPathComponent("token-usage.json")
        let before = try Data(contentsOf: checkpoint)
        let attributes = try FileManager.default.attributesOfItem(atPath: checkpoint.path)
        store = try TokenUsageStore(directory: directory, roots: [logs], at: now)
        let unchanged = try await store.scan(at: now.addingTimeInterval(300))
        try expect(unchanged.latestScan.bytesRead == 0 && unchanged.bins[0].counts.total == 120)
        try expect(try Data(contentsOf: checkpoint) == before)
        let after = try FileManager.default.attributesOfItem(atPath: checkpoint.path)
        try expect(attributes[.modificationDate] as? Date == after[.modificationDate] as? Date)
        try append(try record("another"), to: log)
        let changed = try await store.scan(at: now.addingTimeInterval(301))
        try expect(changed.latestScan.newRecords == 1 && changed.bins[0].counts.total == 240)
        try expect(changed.latestScan.bytesRead == (try record("another")).count)
    }

    func partialLinesAndByteBudgets() async throws {
        let (directory, logs) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = logs.appendingPathComponent("partial.jsonl")
        let whole = try context() + record()
        try write(Data(whole.dropLast(12)), to: log)
        let store = try TokenUsageStore(directory: directory, roots: [logs], at: now)
        var last = try await store.scan(at: now, byteBudget: 71)
        for _ in 0..<30 where last.catchingUp {
            last = try await store.scan(at: now, byteBudget: 71)
            try expect(last.latestScan.bytesRead <= 71)
        }
        try expect(!last.catchingUp && last.bins.isEmpty, "Incomplete record must never be counted")
        try append(Data(whole.suffix(12)), to: log)
        last = try await store.scan(at: now, byteBudget: 71)
        try expect(last.bins.first?.counts.total == 120)
        let restarted = try TokenUsageStore(directory: directory, roots: [logs], at: now)
        let restored = try await restarted.scan(at: now)
        try expect(restored.bins.first?.counts.total == 120 && restored.latestScan.newRecords == 0)

        let (growthDirectory, growthLogs) = try fixture()
        defer { try? FileManager.default.removeItem(at: growthDirectory) }
        let growing = growthLogs.appendingPathComponent("growing.jsonl")
        try write(try context() + record(), to: growing)
        let growthStore = try TokenUsageStore(directory: growthDirectory, roots: [growthLogs], at: now)
        _ = try await growthStore.scan(at: now, byteBudget: 71)
        try append(try record("appended-during-backlog"), to: growing)
        let snapshot = try await growthStore.scan(at: now)
        try expect(snapshot.bins.first?.counts.total == 120 && !snapshot.catchingUp,
                   "A backlog slice must stop at its metadata snapshot, not read later appends")
        let growth = try await growthStore.scan(at: now)
        try expect(growth.bins.first?.counts.total == 240 && growth.latestScan.newRecords == 1)

        let (shortDirectory, shortLogs) = try fixture()
        defer { try? FileManager.default.removeItem(at: shortDirectory) }
        let shrinking = shortLogs.appendingPathComponent("shrinking.jsonl")
        let metadata = try context()
        try write(try metadata + record(), to: shrinking)
        let shortStore = try TokenUsageStore(directory: shortDirectory, roots: [shortLogs], at: now)
        _ = try await shortStore.scan(at: now, byteBudget: metadata.count + 20)
        try write(metadata, to: shrinking) // Truncation removes only an in-memory partial line.
        _ = try await shortStore.scan(at: now.addingTimeInterval(301))
        try append(try record(), to: shrinking)
        let recovered = try await shortStore.scan(at: now.addingTimeInterval(302))
        try expect(recovered.bins.first?.counts.total == 120 && recovered.latestScan.invalidRecords == 0)
    }

    func truncationAndRotationDoNotCountDuplicates() async throws {
        let (directory, logs) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = logs.appendingPathComponent("rolling.jsonl")
        try write(try context() + record() + record("second"), to: log)
        let store = try TokenUsageStore(directory: directory, roots: [logs], at: now)
        _ = try await store.scan(at: now)
        // Truncate the same file to an already seen response.
        try write(try context() + record(), to: log)
        let truncated = try await store.scan(at: now)
        try expect(truncated.bins.first?.counts.total == 240 && truncated.latestScan.newRecords == 0)
        try write(Data(), to: log)
        _ = try await store.scan(at: now)
        try write(try context() + record("after-empty-truncation") + record("second"), to: log)
        let emptyRecovery = try await store.scan(at: now)
        try expect(emptyRecovery.bins.first?.counts.total == 360)
        try FileManager.default.removeItem(at: log)
        try write(try context() + record("third") + record("second"), to: log)
        let rotated = try await store.scan(at: now)
        try expect(rotated.bins.first?.counts.total == 480 && rotated.latestScan.newRecords == 1)
    }

    func legacyInvalidAndModelScopeAreExplicit() async throws {
        let (directory, logs) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(try line("event_msg", ["type": "token_count", "info": ["total_token_usage": ["total_tokens": 1000]]]),
                  to: logs.appendingPathComponent("old.jsonl"))
        let data = try context(model: "codex-auto-review") + record("internal") +
            record("invalid", total: 999) + record("boolean", total: true) +
            context(model: "=untrusted,model") + record("unsafe-model") + record("missing-turn", turn: "not-known")
        try write(data, to: logs.appendingPathComponent("new.jsonl"))
        let store = try TokenUsageStore(directory: directory, roots: [logs], at: now)
        let report = try await store.scan(at: now)
        try expect(report.legacyFiles == 1 && report.warning?.contains("partial") == true)
        try expect(report.latestScan.invalidRecords == 2)
        try expect(report.bins.first { $0.model == "codex-auto-review" }?.counts.total == 120)
        try expect(report.bins.first { $0.model == "unknown" }?.counts.total == 240)
        try expect(report.bins.count == 2)
        let overflowSafe = TokenCounts(total: Int64.max).adding(TokenCounts(total: 1))
        try expect(overflowSafe.total == Int64.max)
        let checkpoint = directory.appendingPathComponent("token-usage.json")
        var corrupt = try JSONSerialization.jsonObject(with: Data(contentsOf: checkpoint)) as! [String: Any]
        var corruptBins = corrupt["bins"] as! [[String: Any]]
        var corruptCounts = corruptBins[0]["counts"] as! [String: Any]
        corruptCounts["total"] = Int64.max
        corruptBins[0]["counts"] = corruptCounts
        corrupt["bins"] = corruptBins
        try JSONSerialization.data(withJSONObject: corrupt).write(to: checkpoint)
        var rejected = false
        do { _ = try TokenUsageStore(directory: directory, roots: [logs], at: now) } catch { rejected = true }
        try expect(rejected, "Corrupt or overflowing persisted totals must be rejected")
    }

    func retentionAndDiscoveryRespectCoverage() async throws {
        let (directory, logs) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = now.addingTimeInterval(-91 * 86400)
        try write(try context() + record("too-old", date: old) + record("today"), to: logs.appendingPathComponent("one.jsonl"))
        let store = try TokenUsageStore(directory: directory, roots: [logs], at: now)
        let first = try await store.scan(at: now)
        try expect(first.bins.count == 1 && first.coverageStart == now)
        try write(try context(model: "gpt-5.6-sol") + record("discovered"), to: logs.appendingPathComponent("two.jsonl"))
        let soon = try await store.scan(at: now.addingTimeInterval(300))
        try expect(soon.bins.count == 1)
        let discovered = try await store.scan(at: now.addingTimeInterval(901))
        try expect(discovered.bins.count == 2)
        let expired = try await store.scan(at: now.addingTimeInterval(91 * 86400))
        try expect(expired.bins.isEmpty && expired.coverageStart == nil)
    }

    func largeIrrelevantLinesMakeBoundedProgress() async throws {
        let (directory, logs) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ignored = try line("response_item", ["text": String(repeating: "private", count: 70_000)])
        try write(try ignored + context() + record(), to: logs.appendingPathComponent("large.jsonl"))
        let store = try TokenUsageStore(directory: directory, roots: [logs], at: now)
        var result = try await store.scan(at: now, byteBudget: 8192)
        for _ in 0..<100 where result.catchingUp {
            result = try await store.scan(at: now, byteBudget: 8192)
            try expect(result.latestScan.bytesRead <= 8192)
        }
        try expect(!result.catchingUp && result.bins.first?.counts.total == 120)
        try expect(result.warning == nil, "Large irrelevant content is not missing token coverage")
    }
}

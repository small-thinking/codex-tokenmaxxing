import Foundation
import CryptoKit
import CoreFoundation

/// Incrementally consumes only token counters and model labels from local Codex logs.
/// Checkpoints contain aggregate counters and SHA-256 identities, never log contents.
public actor TokenUsageStore {
    public static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Codex Tokenmaxxing", isDirectory: true)
    public static let defaultRoots = ["sessions", "archived_sessions"].map {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/\($0)", isDirectory: true)
    }

    private struct Cursor: Codable, Equatable {
        var identity: String
        var offset: UInt64 = 0
        var skippingLine = false
        var model = "unknown"
        var turnModels: [String: String] = [:]
        var hasLegacy = false
        var hasModern = false
    }
    private struct Archive: Codable {
        var version = 1
        var cursors: [String: Cursor] = [:]
        var bins: [HourlyTokenUsage] = []
        var responses: [String: Date] = [:]
        var discardedLines = 0
    }
    private struct Source {
        let url: URL
        let key: String
        let identity: String
        let size: UInt64
        let modified: Date
    }

    private let file: URL
    private let roots: [URL]
    private var archive: Archive
    private var sources: [Source] = []
    private var nextDiscovery = Date.distantPast
    private var nextMetadataRefresh = Date.distantPast
    private var statistics = TokenScanStatistics()
    // Incomplete lines are held only in memory; a restart resumes from the last newline.
    private var pendingLines: [String: Data] = [:]
    private var readEnds: [String: UInt64] = [:]
    private var warning: String?
    private var dirty = false
    private let retention: TimeInterval = 90 * 86_400
    private let maxLineBytes = 256 * 1024
    private let maxCheckpointBytes = 96 * 1024 * 1024
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let timestampParser = ISO8601DateFormatter()
    private let plainTimestampParser = ISO8601DateFormatter()

    public init(directory: URL = defaultDirectory, roots: [URL] = defaultRoots, at now: Date = Date()) throws {
        self.file = directory.appendingPathComponent("token-usage.json")
        self.roots = roots
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        self.decoder = decoder; self.encoder = encoder
        timestampParser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        plainTimestampParser.formatOptions = [.withInternetDateTime]
        if FileManager.default.fileExists(atPath: file.path) {
            let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size <= maxCheckpointBytes else { throw StoreError.checkpointTooLarge }
            let data = try Data(contentsOf: file)
            let restored = try decoder.decode(Archive.self, from: data)
            guard restored.version == 1, Self.validArchive(restored) else { throw StoreError.invalidCheckpoint }
            archive = restored
        } else {
            archive = Archive()
        }
    }

    public enum StoreError: Error {
        case checkpointTooLarge, invalidCheckpoint
    }

    /// Limits actual bytes read, including re-read partial lines. Discovery reads file metadata only.
    /// The first import can take multiple scans; callers should keep it off the main actor.
    public func scan(at now: Date = Date(), byteBudget: Int = 8 * 1024 * 1024) throws -> TokenUsageReport {
        statistics = TokenScanStatistics()
        warning = nil
        let budget = max(0, min(byteBudget, 32 * 1024 * 1024))
        if now >= nextDiscovery || sources.isEmpty {
            discover(at: now)
            nextDiscovery = now.addingTimeInterval(900)
            nextMetadataRefresh = now.addingTimeInterval(300)
        } else if now >= nextMetadataRefresh || !hasBacklog {
            // Old threads can resume: inspect known file sizes without opening unchanged contents.
            sources = sources.compactMap { source in Self.source(source.url) }
            nextMetadataRefresh = now.addingTimeInterval(300)
        }
        let deadline = Date().addingTimeInterval(0.15)
        // Newest files first means current activity is useful during a historical import.
        // Finished files cost metadata only, so older files still make progress.
        for source in sources {
            guard statistics.bytesRead < budget && Date() < deadline else { break }
            var cursor = archive.cursors[source.key] ?? Cursor(identity: source.identity)
            if cursor.identity != source.identity || cursor.offset > source.size ||
                (readEnds[source.key] ?? cursor.offset) > source.size {
                cursor = Cursor(identity: source.identity) // Hash dedup survives truncation/rotation.
                pendingLines[source.key] = nil
                readEnds[source.key] = nil
            }
            if cursor.offset == source.size && !cursor.skippingLine {
                if archive.cursors[source.key] != cursor {
                    archive.cursors[source.key] = cursor; dirty = true
                }
                readEnds[source.key] = cursor.offset
                continue
            }
            do {
                try consume(source, cursor: &cursor, at: now, budget: budget, deadline: deadline)
            } catch {
                warning = "Some local token logs could not be read. Coverage is partial."
            }
            if archive.cursors[source.key] != cursor {
                archive.cursors[source.key] = cursor
                dirty = true
            }
        }
        prune(at: now)
        if dirty { try save() }
        return report(at: now)
    }

    public func report(at now: Date = Date()) -> TokenUsageReport {
        let cutoff = now.addingTimeInterval(-retention)
        let bins = archive.bins.filter { $0.hour >= cutoff && $0.hour <= now }
            .sorted { $0.hour == $1.hour ? $0.model < $1.model : $0.hour < $1.hour }
        let legacy = archive.cursors.values.filter { $0.hasLegacy && !$0.hasModern }.count
        let partial = hasBacklog
        var notes: [String] = []
        if let warning { notes.append(warning) }
        if legacy > 0 { notes.append("Older logs without response-level counters are excluded; historical coverage is partial.") }
        if archive.discardedLines > 0 { notes.append("Some invalid or oversized token records were skipped.") }
        return TokenUsageReport(bins: bins, latestScan: statistics,
                                coverageStart: archive.responses.values.min(), catchingUp: partial,
                                legacyFiles: legacy, warning: notes.isEmpty ? nil : notes.joined(separator: " "))
    }

    /// UTC hours are stable across daylight-saving transitions. All fields are safe aggregate data.
    public func exportCSV(at now: Date = Date()) -> String {
        let format = ISO8601DateFormatter()
        var lines = ["hour_utc,model,input_tokens,cached_input_tokens,cache_write_input_tokens,output_tokens,reasoning_output_tokens,total_tokens,responses"]
        for bin in report(at: now).bins {
            let c = bin.counts
            lines.append("\(format.string(from: bin.hour)),\(bin.model),\(c.input),\(c.cachedInput),\(c.cacheWriteInput),\(c.output),\(c.reasoningOutput),\(c.total),\(bin.responses)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private var hasBacklog: Bool {
        sources.contains { source in
            guard let cursor = archive.cursors[source.key] else { return source.size > 0 }
            return cursor.identity != source.identity || (readEnds[source.key] ?? cursor.offset) < source.size
        }
    }

    private func discover(at now: Date) {
        var found: [String: Source] = [:]
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else { continue }
            for case let url as URL in enumerator {
                guard url.pathExtension == "jsonl", let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true, values.isSymbolicLink != true,
                      let modified = values.contentModificationDate,
                      modified >= now.addingTimeInterval(-retention), let source = Self.source(url) else { continue }
                found[source.key] = source
            }
        }
        sources = found.values.sorted { $0.modified > $1.modified }
        if sources.count > 100_000 {
            sources = Array(sources.prefix(100_000))
            warning = "Too many local log files; coverage is partial."
        }
        let retained = Set(sources.map(\.key))
        let obsolete = archive.cursors.keys.filter { !retained.contains($0) }
        for key in obsolete {
            archive.cursors[key] = nil; pendingLines[key] = nil; readEnds[key] = nil
        }
        if !obsolete.isEmpty { dirty = true }
    }

    private static func source(_ url: URL) -> Source? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let device = attributes[.systemNumber] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return Source(url: url, key: digest(url.standardizedFileURL.path),
                      identity: digest("\(device):\(inode)"), size: size.uint64Value, modified: modified)
    }

    private func consume(_ source: Source, cursor: inout Cursor, at now: Date, budget: Int, deadline: Date) throws {
        let handle = try FileHandle(forReadingFrom: source.url)
        defer { try? handle.close() }
        var pending = pendingLines[source.key] ?? Data()
        try handle.seek(toOffset: cursor.offset + UInt64(pending.count))
        while statistics.bytesRead < budget && Date() < deadline {
            let position = cursor.offset + UInt64(pending.count)
            guard position < source.size else { break }
            let remaining = Int(min(UInt64(Int.max), source.size - position))
            let requested = min(64 * 1024, budget - statistics.bytesRead, remaining)
            guard let chunk = try handle.read(upToCount: requested), !chunk.isEmpty else { break }
            statistics.bytesRead += chunk.count
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 10) {
                let length = pending.distance(from: pending.startIndex, to: newline)
                if !cursor.skippingLine {
                    if length <= maxLineBytes {
                        process(Data(pending.prefix(length)), cursor: &cursor, at: now)
                    } else {
                        statistics.oversizedLines += 1
                        // Large response bodies are expected and irrelevant; only the top-level
                        // type prefix is examined before treating one as missing token coverage.
                        if isCounterLine(pending.prefix(256)) { archive.discardedLines += 1; dirty = true }
                    }
                }
                cursor.offset += UInt64(length + 1)
                cursor.skippingLine = false
                pending.removeSubrange(...newline)
            }
            if pending.count > maxLineBytes {
                if !cursor.skippingLine {
                    statistics.oversizedLines += 1
                    if isCounterLine(pending.prefix(256)) { archive.discardedLines += 1; dirty = true }
                }
                cursor.skippingLine = true
                cursor.offset += UInt64(pending.count)
                pending.removeAll(keepingCapacity: true)
            }
        }
        pendingLines[source.key] = pending.isEmpty ? nil : pending
        readEnds[source.key] = cursor.offset + UInt64(pending.count)
        // An incomplete trailing line remains in memory and on disk, never in the checkpoint.
    }

    private func isCounterLine(_ data: Data) -> Bool {
        data.range(of: Data("\"token_usage_record\"".utf8)) != nil ||
        data.range(of: Data("\"token_count\"".utf8)) != nil
    }

    private func process(_ line: Data, cursor: inout Cursor, at now: Date) {
        // Skip prompts, responses and tool results before parsing JSON. Top-level rollout type
        // precedes payload in the supported schema, and lies within this bounded prefix.
        let prefix = line.prefix(256)
        let relevant = ["\"token_usage_record\"", "\"turn_context\"", "\"event_msg\""]
            .contains { prefix.range(of: Data($0.utf8)) != nil }
        guard relevant else { return }
        if prefix.range(of: Data("\"event_msg\"".utf8)) != nil &&
            prefix.range(of: Data("\"token_count\"".utf8)) == nil { return }
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = object["type"] as? String, let payload = object["payload"] as? [String: Any] else {
            if isCounterLine(prefix) { statistics.invalidRecords += 1; archive.discardedLines += 1; dirty = true }
            return
        }
        if type == "turn_context" {
            let model = Self.safeModel(payload["model"] as? String)
            cursor.model = model
            if let turn = payload["turn_id"] as? String, !turn.isEmpty {
                // Bound checkpoint growth in extremely long threads. Unknown is preferable to
                // borrowing another turn's model when metadata is absent.
                if cursor.turnModels.count >= 256 { cursor.turnModels.removeAll() }
                cursor.turnModels[Self.digest(turn)] = model
            }
            return
        }
        if type == "event_msg" {
            if payload["type"] as? String == "token_count" { cursor.hasLegacy = true }
            return // Never sum cumulative counters or duplicate legacy notifications.
        }
        guard type == "token_usage_record" else { return }
        cursor.hasModern = true
        guard let rawID = payload["response_id"] as? String, !rawID.isEmpty, rawID.count <= 512,
              let rawDate = object["timestamp"] as? String,
              let date = timestampParser.date(from: rawDate) ?? plainTimestampParser.date(from: rawDate),
              date.timeIntervalSince1970.isFinite,
              let counts = Self.counts(payload["usage"] as? [String: Any]) else {
            statistics.invalidRecords += 1; archive.discardedLines += 1; dirty = true; return
        }
        guard date >= now.addingTimeInterval(-retention), date <= now.addingTimeInterval(300) else { return }
        let key = Self.digest(rawID)
        guard archive.responses[key] == nil else { statistics.duplicates += 1; return }
        guard archive.responses.count < 1_000_000 else {
            statistics.invalidRecords += 1; archive.discardedLines += 1; dirty = true; return
        }
        let model: String
        if let turn = payload["turn_id"] as? String {
            model = cursor.turnModels[Self.digest(turn)] ?? "unknown"
        } else { model = cursor.model }
        let hour = Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 3600) * 3600)
        if let index = archive.bins.firstIndex(where: { $0.hour == hour && $0.model == model }) {
            archive.bins[index].counts = archive.bins[index].counts.adding(counts)
            archive.bins[index].responses += 1
        } else {
            guard archive.bins.count < 250_000 else {
                statistics.invalidRecords += 1; archive.discardedLines += 1; dirty = true; return
            }
            archive.bins.append(HourlyTokenUsage(hour: hour, model: model, counts: counts, responses: 1))
        }
        archive.responses[key] = date
        statistics.newRecords += 1
        dirty = true
    }

    private static func counts(_ object: [String: Any]?) -> TokenCounts? {
        guard let object else { return nil }
        func integer(_ key: String, optional: Bool = false) -> Int64? {
            guard let value = object[key] else { return optional ? 0 : nil }
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let d = number.doubleValue
            guard d.isFinite, d >= 0, d <= 1_000_000_000_000, d.rounded() == d else { return nil }
            return number.int64Value
        }
        guard let input = integer("input_tokens"), let cached = integer("cached_input_tokens", optional: true),
              let writes = integer("cache_write_input_tokens", optional: true), let output = integer("output_tokens"),
              let reasoning = integer("reasoning_output_tokens", optional: true), let total = integer("total_tokens"),
              input + output == total, cached <= input, writes <= input, reasoning <= output else { return nil }
        return TokenCounts(input: input, cachedInput: cached, cacheWriteInput: writes,
                           output: output, reasoningOutput: reasoning, total: total)
    }

    private static func safeModel(_ value: String?) -> String {
        guard let value, !value.isEmpty, value.count <= 80,
              value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0) }) else { return "unknown" }
        return value
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func prune(at now: Date) {
        let cutoff = now.addingTimeInterval(-retention)
        let oldBins = archive.bins.count, oldResponses = archive.responses.count
        archive.bins.removeAll { $0.hour < cutoff }
        archive.responses = archive.responses.filter { $0.value >= cutoff }
        if archive.bins.count != oldBins || archive.responses.count != oldResponses { dirty = true }
    }

    private static func validArchive(_ value: Archive) -> Bool {
        let ceiling: Int64 = 1_000_000_000_000_000_000
        var aggregate: Int64 = 0
        for bin in value.bins {
            guard bin.counts.total >= 0, bin.counts.total <= ceiling - aggregate else { return false }
            aggregate += bin.counts.total
        }
        func isDigest(_ text: String) -> Bool {
            text.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        return value.cursors.count <= 100_000 && value.bins.count <= 250_000 && value.responses.count <= 1_000_000 &&
        value.discardedLines >= 0 &&
        value.cursors.allSatisfy { key, cursor in
            isDigest(key) && isDigest(cursor.identity) && cursor.model == safeModel(cursor.model) &&
                cursor.turnModels.count <= 256 && cursor.turnModels.allSatisfy { isDigest($0.key) && $0.value == safeModel($0.value) }
        } &&
        value.responses.allSatisfy { isDigest($0.key) && $0.value.timeIntervalSince1970.isFinite && $0.value.timeIntervalSince1970 >= 0 } &&
        value.bins.allSatisfy { bin in
            let c = bin.counts
            return bin.hour.timeIntervalSince1970.isFinite && bin.hour.timeIntervalSince1970 >= 0 &&
                bin.responses >= 0 && bin.responses <= 1_000_000 && bin.model == safeModel(bin.model) &&
                c.input >= 0 && c.output >= 0 && c.total >= 0 && c.cachedInput >= 0 && c.cacheWriteInput >= 0 &&
                c.reasoningOutput >= 0 && c.cachedInput <= c.input && c.cacheWriteInput <= c.input &&
                c.reasoningOutput <= c.output && c.input <= Int64.max - c.output && c.input + c.output == c.total
        }
    }

    private func save() throws {
        let data = try encoder.encode(archive)
        guard data.count <= maxCheckpointBytes else { throw StoreError.checkpointTooLarge }
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        dirty = false
    }
}

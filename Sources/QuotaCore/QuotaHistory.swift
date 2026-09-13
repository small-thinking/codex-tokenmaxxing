import Foundation

/// Observed weekly-quota consumption, apportioned across hour boundaries.
/// nil consumption means no observed interval; zero means an observed interval with no change.
public struct HourlyQuotaBin: Equatable, Sendable {
    public let start: Date
    public let consumedPercent: Double?
    public let observedSeconds: TimeInterval
    public let expectedSeconds: TimeInterval

    public var coverageFraction: Double {
        expectedSeconds > 0 ? min(1, observedSeconds / expectedSeconds) : 0
    }

    public init(start: Date, consumedPercent: Double?, observedSeconds: TimeInterval,
                expectedSeconds: TimeInterval) {
        self.start = start
        self.consumedPercent = consumedPercent
        self.observedSeconds = observedSeconds
        self.expectedSeconds = expectedSeconds
    }
}

/// An immutable observed target, or an explicitly estimated target recovered between matching readings.
public struct PacePoint: Codable, Equatable, Sendable {
    public let date: Date
    public let percentPerHour: Double
    public let connectsToPrevious: Bool

    public let isEstimated: Bool
    /// The incoming line crosses an inferred interval, even if this endpoint was observed.
    public let estimatedConnection: Bool

    public init(date: Date, percentPerHour: Double, connectsToPrevious: Bool,
                isEstimated: Bool = false, estimatedConnection: Bool = false) {
        self.date = date
        self.percentPerHour = percentPerHour
        self.connectsToPrevious = connectsToPrevious
        self.isEstimated = isEstimated
        self.estimatedConnection = estimatedConnection
    }
}

/// Small local-only history. File I/O and aggregation run on this actor, away from the UI actor.
/// Sampling gaps, new sessions, account switches, and quota resets never imply observed activity.
public actor QuotaHistoryStore {
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Codex Tokenmaxxing", isDirectory: true)
    }
    public nonisolated let loadWarning: String?
    private let file: URL
    private var samples: [Sample]
    private var previous: Sample?
    private var recoveryAllowed = true
    private var recoverySpans: [RecoverySpan]
    private static let retention: TimeInterval = 8 * 86_400
    private static let maximumGap: TimeInterval = 15 * 60
    private static let maximumSamples = 10_000

    private struct Sample: Codable, Equatable {
        let accountKey: String
        let weekly: WeeklySnapshot
        let connectsToPrevious: Bool
        // Absent in version 1. Only the first reading of each UTC half-hour stores a target.
        let pacePercentPerHour: Double?
    }
    /// Only records permission to infer pace, never an observed quota interval.
    private struct RecoverySpan: Codable, Hashable {
        let accountKey: String
        let from: Date
        let through: Date
    }
    private struct Archive: Codable {
        let version: Int
        let samples: [Sample]
        let recoverySpans: [RecoverySpan]?
    }

    public init(directory: URL = QuotaHistoryStore.defaultDirectory, at now: Date = Date()) throws {
        file = directory.appendingPathComponent("quota-history.json")
        var loaded: [Sample] = []
        var recovered: [RecoverySpan] = []
        var warning: String?
        if FileManager.default.fileExists(atPath: file.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            if (attributes[.size] as? NSNumber)?.intValue ?? 0 > 4_000_000 {
                warning = "Saved activity history was too large; starting a new history."
            } else {
                let data = try Data(contentsOf: file)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .secondsSince1970
                if let archive = try? decoder.decode(Archive.self, from: data), (1...3).contains(archive.version),
                   archive.samples.count <= Self.maximumSamples,
                   archive.samples.allSatisfy({ Self.isValid($0) }), Self.isOrdered(archive.samples) {
                    loaded = archive.samples.filter {
                        $0.weekly.fetchedAt >= now.addingTimeInterval(-Self.retention) && $0.weekly.fetchedAt <= now
                    }
                    // Invalid or orphaned inference metadata cannot create points.
                    recovered = Self.validatedSpans(Array((archive.recoverySpans ?? []).prefix(Self.maximumSamples)),
                                                    in: loaded)
                } else {
                    warning = "Saved activity history could not be read; starting a new history."
                }
            }
        }
        samples = loaded
        recoverySpans = recovered
        loadWarning = warning
        // previous intentionally stays nil: elapsed time while the app was closed is unknown.
    }

    public func breakContinuity() { previous = nil; recoveryAllowed = false }

    /// Sleep is unknown activity, but matching observations may later bracket an estimated pace interval.
    public func pauseForSleep() { previous = nil }

    public func record(_ usage: UsageSnapshot) throws {
        guard let accountKey = usage.accountKey else { breakContinuity(); return }
        let candidate = Sample(accountKey: accountKey, weekly: usage.weekly, connectsToPrevious: false, pacePercentPerHour: nil)
        guard Self.isValid(candidate) else { breakContinuity(); return }
        if let latest = samples.last(where: { $0.accountKey == accountKey }),
           candidate.weekly.fetchedAt <= latest.weekly.fetchedAt {
            // Duplicate responses do not add observation time; clock reversal breaks continuity.
            if candidate.weekly != latest.weekly { breakContinuity() }
            return
        }
        let connects = previous.map { Self.canConnect($0, candidate) } ?? false
        let slot = floor(usage.weekly.fetchedAt.timeIntervalSince1970 / 1_800)
        let hasPaceInSlot = samples.contains {
            $0.accountKey == accountKey && $0.pacePercentPerHour != nil
                && floor($0.weekly.fetchedAt.timeIntervalSince1970 / 1_800) == slot
        }
        let pace = hasPaceInSlot ? nil : usage.weekly.requiredPacePerHour(at: usage.weekly.fetchedAt)
        let sample = Sample(accountKey: accountKey, weekly: usage.weekly, connectsToPrevious: connects,
                            pacePercentPerHour: pace)
        if !connects, recoveryAllowed, let left = samples.last,
           Self.canRecover(left, sample),
           samples.contains(where: { $0.accountKey == accountKey && $0.pacePercentPerHour != nil
               && $0.weekly.resetsAt == left.weekly.resetsAt }) {
            recoverySpans.append(RecoverySpan(accountKey: accountKey, from: left.weekly.fetchedAt,
                                              through: sample.weekly.fetchedAt))
        }
        samples.append(sample)
        previous = sample
        recoveryAllowed = true
        samples.removeAll { $0.weekly.fetchedAt < usage.weekly.fetchedAt.addingTimeInterval(-Self.retention) }
        if samples.count > Self.maximumSamples { samples.removeFirst(samples.count - Self.maximumSamples) }
        recoverySpans = Self.validatedSpans(recoverySpans, in: samples)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try encoder.encode(Archive(version: 3, samples: samples, recoverySpans: recoverySpans)).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// Observed points retain their original values. Recovered half-hours are marked as estimates.
    public func pacePoints(accountKey: String, at now: Date, count: Int = 24) -> [PacePoint] {
        guard now.timeIntervalSince1970.isFinite else { return [] }
        let count = min(192, max(1, count))
        let hour = floor(now.timeIntervalSince1970 / 3_600) * 3_600
        let start = hour - Double(count - 1) * 3_600
        let scoped = samples.filter { $0.accountKey == accountKey && $0.weekly.fetchedAt <= now }
        let observedSlots = Set(scoped.filter { $0.pacePercentPerHour != nil }.map {
            floor($0.weekly.fetchedAt.timeIntervalSince1970 / 1_800)
        })
        let spans = Set(recoverySpans.filter { $0.accountKey == accountKey })
        var points: [PacePoint] = []
        var previousSample: Sample?
        var continuousSincePoint = false
        var inferredSincePoint = false
        func append(_ date: Date, _ pace: Double, estimated: Bool) {
            guard date.timeIntervalSince1970 >= start else { return }
            let connects = !points.isEmpty && continuousSincePoint
            points.append(PacePoint(date: date, percentPerHour: pace, connectsToPrevious: connects,
                                    isEstimated: estimated,
                                    estimatedConnection: connects && inferredSincePoint))
            continuousSincePoint = true
            inferredSincePoint = false
        }
        for sample in scoped {
            if let left = previousSample {
                let recovered = spans.contains(RecoverySpan(accountKey: accountKey,
                    from: left.weekly.fetchedAt, through: sample.weekly.fetchedAt))
                continuousSincePoint = continuousSincePoint && (recovered ||
                    (sample.connectsToPrevious && Self.canConnect(left, sample)))
                if recovered, let reset = left.weekly.resetsAt {
                    inferredSincePoint = true
                    let firstSlot = floor(left.weekly.fetchedAt.timeIntervalSince1970 / 1_800) + 1
                    let lastSlot = floor(sample.weekly.fetchedAt.timeIntervalSince1970 / 1_800)
                    if firstSlot <= lastSlot {
                        for slot in stride(from: firstSlot, through: lastSlot, by: 1) {
                            let date = Date(timeIntervalSince1970: slot * 1_800)
                            guard date < sample.weekly.fetchedAt, !observedSlots.contains(slot) else { continue }
                            let pace = left.weekly.remainingPercent / (reset.timeIntervalSince(date) / 3_600)
                            append(date, pace, estimated: true)
                            inferredSincePoint = true
                        }
                    }
                }
            } else {
                continuousSincePoint = false
            }
            previousSample = sample
            if let pace = sample.pacePercentPerHour {
                append(sample.weekly.fetchedAt, pace, estimated: false)
            }
        }
        return points
    }

    public func bins(accountKey: String, at now: Date, count: Int = 24) -> [HourlyQuotaBin] {
        guard now.timeIntervalSince1970.isFinite else { return [] }
        let count = min(192, max(1, count))
        let hour = floor(now.timeIntervalSince1970 / 3_600) * 3_600
        let start = hour - Double(count - 1) * 3_600
        var consumed = [Double](repeating: 0, count: count)
        var observed = [TimeInterval](repeating: 0, count: count)
        let scoped = samples.filter { $0.accountKey == accountKey }
        for (left, right) in zip(scoped, scoped.dropFirst()) {
            guard right.connectsToPrevious, Self.canConnect(left, right), right.weekly.fetchedAt <= now else { continue }
            let a = left.weekly.fetchedAt.timeIntervalSince1970
            let b = right.weekly.fetchedAt.timeIntervalSince1970
            let delta = right.weekly.usedPercent - left.weekly.usedPercent
            for index in 0..<count {
                let binStart = start + Double(index) * 3_600
                let overlap = max(0, min(b, binStart + 3_600) - max(a, binStart))
                observed[index] += overlap
                consumed[index] += delta * overlap / (b - a)
            }
        }
        return (0..<count).map { index in
            let binStart = start + Double(index) * 3_600
            return HourlyQuotaBin(start: Date(timeIntervalSince1970: binStart),
                                  consumedPercent: observed[index] > 0 ? consumed[index] : nil,
                                  observedSeconds: observed[index],
                                  expectedSeconds: min(3_600, max(0, now.timeIntervalSince1970 - binStart)))
        }
    }

    private static func isValid(_ sample: Sample) -> Bool {
        let weekly = sample.weekly
        guard sample.accountKey.count == 64,
              sample.accountKey.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              weekly.usedPercent.isFinite, (0...100).contains(weekly.usedPercent),
              weekly.windowDurationMins == 10_080,
              weekly.fetchedAt.timeIntervalSince1970.isFinite, weekly.fetchedAt.timeIntervalSince1970 >= 0,
              let reset = weekly.resetsAt, reset.timeIntervalSince1970.isFinite,
              reset > weekly.fetchedAt, reset <= Date.distantFuture else { return false }
        if let pace = sample.pacePercentPerHour, !pace.isFinite || pace < 0 { return false }
        return true
    }

    private static func canRecover(_ left: Sample, _ right: Sample) -> Bool {
        left.accountKey == right.accountKey && left.weekly.usedPercent == right.weekly.usedPercent
            && left.weekly.resetsAt == right.weekly.resetsAt
            && left.weekly.windowDurationMins == right.weekly.windowDurationMins
            && right.weekly.fetchedAt > left.weekly.fetchedAt
            && right.weekly.fetchedAt.timeIntervalSince(left.weekly.fetchedAt) <= retention
    }

    private static func validatedSpans(_ spans: [RecoverySpan], in samples: [Sample]) -> [RecoverySpan] {
        // Linear passes keep repeated disk writes and 30-second UI refreshes inexpensive.
        let valid = Set(zip(samples, samples.dropFirst()).compactMap { left, right in
            canRecover(left, right) ? RecoverySpan(accountKey: left.accountKey,
                from: left.weekly.fetchedAt, through: right.weekly.fetchedAt) : nil
        })
        var seen = Set<RecoverySpan>()
        return spans.filter { valid.contains($0) && seen.insert($0).inserted }
    }

    private static func canConnect(_ left: Sample, _ right: Sample) -> Bool {
        let elapsed = right.weekly.fetchedAt.timeIntervalSince(left.weekly.fetchedAt)
        return left.accountKey == right.accountKey && elapsed > 0 && elapsed <= maximumGap
            && left.weekly.resetsAt == right.weekly.resetsAt
            && left.weekly.windowDurationMins == right.weekly.windowDurationMins
            && right.weekly.usedPercent >= left.weekly.usedPercent
    }

    private static func isOrdered(_ samples: [Sample]) -> Bool {
        var last: [String: Date] = [:]
        for sample in samples {
            if let previous = last[sample.accountKey], sample.weekly.fetchedAt <= previous { return false }
            last[sample.accountKey] = sample.weekly.fetchedAt
        }
        return true
    }
}

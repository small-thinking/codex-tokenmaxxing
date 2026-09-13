import Foundation

/// Local model throughput, not a bill or an account-wide usage total.
/// Cached input is included in input; reasoning output is included in output.
public struct TokenCounts: Codable, Equatable, Sendable {
    public var input: Int64
    public var cachedInput: Int64
    public var cacheWriteInput: Int64
    public var output: Int64
    public var reasoningOutput: Int64
    public var total: Int64

    public init(input: Int64 = 0, cachedInput: Int64 = 0, cacheWriteInput: Int64 = 0,
                output: Int64 = 0, reasoningOutput: Int64 = 0, total: Int64 = 0) {
        self.input = input; self.cachedInput = cachedInput; self.cacheWriteInput = cacheWriteInput
        self.output = output; self.reasoningOutput = reasoningOutput; self.total = total
    }

    public func adding(_ other: Self) -> Self {
        // Validated store counters cannot reach this limit. Saturation also makes the public
        // aggregation helper safe for callers constructing arbitrary counters.
        func sum(_ lhs: Int64, _ rhs: Int64) -> Int64 {
            let result = lhs.addingReportingOverflow(rhs)
            return result.overflow ? (rhs >= 0 ? Int64.max : Int64.min) : result.partialValue
        }
        return Self(input: sum(input, other.input), cachedInput: sum(cachedInput, other.cachedInput),
                    cacheWriteInput: sum(cacheWriteInput, other.cacheWriteInput), output: sum(output, other.output),
                    reasoningOutput: sum(reasoningOutput, other.reasoningOutput), total: sum(total, other.total))
    }
}

public struct HourlyTokenUsage: Codable, Equatable, Sendable {
    public let hour: Date
    public let model: String
    public var counts: TokenCounts
    public var responses: Int

    public init(hour: Date, model: String, counts: TokenCounts, responses: Int) {
        self.hour = hour; self.model = model; self.counts = counts; self.responses = responses
    }
}

public struct TokenScanStatistics: Equatable, Sendable {
    public var bytesRead = 0
    public var newRecords = 0
    public var duplicates = 0
    public var invalidRecords = 0
    public var oversizedLines = 0
    public init() {}
}

public struct TokenUsageReport: Equatable, Sendable {
    public let bins: [HourlyTokenUsage]
    public let latestScan: TokenScanStatistics
    /// Earliest accepted response timestamp, not proof of complete earlier coverage.
    public let coverageStart: Date?
    public let catchingUp: Bool
    public let legacyFiles: Int
    public let warning: String?

    public func total(in interval: DateInterval) -> TokenCounts {
        bins.filter { $0.hour >= interval.start && $0.hour < interval.end }
            .reduce(TokenCounts()) { $0.adding($1.counts) }
    }
}

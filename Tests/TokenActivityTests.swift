import Foundation
import TokenAccounting
import QuotaMenuUI

struct TokenActivityTests {
    func chartWindowAndModelEffortGrouping() throws {
        let hour = Date(timeIntervalSince1970: 1_800_000_000)
        func bin(_ offset: Double, _ model: String, _ effort: String, _ input: Int64,
                 _ cached: Int64, _ output: Int64) -> HourlyTokenUsage {
            HourlyTokenUsage(hour: hour.addingTimeInterval(offset * 3_600), model: model,
                            counts: TokenCounts(input: input, cachedInput: cached, output: output, total: input + output),
                            responses: 1, reasoningLevel: effort)
        }
        let bins = [bin(0, "astra", "high", 100, 80, 20), bin(0, "astra", "low", 60, 30, 10),
                    bin(-1, "astra", "high", 50, 20, 10), bin(-23, "sol", "medium", 0, 0, 0),
                    bin(-24, "old", "high", 9999, 0, 0), bin(1, "future", "high", 9999, 0, 0)]
        let now = hour.addingTimeInterval(600)
        let hours = TokenActivityData.hours(bins, at: now)
        try expect(hours.count == 24 && hours.first?.hour == hour.addingTimeInterval(-23 * 3_600))
        try expect(hours.first?.counts?.total == 0 && hours[1].counts == nil,
                   "A recorded zero and missing hour remain distinguishable")
        try expect(hours.last?.counts?.total == 190 && hours.last?.counts?.cachedInput == 110,
                   "Cached input must not be added twice to bar height")
        let current = hours.last!.counts!
        try expect(current.cacheHitRate == 110.0 / 160,
                   "Cache hit rate uses all input as denominator, weighted across models")
        try expect(current.outputRatio == 30.0 / 190,
                   "Output share uses input plus output without adding cached input again")
        try expect(TokenCounts().cacheHitRate == nil && TokenCounts().outputRatio == nil)
        let outputOnly = TokenCounts(output: 20, total: 20)
        try expect(outputOnly.cacheHitRate == nil && outputOnly.outputRatio == 1)
        let rows = TokenActivityData.breakdown(bins, at: now)
        try expect(rows.count == 3 && rows[0].id.model == "astra" && rows[0].id.reasoning == "high")
        try expect(rows[0].counts.total == 180 && rows[1].counts.total == 70)
        let selected = TokenActivityData.breakdown(bins, at: now, selectedHour: hour)
        try expect(selected.count == 2 && selected[0].counts.total == 120)
        let missing = TokenActivityData.breakdown(bins, at: now, selectedHour: hours[1].hour)
        try expect(missing.isEmpty)
        try expect(rows.reduce(Int64(0)) { $0 + $1.counts.total } == hours.reduce(Int64(0)) { $0 + ($1.counts?.total ?? 0) })
    }
}

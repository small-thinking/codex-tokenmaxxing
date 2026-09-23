import Foundation
import QuotaCore
@testable import QuotaMenuUI

struct HourlyActivityViewTests {
    func extremePaceDoesNotFlattenHourlyBars() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let bins = [HourlyQuotaBin(start: now, consumedPercent: 0.6, observedSeconds: 3_600,
                                   expectedSeconds: 3_600, attributedPercent: 0.4)]
        let normal = [PacePoint(date: now, percentPerHour: 0.62, connectsToPrevious: false)]
        let extreme = normal + [PacePoint(date: now.addingTimeInterval(1_800),
                                          percentPerHour: 25.6, connectsToPrevious: true)]

        try expect(abs(HourlyActivityView.chartCeiling(bins: bins, pacePoints: normal) - 1) < 0.001)
        let ceiling = HourlyActivityView.chartCeiling(bins: bins, pacePoints: extreme)
        try expect(ceiling == 5, "An extreme pace must not expand the chart beyond 5%/h")
        try expect(HourlyActivityView.paceY(25.6, ceiling: ceiling, height: 86) == 4,
                   "The outlier marker stays inside the chart")
        try expect(HourlyActivityView.paceY(0.62, ceiling: ceiling, height: 86) > 4,
                   "Normal pace points retain a distinct position")
        try expect(HourlyActivityView.barHeight(25.6, ceiling: ceiling, height: 86) == 86,
                   "An outlier bar stays within the plot")
        try expect(HourlyActivityView.barHeight(0.6, ceiling: ceiling, height: 86) > 2,
                   "Normal hourly bars remain visible")
    }
}

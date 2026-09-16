import SwiftUI
import QuotaCore

/// Confirmed quota changes plus an explicitly labeled local-token attribution estimate.
public struct HourlyActivityView: View {
    public let bins: [HourlyQuotaBin]
    public let message: String?
    public let paceSummary: String
    public let pacePoints: [PacePoint]

    public init(bins: [HourlyQuotaBin], pacePoints: [PacePoint], paceSummary: String, message: String? = nil) {
        self.bins = bins
        self.paceSummary = paceSummary
        self.pacePoints = pacePoints.filter {
            $0.date.timeIntervalSince1970.isFinite && $0.percentPerHour.isFinite && $0.percentPerHour >= 0
        }
        self.message = message
    }

    private var ceiling: Double {
        max(1, max(bins.compactMap { max($0.consumedPercent ?? 0, $0.attributedPercent ?? 0) }.max() ?? 0,
                   pacePoints.map(\.percentPerHour).max() ?? 0) * 1.15)
    }
    private var hasObservations: Bool { bins.contains { $0.consumedPercent != nil } }

    public var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Hourly quota attribution").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(pacePoints.last.map { "Pace \(rate($0.percentPerHour))/h" } ?? "Collecting pace…")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .help(pacePoints.last.map { paceDetail($0) } ?? "Pace is recorded from a fresh quota reading once per half-hour. Previous points stay unchanged.")
            }
            Text(paceSummary).font(.system(size: 10, weight: .medium))
                .help("The gap is quota remaining minus weekly time remaining, in percentage points of the full allowance. 88% − 79% = 9%. This compares with uniform weekly usage; the dashed curve shows recorded required pace.")
            HStack(alignment: .top, spacing: 5) {
                VStack {
                    Text(rate(ceiling, decimals: 1)).lineLimit(1).minimumScaleFactor(0.7)
                    Spacer()
                    Text("0")
                }.font(.system(size: 8)).foregroundStyle(.secondary).frame(width: 34, height: 86, alignment: .trailing)
                VStack(spacing: 4) {
                    GeometryReader { geometry in
                        let width = geometry.size.width
                        let height = geometry.size.height
                        HStack(alignment: .bottom, spacing: 3) {
                            ForEach(bins, id: \.start) { bin in
                                VStack(spacing: 0) {
                                    Spacer(minLength: 0)
                                    if let estimate = bin.attributedPercent {
                                        ZStack(alignment: .bottom) {
                                            RoundedRectangle(cornerRadius: 1)
                                                .fill(Color.teal.opacity(bin.attributionIsPartial ? 0.35 : 0.62))
                                                .frame(height: max(2, height * estimate / ceiling))
                                            if let observed = bin.consumedPercent, observed > 0 {
                                                RoundedRectangle(cornerRadius: 1)
                                                    .fill(Color.teal)
                                                    .frame(width: 2, height: max(2, height * observed / ceiling))
                                            }
                                        }
                                    } else if let value = bin.consumedPercent {
                                        RoundedRectangle(cornerRadius: 1)
                                            .fill(Color.teal.opacity(isPartial(bin) ? 0.45 : 1))
                                            .frame(height: max(2, height * value / ceiling))
                                    } else {
                                        Text("–").font(.system(size: 9)).foregroundStyle(.secondary)
                                            .frame(height: 5)
                                    }
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle()).help(detail(bin))
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(detail(bin))
                            }
                        }
                        // Draw the time series above the bars, using the same hourly time domain.
                        if let first = bins.first, let last = bins.last {
                            let start = first.start.timeIntervalSince1970
                            let duration = last.start.timeIntervalSince(first.start) + 3_600
                            let visible = pacePoints.filter {
                                $0.date.timeIntervalSince1970 >= start && $0.date.timeIntervalSince1970 <= start + duration
                            }
                            ForEach(Array(visible.indices.dropFirst()), id: \.self) { index in
                                let sample = visible[index]
                                let previous = visible[index - 1]
                                let estimated = sample.estimatedConnection
                                    || sample.isEstimated || previous.isEstimated
                                if sample.connectsToPrevious {
                                    Path { path in
                                        path.move(to: CGPoint(
                                            x: width * (previous.date.timeIntervalSince1970 - start) / duration,
                                            y: height * (1 - previous.percentPerHour / ceiling)))
                                        path.addLine(to: CGPoint(
                                            x: width * (sample.date.timeIntervalSince1970 - start) / duration,
                                            y: height * (1 - sample.percentPerHour / ceiling)))
                                    }.stroke(Color.orange.opacity(estimated ? 0.65 : 1),
                                             style: StrokeStyle(lineWidth: 1.5, dash: estimated ? [1, 3] : [3, 3]))
                                        .allowsHitTesting(false)
                                }
                            }
                            ForEach(visible, id: \.date) { sample in
                                Circle().fill(sample.isEstimated ? Color.clear : Color.orange)
                                    .overlay(Circle().stroke(Color.orange, lineWidth: 1))
                                    .frame(width: 4, height: 4)
                                    .padding(3).contentShape(Rectangle())
                                    .position(x: width * (sample.date.timeIntervalSince1970 - start) / duration,
                                              y: height * (1 - sample.percentPerHour / ceiling))
                                    .help(paceDetail(sample)).accessibilityLabel(paceDetail(sample))
                            }
                        }

                    }.frame(height: 86)
                    HStack {
                        if let first = bins.first { Text(hour(first.start)) }
                        Spacer()
                        if bins.count > 12 { Text(hour(bins[bins.count / 2].start)) }
                        Spacer()
                        if let last = bins.last { Text(hour(last.start)) }
                    }.font(.system(size: 8)).foregroundStyle(.secondary)
                }
            }
            if pacePoints.contains(where: { $0.isEstimated || $0.estimatedConnection }) {
                Text("Dotted pace · estimated while offline")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .help("Quota and reset time matched before and after the gap. Dotted segments assume quota stayed unchanged between those readings; this is not observed activity.")
            }
            if let message {
                Text(message).font(.system(size: 9)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !hasObservations {
                Text("Collecting activity · pace recorded every 30m")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            } else {
                Text("24h · wide estimate · thin observed · – missing")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .help("Wide bars retroactively distribute each confirmed quota increase using local model/input/cache/output weights. Thin marks preserve the server-observed jump. Faded estimates have partial local coverage. This proxy is not an account-wide quota ledger.")
            }
        }
    }

    private func paceDetail(_ point: PacePoint) -> String {
        let date = point.date.formatted(.dateTime.month(.abbreviated).day().hour().minute().timeZone())
        if point.isEstimated {
            return "Estimated pace \(date): \(rate(point.percentPerHour))/h. Assumes unchanged quota between matching readings before and after an offline gap. This is not an observed sample."
        }
        return "Pace recorded \(date): \(rate(point.percentPerHour))/h. Quota remaining divided by hours until reset at that moment. Historical samples are unchanged."
    }

    private func rate(_ value: Double, decimals: Int = 2) -> String {
        // Close to reset the valid target may be very large; keep labels within the compact layout.
        if value >= 1_000 { return String(format: "%.1e%%", value) }
        return String(format: "%.*f%%", decimals, value)
    }

    private func isPartial(_ bin: HourlyQuotaBin) -> Bool {
        bin.coverageFraction < 0.95 || bin.expectedSeconds < 3_600
    }

    private func hour(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func detail(_ bin: HourlyQuotaBin) -> String {
        let date = bin.start.formatted(.dateTime.month(.abbreviated).day().hour().minute().timeZone())
        guard bin.consumedPercent != nil || bin.attributedPercent != nil else {
            return "\(date): unobserved. Missing data is not zero usage."
        }
        var parts: [String] = []
        if let estimate = bin.attributedPercent {
            parts.append(String(format: "Estimated attribution %.3f%% of weekly quota%@",
                                estimate, bin.attributionIsPartial ? " (partial local coverage)" : ""))
        }
        if let value = bin.consumedPercent {
            parts.append(String(format: "server-observed interval change %.2f%%", value))
        }
        let coverage = String(format: "%.0f of %.0f elapsed minutes observed", bin.observedSeconds / 60, bin.expectedSeconds / 60)
        return "\(date): \(parts.joined(separator: "; ")); \(coverage).\(isPartial(bin) ? " Partial hour." : "") Attribution uses API-price-equivalent local token weights and is not the Codex quota formula."
    }
}

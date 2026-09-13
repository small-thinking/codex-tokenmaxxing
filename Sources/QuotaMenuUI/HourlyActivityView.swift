import SwiftUI
import QuotaCore

/// Hourly quota changes from observed polling intervals, not raw token counts.
public struct HourlyActivityView: View {
    public let bins: [HourlyQuotaBin]
    public let message: String?
    public let pacePoints: [PacePoint]

    public init(bins: [HourlyQuotaBin], pacePoints: [PacePoint], message: String? = nil) {
        self.bins = bins
        self.pacePoints = pacePoints.filter {
            $0.date.timeIntervalSince1970.isFinite && $0.percentPerHour.isFinite && $0.percentPerHour >= 0
        }
        self.message = message
    }

    private var ceiling: Double {
        max(1, max(bins.compactMap(\.consumedPercent).max() ?? 0, pacePoints.map(\.percentPerHour).max() ?? 0) * 1.15)
    }
    private var hasObservations: Bool { bins.contains { $0.consumedPercent != nil } }

    public var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Hourly quota used").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(pacePoints.last.map { "Pace \(rate($0.percentPerHour))/h" } ?? "Collecting pace…")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .help(pacePoints.last.map { paceDetail($0) } ?? "Pace is recorded from a fresh quota reading once per half-hour. Previous points stay unchanged.")
            }
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
                                    if let value = bin.consumedPercent {
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
                            Path { path in
                                for (index, sample) in visible.enumerated() {
                                    let point = CGPoint(x: width * (sample.date.timeIntervalSince1970 - start) / duration,
                                                        y: height * (1 - sample.percentPerHour / ceiling))
                                    if index == 0 || !sample.connectsToPrevious { path.move(to: point) }
                                    else { path.addLine(to: point) }
                                }
                            }.stroke(Color.orange, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                                .allowsHitTesting(false)
                            ForEach(visible, id: \.date) { sample in
                                Circle().fill(Color.orange).frame(width: 4, height: 4)
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
            if let message {
                Text(message).font(.system(size: 9)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !hasObservations {
                Text("Collecting activity · pace recorded every 30m")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            } else {
                Text("24h · dashed: pace / 30m · faded: partial · –: missing")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .help("Pace points are saved once per half-hour and never recalculated. Lines break across offline periods, resets and app restarts. Bars show hourly quota consumption; the current hour is partial.")
            }
        }
    }

    private func paceDetail(_ point: PacePoint) -> String {
        let date = point.date.formatted(.dateTime.month(.abbreviated).day().hour().minute().timeZone())
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
        guard let value = bin.consumedPercent else { return "\(date): unobserved. Missing data is not zero usage." }
        let prefix = String(format: "%.2f%% of weekly quota consumed", value)
        let coverage = String(format: "%.0f of %.0f elapsed minutes observed", bin.observedSeconds / 60, bin.expectedSeconds / 60)
        return "\(date): \(prefix); \(coverage).\(isPartial(bin) ? " Partial hour; not directly comparable to a full-hour pace sample." : "") Timing is estimated between readings."
    }
}

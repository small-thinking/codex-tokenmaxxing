import SwiftUI
import QuotaCore

/// Hourly quota changes from observed polling intervals, not raw token counts.
public struct HourlyActivityView: View {
    public let bins: [HourlyQuotaBin]
    public let message: String?

    public init(bins: [HourlyQuotaBin], message: String? = nil) {
        self.bins = bins
        self.message = message
    }

    private var ceiling: Double {
        max(1, (bins.compactMap(\.consumedPercent).max() ?? 0) * 1.15)
    }
    private var hasObservations: Bool { bins.contains { $0.consumedPercent != nil } }

    public var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Hourly activity").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(String(format: "Pace %.2f%%/h", HourlyQuotaBin.baselinePercentPerHour))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .help("Fixed uniform weekly baseline: 100% ÷ 168 hours. Bars show observed quota consumption, not raw token counts.")
            }
            HStack(alignment: .top, spacing: 5) {
                VStack {
                    Text(String(format: "%.1f%%", ceiling))
                    Spacer()
                    Text("0")
                }.font(.system(size: 8)).foregroundStyle(.secondary).frame(width: 27, height: 86, alignment: .trailing)
                VStack(spacing: 4) {
                    GeometryReader { geometry in
                        let width = geometry.size.width
                        let height = geometry.size.height
                        Path { path in
                            let y = height * (1 - HourlyQuotaBin.baselinePercentPerHour / ceiling)
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: width, y: y))
                        }.stroke(Color.secondary.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        HStack(alignment: .bottom, spacing: 3) {
                            ForEach(bins, id: \.start) { bin in
                                VStack(spacing: 0) {
                                    Spacer(minLength: 0)
                                    if let value = bin.consumedPercent {
                                        RoundedRectangle(cornerRadius: 1)
                                            .fill(Color.teal.opacity(isPartial(bin) ? 0.45 : 1))
                                            .frame(height: max(2, height * value / ceiling))
                                    } else {
                                        Text("–").font(.system(size: 9)).foregroundStyle(.tertiary)
                                            .frame(height: 5)
                                    }
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle()).help(detail(bin))
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(detail(bin))
                            }
                        }
                    }.frame(height: 86)
                    HStack {
                        if let first = bins.first { Text(hour(first.start)) }
                        Spacer()
                        if bins.count > 12 { Text(hour(bins[bins.count / 2].start)) }
                        Spacer()
                        Text("Now")
                    }.font(.system(size: 8)).foregroundStyle(.secondary)
                }
            }
            if let message {
                Text(message).font(.system(size: 9)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !hasObservations {
                Text("Collecting activity… keep the app running.")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            } else {
                Text("Last 24h · faded = partial · – = unobserved")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .help("The current hour is partial. Changes are split across hour boundaries in proportion to elapsed time between readings; gaps over 15 minutes remain unobserved.")
            }
        }
    }

    private func isPartial(_ bin: HourlyQuotaBin) -> Bool {
        bin.coverageFraction < 0.95 || bin.expectedSeconds < 3_600
    }

    private func hour(_ date: Date) -> String { date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted))) }

    private func detail(_ bin: HourlyQuotaBin) -> String {
        let date = bin.start.formatted(.dateTime.month(.abbreviated).day().hour().minute().timeZone())
        guard let value = bin.consumedPercent else { return "\(date): unobserved. Missing data is not zero usage." }
        let prefix = String(format: "%.2f%% of weekly quota consumed", value)
        let coverage = String(format: "%.0f of %.0f elapsed minutes observed", bin.observedSeconds / 60, bin.expectedSeconds / 60)
        return "\(date): \(prefix); \(coverage).\(isPartial(bin) ? " Partial hour; not directly comparable to a full-hour baseline." : "") Timing is estimated between readings."
    }
}

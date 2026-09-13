import SwiftUI
import QuotaCore

/// Hourly quota changes from observed polling intervals, not raw token counts.
public struct HourlyActivityView: View {
    public let bins: [HourlyQuotaBin]
    public let message: String?
    public let targetPace: Double?

    public init(bins: [HourlyQuotaBin], targetPace: Double?, message: String? = nil) {
        self.bins = bins
        self.targetPace = targetPace.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.message = message
    }

    private var ceiling: Double {
        max(1, max(bins.compactMap(\.consumedPercent).max() ?? 0, targetPace ?? 0) * 1.15)
    }
    private var hasObservations: Bool { bins.contains { $0.consumedPercent != nil } }

    public var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Hourly quota used").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(targetPace.map { "Target \(rate($0))/h" } ?? "Target unavailable")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .help("Current target = quota remaining ÷ hours until reset. The dashed line moves as time or quota changes. Bars are percentages of the full weekly allowance, not token counts.")
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
                        if let targetPace {
                            Path { path in
                                let y = height * (1 - targetPace / ceiling)
                                path.move(to: CGPoint(x: 0, y: y))
                                path.addLine(to: CGPoint(x: width, y: y))
                            }.stroke(Color.secondary.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        }
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
        return "\(date): \(prefix); \(coverage).\(isPartial(bin) ? " Partial hour; not directly comparable to a current full-hour target." : "") Timing is estimated between readings."
    }
}

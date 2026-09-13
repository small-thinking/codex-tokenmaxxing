import SwiftUI
import QuotaMenuUI
import LoginItemSupport

struct OverviewView: View {
    @ObservedObject var model: UsageModel
    let loginItem: LoginItemModel
    @Environment(\.colorScheme) private var colorScheme

    private var appearance: NSAppearance { NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)! }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Codex Tokenmaxxing").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("WEEKLY").font(.system(size: 9, weight: .semibold, design: .rounded))
                        .tracking(1).foregroundStyle(.secondary)
                }
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(model.percentText)
                            .font(.system(size: 38, weight: .light, design: .rounded)).monospacedDigit()
                        Text(model.snapshot == nil ? "awaiting quota" : "remaining")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        legend("Outer · quota", value: model.percentText,
                               color: model.snapshot.map { RingIcon.quotaColor(remaining: $0.remainingPercent, appearance: appearance) })
                        HStack(spacing: 4) {
                            ringMark(color: model.snapshot?.remainingTimeFraction(at: model.now).map {
                                RingIcon.timeColor(remainingFraction: $0, appearance: appearance)
                            })
                            Text("Inner · " + model.countdown.replacingOccurrences(of: "Resets", with: "reset"))
                                .lineLimit(1).minimumScaleFactor(0.85)
                            Spacer(minLength: 2)
                            if let reset = model.snapshot?.resetsAt {
                                Text(compactResetDate(reset)).monospacedDigit().foregroundStyle(.secondary)
                                    .fixedSize()
                            }
                        }.font(.system(size: 9))
                            .help(model.snapshot?.resetsAt.map {
                                "Weekly reset: " + $0.formatted(date: .complete, time: .shortened)
                            } ?? "Weekly reset time unavailable")
                    }.help("Outer: weekly quota remaining. Inner: weekly time remaining until reset. Compare filled proportions, not physical arc lengths.")
                }
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                HourlyActivityView(bins: model.historyBins,
                                   pacePoints: model.pacePoints,
                                   paceSummary: model.paceText,
                                   message: model.historyMessage)
                TokenUsageSection(model: model.tokens)
                Divider()
                ResetCreditsView(bank: model.resetCredits, now: model.now, stale: model.isStale)
                Divider()
                LoginItemSettingsView(model: loginItem)
                HStack(spacing: 10) {
                    Group {
                        if model.isRefreshing { Text("Updating…") }
                        else if let updated = model.snapshot?.fetchedAt {
                            Text("\(model.isStale ? "Last known" : "Updated") \(updated.formatted(date: .omitted, time: .shortened))")
                        } else { Text("No reading yet") }
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(model.isRefreshing).help("Refresh quota").accessibilityLabel("Refresh quota")
                    Button("Quit") { NSApplication.shared.terminate(nil) }
                }.buttonStyle(.borderless)
            }
            .padding(16)
            .frame(width: 340)
        }.frame(width: 340, height: 590)
    }

    private func legend(_ label: String, value: String, color: NSColor?) -> some View {
        HStack(spacing: 6) {
            ringMark(color: color)
            Text(label)
            Spacer(minLength: 4)
            Text(value).monospacedDigit()
        }.font(.system(size: 10))
    }

    private func ringMark(color: NSColor?) -> some View {
        Circle().stroke(Color(nsColor: model.isStale ? .secondaryLabelColor : (color ?? .secondaryLabelColor)), lineWidth: 2)
            .frame(width: 8, height: 8)
    }

    private func compactResetDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "MM/dd h a"
        return formatter.string(from: date)
    }

}

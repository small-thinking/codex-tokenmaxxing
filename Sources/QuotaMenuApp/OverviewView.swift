import SwiftUI
import QuotaMenuUI

struct OverviewView: View {
    @ObservedObject var model: UsageModel
    @Environment(\.colorScheme) private var colorScheme

    private var appearance: NSAppearance { NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)! }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
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
                        legend("Inner · time", value: model.timePercentText,
                               color: model.snapshot?.remainingTimeFraction(at: model.now).map {
                                   RingIcon.timeColor(remainingFraction: $0, appearance: appearance)
                               })
                    }.help("Outer: weekly quota remaining. Inner: weekly time remaining until reset. Compare filled proportions, not physical arc lengths.")
                }
                HStack(spacing: 5) {
                    Label(model.countdown, systemImage: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                    Spacer(minLength: 2)
                    if let reset = model.snapshot?.resetsAt {
                        Text(reset.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .help(reset.formatted(date: .complete, time: .shortened))
                    }
                }
                Text(model.paceText).font(.system(size: 11, weight: .medium))
                    .help("The gap is quota remaining minus weekly time remaining, measured in percentage points of the full allowance. 88% − 79% = 9%. This compares with uniform weekly usage, not recent activity.")
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                HourlyActivityView(bins: model.historyBins, message: model.historyMessage)
                Divider()
                ResetCreditsView(bank: model.resetCredits, now: model.now, stale: model.isStale)
                Divider()
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
            .padding(18)
            .frame(width: 340)
        }.frame(width: 340, height: 615)
    }

    private func legend(_ label: String, value: String, color: NSColor?) -> some View {
        HStack(spacing: 6) {
            Circle().stroke(Color(nsColor: model.isStale ? .secondaryLabelColor : (color ?? .secondaryLabelColor)), lineWidth: 2)
                .frame(width: 8, height: 8)
            Text(label)
            Spacer(minLength: 4)
            Text(value).monospacedDigit()
        }.font(.system(size: 10))
    }
}

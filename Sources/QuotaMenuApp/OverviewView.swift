import SwiftUI
import QuotaMenuUI

struct OverviewView: View {
    @ObservedObject var model: UsageModel
    @Environment(\.colorScheme) private var colorScheme

    private var appearance: NSAppearance { NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)! }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Codex Tokenmaxxing").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("WEEKLY").font(.system(size: 9, weight: .semibold, design: .rounded))
                    .tracking(1).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.percentText).font(.system(size: 42, weight: .light, design: .rounded)).monospacedDigit()
                Text(model.snapshot == nil ? "awaiting quota" : "remaining").font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 5) {
                Label(model.countdown, systemImage: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
                if let reset = model.snapshot?.resetsAt {
                    Text(reset.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                legend("Outer · quota remaining", value: model.percentText,
                       color: model.snapshot.map { RingIcon.quotaColor(remaining: $0.remainingPercent, appearance: appearance) })
                legend("Inner · time until reset", value: model.timePercentText,
                       color: model.snapshot?.remainingTimeFraction(at: model.now).map {
                           RingIcon.timeColor(remainingFraction: $0, appearance: appearance)
                       })
                Text("Inner turns greener as reset approaches.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Text(model.paceText).font(.system(size: 11, weight: .medium))
                Text("Compare filled proportions, not arc lengths. Pace uses a uniform weekly baseline, not recent activity.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
        .padding(20)
        .frame(width: 340)
    }

    private func legend(_ label: String, value: String, color: NSColor?) -> some View {
        HStack(spacing: 7) {
            Circle().stroke(Color(nsColor: model.isStale ? .secondaryLabelColor : (color ?? .secondaryLabelColor)), lineWidth: 2.5)
                .frame(width: 10, height: 10)
            Text(label)
            Spacer()
            Text(value).monospacedDigit()
        }.font(.system(size: 11))
    }
}

import SwiftUI

struct OverviewView: View {
    @ObservedObject var model: UsageModel

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
            } else {
                Text("Outer ring · quota remaining\nInner ring · time until reset")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
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
}

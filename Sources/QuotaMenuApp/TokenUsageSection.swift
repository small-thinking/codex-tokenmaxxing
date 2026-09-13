import SwiftUI
import TokenAccounting
import QuotaMenuUI

struct TokenUsageSection: View {
    @ObservedObject var model: TokenUsageModel
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 9) {
                TokenActivityView(bins: model.report?.bins ?? [], at: Date())
                HStack {
                    Button("Export CSV…") { model.export() }.disabled(model.exporting)
                    Spacer()
                    if let failure = model.failureMessage {
                        Image(systemName: "exclamationmark.circle").help(failure)
                            .accessibilityLabel(failure)
                    }
                }.font(.system(size: 9)).buttonStyle(.borderless)
            }.padding(.top, 6)
        } label: {
            HStack {
                Text("Local tokens").font(.system(size: 11, weight: .medium))
                Spacer()
                Text(model.report == nil ? "—" : "\(format(currentHour)) this hour")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.help(coverage)
    }

    private var currentHour: Int64 {
        TokenActivityData.hours(model.report?.bins ?? [], at: Date()).last?.counts?.total ?? 0
    }

    private var coverage: String {
        var notes = ["Local response tokens. Cached input is included in input; reasoning is included in output. Some older or remote records may be unavailable."]
        if model.report?.catchingUp == true { notes.append("Importing local history.") }
        if let warning = model.report?.warning { notes.append(warning) }
        if let checked = model.lastScannedAt { notes.append("Checked \(checked.formatted(date: .omitted, time: .shortened)).") }
        return notes.joined(separator: " ")
    }

    private func format(_ value: Int64) -> String {
        if value >= 1_000_000_000 { return String(format: "%.2fB", Double(value) / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.2fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000) }
        return String(value)
    }
}

import SwiftUI
import TokenAccounting

struct TokenUsageSection: View {
    @ObservedObject var model: TokenUsageModel
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Input \(format(hourly(\.input))) · cached \(format(hourly(\.cachedInput))) · output \(format(hourly(\.output)))")
                    .help("Current local hour. Cached input is included in input; reasoning tokens are included in output. Total = input + output.")
                Text("24h · \(format(totalSince(Date().addingTimeInterval(-86_400)))) tokens")
                Text("Modern local logs · account/billing scope may differ")
                Text("Earlier tokens may be absent; zero is not proof of no use.")
                if let checked = model.lastScannedAt {
                    Text("Checked \(checked.formatted(date: .omitted, time: .shortened))")
                }
                if let report = model.report {
                    if report.catchingUp { Text("Importing history in small batches…") }
                    if report.legacyFiles > 0 { Text("\(report.legacyFiles) older-format files excluded · history incomplete") }
                } else { Text("Reading local token records…") }
                if let message = model.message { Text(message) }
                Button("Export hourly tokens + quota readings…") { model.export() }
                    .disabled(model.exporting)
            }.font(.system(size: 9)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 3)
        } label: {
            HStack {
                Text("Local tokens").font(.system(size: 11, weight: .medium))
                Spacer()
                Text(model.report == nil ? "—" : "\(format(hourly(\.total)))\(model.report?.catchingUp == true ? "+" : "") this hour")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.help("Observed local response tokens, including cached context. These are not a fixed conversion of weekly quota. Expand for coverage and CSV export.")
    }

    private func hourly(_ key: KeyPath<TokenCounts, Int64>) -> Int64 {
        let hour = floor(Date().timeIntervalSince1970 / 3600) * 3600
        return model.report?.bins.filter { $0.hour.timeIntervalSince1970 == hour }
            .reduce(0) { $0 + $1.counts[keyPath: key] } ?? 0
    }

    private func totalSince(_ date: Date) -> Int64 {
        model.report?.bins.filter { $0.hour >= date }.reduce(0) { $0 + $1.counts.total } ?? 0
    }

    private func format(_ value: Int64) -> String {
        if value >= 1_000_000 { return String(format: "%.2fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000) }
        return String(value)
    }
}

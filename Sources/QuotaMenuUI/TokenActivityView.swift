import SwiftUI
import TokenAccounting

public struct TokenHour: Equatable, Identifiable {
    public let hour: Date
    public let counts: TokenCounts?
    public var id: Date { hour }
}

public struct TokenBreakdown: Equatable, Identifiable {
    public struct Key: Hashable {
        public let model: String
        public let reasoning: String
    }
    public let id: Key
    public var counts: TokenCounts
}

/// One shared time window for the chart, headline and model/effort table.
public enum TokenActivityData {
    public static func hours(_ bins: [HourlyTokenUsage], at now: Date) -> [TokenHour] {
        guard now.timeIntervalSince1970.isFinite else { return [] }
        let last = floor(now.timeIntervalSince1970 / 3_600) * 3_600
        var totals: [Date: TokenCounts] = [:]
        for bin in bins where bin.hour.timeIntervalSince1970 >= last - 23 * 3_600
            && bin.hour.timeIntervalSince1970 <= last {
            totals[bin.hour] = (totals[bin.hour] ?? TokenCounts()).adding(bin.counts)
        }
        return (0..<24).map { index in
            let hour = Date(timeIntervalSince1970: last - Double(23 - index) * 3_600)
            return TokenHour(hour: hour, counts: totals[hour])
        }
    }

    public static func breakdown(_ bins: [HourlyTokenUsage], at now: Date,
                                 selectedHour: Date? = nil) -> [TokenBreakdown] {
        let visible = Set(hours(bins, at: now).map(\.hour))
        var totals: [TokenBreakdown.Key: TokenCounts] = [:]
        for bin in bins where visible.contains(bin.hour) && (selectedHour == nil || bin.hour == selectedHour) {
            let key = TokenBreakdown.Key(model: bin.model, reasoning: bin.reasoningLevel)
            totals[key] = (totals[key] ?? TokenCounts()).adding(bin.counts)
        }
        return totals.map { TokenBreakdown(id: $0.key, counts: $0.value) }.sorted {
            if $0.counts.total != $1.counts.total { return $0.counts.total > $1.counts.total }
            if $0.id.model != $1.id.model { return $0.id.model < $1.id.model }
            return $0.id.reasoning < $1.id.reasoning
        }
    }
}

public struct TokenActivityView: View {
    public let bins: [HourlyTokenUsage]
    public let now: Date
    @State private var selectedHour: Date?

    public init(bins: [HourlyTokenUsage], at now: Date) {
        self.bins = bins
        self.now = now
    }

    private var hours: [TokenHour] { TokenActivityData.hours(bins, at: now) }
    private var rows: [TokenBreakdown] {
        TokenActivityData.breakdown(bins, at: now, selectedHour: selectedHour)
    }

    public var body: some View {
        let timeline = hours
        let breakdown = rows
        let scale = max(1, Double(timeline.compactMap { $0.counts?.total }.max() ?? 0) * 1.12)
        let sum = timeline.reduce(TokenCounts()) { $0.adding($1.counts ?? TokenCounts()) }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tokens / hour").font(.system(size: 11, weight: .medium))
                Spacer()
                Text("\(compact(sum.total)) · 24h").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 5) {
                VStack {
                    Text(compact(Int64(scale))).lineLimit(1).minimumScaleFactor(0.7)
                    Spacer()
                    Text("0")
                }.font(.system(size: 8)).foregroundStyle(.secondary).frame(width: 34, height: 92, alignment: .trailing)
                VStack(spacing: 4) {
                    GeometryReader { geometry in
                        HStack(alignment: .bottom, spacing: 3) {
                            ForEach(timeline) { hour in
                                Button { selectedHour = selectedHour == hour.hour ? nil : hour.hour } label: {
                                    VStack(spacing: 0) {
                                        Spacer(minLength: 0)
                                        if let counts = hour.counts {
                                            if counts.total > 0 {
                                                Rectangle().fill(Color.orange)
                                                    .frame(height: geometry.size.height * Double(counts.output) / scale)
                                                Rectangle().fill(Color.blue)
                                                    .frame(height: geometry.size.height * Double(max(0, counts.input - counts.cachedInput)) / scale)
                                                Rectangle().fill(Color.teal.opacity(0.65))
                                                    .frame(height: geometry.size.height * Double(counts.cachedInput) / scale)
                                            } else {
                                                Rectangle().fill(Color.secondary).frame(height: 2)
                                            }
                                        } else {
                                            Text("–").font(.system(size: 9)).foregroundStyle(.secondary).frame(height: 5)
                                        }
                                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                                        .opacity(hour.hour == timeline.last?.hour ? 0.65 : 1)
                                        .background(selectedHour == hour.hour ? Color.primary.opacity(0.10) : Color.clear)
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain).help(detail(hour))
                                    .accessibilityLabel(detail(hour))
                            }
                        }
                    }.frame(height: 92)
                    HStack {
                        Text(timeline.first.map { time($0.hour) } ?? "")
                        Spacer()
                        Text(timeline.count > 12 ? time(timeline[12].hour) : "")
                        Spacer()
                        Text(timeline.last.map { time($0.hour) } ?? "")
                    }.font(.system(size: 8)).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                legend("New input", color: .blue)
                legend("Cached", color: .teal.opacity(0.65))
                legend("Output", color: .orange)
            }.help("Bar height is total input plus output. Cached input is part of input; reasoning tokens are part of output. The current hour is partial. Click a bar to filter the breakdown.")
            HStack {
                Text(selectedHour.map { "By model · \(time($0))" } ?? "By model · 24h")
                    .font(.system(size: 10, weight: .medium))
                Spacer()
                if selectedHour != nil {
                    Button("All 24h") { selectedHour = nil }.font(.system(size: 9)).buttonStyle(.borderless)
                }
            }
            HStack(spacing: 5) {
                Text("Model · reasoning").frame(maxWidth: .infinity, alignment: .leading)
                column("Input")
                column("Cached")
                column("Output")
            }.font(.system(size: 8)).foregroundStyle(.secondary)
            if breakdown.isEmpty {
                Text("—").font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 7) {
                        ForEach(breakdown) { row in
                            HStack(spacing: 5) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(row.id.model).font(.system(size: 10, weight: .medium))
                                        .lineLimit(1).truncationMode(.middle)
                                    Text(row.id.reasoning == "unknown" ? "Unspecified" : row.id.reasoning.capitalized)
                                        .font(.system(size: 9)).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                column(compact(row.counts.input))
                                column(compact(row.counts.cachedInput))
                                column(compact(row.counts.output))
                            }.font(.system(size: 9)).monospacedDigit()
                                .help("\(row.id.model) · reasoning \(row.id.reasoning). Input \(row.counts.input.formatted()), including \(row.counts.cachedInput.formatted()) cached; output \(row.counts.output.formatted()), including \(row.counts.reasoningOutput.formatted()) reasoning tokens.")
                        }
                    }.padding(.trailing, 2)
                }.frame(height: min(CGFloat(breakdown.count) * 34, 180))
            }
        }.onChange(of: timeline.first?.hour) { _ in
            if let selectedHour, !timeline.contains(where: { $0.hour == selectedHour }) { self.selectedHour = nil }
        }
    }

    private func column(_ value: String) -> some View {
        Text(value).frame(width: 48, alignment: .trailing).lineLimit(1).minimumScaleFactor(0.8)
    }

    private func legend(_ name: String, color: Color) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 6, height: 6)
            Text(name).font(.system(size: 8)).foregroundStyle(.secondary)
        }
    }

    private func detail(_ hour: TokenHour) -> String {
        let date = hour.hour.formatted(date: .abbreviated, time: .shortened)
        guard let c = hour.counts else { return "\(date): no recorded tokens in this hour. Click to filter the breakdown." }
        return "\(date): \(c.total.formatted()) tokens. Input \(c.input.formatted()), cached \(c.cachedInput.formatted()), output \(c.output.formatted()). Click to filter the breakdown."
    }

    private func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func compact(_ value: Int64) -> String {
        if value >= 1_000_000_000 { return String(format: "%.1fB", Double(value) / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000) }
        return String(value)
    }
}

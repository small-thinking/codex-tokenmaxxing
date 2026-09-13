import SwiftUI
import QuotaCore

public struct ResetCreditsView: View {
    public let bank: ResetCreditBank?
    public let now: Date
    public let stale: Bool

    public init(bank: ResetCreditBank?, now: Date, stale: Bool) {
        self.bank = bank
        self.now = now
        self.stale = stale
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Reset opportunities", systemImage: "ticket")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(bank.map { String($0.availableCount) } ?? "—")
                    .font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            if let bank {
                Text(stale ? "Last known available count · refresh needed" : "Available count from the latest reading")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                if bank.availableCredits.isEmpty {
                    Text(bank.availableCount == 0 ? "No reset opportunities available." : "Expiry details unavailable.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(bank.availableCredits.enumerated()), id: \.element.id) { index, credit in
                                creditRow(credit, number: index + 1)
                            }
                        }.padding(.trailing, 4)
                    }
                    .frame(height: min(CGFloat(bank.availableCredits.count) * 66, 190))
                    if bank.hasIncompleteDetails {
                        Text("Expiry details for \(bank.availableCredits.count) of \(bank.availableCount) opportunities.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                if bank.availableCredits.contains(where: { $0.isExpired(at: now) }) {
                    Text("An opportunity has expired. Refresh to confirm the available count.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Reset opportunity information unavailable.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func creditRow(_ credit: ResetCredit, number: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Reset \(number)").fontWeight(.medium)
                Spacer()
                Text(expiryText(credit)).foregroundStyle(.secondary)
            }.font(.system(size: 11))
            if let expiry = credit.expiresAt {
                Text("Expires \(expiry.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let fraction = credit.remainingValidityFraction(at: now) {
                HStack(spacing: 8) {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.15))
                            Capsule().fill(stale ? Color.gray : (fraction <= 0.2 ? .red : .teal))
                                .frame(width: geometry.size.width * fraction)
                        }
                    }.frame(height: 5)
                        .accessibilityLabel("Validity remaining")
                        .accessibilityValue(String(format: "%.0f percent", fraction * 100))
                    Text(String(format: "%.0f%% validity left", fraction * 100))
                        .font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary)
                }.accessibilityElement(children: .combine)
                    .help("Remaining time from grant to expiry. This is separate from the weekly reset countdown.")
            } else {
                Text("Validity progress unavailable").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }

    private func expiryText(_ credit: ResetCredit) -> String {
        guard let expiry = credit.expiresAt else { return "Expiry unknown" }
        guard expiry > now else { return "Expired" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: now, to: expiry).map { "\($0) left" } ?? "Expires soon"
    }
}

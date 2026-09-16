#if DEBUG
import AppKit
import SwiftUI
import QuotaCore
import LoginItemSupport
import TokenAccounting
import QuotaMenuUI

/// Deterministic production-view preview. Never connects to a live account.
@MainActor
func renderPreview(to path: String) {
    _ = NSApplication.shared
    let model = UsageModel(recordsHistory: false)
    let now = Date(timeIntervalSince1970: 1_800_000_600)
    model.now = now
    model.snapshot = WeeklySnapshot(usedPercent: 40, resetsAt: now.addingTimeInterval(241_920),
                                   windowDurationMins: 10_080, fetchedAt: now)
    if CommandLine.arguments.contains("--preview-near-reset") {
        model.snapshot = WeeklySnapshot(usedPercent: 40, resetsAt: now.addingTimeInterval(1),
                                       windowDurationMins: 10080, fetchedAt: now)
    }
    if CommandLine.arguments.contains("--preview-stale") {
        model.errorMessage = "Quota refresh unavailable."
    }
    model.resetCredits = ResetCreditBank(availableCount: 3, credits: [
        ResetCredit(id: "preview1", grantedAt: now.addingTimeInterval(-864_000), expiresAt: now.addingTimeInterval(86_400)),
        ResetCredit(id: "preview2", grantedAt: now.addingTimeInterval(-432_000), expiresAt: now.addingTimeInterval(432_000)),
        ResetCredit(id: "preview3", grantedAt: now.addingTimeInterval(-86_400), expiresAt: now.addingTimeInterval(864_000))
    ], fetchedAt: now)
    let hour = floor(now.timeIntervalSince1970 / 3_600) * 3_600
    let empty = CommandLine.arguments.contains("--preview-empty")
    model.historyBins = (0..<24).map { index in
        let missing = empty || index < 3 || index == 15
        let consumed: Double? = missing ? nil : [0, 0.15, 0.4, 0.9, 1.3, 0.7][index % 6]
        let attributed: Double? = missing ? nil : [0.05, 0.22, 0.48, 0.62, 0.35, 0.18][index % 6]
        let observed: Double = missing ? 0 : (index == 9 ? 900 : (index == 23 ? 300 : 3600))
        return HourlyQuotaBin(start: Date(timeIntervalSince1970: hour - Double(23 - index) * 3600),
                              consumedPercent: consumed, observedSeconds: observed,
                              expectedSeconds: index == 23 ? 600 : 3600,
                              attributedPercent: attributed,
                              attributionIsPartial: index == 9 || index == 23)
    }
    if !empty {
        model.pacePoints = (0..<43).filter { !(25...28).contains($0) }.map { index in
            let value = 0.55 + Double(index) * 0.015 + 0.12 * sin(Double(index) * 0.5)
            return PacePoint(date: Date(timeIntervalSince1970: hour - 21 * 3600 + Double(index) * 1800),
                             percentPerHour: value, connectsToPrevious: index != 0 && index != 29,
                             isEstimated: (12...18).contains(index),
                             estimatedConnection: (12...19).contains(index))
        }
    }
    let dark = CommandLine.arguments.contains("--preview-dark")
    let tokensOnly = CommandLine.arguments.contains("--preview-tokens")
    let summaryOnly = CommandLine.arguments.contains("--preview-token-summary")
    let root: AnyView
    if summaryOnly {
        root = AnyView(VStack(spacing: 16) {
            TokenUsageSummary(counts: TokenCounts(input: 7_200_000, cachedInput: 6_824_000,
                output: 50_000, total: 7_250_000))
            Divider()
            TokenUsageSummary(counts: TokenCounts())
            Divider()
            TokenUsageSummary(counts: nil)
        }.padding(16).frame(width: 340))
    } else if tokensOnly {
        var bins: [HourlyTokenUsage] = []
        let combinations = [("gpt-6-astra", "high"), ("gpt-6-astra", "medium"),
                            ("gpt-5.6-sol", "high"), ("gpt-5.6-sol", "low"), ("unknown", "unknown")]
        if !empty {
            for index in 3..<24 {
                for (group, pair) in combinations.enumerated() {
                    let input = Int64((index % 7 + 1) * (5 - group) * 95_000)
                    let output = Int64((index % 4 + 1) * (5 - group) * 4_000)
                    bins.append(HourlyTokenUsage(hour: Date(timeIntervalSince1970: hour - Double(23 - index) * 3_600),
                        model: pair.0, counts: TokenCounts(input: input, cachedInput: input * 4 / 5,
                            output: output, total: input + output), responses: 10, reasoningLevel: pair.1))
                }
            }
        }
        root = AnyView(VStack(alignment: .leading, spacing: 12) {
            Text("Local tokens").font(.system(size: 12, weight: .semibold))
            TokenActivityView(bins: bins, at: now)
            Button("Export CSV…") {}.font(.system(size: 9)).buttonStyle(.borderless)
        }.padding(16).frame(width: 340))
    } else {
        root = AnyView(OverviewView(model: model, loginItem: LoginItemModel(service: PreviewLoginItemService())))
    }
    let host = NSHostingView(rootView: root.environment(\.colorScheme, dark ? .dark : .light)
        .background(dark ? Color(white: 0.12) : Color.white))
    host.frame = NSRect(x: 0, y: 0, width: 340, height: summaryOnly ? 200 : (tokensOnly ? 450 : 606))
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        fputs("Cannot create preview bitmap\n", stderr); exit(1)
    }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fputs("Cannot render preview\n", stderr); exit(1)
    }
    do { try png.write(to: URL(fileURLWithPath: path)) }
    catch { fputs("Cannot save preview\n", stderr); exit(1) }
}
@MainActor
private final class PreviewLoginItemService: LoginItemService {
    var status: LoginItemStatus { .notRegistered }
    func register() throws {}
    func unregister() throws {}
    func openSettings() {}
}
#endif

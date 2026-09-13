#if DEBUG
import AppKit
import SwiftUI
import QuotaCore

/// Deterministic production-view preview. Never connects to a live account.
@MainActor
func renderPreview(to path: String) {
    _ = NSApplication.shared
    let model = UsageModel()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    model.now = now
    model.snapshot = WeeklySnapshot(usedPercent: 40, resetsAt: now.addingTimeInterval(241_920),
                                   windowDurationMins: 10_080, fetchedAt: now)
    model.resetCredits = ResetCreditBank(availableCount: 3, credits: [
        ResetCredit(id: "preview1", grantedAt: now.addingTimeInterval(-864_000), expiresAt: now.addingTimeInterval(86_400)),
        ResetCredit(id: "preview2", grantedAt: now.addingTimeInterval(-432_000), expiresAt: now.addingTimeInterval(432_000)),
        ResetCredit(id: "preview3", grantedAt: now.addingTimeInterval(-86_400), expiresAt: now.addingTimeInterval(864_000))
    ], fetchedAt: now)
    let dark = CommandLine.arguments.contains("--preview-dark")
    let host = NSHostingView(rootView: OverviewView(model: model).environment(\.colorScheme, dark ? .dark : .light)
        .background(dark ? Color(white: 0.12) : Color.white))
    host.frame = NSRect(x: 0, y: 0, width: 340, height: 620)
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
#endif

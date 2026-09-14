import AppKit
import SwiftUI
import Combine
import Network
import QuotaCore
import CodexConnection
import QuotaMenuUI
import LoginItemSupport

@main
struct QuotaMenuMain {
    @MainActor static func main() {
        if handleLoginItemDiagnostic() { return }
        #if DEBUG
        if let option = CommandLine.arguments.first(where: { $0.hasPrefix("--render-preview=") }) {
            renderPreview(to: String(option.dropFirst("--render-preview=".count)))
            return
        }
        #endif
        if CommandLine.arguments.contains("--check") || CommandLine.arguments.contains("--check-resets") {
            Task {
                let connection = CodexConnection()
                do {
                    let usage = try await connection.readUsage()
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    if CommandLine.arguments.contains("--check-resets") {
                        let bank = usage.resetCredits
                        let diagnostic = ResetCheck(availableCount: bank?.availableCount,
                            detailCount: bank?.availableCredits.count,
                            expiryDates: bank?.availableCredits.compactMap(\.expiresAt) ?? [])
                        print(String(decoding: try encoder.encode(diagnostic), as: UTF8.self))
                    } else {
                        print(String(decoding: try encoder.encode(usage.weekly), as: UTF8.self))
                    }
                    await connection.stop()
                    try? await Task.sleep(nanoseconds: 1_100_000_000)
                    exit(0)
                } catch {
                    fputs("\(error.localizedDescription)\n", stderr)
                    await connection.stop()
                    try? await Task.sleep(nanoseconds: 1_100_000_000)
                    exit(1)
                }
            }
            dispatchMain()
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}

private struct ResetCheck: Encodable {
    let availableCount: Int?
    let detailCount: Int?
    let expiryDates: [Date]
}

@MainActor
final class UsageModel: ObservableObject {
    @Published var snapshot: WeeklySnapshot?
    @Published var resetCredits: ResetCreditBank?
    @Published var historyBins: [HourlyQuotaBin] = []
    @Published var pacePoints: [PacePoint] = []
    @Published var historyMessage: String?
    private let historyStoreTask: Task<QuotaHistoryStore, Error>?
    private var historyAccountKey: String?
    @Published var now = Date()
    @Published var isRefreshing = false
    @Published var errorMessage: String?
    let connection = CodexConnection()
    let tokens: TokenUsageModel
    private var nextRefresh = Date.distantPast
    private var failures = 0
    private var refreshTask: Task<Void, Never>?
    private var stopping = false
    private var needsHistoryPause = false

    init(recordsHistory: Bool = true) {
        tokens = TokenUsageModel(enabled: recordsHistory)
        historyStoreTask = recordsHistory ? Task.detached(priority: .utility) { try QuotaHistoryStore() } : nil
    }

    var isStale: Bool { snapshot.map { $0.isStale(at: now) || errorMessage != nil } ?? false }
    var percentText: String { snapshot.map { String(format: "%.0f%%", $0.remainingPercent) } ?? "—" }
    var timePercentText: String {
        snapshot?.remainingTimeFraction(at: now).map { String(format: "%.0f%%", $0 * 100) } ?? "—"
    }
    var paceText: String {
        guard !isStale, let gap = snapshot?.paceGap(at: now) else { return "Pace unavailable until a fresh reading" }
        if abs(gap) < 1 { return "On pace" }
        return String(format: "%@ · %.0f%%", gap > 0 ? "Under pace" : "Over pace", abs(gap))
    }
    var countdown: String {
        guard let reset = snapshot?.resetsAt else { return "Reset time unavailable" }
        guard reset > now else { return "Waiting for reset update" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: now, to: reset).map { "Resets in \($0)" } ?? "Resetting soon"
    }

    func tick(popoverOpen: Bool) {
        now = Date()
        if now >= nextRefresh { refresh() }
        else if popoverOpen, failures == 0, let snapshot, now.timeIntervalSince(snapshot.fetchedAt) >= 60 {
            refresh()
        }
        if !isRefreshing { Task { [weak self] in await self?.reloadHistoryBins() } }
    }

    func opened() {
        now = Date()
        if snapshot == nil || now.timeIntervalSince(snapshot!.fetchedAt) >= 60 { refresh() }
    }

    func prepareForSleep() {
        needsHistoryPause = true
    }

    func woke() async {
        // Finish any pre-sleep request before forcing a fresh post-wake reading.
        needsHistoryPause = true
        await refreshTask?.value
        needsHistoryPause = true
        now = Date()
        refresh()
    }

    func refresh() {
        guard !isRefreshing, !stopping else { return }
        isRefreshing = true
        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await connection.readUsage()
                guard !stopping else { return }
                snapshot = result.weekly
                resetCredits = result.resetCredits
                if historyAccountKey != result.accountKey {
                    historyBins = []
                    pacePoints = []
                    historyMessage = nil
                    historyAccountKey = result.accountKey
                }
                errorMessage = nil
                failures = 0
                nextRefresh = Date().addingTimeInterval(300)
                if let reset = result.weekly.resetsAt, reset > Date() { nextRefresh = min(nextRefresh, reset) }
                if let expiry = result.resetCredits?.availableCredits.compactMap(\.expiresAt)
                    .filter({ $0 > Date() }).min() {
                    nextRefresh = min(nextRefresh, expiry)
                }
                await recordHistory(result)
                await tokens.recordQuota(result)
            } catch {
                guard !stopping else { return }
                if let error = error as? ConnectionError, error == .signInRequired || error == .accountChanged {
                    snapshot = nil
                    resetCredits = nil
                    historyAccountKey = nil
                    historyBins = []
                    pacePoints = []
                    historyMessage = nil
                    if let store = try? await historyStoreTask?.value { await store.breakContinuity() }
                }
                errorMessage = error.localizedDescription
                failures += 1
                nextRefresh = Date().addingTimeInterval(min(900, 60 * pow(2, Double(min(failures - 1, 4)))))
            }
            now = Date()
            isRefreshing = false
        }
    }

    private func recordHistory(_ usage: UsageSnapshot) async {
        guard historyStoreTask != nil else { return }
        guard usage.accountKey != nil else {
            historyMessage = "Activity unavailable for this account reading."
            return
        }
        do {
            guard let store = try await historyStoreTask?.value else { return }
            if needsHistoryPause {
                needsHistoryPause = false
                await store.pauseForSleep()
            }
            historyMessage = store.loadWarning
            do { try await store.record(usage) }
            catch { historyMessage = "History could not be saved; recent activity is in memory." }
            await reloadHistoryBins()
        } catch {
            historyMessage = "Activity history unavailable."
        }
    }

    private func reloadHistoryBins() async {
        guard !stopping, let key = historyAccountKey else { return }
        let date = Date()
        guard let store = try? await historyStoreTask?.value else { return }
        let bins = await store.bins(accountKey: key, at: date)
        let points = await store.pacePoints(accountKey: key, at: date)
        guard !stopping, historyAccountKey == key else { return }
        historyBins = bins
        pacePoints = points
    }

    func stop() async {
        stopping = true
        tokens.stop()
        refreshTask?.cancel()
        await connection.stop()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = UsageModel()
    private let loginItem = LoginItemModel(service: NativeLoginItemService())
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var observation: AnyCancellable?
    private var statusUpdatePending = false
    private var lastIconState: IconState?

    private struct IconState: Equatable {
        let snapshot: WeeklySnapshot?
        let date: Date
        let stale: Bool
        let dark: Bool
    }
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private let network = NWPathMonitor()
    private var wasOffline = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Finder relaunches normally reuse an instance; guard direct binary launches as well.
        let siblings = NSRunningApplication.runningApplications(withBundleIdentifier: "com.small-thinking.codex-tokenmaxxing")
        if siblings.contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil)
            return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            // effectiveAppearance KVO can fire during AppKit's own status-item
            // snapshot rendering. Mutating the image from that callback loops forever.
            // Resolve appearance on the existing 30-second tick instead.
        }
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 340, height: 606)
        popover.contentViewController = NSHostingController(rootView: OverviewView(model: model, loginItem: loginItem))
        observation = model.objectWillChange.sink { [weak self] in
            guard let self, !self.statusUpdatePending else { return }
            self.statusUpdatePending = true
            DispatchQueue.main.async { [weak self] in
                self?.statusUpdatePending = false
                self?.updateStatusItem()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.model.tick(popoverOpen: self.popover.isShown)
            }
        }
        timer?.tolerance = 5
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.model.prepareForSleep() } }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in await self?.model.woke() } }
        network.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                if path.status == .satisfied, self.wasOffline { self.model.refresh() }
                self.wasOffline = path.status != .satisfied
            }
        }
        network.start(queue: DispatchQueue(label: "com.small-thinking.codex-tokenmaxxing.network"))
        updateStatusItem()
        model.tokens.start()
        model.refresh()
        if !UserDefaults.standard.bool(forKey: "hasShownWelcome") {
            UserDefaults.standard.set(true, forKey: "hasShownWelcome")
            DispatchQueue.main.async { [weak self] in self?.togglePopover() }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        loginItem.refresh()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !popover.isShown { togglePopover() }
        return true
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            loginItem.refresh()
            model.opened()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let appearance = button.effectiveAppearance
        let state = IconState(snapshot: model.snapshot, date: model.now, stale: model.isStale,
                              dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        if lastIconState != state {
            lastIconState = state
            button.image = RingIcon.image(snapshot: model.snapshot, at: model.now, stale: model.isStale,
                                          appearance: appearance)
        }
        let title = " " + model.percentText + (model.isStale ? " ·" : "")
        if button.title != title { button.title = title }
        let status = model.isStale ? "Last known reading. " : ""
        let tooltip = "\(status)Weekly quota: \(model.percentText) remaining. \(model.countdown). Outer ring: quota remaining. Inner ring: \(model.timePercentText) of the weekly time remains. \(model.paceText)."
        if button.toolTip != tooltip { button.toolTip = tooltip }
        button.setAccessibilityLabel("Codex weekly quota, \(model.percentText) remaining\(model.isStale ? ", stale" : "")")
        button.setAccessibilityHelp(button.toolTip)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        timer?.invalidate()
        network.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        Task {
            await model.stop()
            // Give the owned child's termination fallback time to finish before our process exits.
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

import AppKit
import Foundation
import TokenAccounting
import QuotaCore
import UniformTypeIdentifiers

@MainActor
final class TokenUsageModel: ObservableObject {
    @Published var report: TokenUsageReport?
    @Published var message: String?
    @Published var exporting = false
    @Published var lastScannedAt: Date?
    private let storeTask: Task<TokenUsageStore, Error>?
    private let audit = QuotaAuditStore()
    private var collection: Task<Void, Never>?

    init(enabled: Bool = true) {
        storeTask = enabled ? Task.detached(priority: .utility) { try TokenUsageStore() } : nil
    }

    func start() {
        guard collection == nil, let storeTask else { return }
        collection = Task { [weak self] in
            while !Task.isCancelled {
                let started = Date()
                var delay: TimeInterval = 300
                do {
                    let store = try await storeTask.value
                    let report = try await store.scan(at: Date(), byteBudget: 8 * 1024 * 1024)
                    guard !Task.isCancelled else { break }
                    self?.report = report
                    self?.lastScannedAt = Date()
                    self?.message = report.warning
                    // Initial import is bounded and yields between batches. A slow batch
                    // gets proportionally more rest, limiting this worker's CPU duty cycle.
                    if report.catchingUp { delay = max(2, Date().timeIntervalSince(started) * 19) }
                } catch {
                    self?.message = "Token history unavailable: \(error.localizedDescription)"
                }
                do { try await Task.sleep(nanoseconds: UInt64(min(delay, 300) * 1_000_000_000)) }
                catch { break }
            }
        }
    }

    func recordQuota(_ usage: UsageSnapshot) async {
        do { try await audit.record(usage) }
        catch { message = "Quota audit could not be saved." }
    }

    func stop() { collection?.cancel(); collection = nil }

    func export() {
        guard !exporting, let storeTask else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "codex-usage-evidence.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exporting = true
        Task {
            defer { exporting = false }
            do {
                let store = try await storeTask.value
                let report = await store.report(at: Date())
                let quota = try await audit.exportCSVRows()
                let lastScan = lastScannedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown"
                let export = Task.detached(priority: .utility) {
                    let formatter = ISO8601DateFormatter()
                    let header = "record_type,timestamp_utc,model,input_tokens,cached_input_tokens,cache_write_input_tokens,output_tokens,reasoning_output_tokens,total_tokens,quota_used_percent,reset_utc,account_partition"
                    var rows = [header]
                    for bin in report.bins {
                        let c = bin.counts
                        let model = "\"" + bin.model.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                        rows.append("tokens,\(formatter.string(from: bin.hour)),\(model),\(c.input),\(c.cachedInput),\(c.cacheWriteInput),\(c.output),\(c.reasoningOutput),\(c.total),,,")
                    }
                    if !quota.isEmpty { rows.append(quota) }
                    // Include scope/coverage in the same file so partial imports cannot
                    // be mistaken for complete usage when the CSV is moved elsewhere.
                    rows.append("coverage,\(formatter.string(from: Date())),\"local modern response records only; last_scan=\(lastScan); import_partial=\(report.catchingUp); legacy_files=\(report.legacyFiles); no guaranteed account/billing match\",,,,,,,,,")
                    try (rows.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                }
                try await export.value
            } catch { message = "Export failed: \(error.localizedDescription)" }
        }
    }
}

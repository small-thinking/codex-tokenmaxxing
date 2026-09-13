import Foundation
import LoginItemSupport

/// Early exit: these commands never construct the quota model, read history or launch Codex.
@MainActor
func handleLoginItemDiagnostic() -> Bool {
    let commands = CommandLine.arguments.filter {
        ["--login-item-status", "--login-item-enable", "--login-item-disable"].contains($0)
    }
    guard !commands.isEmpty else { return false }
    guard commands.count == 1 else {
        fputs("Choose one login-item diagnostic command.\n", stderr)
        exit(1)
    }
    guard Bundle.main.bundleIdentifier == "com.small-thinking.codex-tokenmaxxing",
          Bundle.main.bundleURL.pathExtension == "app" else {
        fputs("Run this command using the installed Codex Tokenmaxxing.app executable.\n", stderr)
        exit(1)
    }
    let model = LoginItemModel(service: NativeLoginItemService())
    let command = commands[0]
    if command == "--login-item-enable" {
        // Diagnostics report pending consent; only a user-facing Settings button opens that app.
        if model.status != .requiresApproval { model.setEnabled(true) }
    } else if command == "--login-item-disable" { model.setEnabled(false) }
    struct Result: Encodable {
        let status: LoginItemStatus
        let enabled: Bool
        let message: String?
    }
    let result = Result(status: model.status, enabled: model.isEnabled,
                        message: model.errorMessage ?? model.statusMessage)
    do { print(String(decoding: try JSONEncoder().encode(result), as: UTF8.self)) }
    catch { fputs("Cannot encode login-item status.\n", stderr); exit(1) }
    if model.errorMessage != nil { exit(1) }
    if command == "--login-item-enable", !model.isEnabled { exit(2) }
    if command == "--login-item-disable", model.status != .notRegistered { exit(2) }
    return true
}

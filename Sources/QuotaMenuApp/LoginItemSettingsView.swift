import SwiftUI
import LoginItemSupport

struct LoginItemSettingsView: View {
    @ObservedObject var model: LoginItemModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Toggle("Launch at login", isOn: Binding(get: { model.isEnabled }, set: { model.setEnabled($0) }))
                    .toggleStyle(.switch).controlSize(.mini)
                    .help("Open Codex Tokenmaxxing automatically when you sign in to this Mac.")
                if model.status == .requiresApproval {
                    Button("Settings…") { model.openSettings() }.buttonStyle(.borderless)
                }
            }
            if let message = model.errorMessage ?? model.statusMessage {
                Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.font(.system(size: 10))
    }
}

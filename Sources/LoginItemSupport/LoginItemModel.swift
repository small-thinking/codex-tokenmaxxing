import Combine
import Foundation
import ServiceManagement

public enum LoginItemStatus: String, Encodable, Sendable {
    case notRegistered, enabled, requiresApproval, notFound, unknown
}

@MainActor
public protocol LoginItemService: AnyObject {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSettings()
}

@MainActor
public final class NativeLoginItemService: LoginItemService {
    public init() {}
    public var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }
    public func register() throws { try SMAppService.mainApp.register() }
    public func unregister() throws { try SMAppService.mainApp.unregister() }
    public func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// System state is authoritative; no separate preference can drift from Login Items settings.
@MainActor
public final class LoginItemModel: ObservableObject {
    @Published public private(set) var status: LoginItemStatus
    @Published public private(set) var errorMessage: String?
    private let service: any LoginItemService

    public init(service: any LoginItemService) {
        self.service = service
        status = service.status
    }

    public var isEnabled: Bool { status == .enabled }
    public var statusMessage: String? {
        switch status {
        case .requiresApproval: return "Allow this app in System Settings to start at login."
        case .notFound: return "Login item unavailable. Open the installed app and try again."
        case .unknown: return "Login item status unavailable."
        default: return nil
        }
    }

    public func refresh() {
        let current = service.status
        if current != status { errorMessage = nil }
        status = current
    }

    public func setEnabled(_ enabled: Bool) {
        refresh()
        errorMessage = nil
        // Enabling a denied registration needs explicit system approval, not another registration.
        if enabled, status == .requiresApproval {
            service.openSettings()
            return
        }
        if (enabled && status == .enabled) || (!enabled && status == .notRegistered) { return }
        do {
            if enabled { try service.register() }
            else { try service.unregister() }
        } catch {
            errorMessage = "Could not \(enabled ? "enable" : "disable") launch at login: \(error.localizedDescription)"
        }
        status = service.status
    }

    public func openSettings() { service.openSettings() }
}

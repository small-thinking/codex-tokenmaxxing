import Foundation
import LoginItemSupport

struct LoginItemTests {
    @MainActor
    func initialStateAndExternalChangesAreReadOnly() throws {
        for state: LoginItemStatus in [.notRegistered, .enabled, .requiresApproval, .notFound, .unknown] {
            let service = FakeLoginItemService(status: state)
            let model = LoginItemModel(service: service)
            try expect(model.status == state)
            try expect(model.isEnabled == (state == .enabled))
            try expect(service.registrations == 0 && service.unregistrations == 0 && service.settingsOpened == 0)
            service.status = .enabled
            model.refresh()
            try expect(model.isEnabled, "Changes made in System Settings must be reflected")
            service.status = .notRegistered
            model.refresh()
            try expect(!model.isEnabled)
        }
    }

    @MainActor
    func registrationApprovalAndErrorsReflectSystemState() throws {
        let service = FakeLoginItemService(status: .notRegistered)
        let model = LoginItemModel(service: service)
        model.setEnabled(true)
        try expect(model.isEnabled && service.registrations == 1)
        model.setEnabled(true)
        try expect(service.registrations == 1, "Already enabled must not register again")
        model.setEnabled(false)
        try expect(!model.isEnabled && service.unregistrations == 1)
        model.setEnabled(false)
        try expect(service.unregistrations == 1)

        service.registrationResult = .requiresApproval
        model.setEnabled(true)
        try expect(model.status == .requiresApproval && !model.isEnabled)
        try expect(model.statusMessage != nil && service.settingsOpened == 0)
        model.setEnabled(true)
        try expect(service.registrations == 2 && service.settingsOpened == 1,
                   "Pending approval opens settings without another registration")
        model.setEnabled(false)
        try expect(model.status == .notRegistered && service.unregistrations == 2)

        service.error = NSError(domain: "LoginItemTests", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "Test denied"])
        model.setEnabled(true)
        try expect(!model.isEnabled && model.errorMessage?.contains("Test denied") == true)
        service.status = .enabled
        model.refresh()
        try expect(model.isEnabled && model.errorMessage == nil)
        model.setEnabled(false)
        try expect(model.isEnabled && model.errorMessage != nil,
                   "A failed unregister must not pretend launch at login is disabled")
    }
}

@MainActor
private final class FakeLoginItemService: LoginItemService {
    var status: LoginItemStatus
    var registrationResult: LoginItemStatus = .enabled
    var error: Error?
    var registrations = 0
    var unregistrations = 0
    var settingsOpened = 0

    init(status: LoginItemStatus) { self.status = status }
    func register() throws {
        registrations += 1
        if let error { throw error }
        status = registrationResult
    }
    func unregister() throws {
        unregistrations += 1
        if let error { throw error }
        status = .notRegistered
    }
    func openSettings() { settingsOpened += 1 }
}

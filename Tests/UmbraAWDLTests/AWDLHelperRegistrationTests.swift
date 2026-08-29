import Foundation
import Testing
@testable import UmbraAWDL

@MainActor
@Suite("AWDL helper registration")
struct AWDLHelperRegistrationTests {
    @Test("registration crosses the authorization boundary exactly once")
    func registrationIsAttemptedOnce() throws {
        let suite = "AWDLHelperRegistrationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = RecordingAppService(status: .requiresApproval)
        let manager = AWDLHelperRegistrationManager(
            service: service,
            defaults: defaults,
            registrationGeneration: "1"
        )

        #expect(try manager.requestRegistrationOnce() == .requiresApproval)
        #expect(service.registerCount == 1)
        #expect(manager.registrationWasAttempted)
        #expect(throws: AWDLHelperError.registrationAlreadyAttempted) {
            try manager.requestRegistrationOnce()
        }
        let relaunchedManager = AWDLHelperRegistrationManager(
            service: service,
            defaults: defaults,
            registrationGeneration: "1"
        )
        #expect(throws: AWDLHelperError.registrationAlreadyAttempted) {
            try relaunchedManager.requestRegistrationOnce()
        }
        #expect(service.registerCount == 1)
    }

    @Test("status checks never register or prompt")
    func statusIsReadOnly() throws {
        let suite = "AWDLHelperRegistrationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = RecordingAppService(status: .enabled)
        let manager = AWDLHelperRegistrationManager(
            service: service,
            defaults: defaults,
            registrationGeneration: "1"
        )

        #expect(manager.status == .enabled)
        #expect(manager.status == .enabled)
        #expect(service.registerCount == 0)
        #expect(!manager.registrationWasAttempted)
    }

    @Test("revoked approval fails capability without reaching XPC")
    func revokedApprovalFailsExplicitly() async {
        let client = AWDLPrivilegedHelperClient(
            capabilityChecker: RejectingCapabilityChecker()
        )
        await #expect(throws: AWDLHelperError.unavailable("approval revoked")) {
            try await client.status()
        }
    }
}

private struct RejectingCapabilityChecker: AWDLHelperCapabilityChecking {
    func requireEnabled() throws {
        throw AWDLHelperError.unavailable("approval revoked")
    }
}

@MainActor
private final class RecordingAppService: AWDLAppServiceRegistering {
    var status: AWDLHelperRegistrationStatus
    private(set) var registerCount = 0

    init(status: AWDLHelperRegistrationStatus) { self.status = status }
    func register() throws { registerCount += 1 }
}

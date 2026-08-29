import Foundation
import XCTest
import UmbraAWDL
import UmbraCore
import UmbraServices
@testable import UmbraIntegration

final class AWDLStreamLifecycleCoordinatorTests: XCTestCase {
    func testLifecycleChecksCapabilityThenUsesOneLeaseUntilPresentationEnds() async throws {
        let helper = RecordingAWDLHelper()
        let lifecycle = AWDLStreamLifecycleCoordinator(helper: helper)
        let bootstrap = try makeBootstrap()

        try await lifecycle.prepare(for: bootstrap)
        try await lifecycle.commitStreaming(for: bootstrap)
        await lifecycle.finishPresentation()
        await lifecycle.finish()

        let calls = await helper.calls
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls[0], .status)
        guard case .down(let lease) = calls[1] else {
            return XCTFail("Expected an AWDL down lease")
        }
        XCTAssertEqual(calls[2], .up(lease))
    }

    func testUnavailableHelperFailsBeforeAStreamCanCommit() async throws {
        let helper = RecordingAWDLHelper(error: .unavailable("approval revoked"))
        let lifecycle = AWDLStreamLifecycleCoordinator(helper: helper)

        do {
            try await lifecycle.prepare(for: makeBootstrap())
            XCTFail("Expected helper capability failure")
        } catch {
            XCTAssertEqual(error as? AWDLHelperError, .unavailable("approval revoked"))
        }
        let calls = await helper.calls
        XCTAssertEqual(calls, [.status])
    }

    func testLaterCommitFailureRestoresAWDLDuringStartupRollback() async throws {
        let helper = RecordingAWDLHelper()
        let awdl = AWDLStreamLifecycleCoordinator(helper: helper)
        let lifecycle = CompositeStreamSessionLifecycleCoordinator([
            awdl,
            CommitFailingLifecycle(),
        ])
        let bootstrap = try makeBootstrap()

        try await lifecycle.prepare(for: bootstrap)
        do {
            try await lifecycle.commitStreaming(for: bootstrap)
            XCTFail("Expected a later lifecycle commit to fail")
        } catch {
            XCTAssertEqual(error as? AWDLHelperError, .operationFailed("injected"))
        }

        let calls = await helper.calls
        guard calls.count == 3,
              case .down(let lease) = calls[1] else {
            return XCTFail("Expected status, down, and rollback up")
        }
        XCTAssertEqual(calls, [.status, .down(lease), .up(lease)])
    }

    private func makeBootstrap() throws -> StreamBootstrap {
        var host = StreamHost(
            uuid: "host-awdl",
            name: "Host",
            activeAddress: NetworkEndpoint(hostname: "10.0.0.2")
        )
        let application = StreamApplication(id: 1, name: "Desktop")
        host.applications = [application]
        return try StreamBootstrap(
            sessionID: UUID(),
            host: host,
            application: application,
            preferences: .default,
            rtspSessionURL: URL(string: "rtsp://10.0.0.2/session"),
            remoteInputCredentials: RemoteInputCredentials(
                key: Data(0..<16),
                initializationVector: Data(16..<32)
            )
        )
    }
}

private struct CommitFailingLifecycle: StreamSessionLifecycleCoordinating {
    func prepare(for bootstrap: StreamBootstrap) async throws {}
    func commitStreaming(for bootstrap: StreamBootstrap) async throws {
        throw AWDLHelperError.operationFailed("injected")
    }
    func finish() async {}
}

private actor RecordingAWDLHelper: AWDLPrivilegedHelperControlling {
    enum Call: Equatable {
        case status
        case down(String)
        case up(String)
    }

    private(set) var calls: [Call] = []
    private let error: AWDLHelperError?

    init(error: AWDLHelperError? = nil) { self.error = error }

    func status() throws -> AWDLHelperStatus {
        calls.append(.status)
        if let error { throw error }
        return AWDLHelperStatus(interfaceState: .up, leaseIdentifier: nil, priorState: nil)
    }

    func down(leaseIdentifier: String) throws -> AWDLHelperStatus {
        calls.append(.down(leaseIdentifier))
        if let error { throw error }
        return AWDLHelperStatus(
            interfaceState: .down,
            leaseIdentifier: leaseIdentifier,
            priorState: .up
        )
    }

    func up(leaseIdentifier: String) throws -> AWDLHelperStatus {
        calls.append(.up(leaseIdentifier))
        if let error { throw error }
        return AWDLHelperStatus(interfaceState: .up, leaseIdentifier: nil, priorState: nil)
    }
}

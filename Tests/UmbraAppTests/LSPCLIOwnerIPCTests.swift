import Darwin
import Foundation
import XCTest
@testable import UmbraApp

final class LSPCLIOwnerIPCTests: XCTestCase {
    func testSameUserBoundedOwnerEndpointRoutesOnlyMatchingHost() async throws {
        let hostID = UUID()
        let endpoint = try LSPCLIOwnerEndpoint(hostID: hostID) { request in
            guard request.hostID == hostID, request.command == .telemetry else {
                return .init(error: "mismatch", stopKind: nil, telemetry: nil)
            }
            return .init(
                error: nil,
                stopKind: nil,
                telemetry: .init(
                    lifecycle: "authenticated",
                    receivedDatagrams: 10,
                    transmittedDatagrams: 20,
                    droppedDatagrams: 1,
                    authenticationFailures: 0,
                    currentUDPPayloadSize: 1_400,
                    reconnectPhase: nil
                )
            )
        }
        defer { endpoint.stop() }

        let response = try await LSPCLIOwnerEndpoint.request(
            hostID: hostID,
            command: .telemetry
        )
        XCTAssertEqual(response.telemetry?.receivedDatagrams, 10)
        var parentStatus = stat()
        let parent = "/tmp/umbra-lsp-owner-\(geteuid())"
        XCTAssertEqual(lstat(parent, &parentStatus), 0)
        XCTAssertEqual(parentStatus.st_mode & 0o077, 0)
        var socketStatus = stat()
        let socket = "\(parent)/\(hostID.uuidString.lowercased()).sock"
        XCTAssertEqual(lstat(socket, &socketStatus), 0)
        XCTAssertEqual(socketStatus.st_mode & 0o077, 0)
    }

    func testResponseSentHandlerRunsOnlyAfterReplyIsWritableToClient() async throws {
        let hostID = UUID()
        let gate = OwnerResponseSentGate()
        let endpoint = try LSPCLIOwnerEndpoint(
            hostID: hostID,
            handler: { _ in
                .init(error: nil, stopKind: "stopped", telemetry: nil)
            },
            responseSentHandler: { _, _ in
                await gate.enterAndWait()
            }
        )
        defer { endpoint.stop() }

        let request = Task {
            try await LSPCLIOwnerEndpoint.request(hostID: hostID, command: .stop)
        }
        await gate.waitUntilEntered()

        let response = try await request.value
        XCTAssertEqual(response.stopKind, "stopped")
        await gate.open()
    }
}

private actor OwnerResponseSentGate {
    private var entered = false
    private var isOpen = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func open() {
        isOpen = true
        let waiters = openWaiters
        openWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

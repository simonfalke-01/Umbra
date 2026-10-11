import Darwin
import Foundation
import UmbraCLIExecution
import XCTest
@testable import UmbraApp

final class LSPCLIOwnerIPCTests: XCTestCase {
    func testSameUserBoundedOwnerEndpointRoutesOnlyMatchingHost() async throws {
        let hostID = UUID()
        let timing: (UInt64) -> CLILSPTimingDistribution = { value in
            .init(
                boundedWindowSampleCount: Int(value),
                p50Microseconds: value * 10,
                p95Microseconds: value * 20,
                p99Microseconds: value * 30,
                maximumMicroseconds: value * 40,
                measurementDrops: value * 2,
                clockDomain: value.isMultiple(of: 2)
                    ? "client-monotonic/kernel-timestamped" : "client-monotonic"
            )
        }
        let expected = CLILSPTelemetry(
            lifecycle: "authenticated",
            receivedDatagrams: 10,
            transmittedDatagrams: 20,
            droppedDatagrams: 1,
            authenticationFailures: 0,
            currentUDPPayloadSize: 1_400,
            reconnectPhase: nil,
            completeFrameReceiveToVideoToolboxSubmit: timing(1),
            videoToolboxSubmitToDecodeCompletion: timing(2),
            completeFrameReceiveToMetalEnqueue: timing(3),
            metalEnqueueToCommit: timing(4),
            audioReceiveToDecode: timing(5),
            audioDecodeAndRenderEnqueue: timing(6),
            audioUnderruns: 0,
            audioRebuffers: nil,
            audioAcceptedPackets: 120,
            audioPlayedPackets: 117,
            audioDroppedPackets: 2,
            audioRejectedPackets: 1,
            audioCallbackCount: 130,
            audioCallbackError: -66_632,
            audioNonSilentPackets: 119,
            audioQueuedMilliseconds: 30
        )
        let endpoint = try LSPCLIOwnerEndpoint(hostID: hostID) { request in
            guard request.hostID == hostID, request.command == .telemetry else {
                return .init(error: "mismatch", stopKind: nil, telemetry: nil)
            }
            return .init(
                error: nil,
                stopKind: nil,
                telemetry: .init(expected)
            )
        }
        defer { endpoint.stop() }

        let response = try await LSPCLIOwnerEndpoint.request(
            hostID: hostID,
            command: .telemetry
        )
        let telemetry = try XCTUnwrap(response.telemetry?.cliValue)
        XCTAssertEqual(telemetry, expected)
        XCTAssertTrue(telemetry.commandLineOutput.contains(
            "lsp.media.complete_frame_receive_to_videotoolbox_submit.bounded_window_samples=1\n"
        ))
        XCTAssertTrue(telemetry.commandLineOutput.contains(
            "lsp.media.videotoolbox_submit_to_decode_completion.clock_domain="
                + "client-monotonic/kernel-timestamped\n"
        ))
        XCTAssertTrue(telemetry.commandLineOutput.contains("lsp.media.audio_underruns=0\n"))
        XCTAssertTrue(telemetry.commandLineOutput.contains("lsp.media.audio_rebuffers=unavailable\n"))
        XCTAssertTrue(telemetry.commandLineOutput.contains("lsp.media.audio_non_silent_packets=119\n"))
        XCTAssertTrue(telemetry.commandLineOutput.contains("lsp.media.audio_callback_error=-66632\n"))
        var parentStatus = stat()
        let parent = "/tmp/umbra-lsp-owner-\(geteuid())"
        XCTAssertEqual(lstat(parent, &parentStatus), 0)
        XCTAssertEqual(parentStatus.st_mode & 0o077, 0)
        var socketStatus = stat()
        let socket = "\(parent)/\(hostID.uuidString.lowercased()).sock"
        XCTAssertEqual(lstat(socket, &socketStatus), 0)
        XCTAssertEqual(socketStatus.st_mode & 0o077, 0)
        var ownershipStatus = stat()
        let ownership = "\(parent)/\(hostID.uuidString.lowercased()).lock"
        XCTAssertEqual(lstat(ownership, &ownershipStatus), 0)
        XCTAssertEqual(ownershipStatus.st_uid, geteuid())
        XCTAssertEqual(ownershipStatus.st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(ownershipStatus.st_mode & 0o077, 0)
    }

    func testSecondOwnerIsRejectedWithoutReplacingOriginalEndpoint() async throws {
        let hostID = UUID()
        let endpoint = try LSPCLIOwnerEndpoint(hostID: hostID) { _ in
            .init(
                error: nil,
                stopKind: nil,
                telemetry: Self.telemetry(lifecycle: "original")
            )
        }
        defer { endpoint.stop() }

        XCTAssertThrowsError(
            try LSPCLIOwnerEndpoint(hostID: hostID) { _ in
                .init(
                    error: nil,
                    stopKind: nil,
                    telemetry: Self.telemetry(lifecycle: "replacement")
                )
            }
        ) { error in
            guard case LSPCLIOwnerIPCError.ownerAlreadyRunning = error else {
                return XCTFail("Unexpected second-owner error: \(error)")
            }
        }

        let response = try await LSPCLIOwnerEndpoint.request(hostID: hostID, command: .telemetry)
        XCTAssertEqual(response.telemetry?.lifecycle, "original")
    }

    func testStoppedOwnerCannotRemoveSuccessorEndpoint() async throws {
        let hostID = UUID()
        let original = try LSPCLIOwnerEndpoint(hostID: hostID) { _ in
            .init(error: nil, stopKind: nil, telemetry: Self.telemetry(lifecycle: "original"))
        }
        original.stop()

        let successor = try LSPCLIOwnerEndpoint(hostID: hostID) { _ in
            .init(error: nil, stopKind: nil, telemetry: Self.telemetry(lifecycle: "successor"))
        }
        defer { successor.stop() }
        for _ in 0 ..< 20 { await Task.yield() }

        let response = try await LSPCLIOwnerEndpoint.request(hostID: hostID, command: .telemetry)
        XCTAssertEqual(response.telemetry?.lifecycle, "successor")
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

    private static func telemetry(lifecycle: String) -> LSPCLIOwnerTelemetry {
        .init(
            lifecycle: lifecycle,
            receivedDatagrams: 0,
            transmittedDatagrams: 0,
            droppedDatagrams: 0,
            authenticationFailures: 0,
            currentUDPPayloadSize: 1_400,
            reconnectPhase: nil
        )
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

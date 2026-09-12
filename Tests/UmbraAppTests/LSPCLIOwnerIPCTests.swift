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
            audioRebuffers: nil
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

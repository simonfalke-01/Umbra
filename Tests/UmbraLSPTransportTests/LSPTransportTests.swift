import CLSPCore
import Darwin
import XCTest
@testable import UmbraLSPTransport

final class LSPTransportTests: XCTestCase {
    func testABIVersionDigestAndInitialTelemetryMatchNativeCore() throws {
        XCTAssertEqual(clsp_core_abi_version(), 2)
        XCTAssertEqual(String(cString: clsp_core_source_digest()), LSPTransport.sourceDigest)

        let transport = try LSPTransport()
        let telemetry = try transport.telemetrySnapshot()

        XCTAssertEqual(telemetry.lifecycle, .created)
        XCTAssertEqual(telemetry.providers, LSPTransport.availableProviders)
        XCTAssertEqual(telemetry.receivedDatagrams, 0)
        XCTAssertEqual(telemetry.transmittedDatagrams, 0)
        XCTAssertEqual(telemetry.droppedDatagrams, 0)
        XCTAssertEqual(telemetry.authenticationFailures, 0)
        XCTAssertNil(try transport.pollDeviceOffer())

        let timing = try transport.nativeTimingSnapshot()
        XCTAssertEqual(timing.generation, 0)
        XCTAssertEqual(timing.stages.count, LSPNativeTimingStage.allCases.count)
        XCTAssertTrue(timing.stages.allSatisfy { $0.count == 0 && $0.drops == 0 })
        XCTAssertEqual(timing.controllerGenerations, Array(repeating: 0, count: 16))
        XCTAssertEqual(timing.touchGenerations, Array(repeating: 0, count: 16))
        XCTAssertEqual(timing.penGenerations, Array(repeating: 0, count: 16))
        XCTAssertTrue(timing.devices.isEmpty)
    }

    func testStartFailsClosedAtFirstMissingSecurityProvider() throws {
        let transport = try LSPTransport(configuration: .init(handshakeTimeout: .seconds(1)))
        let providers = LSPTransport.availableProviders
        let endpoint = LSPTransportEndpoint(
            host: "127.0.0.1",
            port: 9,
            serverSPKISHA256: Data(repeating: 0x55, count: 32)
        )

        if !providers.contains(.wolfSSL) {
            XCTAssertThrowsError(try transport.start(endpoint: endpoint)) { error in
                XCTAssertEqual(error as? LSPTransportError, .missingWolfSSL)
            }
        } else if !providers.contains(.libSRTP) {
            XCTAssertThrowsError(try transport.start(endpoint: endpoint)) { error in
                XCTAssertEqual(error as? LSPTransportError, .missingLibSRTP)
            }
        } else {
            XCTAssertThrowsError(try transport.start(endpoint: endpoint)) { error in
                XCTAssertTrue(
                    [.timeout, .dtlsFailure, .socketFailure].contains(error as? LSPTransportError)
                )
            }
        }
    }

    func testCompetitionProfileRequiresExplicitCapacityCeiling() {
        XCTAssertThrowsError(
            try LSPTransport(
                configuration: .init(profile: .competitionLAN(capacityMbps: 0))
            )
        ) { error in
            XCTAssertEqual(error as? LSPTransportError, .invalidConfiguration)
        }
    }

    func testHandshakeRetransmissionDoesNotAuthenticateSilentPeer() throws {
        guard LSPTransport.availableProviders.contains([.wolfSSL, .libSRTP]) else {
            throw XCTSkip("The DTLS retransmission regression requires the native security providers.")
        }
        let listener = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        XCTAssertGreaterThanOrEqual(listener, 0)
        guard listener >= 0 else { return }
        defer { Darwin.close(listener) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        guard bound == 0 else { return }
        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let resolved = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listener, $0, &addressLength)
            }
        }
        XCTAssertEqual(resolved, 0)
        guard resolved == 0 else { return }

        let transport = try LSPTransport(configuration: .init(handshakeTimeout: .seconds(2)))
        XCTAssertThrowsError(try transport.start(endpoint: .init(
            host: "127.0.0.1",
            port: UInt16(bigEndian: address.sin_port),
            serverSPKISHA256: Data(repeating: 0x55, count: 32)
        ))) { error in
            XCTAssertEqual(error as? LSPTransportError, .timeout)
        }

        var packet = [UInt8](repeating: 0, count: 2_048)
        var clientHelloCount = 0
        while recv(listener, &packet, packet.count, MSG_DONTWAIT) > 0 {
            if packet[0] == 22 { clientHelloCount += 1 }
        }
        XCTAssertGreaterThanOrEqual(clientHelloCount, 2, "Exercise a real ClientHello retransmission.")
        XCTAssertEqual(try transport.telemetrySnapshot().authenticationFailures, 0)
        let timestamp = try transport.nativeTimingSnapshot().snapshotTimeMicroseconds
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1_000
        XCTAssertGreaterThan(timestamp, 0)
        XCTAssertLessThanOrEqual(timestamp, now)
        XCTAssertLessThan(now - min(now, timestamp), 1_000_000,
                          "Native and media/input timestamps must share the awake-only uptime domain.")
    }

    func testTelemetryIntervalRejectsSub250MillisecondPublication() {
        XCTAssertThrowsError(
            try LSPTransport(configuration: .init(telemetryInterval: .milliseconds(249)))
        ) { error in
            XCTAssertEqual(error as? LSPTransportError, .invalidConfiguration)
        }
    }

    func testLifecycleTerminalStatusPreservesTimeoutSocketAndDTLSFailures() {
        XCTAssertEqual(
            LSPTransport.terminalError(forNativeStatus: CLSP_STATUS_TIMEOUT),
            .timeout
        )
        XCTAssertEqual(
            LSPTransport.terminalError(forNativeStatus: CLSP_STATUS_SOCKET_FAILURE),
            .socketFailure
        )
        XCTAssertEqual(
            LSPTransport.terminalError(forNativeStatus: CLSP_STATUS_DTLS_FAILURE),
            .dtlsFailure
        )
    }

    func testNativeHandoffAtomicSubmitFailureRemainsDefinitelyNotSubmitted() throws {
        let active = try makeInactiveNativeCore()
        let candidate = try makeInactiveNativeCore()
        defer {
            clsp_core_release(candidate)
            clsp_core_release(active)
        }

        let callbacks = NativeHandoffCallbackRecorder()
        var callbackTable = clsp_handoff_callbacks_t()
        callbackTable.abi_version = clsp_core_abi_version()
        callbackTable.structure_size = UInt32(MemoryLayout<clsp_handoff_callbacks_t>.size)
        callbackTable.context = Unmanaged.passUnretained(callbacks).toOpaque()
        callbackTable.retain_context = nativeHandoffRetainContext
        callbackTable.release_context = nativeHandoffReleaseContext
        callbackTable.phase = nativeHandoffPhase
        callbackTable.baseline = nativeHandoffBaseline
        callbackTable.rekey = nativeHandoffRekey
        callbackTable.terminal = nativeHandoffTerminal

        var handoff: OpaquePointer?
        XCTAssertEqual(
            clsp_handoff_create(active, 1, 10, &callbackTable, &handoff),
            CLSP_STATUS_OK
        )
        let owned = try XCTUnwrap(handoff)
        callbacks.handle = owned
        callbacks.core = active

        XCTAssertEqual(callbacks.contextRetains, 1)
        XCTAssertEqual(
            clsp_handoff_begin(
                owned,
                candidate,
                2,
                UInt32(CLSP_HANDOFF_REASON_PLANNED_REKEY.rawValue)
            ),
            CLSP_STATUS_OK
        )
        XCTAssertEqual(clsp_handoff_authenticate(owned, 2), CLSP_STATUS_OK)
        XCTAssertEqual(clsp_handoff_neutralize(owned), CLSP_STATUS_OK)
        var submission = clsp_control_submission_t()
        let emptyMap = Data([0xA0])
        let submitStatus = emptyMap.withUnsafeBytes { bytes in
            clsp_handoff_submit_attach(
                owned,
                0x0202,
                99,
                .init(data: bytes.bindMemory(to: UInt8.self).baseAddress, length: bytes.count),
                1_000,
                &submission
            )
        }
        XCTAssertEqual(submitStatus, CLSP_STATUS_NOT_AUTHENTICATED)
        XCTAssertEqual(submission.request_id, 0)
        var notSubmitted = clsp_handoff_snapshot_t()
        XCTAssertEqual(clsp_handoff_copy_snapshot(owned, &notSubmitted), CLSP_STATUS_OK)
        XCTAssertEqual(notSubmitted.phase, UInt32(CLSP_HANDOFF_PHASE_OLD_INPUT_NEUTRALIZED.rawValue))
        XCTAssertEqual(
            clsp_handoff_cancel(owned, UInt32(CLSP_HANDOFF_CANCEL_DEFINITE_REJECTION.rawValue)),
            CLSP_STATUS_NOT_AUTHENTICATED
        )
        XCTAssertEqual(callbacks.reentrantSnapshotStatus, CLSP_STATUS_REENTRANT_CALLBACK)
        XCTAssertEqual(callbacks.reentrantCoreStatus, CLSP_STATUS_REENTRANT_CALLBACK)
        XCTAssertEqual(callbacks.concurrentCoreStatus, CLSP_STATUS_OK)
        XCTAssertEqual(callbacks.rekeyEvents, 1)
        XCTAssertEqual(callbacks.baselineKinds, [
            UInt32(CLSP_HANDOFF_BASELINE_REQUIRED.rawValue),
        ])
        XCTAssertEqual(callbacks.baselineAuthorityEpochs, [2])
        XCTAssertEqual(callbacks.baselineConnectionGenerations, [1])
        XCTAssertEqual(callbacks.baselineRollbackGenerations, [2])
        XCTAssertEqual(callbacks.terminalEvents, 1)
        callbacks.handle = nil
        callbacks.core = nil
        clsp_handoff_release(owned)
        XCTAssertEqual(callbacks.contextReleases, 1)
    }

    func testNativeHandoffConsumesCanceledGeneration() throws {
        let active = try makeInactiveNativeCore()
        let firstCandidate = try makeInactiveNativeCore()
        let secondCandidate = try makeInactiveNativeCore()
        defer {
            clsp_core_release(secondCandidate)
            clsp_core_release(firstCandidate)
            clsp_core_release(active)
        }
        var handoff: OpaquePointer?
        XCTAssertEqual(clsp_handoff_create(active, 5, 50, nil, &handoff), CLSP_STATUS_OK)
        let owned = try XCTUnwrap(handoff)
        defer { clsp_handoff_release(owned) }

        XCTAssertEqual(
            clsp_handoff_begin(
                owned,
                firstCandidate,
                6,
                UInt32(CLSP_HANDOFF_REASON_PLANNED_REKEY.rawValue)
            ),
            CLSP_STATUS_OK
        )
        XCTAssertEqual(
            clsp_handoff_cancel(
                owned,
                UInt32(CLSP_HANDOFF_CANCEL_DEFINITE_REJECTION.rawValue)
            ),
            CLSP_STATUS_OK
        )
        XCTAssertEqual(
            clsp_handoff_begin(
                owned,
                secondCandidate,
                6,
                UInt32(CLSP_HANDOFF_REASON_PLANNED_REKEY.rawValue)
            ),
            CLSP_STATUS_INVALID_CONFIGURATION
        )
        XCTAssertEqual(
            clsp_handoff_begin(
                owned,
                secondCandidate,
                7,
                UInt32(CLSP_HANDOFF_REASON_TRANSPORT_LOSS.rawValue)
            ),
            CLSP_STATUS_OK
        )
        XCTAssertEqual(clsp_handoff_authenticate(owned, 7), CLSP_STATUS_OK)
        XCTAssertEqual(
            clsp_handoff_cancel(owned, UInt32(CLSP_HANDOFF_CANCEL_DEFINITE_REJECTION.rawValue)),
            CLSP_STATUS_OK
        )
        var snapshot = clsp_handoff_snapshot_t()
        XCTAssertEqual(clsp_handoff_copy_snapshot(owned, &snapshot), CLSP_STATUS_OK)
        XCTAssertEqual(snapshot.phase, UInt32(CLSP_HANDOFF_PHASE_AUTHORITATIVE.rawValue))
        XCTAssertEqual(snapshot.connection_generation_high_watermark, 7)
        XCTAssertEqual(snapshot.terminal_count, 0)
    }

    func testNativeHandoffContinuesForwardAfterOldTransportLoss() throws {
        let active = try makeInactiveNativeCore()
        let candidate = try makeInactiveNativeCore()
        defer {
            clsp_core_release(candidate)
            clsp_core_release(active)
        }
        var handoff: OpaquePointer?
        XCTAssertEqual(clsp_handoff_create(active, 8, 80, nil, &handoff), CLSP_STATUS_OK)
        let owned = try XCTUnwrap(handoff)
        defer { clsp_handoff_release(owned) }

        XCTAssertEqual(
            clsp_handoff_begin(
                owned,
                candidate,
                9,
                UInt32(CLSP_HANDOFF_REASON_TRANSPORT_LOSS.rawValue)
            ),
            CLSP_STATUS_OK
        )
        XCTAssertEqual(clsp_handoff_lost(owned, active), CLSP_STATUS_OK)
        XCTAssertEqual(clsp_handoff_authenticate(owned, 9), CLSP_STATUS_OK)
        XCTAssertEqual(clsp_handoff_neutralize(owned), CLSP_STATUS_OK)
        var submission = clsp_control_submission_t()
        XCTAssertEqual(
            clsp_handoff_submit_attach(owned, 0x0202, 1, .init(), 1_000, &submission),
            CLSP_STATUS_NOT_AUTHENTICATED
        )
        XCTAssertEqual(submission.request_id, 0)
    }

    private func makeInactiveNativeCore() throws -> OpaquePointer {
        var configuration = clsp_configuration_t()
        configuration.abi_version = clsp_core_abi_version()
        configuration.structure_size = UInt32(MemoryLayout<clsp_configuration_t>.size)
        configuration.port = 48_030
        configuration.profile = UInt32(CLSP_PROFILE_ADAPTIVE_LOW_LATENCY.rawValue)
        configuration.telemetry_interval_milliseconds = 1_000
        configuration.handshake_timeout_milliseconds = 1_000
        var core: OpaquePointer?
        XCTAssertEqual(clsp_core_create(&configuration, nil, &core), CLSP_STATUS_OK)
        return try XCTUnwrap(core)
    }

    func testNativeHandoffStartsAuthoritativeAndPublishesSecretFreeSnapshot() throws {
        let active = try LSPTransport()
        let handoff = try LSPNativeHandoff(
            active: active,
            activeConnectionGeneration: 4,
            activeInputGeneration: 9
        )
        let snapshot = try handoff.snapshot()
        XCTAssertEqual(snapshot.phase, .authoritative)
        XCTAssertEqual(snapshot.activeConnectionGeneration, 4)
        XCTAssertEqual(snapshot.activeInputGeneration, 9)
        XCTAssertEqual(snapshot.connectionGenerationHighWatermark, 4)
        XCTAssertFalse(snapshot.baselineRequired)
        XCTAssertFalse(snapshot.forwardOnly)
    }

    func testAssociationBaselineObservationDoesNotRequireHandoffBinding() throws {
        let core = try makeInactiveNativeCore()
        defer { clsp_core_release(core) }
        var snapshot = clsp_input_baseline_snapshot_t()
        XCTAssertEqual(clsp_core_copy_input_baseline(core, &snapshot), CLSP_STATUS_OK)
        XCTAssertEqual(snapshot.abi_version, clsp_core_abi_version())
        XCTAssertEqual(snapshot.structure_size, UInt32(MemoryLayout<clsp_input_baseline_snapshot_t>.size))
        XCTAssertEqual(snapshot.connection_generation, 0)
        XCTAssertEqual(snapshot.input_generation, 0)
        XCTAssertEqual(snapshot.input_authority_epoch, 0)
        XCTAssertEqual(snapshot.event_generation, 0)
        XCTAssertEqual(snapshot.acknowledged, 0)
        XCTAssertEqual(
            clsp_core_wait_input_baseline(core, 1, 1, &snapshot),
            CLSP_STATUS_TIMEOUT
        )
        var edge = clsp_input_edge_snapshot_t()
        XCTAssertEqual(clsp_core_copy_input_edge_snapshot(core, &edge), CLSP_STATUS_NOT_AUTHENTICATED)
    }

    func testNativePINPairingABIRequiresAuthenticatedBoundAssociation() throws {
        let core = try makeInactiveNativeCore()
        defer { clsp_core_release(core) }
        var hello = clsp_host_hello_identity_t()
        hello.abi_version = clsp_core_abi_version()
        hello.structure_size = UInt32(MemoryLayout<clsp_host_hello_identity_t>.size)
        hello.connection_generation = 1
        _ = withUnsafeMutableBytes(of: &hello.host_id) { $0.initializeMemory(as: UInt8.self, repeating: 1) }
        _ = withUnsafeMutableBytes(of: &hello.host_identity_key) { $0.initializeMemory(as: UInt8.self, repeating: 2) }
        _ = withUnsafeMutableBytes(of: &hello.server_spki_sha256) { $0.initializeMemory(as: UInt8.self, repeating: 3) }
        _ = withUnsafeMutableBytes(of: &hello.client_nonce) { $0.initializeMemory(as: UInt8.self, repeating: 4) }
        _ = withUnsafeMutableBytes(of: &hello.server_nonce) { $0.initializeMemory(as: UInt8.self, repeating: 5) }
        XCTAssertEqual(clsp_core_bind_host_hello(core, &hello), CLSP_STATUS_NOT_AUTHENTICATED)

        let name = Data("Umbra".utf8)
        var pairing: OpaquePointer?
        let status = name.withUnsafeBytes { bytes in
            var configuration = clsp_pairing_configuration_t()
            configuration.abi_version = clsp_core_abi_version()
            configuration.structure_size = UInt32(MemoryLayout<clsp_pairing_configuration_t>.size)
            _ = withUnsafeMutableBytes(of: &configuration.client_id) {
                $0.initializeMemory(as: UInt8.self, repeating: 6)
            }
            _ = withUnsafeMutableBytes(of: &configuration.client_identity_key) {
                $0.initializeMemory(as: UInt8.self, repeating: 7)
            }
            configuration.client_name = .init(
                data: bytes.bindMemory(to: UInt8.self).baseAddress,
                length: bytes.count
            )
            configuration.requested_permissions = 0x7F
            return clsp_pairing_create(core, &configuration, &pairing)
        }
        XCTAssertEqual(status, CLSP_STATUS_NOT_AUTHENTICATED)
        XCTAssertNil(pairing)
        XCTAssertEqual(
            String(cString: clsp_status_description(CLSP_STATUS_PAIRING_CONFIRMATION_FAILED)),
            "native PIN pairing confirmation failed"
        )
    }

    func testNativeRuntimeOrdersUrgentReverseVideoAndProductStages() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: repository.appendingPathComponent("Vendor/CLSPCore/src/runtime/Runtime.cpp"),
            encoding: .utf8
        )
        let worker = try XCTUnwrap(source.range(of: "void run_worker() noexcept"))
        let drain = try XCTUnwrap(source.range(of: "status = drain_socket();", range: worker.lowerBound..<source.endIndex))
        let input = try XCTUnwrap(source.range(of: "status = transmit_input();", range: drain.upperBound..<source.endIndex))
        let microphone = try XCTUnwrap(source.range(of: "status = transmit_microphone();", range: input.upperBound..<source.endIndex))
        let video = try XCTUnwrap(source.range(of: "status = process_deferred_video_batch();", range: microphone.upperBound..<source.endIndex))
        let product = try XCTUnwrap(source.range(of: "deliver_video_frames();", range: video.upperBound..<source.endIndex))
        XCTAssertLessThan(drain.lowerBound, input.lowerBound)
        XCTAssertLessThan(input.lowerBound, microphone.lowerBound)
        XCTAssertLessThan(microphone.lowerBound, video.lowerBound)
        XCTAssertLessThan(video.lowerBound, product.lowerBound)
        XCTAssertTrue(source.contains("PendingProtectedMicrophone pending_microphone_"))
        XCTAssertTrue(source.contains("return transmit_pending_microphone();"))
        XCTAssertTrue(source.contains("deferred.token = receive_lease.detach();"))
        XCTAssertTrue(source.contains("receive_lease.adopt(video_receive_pool_, deferred.token)"))
        XCTAssertFalse(source.contains("std::copy_n(deferred.bytes"))
    }

    func testRollbackBaselineCompletionUsesLatchedEpochAfterSnapshotClearsRollbackGeneration() {
        let snapshot = LSPNativeHandoffSnapshot(
            phase: .authoritative,
            activeConnectionGeneration: 41,
            activeInputGeneration: 7,
            candidateConnectionGeneration: 0,
            inputAuthorityEpoch: 42,
            connectionGenerationHighWatermark: 42,
            rollbackConnectionGeneration: 0,
            retiringConnectionGeneration: 0,
            baselineRequired: false,
            forwardOnly: false,
            committedCount: 0,
            rollbackCount: 1,
            terminalCount: 0
        )
        let acknowledged = LSPNativeBaselineEvent(
            kind: .acknowledged,
            inputGeneration: 7,
            inputAuthorityEpoch: 42,
            connectionGeneration: 41,
            rollbackConnectionGeneration: 42
        )

        XCTAssertTrue(LSPNativeHandoff.completedBaselineMatches(
            event: acknowledged,
            snapshot: snapshot,
            inputGeneration: 7
        ))
        var stale = acknowledged
        stale.rollbackConnectionGeneration = 43
        XCTAssertFalse(LSPNativeHandoff.completedBaselineMatches(
            event: stale,
            snapshot: snapshot,
            inputGeneration: 7
        ))
    }
}

private final class NativeHandoffCallbackRecorder: @unchecked Sendable {
    private let lock = NSLock()
    var handle: OpaquePointer?
    var core: OpaquePointer?
    private(set) var contextRetains = 0
    private(set) var contextReleases = 0
    private(set) var rekeyEvents = 0
    private(set) var terminalEvents = 0
    private(set) var baselineKinds: [UInt32] = []
    private(set) var baselineAuthorityEpochs: [UInt32] = []
    private(set) var baselineConnectionGenerations: [UInt32] = []
    private(set) var baselineRollbackGenerations: [UInt32] = []
    private(set) var reentrantSnapshotStatus: clsp_status_t?
    private(set) var reentrantCoreStatus: clsp_status_t?
    private(set) var concurrentCoreStatus: clsp_status_t?

    func retained() {
        lock.lock()
        contextRetains += 1
        lock.unlock()
    }

    func released() {
        lock.lock()
        contextReleases += 1
        lock.unlock()
    }

    func phase() {
        lock.lock()
        guard reentrantSnapshotStatus == nil, let handle else {
            lock.unlock()
            return
        }
        let core = core
        lock.unlock()
        var snapshot = clsp_handoff_snapshot_t()
        let handoffStatus = clsp_handoff_copy_snapshot(handle, &snapshot)
        if let core {
            let coreAddress = UInt(bitPattern: core)
            var telemetry = clsp_telemetry_snapshot_t()
            let coreStatus = clsp_core_copy_telemetry(core, &telemetry)
            let semaphore = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { [weak self] in
                guard let core = OpaquePointer(bitPattern: coreAddress) else {
                    semaphore.signal()
                    return
                }
                var concurrent = clsp_telemetry_snapshot_t()
                let status = clsp_core_copy_telemetry(core, &concurrent)
                self?.lock.lock()
                self?.concurrentCoreStatus = status
                self?.lock.unlock()
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 1)
            lock.lock()
            reentrantCoreStatus = coreStatus
            lock.unlock()
        }
        lock.lock()
        reentrantSnapshotStatus = handoffStatus
        lock.unlock()
    }

    func baseline(_ event: clsp_handoff_baseline_event_t) {
        lock.lock()
        baselineKinds.append(event.kind)
        baselineAuthorityEpochs.append(event.input_authority_epoch)
        baselineConnectionGenerations.append(event.connection_generation)
        baselineRollbackGenerations.append(event.rollback_connection_generation)
        lock.unlock()
    }

    func rekey() {
        lock.lock()
        rekeyEvents += 1
        lock.unlock()
    }

    func terminal() {
        lock.lock()
        terminalEvents += 1
        lock.unlock()
    }
}

private func nativeHandoffRetainContext(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let recorder = Unmanaged<NativeHandoffCallbackRecorder>.fromOpaque(context).takeUnretainedValue()
    recorder.retained()
    _ = Unmanaged<NativeHandoffCallbackRecorder>.fromOpaque(context).retain()
}

private func nativeHandoffReleaseContext(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let recorder = Unmanaged<NativeHandoffCallbackRecorder>.fromOpaque(context).takeUnretainedValue()
    recorder.released()
    Unmanaged<NativeHandoffCallbackRecorder>.fromOpaque(context).release()
}

private func nativeHandoffPhase(
    _ context: UnsafeMutableRawPointer?,
    _ event: UnsafePointer<clsp_handoff_phase_event_t>?
) {
    guard let context, event != nil else { return }
    Unmanaged<NativeHandoffCallbackRecorder>.fromOpaque(context).takeUnretainedValue().phase()
}

private func nativeHandoffBaseline(
    _ context: UnsafeMutableRawPointer?,
    _ event: UnsafePointer<clsp_handoff_baseline_event_t>?
) {
    guard let context, let event else { return }
    Unmanaged<NativeHandoffCallbackRecorder>.fromOpaque(context).takeUnretainedValue().baseline(event.pointee)
}

private func nativeHandoffRekey(
    _ context: UnsafeMutableRawPointer?,
    _ event: UnsafePointer<clsp_handoff_rekey_event_t>?
) {
    guard let context, event != nil else { return }
    Unmanaged<NativeHandoffCallbackRecorder>.fromOpaque(context).takeUnretainedValue().rekey()
}

private func nativeHandoffTerminal(
    _ context: UnsafeMutableRawPointer?,
    _ event: UnsafePointer<clsp_handoff_terminal_event_t>?
) {
    guard let context, event != nil else { return }
    Unmanaged<NativeHandoffCallbackRecorder>.fromOpaque(context).takeUnretainedValue().terminal()
}

import Foundation
import UmbraCLI
import UmbraCLIExecution
import UmbraCore
import UmbraLSP
import UmbraLSPTransport
import UmbraMedia
import UmbraNetworking

/// LSP-only CLI adapter; every failure remains native and never redirects to GameStream.
actor LiveUmbraCLILSPService: UmbraCLILSPServicing {
    private let product: LSPProductClient
    private let discovery = LSPDiscovery.makeBonjourBrowser(
        queue: DispatchQueue(label: "app.umbra.cli-lsp-discovery")
    )
    private var discoveryStarted = false
    private var candidates: [UUID: LSPDiscoveredPairingHost] = [:]
    private var activeApplications: [UUID: String] = [:]
    private var captures: [UUID: LSPAppleInputCapture] = [:]
    private var ownerEndpoints: [UUID: LSPCLIOwnerEndpoint] = [:]
    private var maintenanceTasks: [UUID: Task<Void, Never>] = [:]
    private var terminalOutcomes: [UUID: CLILSPStopOutcome] = [:]
    private var terminalWaiters: [UUID: [CheckedContinuation<CLILSPStopOutcome, Never>]] = [:]

    init() throws {
        product = try LSPProductClient.applicationSupport(videoRenderer: HeadlessLSPRenderer())
    }

    deinit {
        discovery.stop()
        for capture in captures.values { capture.stop() }
        for endpoint in ownerEndpoints.values { endpoint.stop() }
        for task in maintenanceTasks.values { task.cancel() }
    }

    func resolveHost(query: String, exactHostID: UUID?) async throws -> CLILSPHost {
        ensureDiscoveryStarted()
        let deadline = ContinuousClock.now + .seconds(3)
        while true {
            let persisted = (try? await product.hosts()) ?? []
            if let host = resolvedHost(query: query, exactHostID: exactHostID, persisted: persisted) {
                return host
            }
            guard ContinuousClock.now < deadline else { throw LSPTransportError.invalidEndpoint }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    func applications(hostID: UUID) async throws -> [CLILSPApplication] {
        try await product.applications(hostID: hostID).map {
            CLILSPApplication(id: $0.id, name: $0.name)
        }
    }

    func beginPairing(
        hostID: UUID,
        permissions: CLILSPPermissionSet
    ) async throws -> CLILSPPairingPrompt {
        guard let candidate = candidates[hostID] else { throw LSPTransportError.invalidEndpoint }
        _ = await product.registerDiscoveredPairingHost(candidate)
        let prompt = try await product.beginPairing(
            hostID: hostID,
            requestedPermissions: LSPPermission(rawValue: permissions.rawValue)
        )
        return .init(
            host: cliHost(candidate, paired: false),
            pin: prompt.pin,
            expiresAtUTCSeconds: prompt.expiresAtUTCSeconds
        )
    }

    func completePairing(hostID: UUID) async throws -> CLILSPHost {
        let host = try await product.completePairing(hostID: hostID)
        return cliHost(host, paired: true)
    }

    func cancelPairing(hostID: UUID) async {
        await product.cancelPairing(hostID: hostID)
    }

    func configure(
        profile: LSPNetworkProfilePreference,
        competitionCapacityMbps: Int
    ) async throws {
        let transportProfile: LSPTransportProfile
        switch profile {
        case .adaptiveLowLatency:
            transportProfile = .adaptiveLowLatency
        case .competitionLAN:
            guard let capacity = UInt32(exactly: competitionCapacityMbps), capacity > 0 else {
                throw LSPTransportError.invalidConfiguration
            }
            transportProfile = .competitionLAN(capacityMbps: capacity)
        }
        try await product.configureTransport(.init(profile: transportProfile))
    }

    func start(_ request: CLILSPStartRequest) async throws {
        if LSPCLIOwnerEndpoint.endpointExists(hostID: request.hostID) {
            do {
                _ = try await LSPCLIOwnerEndpoint.request(hostID: request.hostID, command: .telemetry)
                throw LSPControlStatus.busy
            } catch LSPCLIOwnerIPCError.unavailable {
                // A same-user stale socket is recoverable; listener creation removes it safely.
            }
        }
        guard let frameRate = request.preferences.normalizedFrameRate else {
            throw LSPTransportError.invalidConfiguration
        }
        let microphone: LSPMicrophoneOffer? = switch request.microphone {
        case .off:
            nil
        case .optional:
            .init(maximumBitrate: 64_000, inbandFEC: true, dtx: true, required: false)
        case .required:
            .init(maximumBitrate: 64_000, inbandFEC: true, dtx: true, required: true)
        }
        let session = try await product.startInput(
            hostID: request.hostID,
            applicationID: request.applicationID,
            resume: request.resume,
            pointerRate: request.pointerRate,
            controllerRate: request.controllerRate,
            sensorRate: request.sensorRate,
            reconciliationRate: request.reconciliationRate,
            microphoneOffer: microphone,
            capabilities: .probe(),
            preferences: request.preferences,
            refreshNumerator: frameRate.numerator,
            refreshDenominator: frameRate.denominator
        )
        captures[request.hostID]?.stop()
        captures[request.hostID] = try session.startAppleInputCapture()
        activeApplications[request.hostID] = request.applicationID
        terminalOutcomes.removeValue(forKey: request.hostID)
        do {
            try installOwner(hostID: request.hostID, session: session)
        } catch {
            captures.removeValue(forKey: request.hostID)?.stop()
            activeApplications.removeValue(forKey: request.hostID)
            _ = await product.stop(hostID: request.hostID)
            throw error
        }
    }

    func runUntilTerminated(hostID: UUID) async -> CLILSPStopOutcome {
        if let outcome = terminalOutcomes.removeValue(forKey: hostID) { return outcome }
        guard ownerEndpoints[hostID] != nil else { return .notRunning }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                terminalWaiters[hostID, default: []].append(continuation)
            }
        } onCancel: {
            Task { [weak self] in _ = await self?.stopLocal(hostID: hostID) }
        }
    }

    func attach(hostID: UUID) async throws {
        if ownerEndpoints[hostID] == nil, LSPCLIOwnerEndpoint.endpointExists(hostID: hostID) {
            let response = try await LSPCLIOwnerEndpoint.request(hostID: hostID, command: .attach)
            if let error = response.error { throw LSPCLIOwnerIPCError.remote(error) }
            return
        }
        try await attachLocal(hostID: hostID)
    }

    private func attachLocal(hostID: UUID) async throws {
        let replacement = try await product.reconnectInput(
            hostID: hostID,
            reason: .transportLoss,
            quiesceOldCapture: { [weak self] in
                guard let self else { return }
                await self.stopCapture(hostID: hostID)
            }
        )
        do {
            captures[hostID] = try replacement.startAppleInputCapture()
            await product.markCaptureTransferred(hostID: hostID, session: replacement)
            installSessionHandlers(hostID: hostID, session: replacement)
        } catch {
            await receiveTerminal(hostID: hostID, outcome: .transportFailed(error.localizedDescription))
            throw error
        }
    }

    func stop(hostID: UUID) async -> CLILSPStopOutcome {
        if ownerEndpoints[hostID] == nil, LSPCLIOwnerEndpoint.endpointExists(hostID: hostID) {
            do {
                return try stopOutcome(
                    from: await LSPCLIOwnerEndpoint.request(hostID: hostID, command: .stop)
                )
            } catch {
                return .transportFailed(error.localizedDescription)
            }
        }
        return await stopLocal(hostID: hostID)
    }

    private func stopLocal(hostID: UUID) async -> CLILSPStopOutcome {
        if let terminal = terminalOutcomes[hostID] { return terminal }
        captures.removeValue(forKey: hostID)?.stop()
        activeApplications.removeValue(forKey: hostID)
        let outcome: CLILSPStopOutcome = switch await product.stop(hostID: hostID) {
        case .notRunning: .notRunning
        case .stopped: .stopped
        case .remoteRejected(let status): .rejected("status \(status.rawValue)")
        case .transportFailed(let error): .transportFailed(error.localizedDescription)
        }
        finishOwner(hostID: hostID, outcome: outcome)
        return outcome
    }

    func quit(hostID: UUID) async throws {
        if ownerEndpoints[hostID] == nil, LSPCLIOwnerEndpoint.endpointExists(hostID: hostID) {
            let response = try await LSPCLIOwnerEndpoint.request(hostID: hostID, command: .quit)
            if let error = response.error { throw LSPCLIOwnerIPCError.remote(error) }
            return
        }
        let applicationID: String?
        if let active = activeApplications[hostID] {
            applicationID = active
        } else {
            applicationID = try? await product.activeApplicationID(hostID: hostID)
        }
        guard let applicationID else {
            throw LSPTransportError.invalidState
        }
        try await product.quitApplication(hostID: hostID, applicationID: applicationID)
        activeApplications.removeValue(forKey: hostID)
    }

    func telemetry(hostID: UUID) async throws -> CLILSPTelemetry {
        if ownerEndpoints[hostID] == nil, LSPCLIOwnerEndpoint.endpointExists(hostID: hostID) {
            let response = try await LSPCLIOwnerEndpoint.request(hostID: hostID, command: .telemetry)
            if let error = response.error { throw LSPCLIOwnerIPCError.remote(error) }
            guard let value = response.telemetry else { throw LSPCLIOwnerIPCError.invalidMessage }
            return value.cliValue
        }
        return try await telemetryLocal(hostID: hostID)
    }

    private func telemetryLocal(hostID: UUID) async throws -> CLILSPTelemetry {
        guard let session = await product.currentSession(hostID: hostID) else {
            throw LSPTransportError.invalidState
        }
        let value = try await session.telemetrySnapshot()
        let reconnect = await product.reconnectTelemetry(hostID: hostID)
        let media = await product.productTelemetry(hostID: hostID)
        return .init(
            lifecycle: String(describing: value.lifecycle),
            receivedDatagrams: value.receivedDatagrams,
            transmittedDatagrams: value.transmittedDatagrams,
            droppedDatagrams: value.droppedDatagrams,
            authenticationFailures: value.authenticationFailures,
            currentUDPPayloadSize: value.currentUDPPayloadSize,
            reconnectPhase: reconnect.map { String(describing: $0.phase) },
            completeFrameReceiveToVideoToolboxSubmit: media
                .flatMap(\.completeFrameReceiveToVideoToolboxSubmit)
                .map(CLILSPTimingDistribution.init),
            videoToolboxSubmitToDecodeCompletion: media
                .flatMap(\.videoToolboxSubmitToDecodeCompletion)
                .map(CLILSPTimingDistribution.init),
            completeFrameReceiveToMetalEnqueue: media
                .flatMap(\.completeFrameReceiveToMetalEnqueue)
                .map(CLILSPTimingDistribution.init),
            metalEnqueueToCommit: media
                .flatMap(\.metalEnqueueToCommit)
                .map(CLILSPTimingDistribution.init),
            audioReceiveToDecode: media
                .flatMap(\.audioReceiveToDecode)
                .map(CLILSPTimingDistribution.init),
            audioDecodeAndRenderEnqueue: media
                .flatMap(\.audioDecodeAndRenderEnqueue)
                .map(CLILSPTimingDistribution.init),
            audioUnderruns: media?.audioUnderruns,
            audioRebuffers: media?.audioRebuffers,
            audioAcceptedPackets: media?.audioAcceptedPackets,
            audioPlayedPackets: media?.audioPlayedPackets,
            audioDroppedPackets: media?.audioDroppedPackets,
            audioRejectedPackets: media?.audioRejectedPackets,
            audioCallbackCount: media?.audioCallbackCount,
            audioCallbackError: media?.audioCallbackError,
            audioNonSilentPackets: media?.audioNonSilentPackets,
            audioQueuedMilliseconds: media?.audioQueuedMilliseconds
        )
    }

    private func installOwner(hostID: UUID, session: LSPClientSession) throws {
        ownerEndpoints.removeValue(forKey: hostID)?.stop()
        let endpoint = try LSPCLIOwnerEndpoint(hostID: hostID) { [weak self] request in
            guard let self else {
                return .init(error: LSPCLIOwnerIPCError.unavailable.localizedDescription, stopKind: nil, telemetry: nil)
            }
            return await self.handleOwnerRequest(request)
        }
        ownerEndpoints[hostID] = endpoint
        installSessionHandlers(hostID: hostID, session: session)
        maintenanceTasks.removeValue(forKey: hostID)?.cancel()
        maintenanceTasks[hostID] = Task { [weak self] in
            guard let self else { return }
            var nextRekey = ContinuousClock.now + .seconds(30 * 60)
            while !Task.isCancelled {
                guard let current = await self.product.currentSession(hostID: hostID),
                      await current.state == .inputActive else { return }
                do {
                    try await self.product.drainDeviceOffers(hostID: hostID)
                } catch is CancellationError {
                    return
                } catch {
                    // The session retains the unacknowledged offer and retries at the next 50 ms cadence.
                }
                if ContinuousClock.now >= nextRekey {
                    do {
                        try await self.attachLocal(hostID: hostID)
                        nextRekey = ContinuousClock.now + .seconds(30 * 60)
                    } catch is CancellationError {
                        return
                    } catch {
                        nextRekey = ContinuousClock.now + .seconds(60)
                    }
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func installSessionHandlers(hostID: UUID, session: LSPClientSession) {
        session.setTerminationHandler { [weak self] termination in
            Task { [weak self] in
                let outcome: CLILSPStopOutcome = switch termination {
                case .streamEnded: .stopped
                case .failed(let error): .transportFailed(error.localizedDescription)
                }
                await self?.receiveTerminal(hostID: hostID, outcome: outcome)
            }
        }
        session.setTransportLifecycleHandler { [weak self, weak session] lifecycle in
            guard lifecycle == .failed, let session else { return }
            Task { [weak self, session] in
                guard let self, await self.product.isCurrentSession(session, hostID: hostID) else { return }
                do {
                    try await self.attachLocal(hostID: hostID)
                } catch {
                    await self.receiveTerminal(
                        hostID: hostID,
                        outcome: .transportFailed(error.localizedDescription)
                    )
                }
            }
        }
    }

    private func handleOwnerRequest(_ request: LSPCLIOwnerRequest) async -> LSPCLIOwnerResponse {
        do {
            switch request.command {
            case .attach:
                try await attachLocal(hostID: request.hostID)
                return .init(error: nil, stopKind: nil, telemetry: nil)
            case .stop:
                return .init(error: nil, stopKind: stopKind(await stopLocal(hostID: request.hostID)), telemetry: nil)
            case .quit:
                guard let applicationID = activeApplications[request.hostID] else {
                    throw LSPTransportError.invalidState
                }
                try await product.quitApplication(hostID: request.hostID, applicationID: applicationID)
                activeApplications.removeValue(forKey: request.hostID)
                return .init(error: nil, stopKind: nil, telemetry: nil)
            case .telemetry:
                let value = try await telemetryLocal(hostID: request.hostID)
                return .init(
                    error: nil,
                    stopKind: nil,
                    telemetry: .init(value)
                )
            }
        } catch {
            return .init(error: error.localizedDescription, stopKind: nil, telemetry: nil)
        }
    }

    private func receiveTerminal(hostID: UUID, outcome: CLILSPStopOutcome) async {
        captures.removeValue(forKey: hostID)?.stop()
        activeApplications.removeValue(forKey: hostID)
        await product.failSession(hostID: hostID)
        finishOwner(hostID: hostID, outcome: outcome)
    }

    private func finishOwner(hostID: UUID, outcome: CLILSPStopOutcome) {
        maintenanceTasks.removeValue(forKey: hostID)?.cancel()
        ownerEndpoints.removeValue(forKey: hostID)?.stop()
        terminalOutcomes[hostID] = outcome
        let waiters = terminalWaiters.removeValue(forKey: hostID) ?? []
        for waiter in waiters { waiter.resume(returning: outcome) }
    }

    private func stopKind(_ outcome: CLILSPStopOutcome) -> String {
        switch outcome {
        case .notRunning: "not-running"
        case .stopped: "stopped"
        case .rejected(let reason): "rejected:\(reason)"
        case .transportFailed(let reason): "transport:\(reason)"
        }
    }

    private func stopOutcome(from response: LSPCLIOwnerResponse) throws -> CLILSPStopOutcome {
        if let error = response.error { throw LSPCLIOwnerIPCError.remote(error) }
        guard let kind = response.stopKind else { throw LSPCLIOwnerIPCError.invalidMessage }
        if kind == "not-running" { return .notRunning }
        if kind == "stopped" { return .stopped }
        if kind.hasPrefix("rejected:") { return .rejected(String(kind.dropFirst(9))) }
        if kind.hasPrefix("transport:") { return .transportFailed(String(kind.dropFirst(10))) }
        throw LSPCLIOwnerIPCError.invalidMessage
    }

    private func ensureDiscoveryStarted() {
        guard !discoveryStarted else { return }
        discoveryStarted = true
        discovery.start { [weak self] event in
            Task { await self?.receiveDiscovery(event) }
        }
    }

    private func receiveDiscovery(_ event: DiscoveryEvent) async {
        switch event {
        case .added(let service), .updated(_, let service):
            guard let resolved = await LSPBonjourTXTResolver().resolve(service),
                  let candidate = LSPDiscovery.pairingHost(
                    from: resolved.service,
                    resolvedEndpoint: resolved.endpoint
                  ) else { return }
            candidates[candidate.hostID] = candidate
            _ = try? await product.refreshPairedDiscovery(candidate)
            _ = await product.registerDiscoveredPairingHost(candidate)
        case .removed(let service):
            guard let candidate = candidates.values.first(where: { $0.discoveryServiceID == service.id }) else { return }
            candidates.removeValue(forKey: candidate.hostID)
            _ = await product.unregisterDiscoveredPairingHost(
                hostID: candidate.hostID,
                discoveryServiceID: service.id
            )
        case .failed:
            break
        }
    }

    private func resolvedHost(
        query: String,
        exactHostID: UUID?,
        persisted: [LSPHostRecord]
    ) -> CLILSPHost? {
        let requestedID = exactHostID ?? UUID(uuidString: query)
        if let requestedID {
            if let candidate = candidates[requestedID] { return cliHost(candidate, paired: persisted.contains { $0.hostID == requestedID }) }
            if let host = persisted.first(where: { $0.hostID == requestedID }) { return cliHost(host, paired: true) }
            return nil
        }
        if let candidate = candidates.values.first(where: {
            $0.name.caseInsensitiveCompare(query) == .orderedSame ||
                $0.host.caseInsensitiveCompare(query) == .orderedSame
        }) {
            return cliHost(candidate, paired: persisted.contains { $0.hostID == candidate.hostID })
        }
        if let host = persisted.first(where: {
            $0.name.caseInsensitiveCompare(query) == .orderedSame ||
                $0.address.caseInsensitiveCompare(query) == .orderedSame
        }) {
            return cliHost(host, paired: true)
        }
        return nil
    }

    private func stopCapture(hostID: UUID) {
        captures.removeValue(forKey: hostID)?.stop()
    }

    private func cliHost(_ host: LSPDiscoveredPairingHost, paired: Bool) -> CLILSPHost {
        .init(id: host.hostID, name: host.name, address: "\(host.host):\(host.port)", paired: paired)
    }

    private func cliHost(_ host: LSPHostRecord, paired: Bool) -> CLILSPHost {
        .init(id: host.hostID, name: host.name, address: "\(host.address):\(host.port)", paired: paired)
    }
}

private final class HeadlessLSPRenderer: MetalVideoRendering, @unchecked Sendable {
    private let lock = NSLock()
    private var commit: (@Sendable (Int) -> Void)?

    func enqueue(_ frame: DecodedVideoFrame) {
        lock.withLock { commit }?(frame.frameNumber)
    }

    func flush() {}

    func installCommandCommitHandler(_ handler: @escaping @Sendable (Int) -> Void) {
        lock.withLock { commit = handler }
    }
}

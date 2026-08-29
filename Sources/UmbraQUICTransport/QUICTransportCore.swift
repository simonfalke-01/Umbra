import Foundation

final class QUICTransportCore: QUICTransportProtocol, @unchecked Sendable {
    private enum DeadlineKey: Hashable {
        case tls
        case readiness
        case hello
        case authentication
        case waiting
        case send(UInt64)
    }

    private let configuration: QUICTransportConfiguration
    private let adapter: any QUICNetworkAdapter
    private let deadlines: any QUICDeadlineScheduling
    private let now: @Sendable () -> UInt64
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let scheduler: QUICSendScheduler
    private let stateMachine = QUICSessionStateMachine()
    private let controlDecoder = QUICControlFrameDecoder()
    private let receiveSequences = QUICReceiveSequenceTracker()
    private let handlerLock = NSLock()

    private var storedEventHandler: (@Sendable (QUICTransportEvent) -> Void)?
    private var storedAuthenticationHandler: (@Sendable (QUICApplicationAuthenticationHandoff) -> Void)?
    private var activeEventHandler: (@Sendable (QUICTransportEvent) -> Void)?
    private var activeAuthenticationHandler: (@Sendable (QUICApplicationAuthenticationHandoff) -> Void)?
    private var handlersFrozen = false
    private var deadlineTokens = [DeadlineKey: any QUICDeadlineToken]()
    private var verifiedPin: Data?
    private var networkReady = false
    private var helloComplete = false
    private var authenticationHandoffDelivered = false
    private var adapterCancelled = false
    private var generation: UInt64 = 0
    private var malformedCount = 0
    private var prematureCount = 0
    private var duplicateCount = 0
    private var staleCount = 0
    private var activeSessionID: Data?
    private var reliableSendInFlight = false
    private var lastOutboundRequestID: UInt64 = 0
    private var currentDatagramPayloadCap: Int?
    private var malformedTimes = [UInt64]()
    private var malformedTimesHead = 0
    private var invalidDatagramSecond: UInt64?
    private var invalidDatagramsThisSecond = 0
    private var consecutiveHighInvalidDatagramSeconds = 0

    var eventHandler: (@Sendable (QUICTransportEvent) -> Void)? {
        get { handlerLock.withLock { activeEventHandler ?? storedEventHandler } }
        set {
            handlerLock.withLock {
                guard !handlersFrozen else { return }
                storedEventHandler = newValue
            }
        }
    }

    var authenticationHandler: (@Sendable (QUICApplicationAuthenticationHandoff) -> Void)? {
        get { handlerLock.withLock { activeAuthenticationHandler ?? storedAuthenticationHandler } }
        set {
            handlerLock.withLock {
                guard !handlersFrozen else { return }
                storedAuthenticationHandler = newValue
            }
        }
    }

    init(
        configuration: QUICTransportConfiguration,
        adapter: any QUICNetworkAdapter,
        queue: DispatchQueue? = nil,
        deadlines: (any QUICDeadlineScheduling)? = nil,
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) throws {
        guard configuration.isValid else { throw QUICTransportError.invalidConfiguration }
        let workQueue = queue ?? DispatchQueue(label: "app.umbra.quic.core", qos: .userInteractive)
        self.configuration = configuration
        self.adapter = adapter
        self.queue = workQueue
        workQueue.setSpecific(key: queueKey, value: 1)
        self.deadlines = deadlines ?? DispatchQUICDeadlineScheduler(queue: workQueue)
        self.now = now
        scheduler = try QUICSendScheduler(
            mode: configuration.profile.mode,
            limits: configuration.profile.schedulerLimits
        )
    }

    func start() throws {
        guard handlerLock.withLock({
            guard let storedEventHandler, let storedAuthenticationHandler else { return false }
            activeEventHandler = storedEventHandler
            activeAuthenticationHandler = storedAuthenticationHandler
            handlersFrozen = true
            return true
        }) else {
            throw QUICTransportError.handlersRequired
        }
        try queue.sync {
            guard stateMachine.state == .idle else { throw QUICTransportError.invalidState }
            generation &+= 1
            let current = generation
            adapter.eventHandler = { [weak self] event in
                guard let self else { return }
                if DispatchQueue.getSpecific(key: self.queueKey) != nil {
                    self.handle(event, generation: current)
                } else {
                    self.queue.sync { self.handle(event, generation: current) }
                }
            }
            emit(.stateChanged(try stateMachine.start()))
            schedule(.tls, after: configuration.profile.timeouts.tlsNanoseconds, generation: current)
            adapter.start(configuration: configuration)
        }
    }

    func send(_ request: QUICOutboundRequest) {
        queue.async { [weak self] in
            guard let self, !stateMachine.isTerminal else { return }
            let state = stateMachine.state
            guard state == .ready || (state == .authenticatingApplication && request.lane == .control) else {
                recordPremature(terminal: request.lane != .control)
                return
            }
            guard request.wireMetadata != nil else {
                recordMalformed(
                    terminal: stateMachine.state != .ready,
                    reason: "missing v3 wire metadata"
                )
                return
            }
            let result = scheduler.enqueue(request, nowNanoseconds: now())
            emit(result.dispositions)
            pump()
        }
    }

    func setActiveSessionID(_ sessionID: Data?) throws {
        guard sessionID == nil || sessionID?.count == 16 else {
            throw QUICTransportError.invalidConfiguration
        }
        let apply = {
            guard self.stateMachine.state == .ready,
                  sessionID == nil || self.currentDatagramPayloadCap != nil
            else {
                throw QUICTransportError.invalidState
            }
            guard self.activeSessionID != sessionID else { return }
            self.activeSessionID = sessionID
            self.receiveSequences.reset()
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            try apply()
        } else {
            try queue.sync { try apply() }
        }
    }

    func applicationHelloDidComplete(success: Bool) {
        queue.async { [weak self] in
            guard let self, !stateMachine.isTerminal,
                  stateMachine.state == .authenticatingApplication,
                  authenticationHandoffDelivered,
                  !helloComplete
            else {
                self?.terminateFailed("invalid or duplicate HELLO completion")
                return
            }
            cancelDeadline(.hello)
            guard success else {
                terminateFailed("application HELLO failed")
                return
            }
            helloComplete = true
            schedule(
                .authentication,
                after: configuration.profile.timeouts.authenticationNanoseconds,
                generation: generation
            )
        }
    }

    func applicationAuthenticationDidComplete(success: Bool) {
        let apply = {
            guard !self.stateMachine.isTerminal, self.helloComplete else {
                self.terminateFailed("authentication completed before HELLO")
                return
            }
            self.cancelDeadline(.authentication)
            guard success else {
                self.terminateFailed("application authentication failed")
                return
            }
            do {
                let state = try self.stateMachine.applicationAuthenticationCompleted(success: true)
                self.adapter.setInboundBulkEnabled(true)
                self.emit(.stateChanged(state))
                self.pump() // Atomic on this queue: all post-auth lanes become eligible here.
            } catch {
                self.terminateFailed("invalid authentication transition")
            }
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            apply()
        } else {
            queue.sync(execute: apply)
        }
    }

    func acceptInboundBulk(requestID: UInt64, objectID: UInt64) {
        decideInboundBulk(requestID: requestID, objectID: objectID, accept: true)
    }

    func rejectInboundBulk(requestID: UInt64, objectID: UInt64) {
        decideInboundBulk(requestID: requestID, objectID: objectID, accept: false)
    }

    private func decideInboundBulk(requestID: UInt64, objectID: UInt64, accept: Bool) {
        queue.async { [weak self] in
            guard let self, !stateMachine.isTerminal else { return }
            guard stateMachine.state == .ready, requestID != 0, objectID != 0 else {
                recordPremature(terminal: true)
                return
            }
            adapter.decideInboundBulk(requestID: requestID, objectID: objectID, accept: accept)
        }
    }

    func cancel() {
        queue.async { [weak self] in self?.terminateCancelled() }
    }

    private func handle(_ event: QUICNetworkAdapterEvent, generation: UInt64) {
        guard self.generation == generation, !stateMachine.isTerminal else { return }
        switch event {
        case .peerVerificationStarted:
            if stateMachine.state == .verifyingPeer { return }
            do { emit(.stateChanged(try stateMachine.beginPeerVerification())) }
            catch { terminateFailed("invalid peer-verification transition") }
        case .peerVerified(let digest):
            if let verifiedPin {
                if verifiedPin != digest { terminateFailed("conflicting repeated SPKI verification") }
                return
            }
            guard digest == configuration.expectedLeafSPKISHA256 else {
                terminateFailed("adapter returned mismatched SPKI pin")
                return
            }
            verifiedPin = digest
            cancelDeadline(.tls)
            if !networkReady {
                schedule(
                    .readiness,
                    after: configuration.profile.timeouts.readinessNanoseconds,
                    generation: generation
                )
            }
            emit(.stateChanged(stateMachine.peerVerificationCompleted(success: true)))
            beginAuthenticationIfReady()
        case .peerVerificationFailed:
            terminateFailed("peer SPKI verification failed")
        case .ready(let alpn, let usableDatagramByteCount):
            guard alpn == QUICTransportConfiguration.applicationProtocol else {
                terminateFailed("unexpected ALPN")
                return
            }
            if networkReady { return }
            let payloadCap = Self.admittedDatagramPayloadByteCount(
                wireByteCount: usableDatagramByteCount
            )
            currentDatagramPayloadCap = payloadCap
            scheduler.updateUsableDatagramPayloadSize(
                payloadCap ?? 0
            )
            networkReady = true
            cancelDeadline(.readiness)
            do { emit(.stateChanged(try stateMachine.networkBecameReady())) }
            catch { terminateFailed("invalid readiness transition"); return }
            emit(
                .negotiated(
                    .init(
                        applicationProtocol: alpn,
                        usableDatagramPayloadSize: payloadCap ?? 0
                    )
                )
            )
            beginAuthenticationIfReady()
        case .datagramCapacityChanged(let wireByteCount):
            guard networkReady else {
                recordPremature(terminal: false)
                return
            }
            guard let payloadCount = Self.admittedDatagramPayloadByteCount(
                wireByteCount: wireByteCount
            ) else {
                currentDatagramPayloadCap = nil
                scheduler.updateUsableDatagramPayloadSize(0)
                endMediaSession("QUIC path cannot carry the complete phase-one ULM3 record")
                emit(.datagramCapacityChanged(wireByteCount: wireByteCount, payloadByteCount: 0))
                return
            }
            currentDatagramPayloadCap = payloadCount
            scheduler.updateUsableDatagramPayloadSize(payloadCount)
            emit(.datagramCapacityChanged(
                wireByteCount: QUICTransportProfile.semanticDatagramByteCount,
                payloadByteCount: payloadCount
            ))
            pump()
        case .waiting(let reason):
            if case .waiting = stateMachine.state { return }
            emit(.stateChanged(stateMachine.wait(reason: reason)))
            schedule(.waiting, after: configuration.profile.timeouts.waitingNanoseconds, generation: generation)
        case .recovered:
            guard case .waiting = stateMachine.state else { return }
            cancelDeadline(.waiting)
            do { emit(.stateChanged(try stateMachine.networkRecovered())); pump() }
            catch { terminateFailed("invalid path recovery") }
        case .pathChanged(let observation):
            emit(.pathChanged(observation))
        case .controlBytes(let bytes):
            receiveControl(bytes)
        case .datagram(let bytes):
            receiveDatagram(bytes)
        case .bulkHeader(let header):
            guard stateMachine.state == .ready else {
                recordPremature(terminal: true)
                return
            }
            emit(.bulkHeader(header))
        case .bulkObject(let object):
            guard stateMachine.state == .ready else {
                recordPremature(terminal: true)
                return
            }
            emit(.bulkObject(object))
        case .bulkFailure(let failure):
            guard stateMachine.state == .ready else {
                recordPremature(terminal: true)
                return
            }
            emit(.bulkFailure(failure))
            recordMalformed(terminal: false, reason: failure.reason)
        case .malformed(let reason):
            recordMalformed(
                terminal: stateMachine.state != .ready,
                invalidDatagram: false,
                reason: reason
            )
        case .failed(let reason):
            terminateFailed(reason)
        case .cancelled:
            terminateFailed("network adapter cancelled unexpectedly")
        }
    }

    private func beginAuthenticationIfReady() {
        guard networkReady,
              let verifiedPin,
              stateMachine.state == .authenticatingApplication,
              !authenticationHandoffDelivered
        else {
            return
        }
        authenticationHandoffDelivered = true
        schedule(.hello, after: configuration.profile.timeouts.helloNanoseconds, generation: generation)
        handlerLock.withLock { activeAuthenticationHandler }?(
            .init(leafSPKISHA256: verifiedPin)
        )
        pump() // Only .control is eligible before authenticated.
    }

    private func receiveControl(_ bytes: Data) {
        guard stateMachine.state == .authenticatingApplication || stateMachine.state == .ready else {
            recordPremature(terminal: true)
            return
        }
        do {
            for frame in try controlDecoder.append(bytes) {
                if frame.flags & 0x01 != 0 {
                    guard frame.requestID != 0, !frame.requestID.isMultiple(of: 2) else {
                        throw QUICWireCodec.WireError.malformed
                    }
                } else if frame.requestID != 0, !frame.requestID.isMultiple(of: 2) {
                    throw QUICWireCodec.WireError.malformed
                }
                emit(
                    .inbound(
                        .init(
                            lane: .control,
                            payload: frame.payload,
                            receivedAtNanoseconds: now(),
                            semanticSequence: nil,
                            objectID: nil,
                            controlFlags: frame.flags,
                            controlType: frame.type,
                            requestID: frame.requestID,
                            datagramChannel: nil,
                            datagramKind: nil,
                            datagramFlags: nil
                        )
                    )
                )
            }
        } catch {
            recordMalformed(terminal: true, reason: "malformed ULC3 stream")
        }
    }

    private func receiveDatagram(_ bytes: Data) {
        guard stateMachine.state == .ready else {
            recordPremature(terminal: true)
            return
        }
        do {
            let message = try QUICWireCodec.decodeDatagram(bytes)
            guard message.sessionID == activeSessionID else {
                recordMalformed(terminal: false, invalidDatagram: true, reason: "ULM3 session mismatch")
                return
            }
            switch receiveSequences.observe(
                channel: message.channel,
                sequence: message.semanticSequence,
                objectID: message.objectID
            ) {
            case .accepted:
                let lane = try QUICWireCodec.inboundLane(channel: message.channel, kind: message.kind)
                emit(
                    .inbound(
                        .init(
                            lane: lane,
                            payload: message.payload,
                            receivedAtNanoseconds: now(),
                            semanticSequence: message.semanticSequence,
                            objectID: message.objectID,
                            controlFlags: nil,
                            controlType: nil,
                            requestID: nil,
                            datagramChannel: message.channel,
                            datagramKind: message.kind,
                            datagramFlags: message.flags
                        )
                    )
                )
            case .duplicate:
                duplicateCount += 1
                emitCounters()
                recordInvalidDatagramRate()
            case .staleOrWrapped:
                staleCount += 1
                emitCounters()
                recordInvalidDatagramRate()
            }
        } catch {
            recordMalformed(terminal: false, invalidDatagram: true, reason: "malformed ULM3 DATAGRAM")
        }
    }

    private func pump() {
        guard !stateMachine.isTerminal else { return }
        let eligible: Set<QUICSemanticLane> = stateMachine.state == .ready
            ? Set(QUICSemanticLane.allCases.filter { $0 != .bulk })
            : [.control]
        let effectiveEligible = reliableSendInFlight
            ? eligible.filter { $0.delivery != .reliableOrdered }
            : eligible
        while true {
            let drain = scheduler.dequeue(nowNanoseconds: now(), eligibleLanes: Set(effectiveEligible))
            emit(drain.dispositions)
            guard !stateMachine.isTerminal else { return }
            guard let send = drain.send else { return }
            do {
                let submission = try makeSubmission(send)
                if send.lane.delivery == .reliableOrdered { reliableSendInFlight = true }
                let remaining = max(1, send.deadlineNanoseconds! - min(send.deadlineNanoseconds!, now()))
                let timeout = send.lane.delivery == .reliableOrdered
                    ? min(configuration.profile.timeouts.reliableSendNanoseconds, remaining)
                    : remaining
                schedule(.send(send.id), after: timeout, generation: generation)
                adapter.submit(submission) { [weak self] failure in
                    guard let self else { return }
                    self.queue.async { self.complete(send: send, failure: failure) }
                }
                if send.lane.delivery == .reliableOrdered { return }
            } catch {
                if send.lane.delivery == .reliableOrdered { reliableSendInFlight = false }
                if let disposition = scheduler.complete(
                    id: send.id,
                    failureDescription: "invalid v3 submission"
                ) {
                    emit(.sendDisposition(disposition))
                }
                if send.lane.delivery == .reliableOrdered {
                    terminateFailed("invalid ULC3 submission")
                    return
                }
                recordMalformed(terminal: false, reason: "invalid ULM3 submission")
            }
        }
    }

    private func makeSubmission(_ send: QUICScheduledSend) throws -> QUICNetworkSubmission {
        let header: Data
        guard let metadata = send.wireMetadata else { throw QUICWireCodec.WireError.malformed }
        switch metadata {
        case .control(let flags, let type, let requestID):
            if flags & 0x01 != 0 {
                guard requestID != 0, requestID.isMultiple(of: 2) else {
                    throw QUICWireCodec.WireError.malformed
                }
            } else if requestID != 0 {
                let next = lastOutboundRequestID.addingReportingOverflow(2)
                guard !next.overflow else { throw QUICWireCodec.WireError.malformed }
                let expected = lastOutboundRequestID == 0 ? UInt64(1) : next.partialValue
                guard requestID == expected, !requestID.isMultiple(of: 2) else {
                    throw QUICWireCodec.WireError.malformed
                }
                lastOutboundRequestID = requestID
            }
            header = try QUICWireCodec.controlHeader(
                flags: flags,
                type: type,
                requestID: requestID,
                payloadByteCount: send.payload.count
            )
        case .datagram(let session, let channel, let kind, let flags, let objectID):
            guard session == activeSessionID else {
                throw QUICWireCodec.WireError.unsupportedRoute
            }
            switch (channel, kind) {
            case (1, 1):
                guard send.lane == .inputEdge || send.lane == .inputState else {
                    throw QUICWireCodec.WireError.unsupportedRoute
                }
            case (2, 3):
                guard send.lane == .video else { throw QUICWireCodec.WireError.unsupportedRoute }
            case (4, 1):
                guard send.lane == .microphone else { throw QUICWireCodec.WireError.unsupportedRoute }
            default: throw QUICWireCodec.WireError.unsupportedRoute
            }
            try QUICWireCodec.validateOutboundPayload(
                channel: channel,
                kind: kind,
                objectID: objectID,
                payload: send.payload
            )
            header = try QUICWireCodec.datagramHeader(
                sessionID: session,
                channel: channel,
                kind: kind,
                flags: flags,
                sequence: send.semanticSequence,
                objectID: objectID,
                payloadByteCount: send.payload.count
            )
        }
        return .init(
            id: send.id,
            lane: send.lane,
            header: header,
            payload: send.payload,
            deadlineNanoseconds: send.deadlineNanoseconds!
        )
    }

    private func complete(send: QUICScheduledSend, failure: String?) {
        guard !stateMachine.isTerminal else { return }
        cancelDeadline(.send(send.id))
        if send.lane.delivery == .reliableOrdered { reliableSendInFlight = false }
        if let disposition = scheduler.complete(id: send.id, failureDescription: failure) {
            emit([disposition])
        }
        if failure != nil, send.lane.delivery == .reliableOrdered {
            terminateFailed("reliable QUIC send failed")
        } else {
            pump()
        }
    }

    private func recordPremature(terminal: Bool) {
        prematureCount += 1
        emitCounters()
        if terminal { terminateFailed("pre-auth DATAGRAM/bulk violation") }
    }

    private func recordMalformed(
        terminal: Bool,
        invalidDatagram: Bool = false,
        reason: String
    ) {
        malformedCount += 1
        emitCounters()
        if terminal {
            terminateFailed(reason)
            return
        }
        let timestamp = now()
        malformedTimes.append(timestamp)
        let cutoff = timestamp > QUICTransportProfile.malformedWindowNanoseconds
            ? timestamp - QUICTransportProfile.malformedWindowNanoseconds
            : 0
        while malformedTimesHead < malformedTimes.count,
              malformedTimes[malformedTimesHead] < cutoff
        {
            malformedTimesHead += 1
        }
        if malformedTimesHead >= 64, malformedTimesHead * 2 >= malformedTimes.count {
            malformedTimes = Array(malformedTimes[malformedTimesHead...])
            malformedTimesHead = 0
        }
        if malformedTimes.count - malformedTimesHead >=
            QUICTransportProfile.maximumMalformedMessagesPerWindow
        {
            terminateFailed("malformed record rolling-window limit exceeded")
            return
        }
        if invalidDatagram { recordInvalidDatagramRate() }
    }

    private func emitCounters() {
        emit(
            .abuseCounters(
                .init(
                    malformedMessages: malformedCount,
                    prematureMessages: prematureCount,
                    duplicateMessages: duplicateCount,
                    staleMessages: staleCount
                )
            )
        )
    }

    private func recordInvalidDatagramRate() {
        let second = now() / 1_000_000_000
        if invalidDatagramSecond == second {
            invalidDatagramsThisSecond += 1
        } else {
            if let previous = invalidDatagramSecond, second == previous + 1,
               invalidDatagramsThisSecond > QUICTransportProfile.maximumInvalidDatagramsPerSecond
            {
                consecutiveHighInvalidDatagramSeconds += 1
            } else {
                consecutiveHighInvalidDatagramSeconds = 0
            }
            invalidDatagramSecond = second
            invalidDatagramsThisSecond = 1
        }
        if invalidDatagramsThisSecond > QUICTransportProfile.maximumInvalidDatagramsPerSecond,
           consecutiveHighInvalidDatagramSeconds >= 2
        {
            terminateFailed("invalid DATAGRAM sustained-rate limit exceeded")
        }
    }

    private func schedule(_ key: DeadlineKey, after duration: UInt64, generation: UInt64) {
        cancelDeadline(key)
        let result = now().addingReportingOverflow(duration)
        let deadline = result.overflow ? UInt64.max : result.partialValue
        deadlineTokens[key] = deadlines.schedule(deadlineNanoseconds: deadline) { [weak self] in
            guard let self else { return }
            self.queue.async { self.deadlineExpired(key, generation: generation) }
        }
    }

    private func deadlineExpired(_ key: DeadlineKey, generation: UInt64) {
        guard self.generation == generation, !stateMachine.isTerminal else { return }
        deadlineTokens.removeValue(forKey: key)
        switch key {
        case .send(let id):
            guard let disposition = scheduler.complete(id: id, failureDescription: "send deadline") else { return }
            if disposition.lane.delivery == .reliableOrdered { reliableSendInFlight = false }
            emit([disposition])
            if disposition.lane.delivery == .reliableOrdered {
                terminateFailed("reliable-send deadline exceeded")
            } else {
                pump()
            }
        default:
            terminateFailed("\(key) deadline exceeded")
        }
    }

    private func cancelDeadline(_ key: DeadlineKey) {
        deadlineTokens.removeValue(forKey: key)?.cancel()
    }

    private func cancelAllDeadlines() {
        let tokens = deadlineTokens.values
        deadlineTokens = [:]
        tokens.forEach { $0.cancel() }
    }

    private func terminateFailed(_ reason: String) {
        guard !stateMachine.isTerminal else { return }
        let state = stateMachine.fail(reason: reason)
        generation &+= 1
        cancelAllDeadlines()
        emit(scheduler.cancel())
        cancelAdapterOnce()
        emit(.stateChanged(state))
    }

    private func terminateCancelled() {
        guard !stateMachine.isTerminal else { return }
        let state = stateMachine.cancel()
        generation &+= 1
        cancelAllDeadlines()
        emit(scheduler.cancel())
        cancelAdapterOnce()
        emit(.stateChanged(state))
    }

    private func cancelAdapterOnce() {
        guard !adapterCancelled else { return }
        adapterCancelled = true
        adapter.eventHandler = nil
        adapter.cancel()
    }

    private func emit(_ dispositions: [QUICSendDisposition]) {
        for disposition in dispositions {
            emit(.sendDisposition(disposition))
            if case .datagramTooLarge = disposition.outcome {
                switch disposition.lane {
                case .video:
                    emit(.videoRecoveryRequired)
                case .inputState, .audio, .microphone:
                    endMediaSession("ULM3 record exceeds current QUIC path capacity")
                    return
                default:
                    break
                }
            } else if case .transportFailure = disposition.outcome,
                      disposition.lane == .video
            {
                emit(.videoRecoveryRequired)
            }
        }
    }

    private func endMediaSession(_ reason: String) {
        guard activeSessionID != nil else { return }
        activeSessionID = nil
        receiveSequences.reset()
        let datagramLanes = Set(
            QUICSemanticLane.allCases.filter { $0.delivery != .reliableOrdered }
        )
        let discarded = scheduler.discardQueued(lanes: datagramLanes)
        discarded.forEach { emit(.sendDisposition($0)) }
        emit(.mediaSessionEnded(reason))
    }

    static func admittedDatagramPayloadByteCount(wireByteCount: Int) -> Int? {
        guard wireByteCount >= QUICTransportProfile.semanticDatagramByteCount else { return nil }
        return QUICTransportProfile.semanticDatagramPayloadByteCount
    }

    private func emit(_ event: QUICTransportEvent) {
        handlerLock.withLock { activeEventHandler ?? storedEventHandler }?(event)
    }
}

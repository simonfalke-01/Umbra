import CryptoKit
import Foundation
import Network
import Security

@available(macOS 13.0, *)
final class NWQUICNetworkAdapter: QUICNetworkAdapter, @unchecked Sendable {
    private enum WaitSource: Hashable { case group, control, datagram }
    private final class ImmutableDataOwner: @unchecked Sendable {
        let data: NSData
        init(_ data: Data) { self.data = data as NSData }
    }
    private final class BulkReceiveState: @unchecked Sendable {
        let connection: NWConnection
        var headerBytes = Data()
        var header: QUICInboundBulkHeader?
        var payload = Data()
        var reservedPayloadBytes = 0
        var approved = false
        var timeout: DispatchWorkItem?

        init(connection: NWConnection) {
            self.connection = connection
        }
    }
    private static let bulkHeaderBytes = 64
    private static let maximumBulkPayloadBytes = 16 * 1_048_576
    private static let maximumBulkStreams = 4
    private static let maximumBufferedBulkBytes = 32 * 1_048_576
    private let queue = DispatchQueue(label: "app.umbra.quic.network", qos: .userInteractive)
    private let handlerLock = NSLock()
    private let migrationTracker = QUICPathMigrationTracker()
    private var storedHandler: (@Sendable (QUICNetworkAdapterEvent) -> Void)?
    private var group: NWConnectionGroup?
    private var control: NWConnection?
    private var datagram: NWConnection?
    private var controlReady = false
    private var datagramReady = false
    private var readyEmitted = false
    private var controlReceiveStarted = false
    private var datagramReceiveStarted = false
    private var waitingSources = Set<WaitSource>()
    private var cancelled = false
    private var generation: UInt64 = 0
    private var negotiatedALPN: String?
    private var usableDatagramByteCount = 0
    private var inboundBulkEnabled = false
    private var bulkTimeoutNanoseconds: UInt64 = 5_000_000_000
    private var bulkReceivers: [ObjectIdentifier: BulkReceiveState] = [:]
    private var bulkReservedPayloadBytes = 0
    private var seenBulkObjectIDs = Set<UInt64>()

    var eventHandler: (@Sendable (QUICNetworkAdapterEvent) -> Void)? {
        get { handlerLock.withLock { storedHandler } }
        set { handlerLock.withLock { storedHandler = newValue } }
    }

    func start(configuration: QUICTransportConfiguration) {
        queue.async { [weak self] in self?.startOnQueue(configuration) }
    }

    func submit(
        _ submission: QUICNetworkSubmission,
        completion: @escaping @Sendable (String?) -> Void
    ) {
        queue.async { [weak self] in
            guard let self, !cancelled else {
                completion("adapter cancelled")
                return
            }
            if submission.lane.delivery == .reliableOrdered {
                submitControl(submission, completion: completion)
            } else {
                submitDatagram(submission, completion: completion)
            }
        }
    }

    func setInboundBulkEnabled(_ enabled: Bool) {
        queue.async { [weak self] in self?.inboundBulkEnabled = enabled }
    }

    func decideInboundBulk(requestID: UInt64, objectID: UInt64, accept: Bool) {
        queue.async { [weak self] in
            guard let self, !cancelled else { return }
            guard let state = bulkReceivers.values.first(where: {
                $0.header?.requestID == requestID && $0.header?.objectID == objectID
            }) else {
                emit(.bulkFailure(.init(
                    requestID: requestID,
                    objectID: objectID,
                    reason: "unknown ULB3 stream decision"
                )))
                return
            }
            guard accept else {
                failBulk(state, reason: "ULB3 metadata rejected")
                return
            }
            guard !state.approved else { return }
            state.approved = true
            receiveBulkPayload(state, generation: generation)
        }
    }

    func cancel() {
        queue.async { [weak self] in self?.cancelOnQueue() }
    }

    private func startOnQueue(_ configuration: QUICTransportConfiguration) {
        guard !cancelled, group == nil else { return }
        generation &+= 1
        let current = generation
        bulkTimeoutNanoseconds = configuration.profile.timeouts.maximumLaneAgeNanoseconds[.bulk]
            ?? 5_000_000_000
        emit(.peerVerificationStarted)

        let options = NWProtocolQUIC.Options(alpn: [QUICTransportConfiguration.applicationProtocol])
        options.idleTimeout = configuration.profile.mode == .latency ? 15_000 : 30_000
        options.maxUDPPayloadSize = 1_350
        options.maxDatagramFrameSize = QUICTransportProfile.semanticDatagramByteCount
        options.initialMaxStreamsBidirectional = 1
        options.initialMaxStreamsUnidirectional = 8
        options.initialMaxData = configuration.profile.mode == .latency ? 8 * 1_048_576 : 64 * 1_048_576
        options.initialMaxStreamDataBidirectionalLocal = 4 * 1_048_576
        options.initialMaxStreamDataBidirectionalRemote = 4 * 1_048_576
        options.initialMaxStreamDataUnidirectional = 16 * 1_048_576

        let security = options.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(security, .TLSv13)
        sec_protocol_options_set_tls_tickets_enabled(security, false)
        sec_protocol_options_set_tls_resumption_enabled(security, false)
        sec_protocol_options_set_tls_false_start_enabled(security, false)
        sec_protocol_options_set_peer_authentication_required(security, true)
        if let serverName = configuration.serverName {
            sec_protocol_options_set_tls_server_name(security, serverName)
        }
        let expectedPin = configuration.expectedLeafSPKISHA256
        sec_protocol_options_set_verify_block(security, { [weak self] _, trust, complete in
            guard let self, generation == current, !cancelled else {
                complete(false)
                return
            }
            guard let digest = Self.verifyLeaf(trust: trust, expectedPin: expectedPin) else {
                complete(false) // Authentication decision is final before teardown/event delivery.
                emit(.peerVerificationFailed)
                cancelOnQueue()
                return
            }
            complete(true)
            emit(.peerVerified(digest))
        }, queue)

        let endpoint = NWEndpoint.hostPort(
            host: .init(configuration.endpoint.host),
            port: .init(rawValue: configuration.endpoint.port)!
        )
        let parameters = NWParameters(quic: options)
        parameters.serviceClass = configuration.profile.mode == .latency ? .responsiveData : .interactiveVideo
        let connectionGroup = NWConnectionGroup(with: NWMultiplexGroup(to: endpoint), using: parameters)
        group = connectionGroup
        connectionGroup.stateUpdateHandler = { [weak self] state in
            self?.handleGroupState(state, generation: current)
        }
        connectionGroup.newConnectionHandler = { [weak self] connection in
            guard let self, self.generation == current, !cancelled else {
                connection.cancel()
                return
            }
            handleInboundBulkConnection(connection, generation: current)
        }
        connectionGroup.start(queue: queue)
    }

    private func handleGroupState(_ state: NWConnectionGroup.State, generation: UInt64) {
        guard self.generation == generation, !cancelled else { return }
        switch state {
        case .ready:
            leaveWaiting(.group)
            if control == nil { openFlows(generation: generation) }
        case .waiting(let error):
            enterWaiting(.group, reason: error.debugDescription)
        case .failed(let error):
            emit(.failed(error.debugDescription))
        case .cancelled:
            emit(.cancelled)
        case .setup:
            break
        @unknown default:
            emit(.failed("unknown Network.framework group state"))
        }
    }

    private func openFlows(generation: UInt64) {
        guard let group else { return }
        let streamOptions = NWProtocolQUIC.Options()
        streamOptions.direction = .bidirectional
        guard let control = NWConnection(from: group, using: streamOptions) else {
            emit(.failed("unable to open control stream 0"))
            return
        }
        self.control = control
        control.stateUpdateHandler = { [weak self, weak control] state in
            guard let self, let control, self.generation == generation, !cancelled else { return }
            handleControlState(state, connection: control, generation: generation)
        }
        control.start(queue: queue)

        let datagramOptions = NWProtocolQUIC.Options()
        datagramOptions.isDatagram = true
        guard let datagram = NWConnection(from: group, using: datagramOptions) else {
            emit(.failed("unable to open RFC 9221 flow"))
            return
        }
        self.datagram = datagram
        datagram.stateUpdateHandler = { [weak self, weak datagram] state in
            guard let self, let datagram, self.generation == generation, !cancelled else { return }
            handleDatagramState(state, connection: datagram, generation: generation)
        }
        datagram.pathUpdateHandler = { [weak self] path in
            self?.observe(path: path, generation: generation)
        }
        datagram.start(queue: queue)
    }

    private func handleControlState(
        _ state: NWConnection.State,
        connection: NWConnection,
        generation: UInt64
    ) {
        switch state {
        case .ready:
            leaveWaiting(.control)
            guard let metadata = connection.metadata(definition: NWProtocolQUIC.definition)
                    as? NWProtocolQUIC.Metadata,
                  metadata.streamIdentifier == 0
            else {
                emit(.failed("control stream is not QUIC stream 0"))
                return
            }
            negotiatedALPN = metadata.negotiatedALPN
            controlReady = true
            if !controlReceiveStarted {
                controlReceiveStarted = true
                receiveControl(connection, generation: generation)
            }
            emitReadyIfComplete()
        case .waiting(let error):
            enterWaiting(.control, reason: error.debugDescription)
        case .failed(let error): emit(.failed(error.debugDescription))
        case .cancelled: break
        case .setup, .preparing: break
        @unknown default: emit(.failed("unknown control-stream state"))
        }
    }

    private func handleDatagramState(
        _ state: NWConnection.State,
        connection: NWConnection,
        generation: UInt64
    ) {
        switch state {
        case .ready:
            leaveWaiting(.datagram)
            guard let metadata = connection.metadata(definition: NWProtocolQUIC.definition)
                    as? NWProtocolQUIC.Metadata
            else {
                emit(.failed("missing QUIC DATAGRAM metadata"))
                return
            }
            negotiatedALPN = metadata.negotiatedALPN
            usableDatagramByteCount = metadata.usableDatagramFrameSize
            datagramReady = true
            if !datagramReceiveStarted {
                datagramReceiveStarted = true
                receiveDatagram(connection, generation: generation)
            }
            emitReadyIfComplete()
        case .waiting(let error):
            enterWaiting(.datagram, reason: error.debugDescription)
        case .failed(let error): emit(.failed(error.debugDescription))
        case .cancelled: break
        case .setup, .preparing: break
        @unknown default: emit(.failed("unknown DATAGRAM state"))
        }
    }

    private func emitReadyIfComplete() {
        guard controlReady, datagramReady, !readyEmitted, let negotiatedALPN else { return }
        readyEmitted = true
        emit(.ready(alpn: negotiatedALPN, usableDatagramByteCount: usableDatagramByteCount))
    }

    private func enterWaiting(_ source: WaitSource, reason: String) {
        let wasEmpty = waitingSources.isEmpty
        waitingSources.insert(source)
        if wasEmpty { emit(.waiting(reason)) }
    }

    private func leaveWaiting(_ source: WaitSource) {
        guard waitingSources.remove(source) != nil, waitingSources.isEmpty else { return }
        emit(.recovered)
    }

    private func submitControl(
        _ submission: QUICNetworkSubmission,
        completion: @escaping @Sendable (String?) -> Void
    ) {
        guard let control else { completion("control stream unavailable"); return }
        control.batch {
            control.send(
                content: submission.header,
                contentContext: .defaultMessage,
                isComplete: false,
                completion: .idempotent
            )
            control.send(
                content: submission.payload,
                contentContext: .defaultMessage,
                isComplete: true,
                completion: .contentProcessed { error in completion(error?.debugDescription) }
            )
        }
    }

    private func submitDatagram(
        _ submission: QUICNetworkSubmission,
        completion: @escaping @Sendable (String?) -> Void
    ) {
        guard let datagram else { completion("DATAGRAM flow unavailable"); return }
        var content = dispatchDataRetaining(submission.header)
        content.append(dispatchDataRetaining(submission.payload))
        let current = DispatchTime.now().uptimeNanoseconds
        let expiration = submission.deadlineNanoseconds > current
            ? max(1, (submission.deadlineNanoseconds - current) / 1_000_000)
            : 1
        let context = NWConnection.ContentContext(
            identifier: "ULM3-\(submission.id)",
            expiration: expiration,
            priority: submission.lane.schedulerPriority <= 3 ? 1 : 0.5
        )
        datagram.send(
            content: content,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { error in completion(error?.debugDescription) }
        )
    }

    private func receiveControl(_ connection: NWConnection, generation: UInt64) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] data, _, complete, error in
            guard let self, self.generation == generation, !cancelled else { return }
            if let data { emit(.controlBytes(data)) }
            if let error { emit(.failed(error.debugDescription)) }
            else if complete { emit(.failed("ULC3 control stream closed")) }
            else { receiveControl(connection, generation: generation) }
        }
    }

    private func receiveDatagram(_ connection: NWConnection, generation: UInt64) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, self.generation == generation, !cancelled else { return }
            if let data { emit(.datagram(data)) }
            if let error { emit(.failed(error.debugDescription)) }
            else { receiveDatagram(connection, generation: generation) }
        }
    }

    private func handleInboundBulkConnection(_ connection: NWConnection, generation: UInt64) {
        guard inboundBulkEnabled else {
            connection.cancel()
            emit(.bulkFailure(.init(
                requestID: nil,
                objectID: nil,
                reason: "pre-auth peer-initiated QUIC stream"
            )))
            return
        }
        guard bulkReceivers.count < Self.maximumBulkStreams else {
            connection.cancel()
            emit(.bulkFailure(.init(
                requestID: nil,
                objectID: nil,
                reason: "ULB3 concurrent stream limit"
            )))
            return
        }
        let identifier = ObjectIdentifier(connection)
        let state = BulkReceiveState(connection: connection)
        bulkReceivers[identifier] = state
        scheduleBulkTimeout(state, generation: generation)
        connection.stateUpdateHandler = { [weak self, weak connection] streamState in
            guard let self, let connection, self.generation == generation, !cancelled else { return }
            switch streamState {
            case .ready:
                guard let metadata = connection.metadata(definition: NWProtocolQUIC.definition)
                        as? NWProtocolQUIC.Metadata,
                      metadata.streamIdentifier & 0x03 == 0x03 else {
                    failBulk(state, reason: "peer stream is not host-initiated unidirectional QUIC")
                    return
                }
                receiveBulkHeader(state, generation: generation)
            case .failed(let error):
                failBulk(state, reason: "ULB3 stream failed: \(error.debugDescription)")
            case .cancelled:
                if bulkReceivers[identifier] != nil {
                    failBulk(state, reason: "ULB3 stream reset before FIN")
                }
            case .waiting, .setup, .preparing:
                break
            @unknown default:
                failBulk(state, reason: "unknown ULB3 stream state")
            }
        }
        connection.start(queue: queue)
    }

    private func receiveBulkHeader(_ state: BulkReceiveState, generation: UInt64) {
        guard self.generation == generation, !cancelled,
              state.header == nil,
              bulkReceivers[ObjectIdentifier(state.connection)] === state else { return }
        let remaining = Self.bulkHeaderBytes - state.headerBytes.count
        guard remaining > 0 else {
            parseBulkHeader(state)
            return
        }
        state.connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: remaining
        ) { [weak self] data, _, complete, error in
            guard let self, self.generation == generation, !cancelled else { return }
            if let error {
                failBulk(state, reason: "ULB3 header failed: \(error.debugDescription)")
                return
            }
            if let data { state.headerBytes.append(data) }
            guard state.headerBytes.count <= Self.bulkHeaderBytes else {
                failBulk(state, reason: "ULB3 header overflow")
                return
            }
            if state.headerBytes.count == Self.bulkHeaderBytes {
                parseBulkHeader(state)
            } else if complete {
                failBulk(state, reason: "truncated ULB3 header")
            } else {
                receiveBulkHeader(state, generation: generation)
            }
        }
    }

    private func parseBulkHeader(_ state: BulkReceiveState) {
        let bytes = state.headerBytes
        guard bytes.count == Self.bulkHeaderBytes,
              bytes.prefix(4) == Data("ULB3".utf8),
              bytes[4] == 3,
              bytes[5] == 1,
              Self.readUInt16(bytes, 6) == 0 else {
            failBulk(state, reason: "malformed ULB3 header")
            return
        }
        let requestID = Self.readUInt64(bytes, 8)
        let objectID = Self.readUInt64(bytes, 16)
        let payloadLength = Self.readUInt64(bytes, 24)
        let digest = Data(bytes[32..<64])
        guard requestID != 0, objectID != 0,
              payloadLength <= UInt64(Self.maximumBulkPayloadBytes),
              let reserved = Int(exactly: payloadLength),
              bulkReservedPayloadBytes <= Self.maximumBufferedBulkBytes - reserved,
              seenBulkObjectIDs.count < 4_096,
              seenBulkObjectIDs.insert(objectID).inserted else {
            failBulk(state, reason: "ULB3 object bounds or duplicate object ID")
            return
        }
        let header = QUICInboundBulkHeader(
            kind: 1,
            requestID: requestID,
            objectID: objectID,
            payloadLength: payloadLength,
            sha256: digest
        )
        state.header = header
        state.reservedPayloadBytes = reserved
        bulkReservedPayloadBytes += reserved
        emit(.bulkHeader(header))
        // Payload receive remains paused until matching authenticated 0x0203 metadata accepts it.
    }

    private func receiveBulkPayload(_ state: BulkReceiveState, generation: UInt64) {
        guard self.generation == generation, !cancelled,
              state.approved,
              let header = state.header,
              bulkReceivers[ObjectIdentifier(state.connection)] === state else { return }
        let remaining = state.reservedPayloadBytes - state.payload.count
        let maximumLength = max(1, min(64 * 1_024, remaining + 1))
        state.connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: maximumLength
        ) { [weak self] data, _, complete, error in
            guard let self, self.generation == generation, !cancelled else { return }
            if let error {
                failBulk(state, reason: "ULB3 payload failed: \(error.debugDescription)")
                return
            }
            if let data {
                guard data.count <= state.reservedPayloadBytes - state.payload.count else {
                    failBulk(state, reason: "ULB3 payload has extra bytes")
                    return
                }
                state.payload.append(data)
            }
            if complete {
                guard state.payload.count == state.reservedPayloadBytes else {
                    failBulk(state, reason: "ULB3 payload truncated before FIN")
                    return
                }
                guard Data(SHA256.hash(data: state.payload)) == header.sha256 else {
                    failBulk(state, reason: "ULB3 payload digest mismatch")
                    return
                }
                completeBulk(state, object: .init(header: header, payload: state.payload))
            } else {
                receiveBulkPayload(state, generation: generation)
            }
        }
    }

    private func scheduleBulkTimeout(_ state: BulkReceiveState, generation: UInt64) {
        state.timeout?.cancel()
        let work = DispatchWorkItem { [weak self, weak state] in
            guard let self, let state, self.generation == generation, !cancelled else { return }
            failBulk(
                state,
                reason: state.approved
                    ? "ULB3 payload missing FIN before deadline"
                    : "ULB3 metadata was not matched before deadline"
            )
        }
        state.timeout = work
        queue.asyncAfter(
            deadline: .init(
                uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + bulkTimeoutNanoseconds
            ),
            execute: work
        )
    }

    private func completeBulk(_ state: BulkReceiveState, object: QUICInboundBulkObject) {
        let identifier = ObjectIdentifier(state.connection)
        guard bulkReceivers.removeValue(forKey: identifier) != nil else { return }
        state.timeout?.cancel()
        bulkReservedPayloadBytes -= state.reservedPayloadBytes
        state.connection.cancel()
        emit(.bulkObject(object))
    }

    private func failBulk(_ state: BulkReceiveState, reason: String) {
        let identifier = ObjectIdentifier(state.connection)
        guard bulkReceivers.removeValue(forKey: identifier) != nil else { return }
        state.timeout?.cancel()
        bulkReservedPayloadBytes -= state.reservedPayloadBytes
        state.connection.cancel()
        emit(.bulkFailure(.init(
            requestID: state.header?.requestID,
            objectID: state.header?.objectID,
            reason: reason
        )))
    }

    private func observe(path: NWPath, generation: UInt64) {
        guard self.generation == generation, !cancelled else { return }
        let status: QUICPathSnapshot.Status
        switch path.status {
        case .satisfied: status = .satisfied
        case .unsatisfied: status = .unsatisfied
        case .requiresConnection: status = .requiresConnection
        @unknown default: status = .unsatisfied
        }
        let snapshot = QUICPathSnapshot(
            status: status,
            usesWiFi: path.usesInterfaceType(.wifi),
            usesWiredEthernet: path.usesInterfaceType(.wiredEthernet),
            usesCellular: path.usesInterfaceType(.cellular),
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained,
            supportsIPv4: path.supportsIPv4,
            supportsIPv6: path.supportsIPv6
        )
        if let observation = migrationTracker.observe(snapshot) {
            emit(.pathChanged(observation))
        }
        if let datagram,
           let metadata = datagram.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata,
           metadata.usableDatagramFrameSize != usableDatagramByteCount
        {
            usableDatagramByteCount = metadata.usableDatagramFrameSize
            emit(.datagramCapacityChanged(usableDatagramByteCount))
        }
    }

    private func cancelOnQueue() {
        guard !cancelled else { return }
        cancelled = true
        generation &+= 1
        group?.cancel()
        control?.cancel()
        datagram?.cancel()
        for state in bulkReceivers.values {
            state.timeout?.cancel()
            state.connection.cancel()
        }
        bulkReceivers.removeAll()
        bulkReservedPayloadBytes = 0
        seenBulkObjectIDs.removeAll()
        group = nil
        control = nil
        datagram = nil
    }

    private func emit(_ event: QUICNetworkAdapterEvent) {
        handlerLock.withLock { storedHandler }?(event)
    }

    private func dispatchDataRetaining(_ data: Data) -> DispatchData {
        let owner = ImmutableDataOwner(data)
        let bytes = UnsafeRawBufferPointer(start: owner.data.bytes, count: owner.data.length)
        return DispatchData(bytesNoCopy: bytes, deallocator: .custom(queue) { _ = owner })
    }

    private static func verifyLeaf(trust: sec_trust_t, expectedPin: Data) -> Data? {
        let reference = sec_trust_copy_ref(trust).takeRetainedValue()
        guard let chain = SecTrustCopyCertificateChain(reference) as? [SecCertificate],
              let leaf = chain.first
        else {
            return nil
        }
        return try? QUICLeafSPKIVerifier.verify(
            certificateDER: SecCertificateCopyData(leaf) as Data,
            expectedSHA256: expectedPin
        )
    }

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        data[offset..<(offset + 2)].reduce(0) { ($0 << 8) | UInt16($1) }
    }

    private static func readUInt64(_ data: Data, _ offset: Int) -> UInt64 {
        data[offset..<(offset + 8)].reduce(0) { ($0 << 8) | UInt64($1) }
    }
}

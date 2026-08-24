import Foundation

public enum QUICOptimizationMode: String, Equatable, Sendable {
    case latency
    case quality
}

/// Stable application lanes multiplexed over one QUIC connection and one UDP endpoint.
/// Reliable lanes are opened once per connection; datagram lanes share one RFC 9221 flow.
public enum QUICSemanticLane: UInt8, CaseIterable, Equatable, Hashable, Sendable {
    case inputEdge = 0x01
    case control = 0x02
    case inputState = 0x03
    case audio = 0x04
    case video = 0x05
    case microphone = 0x06
    case hostEvents = 0x07
    case bulk = 0x08

    public enum Delivery: Equatable, Sendable {
        case reliableOrdered
        case unreliableDatagram
        case latestDatagram
    }

    public var delivery: Delivery {
        switch self {
        case .control, .hostEvents, .bulk:
            return .reliableOrdered
        case .inputState:
            return .latestDatagram
        case .inputEdge, .audio, .video, .microphone:
            return .unreliableDatagram
        }
    }

    /// Lower values are selected first. Input edges and control cannot queue behind media.
    public var schedulerPriority: Int {
        switch self {
        case .inputEdge: 0
        case .control: 1
        case .hostEvents: 2
        case .inputState: 3
        case .audio: 4
        case .microphone: 5
        case .video: 6
        case .bulk: 7
        }
    }

    public static let schedulerOrder = allCases.sorted {
        $0.schedulerPriority < $1.schedulerPriority
    }
}

public struct QUICTransportTimeoutProfile: Equatable, Sendable {
    public let tlsNanoseconds: UInt64
    public let helloNanoseconds: UInt64
    public let authenticationNanoseconds: UInt64
    public let readinessNanoseconds: UInt64
    public let waitingNanoseconds: UInt64
    public let reliableSendNanoseconds: UInt64
    public let maximumLaneAgeNanoseconds: [QUICSemanticLane: UInt64]
}

public struct QUICTransportProfile: Equatable, Sendable {
    public static let semanticDatagramByteCount = 1_152
    public static let maximumMalformedMessagesPerWindow = 32
    public static let malformedWindowNanoseconds: UInt64 = 10_000_000_000
    public static let maximumInvalidDatagramsPerSecond = 256

    public let mode: QUICOptimizationMode
    public let schedulerLimits: QUICSchedulerLimits
    public let timeouts: QUICTransportTimeoutProfile

    private init(
        mode: QUICOptimizationMode,
        schedulerLimits: QUICSchedulerLimits,
        timeouts: QUICTransportTimeoutProfile
    ) {
        self.mode = mode
        self.schedulerLimits = schedulerLimits
        self.timeouts = timeouts
    }

    public static func immutable(_ mode: QUICOptimizationMode) -> Self {
        let ages: [QUICSemanticLane: UInt64]
        let timeouts: QUICTransportTimeoutProfile
        switch mode {
        case .latency:
            ages = [
                .inputEdge: 8_000_000,
                .control: 250_000_000,
                .hostEvents: 250_000_000,
                .inputState: 8_000_000,
                .audio: 20_000_000,
                .microphone: 20_000_000,
                .video: 12_000_000,
                .bulk: 2_000_000_000,
            ]
            timeouts = .init(
                tlsNanoseconds: 5_000_000_000,
                helloNanoseconds: 2_000_000_000,
                authenticationNanoseconds: 3_000_000_000,
                readinessNanoseconds: 2_000_000_000,
                waitingNanoseconds: 2_000_000_000,
                reliableSendNanoseconds: 500_000_000,
                maximumLaneAgeNanoseconds: ages
            )
        case .quality:
            ages = [
                .inputEdge: 12_000_000,
                .control: 500_000_000,
                .hostEvents: 500_000_000,
                .inputState: 12_000_000,
                .audio: 40_000_000,
                .microphone: 40_000_000,
                .video: 35_000_000,
                .bulk: 5_000_000_000,
            ]
            timeouts = .init(
                tlsNanoseconds: 5_000_000_000,
                helloNanoseconds: 2_000_000_000,
                authenticationNanoseconds: 3_000_000_000,
                readinessNanoseconds: 2_000_000_000,
                waitingNanoseconds: 3_000_000_000,
                reliableSendNanoseconds: 1_000_000_000,
                maximumLaneAgeNanoseconds: ages
            )
        }
        return Self(mode: mode, schedulerLimits: .defaults(for: mode), timeouts: timeouts)
    }

    public var isValid: Bool {
        schedulerLimits.isValid &&
            Set(timeouts.maximumLaneAgeNanoseconds.keys) == Set(QUICSemanticLane.allCases) &&
            timeouts.maximumLaneAgeNanoseconds.values.allSatisfy { $0 > 0 } &&
            timeouts.tlsNanoseconds > 0 &&
            timeouts.helloNanoseconds > 0 &&
            timeouts.authenticationNanoseconds > 0 &&
            timeouts.readinessNanoseconds > 0 &&
            timeouts.waitingNanoseconds > 0 &&
            timeouts.reliableSendNanoseconds > 0
    }
}

public struct QUICTransportEndpoint: Equatable, Sendable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}

public struct QUICLaneQueueLimit: Equatable, Sendable {
    public let messageCount: Int
    public let byteCount: Int

    public init(messageCount: Int, byteCount: Int) {
        self.messageCount = messageCount
        self.byteCount = byteCount
    }
}

public struct QUICSchedulerLimits: Equatable, Sendable {
    public let totalMessageCount: Int
    public let totalByteCount: Int
    public let maximumInFlightSends: Int
    public let perLane: [QUICSemanticLane: QUICLaneQueueLimit]

    public init(
        totalMessageCount: Int,
        totalByteCount: Int,
        maximumInFlightSends: Int,
        perLane: [QUICSemanticLane: QUICLaneQueueLimit]
    ) {
        self.totalMessageCount = totalMessageCount
        self.totalByteCount = totalByteCount
        self.maximumInFlightSends = maximumInFlightSends
        self.perLane = perLane
    }

    public static func defaults(for mode: QUICOptimizationMode) -> Self {
        switch mode {
        case .latency:
            return Self(
                totalMessageCount: 160,
                totalByteCount: 8 * 1_048_576,
                maximumInFlightSends: 8,
                perLane: [
                    .inputEdge: .init(messageCount: 32, byteCount: 64 * 1_024),
                    .control: .init(messageCount: 32, byteCount: 2 * 1_048_576),
                    .inputState: .init(messageCount: 16, byteCount: 64 * 1_024),
                    .audio: .init(messageCount: 24, byteCount: 512 * 1_024),
                    .video: .init(messageCount: 32, byteCount: 5 * 1_048_576),
                    .microphone: .init(messageCount: 16, byteCount: 256 * 1_024),
                    .hostEvents: .init(messageCount: 8, byteCount: 128 * 1_024),
                    .bulk: .init(messageCount: 4, byteCount: 512 * 1_024),
                ]
            )
        case .quality:
            return Self(
                totalMessageCount: 384,
                totalByteCount: 48 * 1_048_576,
                maximumInFlightSends: 16,
                perLane: [
                    .inputEdge: .init(messageCount: 64, byteCount: 128 * 1_024),
                    .control: .init(messageCount: 64, byteCount: 4 * 1_048_576),
                    .inputState: .init(messageCount: 16, byteCount: 64 * 1_024),
                    .audio: .init(messageCount: 64, byteCount: 2 * 1_048_576),
                    .video: .init(messageCount: 128, byteCount: 36 * 1_048_576),
                    .microphone: .init(messageCount: 32, byteCount: 1 * 1_048_576),
                    .hostEvents: .init(messageCount: 16, byteCount: 256 * 1_024),
                    .bulk: .init(messageCount: 32, byteCount: 16 * 1_048_576),
                ]
            )
        }
    }

    public var isValid: Bool {
        guard totalMessageCount > 0,
              totalByteCount > 0,
              maximumInFlightSends > 0,
              maximumInFlightSends <= totalMessageCount,
              Set(perLane.keys) == Set(QUICSemanticLane.allCases)
        else {
            return false
        }
        return perLane.values.allSatisfy {
            $0.messageCount > 0 &&
                $0.byteCount > 0 &&
                $0.messageCount <= totalMessageCount &&
                $0.byteCount <= totalByteCount
        }
    }
}

public struct QUICTransportConfiguration: Equatable, Sendable {
    public static let applicationProtocol = "lumen/3"

    public let endpoint: QUICTransportEndpoint
    public let expectedLeafSPKISHA256: Data
    public let serverName: String?
    public let profile: QUICTransportProfile

    public init(
        endpoint: QUICTransportEndpoint,
        expectedLeafSPKISHA256: Data,
        serverName: String? = nil,
        mode: QUICOptimizationMode
    ) {
        self.endpoint = endpoint
        self.expectedLeafSPKISHA256 = expectedLeafSPKISHA256
        self.serverName = serverName
        profile = .immutable(mode)
    }

    public var isValid: Bool {
        !endpoint.host.isEmpty &&
            endpoint.host.utf8.count <= 253 &&
            endpoint.host.unicodeScalars.allSatisfy { !$0.properties.isWhitespace } &&
            endpoint.port != 0 &&
            expectedLeafSPKISHA256.count == 32 &&
            (serverName == nil || (!(serverName?.isEmpty ?? true) && (serverName?.utf8.count ?? 0) <= 253)) &&
            profile.isValid
    }
}

public enum QUICOutboundWireMetadata: Equatable, Sendable {
    case control(flags: UInt8, type: UInt16, requestID: UInt64)
    case datagram(sessionID: Data, channel: UInt8, kind: UInt8, flags: UInt8, objectID: UInt64)
}

public struct QUICOutboundRequest: Equatable, Sendable {
    public let lane: QUICSemanticLane
    public let payload: Data
    public let deadlineNanoseconds: UInt64?
    public let supersessionKey: UInt64?
    public let wireMetadata: QUICOutboundWireMetadata?

    public init(
        lane: QUICSemanticLane,
        payload: Data,
        deadlineNanoseconds: UInt64? = nil,
        supersessionKey: UInt64? = nil,
        wireMetadata: QUICOutboundWireMetadata? = nil
    ) {
        self.lane = lane
        self.payload = payload
        self.deadlineNanoseconds = deadlineNanoseconds
        self.supersessionKey = supersessionKey
        self.wireMetadata = wireMetadata
    }
}

public struct QUICScheduledSend: Equatable, Sendable {
    public let id: UInt64
    public let lane: QUICSemanticLane
    public let payload: Data
    public let deadlineNanoseconds: UInt64?
    public let enqueuedAtNanoseconds: UInt64
    public let semanticSequence: UInt64
    public let wireMetadata: QUICOutboundWireMetadata?
}

public enum QUICSendOutcome: Equatable, Sendable {
    /// Network.framework accepted the complete application message. This is not an ACK claim.
    case submittedToNetwork
    case superseded(by: UInt64)
    case expired
    case cancelled
    case rejectedQueueFull
    case rejectedInvalidRequest
    case rejectedPremature
    case sequenceExhausted
    case datagramTooLarge(maximumPayloadBytes: Int)
    case transportFailure(String)
}

public struct QUICSendDisposition: Equatable, Sendable {
    public let id: UInt64
    public let lane: QUICSemanticLane
    public let outcome: QUICSendOutcome
}

public struct QUICEnqueueResult: Equatable, Sendable {
    public let acceptedID: UInt64?
    public let dispositions: [QUICSendDisposition]

    public var isAccepted: Bool { acceptedID != nil }
}

public struct QUICSchedulerDrain: Equatable, Sendable {
    public let send: QUICScheduledSend?
    public let dispositions: [QUICSendDisposition]
}

public struct QUICSchedulerSnapshot: Equatable, Sendable {
    public let isCancelled: Bool
    public let queuedMessageCount: Int
    public let queuedByteCount: Int
    public let inFlightMessageCount: Int
    public let usableDatagramPayloadSize: Int?
    public let retainedQueueSlotCount: Int
}

public enum QUICConnectionState: Equatable, Sendable {
    case idle
    case preparing
    case verifyingPeer
    case authenticatingApplication
    case ready
    case waiting(String)
    case failed(String)
    case cancelled
}

public struct QUICPathSnapshot: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case satisfied
        case unsatisfied
        case requiresConnection
    }

    public let status: Status
    public let usesWiFi: Bool
    public let usesWiredEthernet: Bool
    public let usesCellular: Bool
    public let isExpensive: Bool
    public let isConstrained: Bool
    public let supportsIPv4: Bool
    public let supportsIPv6: Bool

    public init(
        status: Status,
        usesWiFi: Bool,
        usesWiredEthernet: Bool,
        usesCellular: Bool,
        isExpensive: Bool,
        isConstrained: Bool,
        supportsIPv4: Bool,
        supportsIPv6: Bool
    ) {
        self.status = status
        self.usesWiFi = usesWiFi
        self.usesWiredEthernet = usesWiredEthernet
        self.usesCellular = usesCellular
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.supportsIPv4 = supportsIPv4
        self.supportsIPv6 = supportsIPv6
    }
}

public struct QUICMigrationObservation: Equatable, Sendable {
    public let generation: UInt64
    public let previous: QUICPathSnapshot
    public let current: QUICPathSnapshot
}

public struct QUICNegotiatedParameters: Equatable, Sendable {
    public let applicationProtocol: String
    public let usableDatagramPayloadSize: Int
}

public struct QUICInboundMessage: Equatable, Sendable {
    public let lane: QUICSemanticLane
    public let payload: Data
    public let receivedAtNanoseconds: UInt64
    public let semanticSequence: UInt64?
    public let objectID: UInt64?
    public let controlFlags: UInt8?
    public let controlType: UInt16?
    public let requestID: UInt64?
    public let datagramChannel: UInt8?
    public let datagramKind: UInt8?
    public let datagramFlags: UInt8?

    public init(
        lane: QUICSemanticLane,
        payload: Data,
        receivedAtNanoseconds: UInt64,
        semanticSequence: UInt64?,
        objectID: UInt64?,
        controlFlags: UInt8?,
        controlType: UInt16?,
        requestID: UInt64?,
        datagramChannel: UInt8? = nil,
        datagramKind: UInt8? = nil,
        datagramFlags: UInt8? = nil
    ) {
        self.lane = lane
        self.payload = payload
        self.receivedAtNanoseconds = receivedAtNanoseconds
        self.semanticSequence = semanticSequence
        self.objectID = objectID
        self.controlFlags = controlFlags
        self.controlType = controlType
        self.requestID = requestID
        self.datagramChannel = datagramChannel
        self.datagramKind = datagramKind
        self.datagramFlags = datagramFlags
    }
}

public struct QUICAbuseCounters: Equatable, Sendable {
    public let malformedMessages: Int
    public let prematureMessages: Int
    public let duplicateMessages: Int
    public let staleMessages: Int
}

public struct QUICInboundBulkHeader: Equatable, Sendable {
    public let kind: UInt8
    public let requestID: UInt64
    public let objectID: UInt64
    public let payloadLength: UInt64
    public let sha256: Data

    public init(
        kind: UInt8,
        requestID: UInt64,
        objectID: UInt64,
        payloadLength: UInt64,
        sha256: Data
    ) {
        self.kind = kind
        self.requestID = requestID
        self.objectID = objectID
        self.payloadLength = payloadLength
        self.sha256 = sha256
    }
}

public struct QUICInboundBulkObject: Equatable, Sendable {
    public let header: QUICInboundBulkHeader
    public let payload: Data

    public init(header: QUICInboundBulkHeader, payload: Data) {
        self.header = header
        self.payload = payload
    }
}

public struct QUICInboundBulkFailure: Equatable, Sendable {
    public let requestID: UInt64?
    public let objectID: UInt64?
    public let reason: String

    public init(requestID: UInt64?, objectID: UInt64?, reason: String) {
        self.requestID = requestID
        self.objectID = objectID
        self.reason = reason
    }
}

public enum QUICTransportEvent: Equatable, Sendable {
    case stateChanged(QUICConnectionState)
    case negotiated(QUICNegotiatedParameters)
    case datagramCapacityChanged(wireByteCount: Int, payloadByteCount: Int)
    case videoRecoveryRequired
    case mediaSessionEnded(String)
    case pathChanged(QUICMigrationObservation)
    case laneWaiting(QUICSemanticLane, String)
    case datagramFlowWaiting(String)
    case abuseCounters(QUICAbuseCounters)
    case inbound(QUICInboundMessage)
    case bulkHeader(QUICInboundBulkHeader)
    case bulkObject(QUICInboundBulkObject)
    case bulkFailure(QUICInboundBulkFailure)
    case sendDisposition(QUICSendDisposition)
}

public enum QUICTransportError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidState
    case unsupportedPlatform
    case handlersRequired
}

/// Passed to the protocol-v3 authentication owner after TLS and QR pin verification.
/// Fresh signed nonces, request IDs, generations, and replay handling remain outside this target.
public struct QUICApplicationAuthenticationHandoff: Sendable {
    public let leafSPKISHA256: Data

    public init(leafSPKISHA256: Data) {
        self.leafSPKISHA256 = leafSPKISHA256
    }
}

public protocol QUICTransportProtocol: AnyObject, Sendable {
    var eventHandler: (@Sendable (QUICTransportEvent) -> Void)? { get set }
    var authenticationHandler: (@Sendable (QUICApplicationAuthenticationHandoff) -> Void)? { get set }

    func start() throws
    func send(_ request: QUICOutboundRequest)
    func setActiveSessionID(_ sessionID: Data?) throws
    func applicationHelloDidComplete(success: Bool)
    func applicationAuthenticationDidComplete(success: Bool)
    func acceptInboundBulk(requestID: UInt64, objectID: UInt64)
    func rejectInboundBulk(requestID: UInt64, objectID: UInt64)
    func cancel()
}

import Foundation
import UmbraCore
import UmbraNetworking

public enum ServiceOperation: String, Sendable {
    case discovery
    case loading
    case saving
    case refresh
    case addHost
    case pairing
    case applications
    case artwork
    case wake
    case connectivityTest
    case launch
    case resume
    case cancel
    case streaming
}

public enum UmbraServiceError: Error, Equatable, Sendable {
    case invalidInput(field: String, message: String)
    case hostNotFound(String)
    case applicationNotFound(hostID: String, applicationID: Int)
    case hostUnavailable(hostID: String?, message: String)
    case hostNotPaired(String)
    case unsupportedServer(String)
    case authenticationFailed(String)
    case networkBlocked([ConnectivityPort])
    case protocolFailure(operation: ServiceOperation, statusCode: Int?, message: String)
    case persistence(operation: ServiceOperation, message: String)
    case discovery(String)
    case wakeFailed(String)
    case pairingUnavailable
    case streamingUnavailable
    case streamFailure(SessionFailure)
    case sessionInProgress
    case sessionNotActive
    case cancelled
    case underlying(operation: ServiceOperation, message: String)
}

extension UmbraServiceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidInput(field, message):
            "Invalid \(field): \(message)"
        case let .hostNotFound(id):
            "The saved host \(id) could not be found."
        case let .applicationNotFound(_, applicationID):
            "Application \(applicationID) is not available on this host."
        case let .hostUnavailable(_, message), let .authenticationFailed(message),
             let .discovery(message), let .wakeFailed(message), let .underlying(_, message):
            message
        case let .hostNotPaired(id):
            "Host \(id) must be paired before this operation."
        case let .unsupportedServer(id):
            "Host \(id) is running an unsupported server version."
        case let .networkBlocked(ports):
            "The network blocked required ports: \(ports.map(\.description).joined(separator: ", "))."
        case let .protocolFailure(_, statusCode, message):
            statusCode.map { "Server returned \($0): \(message)" } ?? message
        case let .persistence(_, message):
            "Umbra could not update its saved state: \(message)"
        case .pairingUnavailable:
            "The native pairing adapter is not available in this build."
        case .streamingUnavailable:
            "The native streaming adapter is not available in this build."
        case let .streamFailure(failure):
            failure.message
        case .sessionInProgress:
            "Another streaming session is already active."
        case .sessionNotActive:
            "There is no active streaming session."
        case .cancelled:
            "The operation was cancelled."
        }
    }

    public func sessionFailure(stage: SessionStage? = nil) -> SessionFailure {
        if case let .streamFailure(failure) = self { return failure }
        let kind: SessionFailureKind
        let failingPorts: [UInt16]
        switch self {
        case .cancelled:
            kind = .cancelled
            failingPorts = []
        case .invalidInput:
            kind = .invalidConfiguration
            failingPorts = []
        case .hostUnavailable, .hostNotFound:
            kind = .hostUnavailable
            failingPorts = []
        case .hostNotPaired:
            kind = .hostNotPaired
            failingPorts = []
        case .applicationNotFound:
            kind = .applicationUnavailable
            failingPorts = []
        case .authenticationFailed:
            kind = .authenticationFailed
            failingPorts = []
        case let .networkBlocked(ports):
            kind = .networkBlocked
            failingPorts = ports.map(\.port)
        case .streamingUnavailable:
            kind = .decoderUnavailable
            failingPorts = []
        case .protocolFailure, .underlying:
            kind = .connectionFailed
            failingPorts = []
        default:
            kind = .unknown
            failingPorts = []
        }
        return SessionFailure(
            kind: kind,
            message: localizedDescription,
            stage: stage,
            failingPorts: failingPorts
        )
    }
}

public enum ConnectivityProtocol: String, Codable, Hashable, Sendable {
    case tcp = "TCP"
    case udp = "UDP"
}

public struct ConnectivityPort: Codable, Hashable, Sendable, CustomStringConvertible {
    public var transport: ConnectivityProtocol
    public var port: UInt16

    public init(_ transport: ConnectivityProtocol, _ port: UInt16) {
        self.transport = transport
        self.port = port
    }

    public var description: String { "\(transport.rawValue) \(port)" }

    public static let moonlightRequired: [Self] = [
        Self(.tcp, 47_984),
        Self(.tcp, 47_989),
        Self(.tcp, 48_010),
        Self(.udp, 47_998),
        Self(.udp, 47_999),
        Self(.udp, 48_000),
        Self(.udp, 48_010),
    ]
}

public enum ConnectivityTestResult: Equatable, Sendable {
    case clear
    case blocked([ConnectivityPort])
    case inconclusive(String)
}

public struct HostDetails: Equatable, Sendable {
    public var host: StreamHost
    public var addresses: [NetworkEndpoint]
    public var canWake: Bool
    public var runningApplication: StreamApplication?

    public init(host: StreamHost) {
        self.host = host
        self.addresses = host.uniqueAddresses
        self.canWake = host.macAddress.count == 6
        self.runningApplication = host.currentGameID.flatMap { id in
            host.applications.first { $0.id == id }
        }
    }
}

public enum SessionIntentKind: String, Codable, Sendable {
    case launch
    case resume
}

public struct SessionIntent: Sendable, Equatable {
    public var hostID: String
    public var applicationID: Int
    public var kind: SessionIntentKind
    public var preferences: StreamingPreferences
    /// Runtime-only refresh rate for the resolved target display. A nil value
    /// leaves Moonlight's client refresh hint unspecified.
    public var clientRefreshRateX100: Int32?
    /// Immutable session policy resolved before entering the service layer.
    public var effectivePolicy: EffectiveStreamingPolicy
    public var gamepadMask: UInt32
    public var persistGameControllers: Bool

    public init(
        hostID: String,
        applicationID: Int,
        kind: SessionIntentKind,
        preferences: StreamingPreferences = .default,
        clientRefreshRateX100: Int32? = nil,
        effectivePolicy: EffectiveStreamingPolicy? = nil,
        gamepadMask: UInt32 = 0,
        persistGameControllers: Bool = false
    ) {
        self.hostID = hostID
        self.applicationID = applicationID
        self.kind = kind
        self.preferences = preferences
        self.clientRefreshRateX100 = clientRefreshRateX100
        self.effectivePolicy = effectivePolicy ?? .resolve(for: preferences)
        self.gamepadMask = gamepadMask
        self.persistGameControllers = persistGameControllers
    }
}

public struct RemoteInputCredentials: Sendable, Equatable {
    public var key: Data
    public var initializationVector: Data

    public init(key: Data, initializationVector: Data) throws {
        guard key.count == 16 else {
            throw UmbraServiceError.invalidInput(field: "remote input key", message: "must contain 16 bytes")
        }
        guard initializationVector.count == 16 else {
            throw UmbraServiceError.invalidInput(field: "remote input IV", message: "must contain 16 bytes")
        }
        self.key = key
        self.initializationVector = initializationVector
    }

    public var keyID: UInt32 {
        initializationVector.prefix(4).reduce(UInt32.zero) { ($0 << 8) | UInt32($1) }
    }
}

public struct StreamBootstrap: Sendable, Equatable {
    public var sessionID: UUID
    public var host: StreamHost
    public var application: StreamApplication
    public var preferences: StreamingPreferences
    /// Runtime-only target display refresh hint. This is deliberately kept out
    /// of StreamingPreferences so display state is never persisted.
    public var clientRefreshRateX100: Int32?
    /// The exact session policy supplied by the launch boundary.
    public var effectivePolicy: EffectiveStreamingPolicy
    public var rtspSessionURL: URL?
    public var remoteInputCredentials: RemoteInputCredentials

    public init(
        sessionID: UUID,
        host: StreamHost,
        application: StreamApplication,
        preferences: StreamingPreferences,
        clientRefreshRateX100: Int32? = nil,
        effectivePolicy: EffectiveStreamingPolicy? = nil,
        rtspSessionURL: URL?,
        remoteInputCredentials: RemoteInputCredentials
    ) {
        self.sessionID = sessionID
        self.host = host
        self.application = application
        self.preferences = preferences
        self.clientRefreshRateX100 = clientRefreshRateX100
        self.effectivePolicy = effectivePolicy ?? .resolve(for: preferences)
        self.rtspSessionURL = rtspSessionURL
        self.remoteInputCredentials = remoteInputCredentials
    }
}

/// The final video mode selected during local media preparation. The selected
/// raw value is one exact Moonlight client-format bit, never a capability set.
public enum StreamVideoFidelityClass: String, Sendable, Equatable {
    case rateControlled
    case latencyRateControlled
    case visuallyLosslessRateControlled
    case codecLosslessYUV4208Bit
    case codecLosslessYUV42010Bit
    case codecLosslessYUV4448Bit
    case codecLosslessYUV44410Bit

    /// Codec-lossless classes preserve the selected YUV samples only. This remains false
    /// for any broader source-RGB or display-pixel losslessness claim.
    public var preservesSourceRGBExactly: Bool { false }
}

public struct StreamPreparationResult: Sendable, Equatable {
    public var selectedVideoFormat: Int32
    public var isHDR: Bool
    public var isYUV444: Bool
    public var fidelity: StreamVideoFidelityClass

    public init(
        selectedVideoFormat: Int32,
        isHDR: Bool,
        isYUV444: Bool,
        fidelity: StreamVideoFidelityClass = .rateControlled
    ) {
        self.selectedVideoFormat = selectedVideoFormat
        self.isHDR = isHDR
        self.isYUV444 = isYUV444
        self.fidelity = fidelity
    }

    public func applying(to preferences: StreamingPreferences) -> StreamingPreferences {
        var resolved = preferences
        resolved.enableHDR = isHDR
        resolved.enableYUV444 = isYUV444
        if resolved.autoAdjustBitrate {
            resolved.bitrateKbps = StreamingPreferences.defaultBitrateKbps(
                width: resolved.width,
                height: resolved.height,
                fps: resolved.exactFrameRate,
                yuv444: isYUV444
            )
        }
        return resolved
    }
}

public enum StreamDriverEvent: Sendable, Equatable {
    case connecting(SessionStage)
    case streaming(Date)
    case warning(String)
}

public enum HostServiceEvent: Sendable, Equatable {
    case hosts([StreamHost])
    case session(StreamSession?)
    case pairing(PairingProgress)
    case failure(UmbraServiceError)
}

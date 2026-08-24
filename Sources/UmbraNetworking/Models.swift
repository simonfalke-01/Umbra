import Foundation

public enum UmbraNetworkingError: Error, Equatable, Sendable {
    case invalidAddress(String)
    case invalidPort(String)
    case malformedXML(String)
    case missingRootElement
    case serverResponse(statusCode: Int, message: String)
    case invalidApplication(String)
    case invalidMACAddress(String)
    case invalidRequest(String)
    case invalidHTTPResponse
    case httpProtocolViolation(String)
    case httpResponseTooLarge(limit: Int)
    case httpStatus(Int)
    case certificateRejected(host: String)
    case clientIdentityUnavailable(String)
    case pairingUnsupported(stage: PairingStage)
}

extension UmbraNetworkingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidAddress(let value):
            "Invalid host address: \(value)"
        case .invalidPort(let value):
            "Invalid port: \(value)"
        case .malformedXML(let message):
            "Malformed XML: \(message)"
        case .missingRootElement:
            "Malformed XML: missing root element"
        case .serverResponse(let statusCode, let message):
            "Server returned \(statusCode): \(message)"
        case .invalidApplication(let message):
            "Invalid application entry: \(message)"
        case .invalidMACAddress(let value):
            "Invalid MAC address: \(value)"
        case .invalidRequest(let message):
            "Invalid request: \(message)"
        case .invalidHTTPResponse:
            "The server did not return an HTTP response"
        case .httpProtocolViolation(let message):
            "Invalid HTTP response: \(message)"
        case .httpResponseTooLarge(let limit):
            "HTTP response exceeded the \(limit)-byte endpoint limit"
        case .httpStatus(let status):
            "HTTP request failed with status \(status)"
        case .certificateRejected(let host):
            "The TLS certificate for \(host) did not match the pinned certificate"
        case .clientIdentityUnavailable(let message):
            "The GameStream client identity is unavailable: \(message)"
        case .pairingUnsupported(let stage):
            "Pairing is unavailable at stage \(stage.rawValue)"
        }
    }
}

public struct HostAddress: Hashable, Codable, Sendable {
    public static let defaultHTTPPort: UInt16 = 47_989
    public static let defaultHTTPSPort: UInt16 = 47_984

    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16 = HostAddress.defaultHTTPPort) {
        self.host = host
        self.port = port
    }

    public func url(scheme: String) throws -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        components.port = Int(port)
        guard let url = components.url else {
            throw UmbraNetworkingError.invalidAddress(description)
        }
        return url
    }
}

extension HostAddress: CustomStringConvertible {
    public var description: String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}

public struct DisplayMode: Equatable, Hashable, Codable, Sendable {
    public var width: Int
    public var height: Int
    public var refreshRate: Int

    public init(width: Int, height: Int, refreshRate: Int) {
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
    }
}

public struct GameStreamApp: Equatable, Hashable, Codable, Identifiable, Sendable {
    public var id: Int
    public var name: String
    public var supportsHDR: Bool
    public var isAppCollectorGame: Bool

    public init(id: Int, name: String, supportsHDR: Bool = false, isAppCollectorGame: Bool = false) {
        self.id = id
        self.name = name
        self.supportsHDR = supportsHDR
        self.isAppCollectorGame = isAppCollectorGame
    }
}

public enum PairState: String, Codable, Sendable {
    case paired
    case notPaired
    case unknown
}

public struct ServerInfo: Equatable, Codable, Sendable {
    public var name: String
    public var uniqueID: String
    public var macAddress: Data?
    public var localAddress: String?
    public var externalAddress: String?
    public var httpsPort: UInt16
    public var externalPort: UInt16?
    public var pairState: PairState
    public var currentGameID: Int
    public var state: String
    public var appVersion: String
    public var gfeVersion: String?
    public var gpuModel: String?
    public var serverCodecModeSupport: Int
    public var maxLumaPixelsHEVC: Int
    public var displayModes: [DisplayMode]
    public var isNVIDIAServerSoftware: Bool

    public init(
        name: String,
        uniqueID: String,
        macAddress: Data? = nil,
        localAddress: String? = nil,
        externalAddress: String? = nil,
        httpsPort: UInt16 = HostAddress.defaultHTTPSPort,
        externalPort: UInt16? = nil,
        pairState: PairState = .unknown,
        currentGameID: Int = 0,
        state: String = "",
        appVersion: String = "",
        gfeVersion: String? = nil,
        gpuModel: String? = nil,
        serverCodecModeSupport: Int = 1,
        maxLumaPixelsHEVC: Int = 0,
        displayModes: [DisplayMode] = [],
        isNVIDIAServerSoftware: Bool = false
    ) {
        self.name = name
        self.uniqueID = uniqueID
        self.macAddress = macAddress
        self.localAddress = localAddress
        self.externalAddress = externalAddress
        self.httpsPort = httpsPort
        self.externalPort = externalPort
        self.pairState = pairState
        self.currentGameID = currentGameID
        self.state = state
        self.appVersion = appVersion
        self.gfeVersion = gfeVersion
        self.gpuModel = gpuModel
        self.serverCodecModeSupport = serverCodecModeSupport
        self.maxLumaPixelsHEVC = maxLumaPixelsHEVC
        self.displayModes = displayModes
        self.isNVIDIAServerSoftware = isNVIDIAServerSoftware
    }
}

public struct LaunchResponse: Equatable, Sendable {
    public var sessionURL: URL?

    public init(sessionURL: URL?) {
        self.sessionURL = sessionURL
    }
}

public enum PairingStage: String, Codable, CaseIterable, Sendable {
    case requestingServerCertificate
    case exchangingChallenges
    case verifyingServerSecret
    case sendingClientSecret
    case confirmingPairChallenge
    case complete
}

public struct PairingProgress: Equatable, Sendable {
    public var stage: PairingStage
    public var message: String

    public init(stage: PairingStage, message: String) {
        self.stage = stage
        self.message = message
    }
}

public protocol PairingCoordinating: Sendable {
    func pair(host: HostAddress, pin: String) async throws -> AsyncStream<PairingProgress>
}

/// Pairing requires digest, AES, certificate signing, and signature verification primitives.
/// This explicit implementation prevents an incomplete or insecure handshake from being mistaken
/// for real pairing support while preserving the native API surface for a secure implementation.
public struct UnsupportedPairingCoordinator: PairingCoordinating {
    public init() {}

    public func pair(host: HostAddress, pin: String) async throws -> AsyncStream<PairingProgress> {
        throw UmbraNetworkingError.pairingUnsupported(stage: .requestingServerCertificate)
    }
}

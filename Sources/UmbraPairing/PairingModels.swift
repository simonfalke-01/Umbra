import Foundation
import Security
import UmbraNetworking

public enum PairingDigest: String, Sendable {
    case sha1
    case sha256

    public static func forServerVersion(_ version: String) throws -> PairingDigest {
        guard let majorComponent = version.split(separator: ".", omittingEmptySubsequences: false).first,
              let major = Int(majorComponent)
        else {
            throw PairingError.invalidServerVersion(version)
        }
        return major >= 7 ? .sha256 : .sha1
    }
}

public struct PairedHostIdentity: Equatable, Sendable {
    public let serverCertificateDER: Data

    public init(serverCertificateDER: Data) {
        self.serverCertificateDER = serverCertificateDER
    }
}

public enum PairingError: Error, Equatable, Sendable {
    case invalidPIN
    case invalidServerVersion(String)
    case identityUnavailable(String)
    case randomGeneration(status: OSStatus)
    case cryptography(operation: String, status: Int)
    case invalidCertificate(String)
    case invalidResponse(stage: PairingStage, reason: String)
    case serverRejected(stage: PairingStage)
    case alreadyInProgress
    case incorrectPIN
    case serverAuthenticationFailed
    case transport(stage: PairingStage, message: String)
    case unpairRejected(statusCode: Int)
    case cleanupFailed(pairing: String, cleanup: String)
    case cancelled
}

extension PairingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidPIN:
            "The pairing PIN must contain exactly four digits."
        case .invalidServerVersion(let version):
            "The server version is invalid: \(version)"
        case .identityUnavailable(let reason):
            "The client identity is unavailable: \(reason)"
        case .randomGeneration(let status):
            "Secure random generation failed with status \(status)."
        case .cryptography(let operation, let status):
            "Cryptographic operation \(operation) failed with status \(status)."
        case .invalidCertificate(let reason):
            "The pairing certificate is invalid: \(reason)"
        case .invalidResponse(let stage, let reason):
            "The host returned an invalid pairing response during \(stage.rawValue): \(reason)"
        case .serverRejected(let stage):
            "The host rejected pairing during \(stage.rawValue)."
        case .alreadyInProgress:
            "The host is already pairing with another client."
        case .incorrectPIN:
            "The pairing PIN was incorrect."
        case .serverAuthenticationFailed:
            "The host could not prove ownership of its pairing certificate."
        case .transport(let stage, let message):
            "The pairing request failed during \(stage.rawValue): \(message)"
        case .unpairRejected(let statusCode):
            "The host rejected the unpair request with status \(statusCode)."
        case .cleanupFailed(let pairing, let cleanup):
            "\(pairing) Cleanup also failed: \(cleanup)"
        case .cancelled:
            "Pairing was cancelled."
        }
    }
}

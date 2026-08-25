import Foundation
import UmbraCore

public enum UmbraIntegrationError: Error, Equatable, Sendable {
    case missingHostAddress(String)
    case missingServerAppVersion(String)
    case unsupportedVideoConfiguration(VideoCodecPreference)
    case codecLosslessUnavailable(String)
    case unsupportedRendererConfiguration(RendererPreference)
    case videoRendererUnavailable
    case audioDecoderUnavailable
    case audioOutputUnavailable
    case clientMicrophoneRequiredUnavailable(String)
    case mediaConfigurationFailed(String)
    case sessionNotPrepared(UUID)
    case preparedSessionMismatch(expected: UUID, actual: UUID)
    case streamingStageFailed(stage: SessionStage, code: Int32)
    case streamTerminated(code: Int32)
    case inputQueueOverflow
}

extension UmbraIntegrationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .missingHostAddress(hostID):
            "Host \(hostID) has no active streaming address."
        case let .missingServerAppVersion(hostID):
            "Host \(hostID) did not report a GameStream protocol version."
        case let .unsupportedVideoConfiguration(codec):
            "The requested \(String(describing: codec)) video configuration is not supported by this Mac."
        case let .codecLosslessUnavailable(reason):
            "Codec-lossless Quality mode is unavailable: \(reason)"
        case let .unsupportedRendererConfiguration(renderer):
            "The requested \(String(describing: renderer)) renderer is not available in the native macOS client."
        case .videoRendererUnavailable:
            "A native Metal video renderer has not been attached to the streaming window."
        case .audioDecoderUnavailable:
            "A native Opus decoder is not available in this build."
        case .audioOutputUnavailable:
            "No compatible Core Audio output is available."
        case let .clientMicrophoneRequiredUnavailable(reason):
            "Microphone forwarding is required but unavailable: \(reason)"
        case let .mediaConfigurationFailed(message):
            "The native media pipeline could not be configured: \(message)"
        case let .sessionNotPrepared(sessionID):
            "Streaming session \(sessionID.uuidString) was not prepared before it was started."
        case let .preparedSessionMismatch(expected, actual):
            "Streaming session \(actual.uuidString) cannot use preparation for \(expected.uuidString)."
        case let .streamingStageFailed(stage, code):
            "Streaming failed during \(stage.rawValue) with error \(code)."
        case let .streamTerminated(code):
            "The host terminated the stream with error \(code)."
        case .inputQueueOverflow:
            "Input delivery could not keep up; excess input was dropped to preserve responsiveness."
        }
    }
}

extension UmbraIntegrationError: SessionFailureProviding {
    public var sessionFailure: SessionFailure {
        let kind: SessionFailureKind
        let stage: SessionStage
        let errorCode: Int?
        switch self {
        case .missingHostAddress:
            kind = .hostUnavailable
            stage = .nameResolution
            errorCode = nil
        case .missingServerAppVersion:
            kind = .connectionFailed
            stage = .serverHandshake
            errorCode = nil
        case .unsupportedVideoConfiguration, .codecLosslessUnavailable:
            kind = .decoderUnavailable
            stage = .platformInitialization
            errorCode = nil
        case .unsupportedRendererConfiguration, .videoRendererUnavailable:
            kind = .rendererUnavailable
            stage = .platformInitialization
            errorCode = nil
        case .audioDecoderUnavailable, .audioOutputUnavailable, .mediaConfigurationFailed:
            kind = .audioUnavailable
            stage = .audioStreamInitialization
            errorCode = nil
        case .clientMicrophoneRequiredUnavailable:
            kind = .invalidConfiguration
            stage = .platformInitialization
            errorCode = nil
        case .sessionNotPrepared, .preparedSessionMismatch:
            kind = .invalidConfiguration
            stage = .platformInitialization
            errorCode = nil
        case let .streamingStageFailed(failureStage, code):
            kind = .connectionFailed
            stage = failureStage
            errorCode = Int(code)
        case let .streamTerminated(code):
            kind = .streamTerminated
            stage = .connection
            errorCode = Int(code)
        case .inputQueueOverflow:
            kind = .connectionFailed
            stage = .inputStreamInitialization
            errorCode = nil
        }
        return SessionFailure(
            kind: kind,
            message: localizedDescription,
            stage: stage,
            errorCode: errorCode
        )
    }
}

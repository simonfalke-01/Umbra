import AVFoundation
import Foundation

public enum ClientMicrophoneAuthorizationStatus: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted

    public var permitsCapture: Bool { self == .authorized }
}

public protocol ClientMicrophoneAuthorizing: Sendable {
    func status() -> ClientMicrophoneAuthorizationStatus
    func requestAuthorization() async -> ClientMicrophoneAuthorizationStatus
}

/// The permission boundary is independent of capture so RTSP microphone setup is
/// never requested until macOS has already authorized input access.
public struct SystemClientMicrophoneAuthorization: ClientMicrophoneAuthorizing, Sendable {
    public init() {}

    public func status() -> ClientMicrophoneAuthorizationStatus {
        Self.map(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    public func requestAuthorization() async -> ClientMicrophoneAuthorizationStatus {
        let existing = status()
        guard existing == .notDetermined else { return existing }
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        return status()
    }

    private static func map(_ status: AVAuthorizationStatus) -> ClientMicrophoneAuthorizationStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .restricted
        }
    }
}

public enum ClientMicrophonePreparationError: Error, Equatable, Sendable, CustomStringConvertible {
    case permissionDenied(ClientMicrophoneAuthorizationStatus)
    case noUsableHostAddress
    case socketCreationFailed(Int32)
    case socketBindingFailed(Int32)
    case socketNameQueryFailed(Int32)
    case socketConnectionFailed(Int32)
    case invalidClientPort
    case invalidGeneration
    case alreadyStarted
    case captureFailed(String)

    public var description: String {
        switch self {
        case let .permissionDenied(status):
            "Microphone access is \(status == .restricted ? "restricted" : "not allowed")"
        case .noUsableHostAddress:
            "The streaming host has no usable UDP address"
        case let .socketCreationFailed(code):
            "Could not create the microphone UDP socket (errno \(code))"
        case let .socketBindingFailed(code):
            "Could not bind the microphone UDP socket (errno \(code))"
        case let .socketNameQueryFailed(code):
            "Could not read the microphone UDP client port (errno \(code))"
        case let .socketConnectionFailed(code):
            "Could not connect the microphone UDP socket (errno \(code))"
        case .invalidClientPort:
            "The microphone UDP socket returned an invalid client port"
        case .invalidGeneration:
            "The host returned invalid microphone generation credentials"
        case .alreadyStarted:
            "Microphone forwarding is already active"
        case let .captureFailed(message):
            "Microphone capture could not start: \(message)"
        }
    }
}

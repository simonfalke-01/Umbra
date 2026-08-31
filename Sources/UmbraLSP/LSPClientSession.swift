import Foundation
import UmbraLSPTransport

/// Product-visible LSP connection state at application/control frequency.
public enum LSPClientSessionState: Equatable, Sendable {
    case idle
    case starting
    case running
    case stopped
    case failed(LSPTransportError)
}

/// Coarse LSP client-session coordinator.
///
/// Packet, media-fragment, and raw-input work remains exclusively inside the
/// native core; this actor owns only application lifecycle state.
public actor LSPClientSession {
    public private(set) var state: LSPClientSessionState = .idle
    private let transport: LSPTransport

    public init(configuration: LSPTransportConfiguration = .init()) throws {
        transport = try LSPTransport(configuration: configuration)
    }

    public func start() throws {
        guard state == .idle || state == .stopped else {
            throw LSPTransportError.invalidState
        }
        state = .starting
        do {
            try transport.start()
            state = .running
        } catch let error as LSPTransportError {
            state = .failed(error)
            throw error
        }
    }

    public func stop() throws {
        guard state == .running else {
            throw LSPTransportError.invalidState
        }
        do {
            try transport.stop()
            state = .stopped
        } catch let error as LSPTransportError {
            state = .failed(error)
            throw error
        }
    }

    public func telemetrySnapshot() throws -> LSPTelemetrySnapshot {
        try transport.telemetrySnapshot()
    }
}

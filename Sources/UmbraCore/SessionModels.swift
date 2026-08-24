import Foundation

public enum SessionStage: String, Codable, CaseIterable, Sendable {
    case platformInitialization
    case nameResolution
    case serverHandshake
    case controlStreamInitialization
    case videoStreamInitialization
    case audioStreamInitialization
    case inputStreamInitialization
    case connection
}

public enum SessionFailureKind: String, Codable, CaseIterable, Sendable {
    case cancelled
    case invalidConfiguration
    case hostUnavailable
    case hostNotPaired
    case applicationUnavailable
    case connectionFailed
    case authenticationFailed
    case networkBlocked
    case decoderUnavailable
    case rendererUnavailable
    case audioUnavailable
    case streamTerminated
    case unknown
}

public struct SessionFailure: Error, Codable, Hashable, Sendable, Identifiable, LocalizedError {
    public let id: UUID
    public var kind: SessionFailureKind
    public var message: String
    public var stage: SessionStage?
    public var errorCode: Int?
    public var failingPorts: [UInt16]
    public var occurredAt: Date

    public init(
        id: UUID = UUID(),
        kind: SessionFailureKind,
        message: String,
        stage: SessionStage? = nil,
        errorCode: Int? = nil,
        failingPorts: [UInt16] = [],
        occurredAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.message = message
        self.stage = stage
        self.errorCode = errorCode
        self.failingPorts = failingPorts
        self.occurredAt = occurredAt
    }

    public var errorDescription: String? { message }
}

/// Supplies a fully classified session failure without coupling callers to the
/// module that produced it. Integration and service layers can both conform to
/// this Core-owned contract without introducing a dependency cycle.
public protocol SessionFailureProviding: Error, Sendable {
    var sessionFailure: SessionFailure { get }
}

extension SessionFailure: SessionFailureProviding {
    public var sessionFailure: SessionFailure { self }
}

public struct SessionResult: Codable, Hashable, Sendable {
    public var portTestResult: Int
    public var quitHostApplication: Bool
    public var endedAt: Date

    public init(portTestResult: Int = 0, quitHostApplication: Bool = false, endedAt: Date = Date()) {
        self.portTestResult = portTestResult
        self.quitHostApplication = quitHostApplication
        self.endedAt = endedAt
    }
}

public enum SessionState: Codable, Hashable, Sendable {
    case idle
    case preparing
    case connecting(stage: SessionStage)
    case streaming(startedAt: Date)
    case stopping(quitHostApplication: Bool)
    case finished(SessionResult)
    case failed(SessionFailure)

    public var isTerminal: Bool {
        switch self {
        case .finished, .failed:
            true
        default:
            false
        }
    }
}

public struct StreamSession: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var hostID: String
    public var applicationID: Int
    public var preferences: StreamingPreferences
    public var state: SessionState
    public var launchWarnings: [String]
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        hostID: String,
        applicationID: Int,
        preferences: StreamingPreferences = .default,
        state: SessionState = .idle,
        launchWarnings: [String] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.hostID = hostID
        self.applicationID = applicationID
        self.preferences = preferences
        self.state = state
        self.launchWarnings = launchWarnings
        self.createdAt = createdAt
    }

    public func validate() throws {
        guard !hostID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelValidationError(field: "session.hostID", reason: "must not be empty")
        }
        guard applicationID > 0 else {
            throw ModelValidationError(field: "session.applicationID", reason: "must be greater than zero")
        }
        try preferences.validate()
    }
}

import CLSPCore
import Foundation

/// Congestion profile selected for an LSP connection.
public enum LSPTransportProfile: Sendable {
    /// Safe delay-adaptive behavior for ordinary networks.
    case adaptiveLowLatency

    /// Explicitly provisioned competition-LAN behavior.
    case competitionLAN(capacityMbps: UInt32)
}

/// Coarse native transport construction settings.
public struct LSPTransportConfiguration: Sendable {
    /// LSP UDP application port.
    public var port: UInt16

    /// Congestion-control profile and optional explicit capacity ceiling.
    public var profile: LSPTransportProfile

    /// Low-rate telemetry publication interval.
    public var telemetryInterval: Duration

    /// Creates transport settings without starting a connection.
    ///
    /// - Parameters:
    ///   - port: Nonzero LSP UDP application port.
    ///   - profile: Safe adaptive profile by default.
    ///   - telemetryInterval: Snapshot interval; values below 250 ms are rejected.
    public init(
        port: UInt16 = 48_030,
        profile: LSPTransportProfile = .adaptiveLowLatency,
        telemetryInterval: Duration = .seconds(1)
    ) {
        self.port = port
        self.profile = profile
        self.telemetryInterval = telemetryInterval
    }
}

/// Security providers linked into the native LSP core.
public struct LSPTransportProviders: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Commercial wolfSSL DTLS 1.3 provider.
    public static let wolfSSL = Self(rawValue: UInt32(CLSP_PROVIDER_WOLFSSL.rawValue))

    /// libSRTP AES-128-GCM provider.
    public static let libSRTP = Self(rawValue: UInt32(CLSP_PROVIDER_LIBSRTP.rawValue))
}

/// Native lifecycle state copied at telemetry frequency.
public enum LSPTransportLifecycle: UInt32, Sendable {
    case created = 0
    case running = 1
    case stopped = 2
}

/// Low-rate telemetry copied from the native packet core.
public struct LSPTelemetrySnapshot: Equatable, Sendable {
    /// Coarse native lifecycle state.
    public var lifecycle: LSPTransportLifecycle

    /// Production security providers linked into the native core.
    public var providers: LSPTransportProviders

    /// Authenticated receive count.
    public var receivedDatagrams: UInt64

    /// Socket submission count.
    public var transmittedDatagrams: UInt64

    /// Count discarded by bounded native policy.
    public var droppedDatagrams: UInt64

    /// DTLS, SRTP, and SRTCP authentication failure count.
    public var authenticationFailures: UInt64
}

/// Stable typed failure returned by the coarse LSP transport façade.
public enum LSPTransportError: Error, Equatable, LocalizedError, Sendable {
    case abiMismatch(expected: UInt32, actual: UInt32)
    case sourceDigestMismatch(expected: String, actual: String)
    case missingWolfSSL
    case missingLibSRTP
    case invalidConfiguration
    case invalidState
    case reentrantCallback
    case resourceExhausted
    case unsupported
    case internalFailure
    case unknownStatus(Int32)

    public var errorDescription: String? {
        switch self {
        case .abiMismatch(let expected, let actual):
            "LSP native ABI mismatch: expected \(expected), received \(actual)."
        case .sourceDigestMismatch:
            "LSP portable-core source digest does not match this client build."
        case .missingWolfSSL:
            "LSP requires the commercial wolfSSL DTLS 1.3 provider."
        case .missingLibSRTP:
            "LSP requires the libSRTP AES-GCM provider."
        case .invalidConfiguration:
            "The LSP transport configuration is invalid."
        case .invalidState:
            "The LSP transport lifecycle transition is invalid."
        case .reentrantCallback:
            "An LSP lifecycle operation cannot run from its native callback."
        case .resourceExhausted:
            "A bounded LSP native resource is unavailable."
        case .unsupported:
            "The requested LSP capability is not implemented."
        case .internalFailure:
            "The LSP native core reported an internal failure."
        case .unknownStatus(let status):
            "The LSP native core returned unknown status \(status)."
        }
    }
}

/// Coarse application lifecycle boundary over the native C++23 LSP core.
///
/// This type never receives a per-packet or raw-input callback. Swift owns only
/// configuration, start/stop, and low-rate telemetry snapshots.
public final class LSPTransport: @unchecked Sendable {
    /// ABI version compiled into the Swift façade.
    public static let abiVersion: UInt32 = 1

    /// Expected source digest for Lumen's mirrored portable protocol core.
    public static let sourceDigest = "7f338b3da343cc9b1fdc36d7a2590cfccdf00afd87c12d8cfc1acfff0c6e6362"

    /// Providers compiled into the native target.
    public static var availableProviders: LSPTransportProviders {
        LSPTransportProviders(rawValue: clsp_core_provider_flags())
    }

    private let core: OpaquePointer

    /// Validates ABI and source identity, then creates an inactive native handle.
    ///
    /// - Parameter configuration: Coarse construction settings.
    /// - Throws: `LSPTransportError` on ABI, digest, or configuration failure.
    public init(configuration: LSPTransportConfiguration = .init()) throws {
        let actualABIVersion = clsp_core_abi_version()
        guard actualABIVersion == Self.abiVersion else {
            throw LSPTransportError.abiMismatch(expected: Self.abiVersion, actual: actualABIVersion)
        }
        let actualDigest = String(cString: clsp_core_source_digest())
        guard actualDigest == Self.sourceDigest else {
            throw LSPTransportError.sourceDigestMismatch(expected: Self.sourceDigest, actual: actualDigest)
        }

        var nativeConfiguration = try Self.makeNativeConfiguration(configuration)
        var output: OpaquePointer?
        let status = clsp_core_create(&nativeConfiguration, nil, &output)
        try Self.requireSuccess(status)
        guard let output else {
            throw LSPTransportError.internalFailure
        }
        core = output
    }

    deinit {
        clsp_core_release(core)
    }

    /// Starts native ownership only when both production security providers are linked.
    ///
    /// - Throws: A fail-closed provider or lifecycle error.
    public func start() throws {
        try Self.requireSuccess(clsp_core_start(core))
    }

    /// Stops and quiesces a running native transport.
    ///
    /// - Throws: A typed lifecycle error.
    public func stop() throws {
        try Self.requireSuccess(clsp_core_stop(core))
    }

    /// Copies one low-rate telemetry snapshot without exposing packet storage.
    ///
    /// - Returns: Coarse counters and lifecycle state.
    /// - Throws: A typed native status.
    public func telemetrySnapshot() throws -> LSPTelemetrySnapshot {
        var native = clsp_telemetry_snapshot_t()
        try Self.requireSuccess(clsp_core_copy_telemetry(core, &native))
        guard let lifecycle = LSPTransportLifecycle(rawValue: native.lifecycle_state) else {
            throw LSPTransportError.internalFailure
        }
        return LSPTelemetrySnapshot(
            lifecycle: lifecycle,
            providers: LSPTransportProviders(rawValue: native.provider_flags),
            receivedDatagrams: native.received_datagrams,
            transmittedDatagrams: native.transmitted_datagrams,
            droppedDatagrams: native.dropped_datagrams,
            authenticationFailures: native.authentication_failures
        )
    }

    private static func makeNativeConfiguration(
        _ configuration: LSPTransportConfiguration
    ) throws -> clsp_configuration_t {
        guard configuration.port != 0 else {
            throw LSPTransportError.invalidConfiguration
        }
        let components = configuration.telemetryInterval.components
        guard components.seconds >= 0, components.attoseconds >= 0 else {
            throw LSPTransportError.invalidConfiguration
        }
        let wholeMilliseconds = components.seconds.multipliedReportingOverflow(by: 1_000)
        guard !wholeMilliseconds.overflow else {
            throw LSPTransportError.invalidConfiguration
        }
        let fractionalMilliseconds = components.attoseconds / 1_000_000_000_000_000
        let totalMilliseconds = wholeMilliseconds.partialValue.addingReportingOverflow(fractionalMilliseconds)
        guard !totalMilliseconds.overflow,
              totalMilliseconds.partialValue >= 250,
              totalMilliseconds.partialValue <= Int64(UInt32.max)
        else {
            throw LSPTransportError.invalidConfiguration
        }

        var native = clsp_configuration_t()
        native.abi_version = Self.abiVersion
        native.structure_size = UInt32(MemoryLayout<clsp_configuration_t>.size)
        native.port = configuration.port
        native.telemetry_interval_milliseconds = UInt32(totalMilliseconds.partialValue)
        switch configuration.profile {
        case .adaptiveLowLatency:
            native.profile = UInt32(CLSP_PROFILE_ADAPTIVE_LOW_LATENCY.rawValue)
            native.competition_capacity_mbps = 0
        case .competitionLAN(let capacityMbps):
            guard capacityMbps > 0 else {
                throw LSPTransportError.invalidConfiguration
            }
            native.profile = UInt32(CLSP_PROFILE_COMPETITION_LAN.rawValue)
            native.competition_capacity_mbps = capacityMbps
        }
        return native
    }

    private static func requireSuccess(_ status: clsp_status_t) throws {
        switch status {
        case CLSP_STATUS_OK:
            return
        case CLSP_STATUS_ABI_MISMATCH:
            throw LSPTransportError.abiMismatch(expected: abiVersion, actual: clsp_core_abi_version())
        case CLSP_STATUS_MISSING_WOLFSSL:
            throw LSPTransportError.missingWolfSSL
        case CLSP_STATUS_MISSING_LIBSRTP:
            throw LSPTransportError.missingLibSRTP
        case CLSP_STATUS_INVALID_ARGUMENT, CLSP_STATUS_INVALID_CONFIGURATION:
            throw LSPTransportError.invalidConfiguration
        case CLSP_STATUS_INVALID_STATE:
            throw LSPTransportError.invalidState
        case CLSP_STATUS_REENTRANT_CALLBACK:
            throw LSPTransportError.reentrantCallback
        case CLSP_STATUS_RESOURCE_EXHAUSTED:
            throw LSPTransportError.resourceExhausted
        case CLSP_STATUS_UNSUPPORTED:
            throw LSPTransportError.unsupported
        case CLSP_STATUS_INTERNAL_FAILURE:
            throw LSPTransportError.internalFailure
        default:
            throw LSPTransportError.unknownStatus(Int32(status.rawValue))
        }
    }
}

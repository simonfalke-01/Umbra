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

    /// Maximum synchronous DTLS authentication time.
    public var handshakeTimeout: Duration

    /// Creates transport settings without starting a connection.
    ///
    /// - Parameters:
    ///   - port: Nonzero LSP UDP application port.
    ///   - profile: Safe adaptive profile by default.
    ///   - telemetryInterval: Snapshot interval; values below 250 ms are rejected.
    ///   - handshakeTimeout: Exact-security startup deadline from one through 30 seconds.
    public init(
        port: UInt16 = 48_030,
        profile: LSPTransportProfile = .adaptiveLowLatency,
        telemetryInterval: Duration = .seconds(1),
        handshakeTimeout: Duration = .seconds(5)
    ) {
        self.port = port
        self.profile = profile
        self.telemetryInterval = telemetryInterval
        self.handshakeTimeout = handshakeTimeout
    }
}

/// Exact remote LSP endpoint derived from an invitation or persisted trust.
public struct LSPTransportEndpoint: Equatable, Sendable {
    /// DNS name or numeric IP literal.
    public var host: String

    /// Single LSP UDP application port.
    public var port: UInt16

    /// SHA-256 digest of the server certificate's DER SubjectPublicKeyInfo.
    public var serverSPKISHA256: Data

    /// Creates a pinned endpoint.
    public init(host: String, port: UInt16 = 48_030, serverSPKISHA256: Data) {
        self.host = host
        self.port = port
        self.serverSPKISHA256 = serverSPKISHA256
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
    case connecting = 1
    case authenticated = 2
    case stopped = 3
    case failed = 4
}

/// Authenticated version-one LSPC flags.
public struct LSPControlFlags: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let acknowledgementRequired = Self(rawValue: 1 << 0)
    public static let response = Self(rawValue: 1 << 1)
    public static let errorResponse = Self(rawValue: 1 << 2)
    public static let acknowledgementOnly = Self(rawValue: 1 << 3)
    public static let finalChunk = Self(rawValue: 1 << 4)
}

/// One authenticated, de-duplicated LSPC frame copied at control frequency.
public struct LSPControlEvent: Equatable, Sendable {
    public var messageType: UInt16
    public var flags: LSPControlFlags
    public var connectionGeneration: UInt32
    public var messageID: UInt64
    public var requestID: UInt64
    public var payload: Data
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
    case invalidEndpoint
    case socketFailure
    case dtlsFailure
    case spkiMismatch
    case srtpFailure
    case notAuthenticated
    case controlWindowFull
    case timeout
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
        case .invalidEndpoint:
            "The LSP endpoint or server SPKI pin is invalid."
        case .socketFailure:
            "The LSP UDP socket or kqueue worker failed."
        case .dtlsFailure:
            "The required wolfSSL DTLS 1.3 policy failed."
        case .spkiMismatch:
            "The server certificate does not match the paired LSP SPKI pin."
        case .srtpFailure:
            "The libSRTP AEAD AES-128-GCM contexts failed."
        case .notAuthenticated:
            "The LSP association is not authenticated."
        case .controlWindowFull:
            "The bounded LSP control window is full."
        case .timeout:
            "The LSP operation timed out."
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
    public static let sourceDigest = "587cdc5f65b445162d02bf4bb0d54487967c93811c5565d2548321c526fbc0e5"

    /// Providers compiled into the native target.
    public static var availableProviders: LSPTransportProviders {
        LSPTransportProviders(rawValue: clsp_core_provider_flags())
    }

    private let core: OpaquePointer
    private let callbackState: LSPNativeCallbackState

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

        callbackState = LSPNativeCallbackState()
        var nativeConfiguration = try Self.makeNativeConfiguration(configuration)
        var nativeCallbacks = clsp_callbacks_t()
        nativeCallbacks.abi_version = Self.abiVersion
        nativeCallbacks.structure_size = UInt32(MemoryLayout<clsp_callbacks_t>.size)
        nativeCallbacks.context = Unmanaged.passUnretained(callbackState).toOpaque()
        nativeCallbacks.retain_context = lspRetainCallbackContext
        nativeCallbacks.release_context = lspReleaseCallbackContext
        nativeCallbacks.lifecycle = lspLifecycleCallback
        nativeCallbacks.control = lspControlCallback
        var output: OpaquePointer?
        let status = clsp_core_create(&nativeConfiguration, &nativeCallbacks, &output)
        try Self.requireSuccess(status)
        guard let output else {
            throw LSPTransportError.internalFailure
        }
        core = output
    }

    deinit {
        clsp_core_release(core)
    }

    /// Starts and synchronously authenticates the pinned DTLS association.
    ///
    /// - Parameter endpoint: Invitation- or trust-derived host, port, and SPKI pin.
    /// - Throws: A fail-closed provider or lifecycle error.
    public func start(endpoint: LSPTransportEndpoint) throws {
        let hostBytes = Array(endpoint.host.utf8)
        guard !hostBytes.isEmpty, hostBytes.count <= 255, endpoint.port != 0,
              endpoint.serverSPKISHA256.count == 32,
              endpoint.serverSPKISHA256.contains(where: { $0 != 0 })
        else {
            throw LSPTransportError.invalidEndpoint
        }
        var native = clsp_endpoint_t()
        native.abi_version = Self.abiVersion
        native.structure_size = UInt32(MemoryLayout<clsp_endpoint_t>.size)
        native.port = endpoint.port
        endpoint.serverSPKISHA256.withUnsafeBytes { pinBytes in
            withUnsafeMutableBytes(of: &native.server_spki_sha256) { destination in
                destination.copyBytes(from: pinBytes)
            }
        }
        try hostBytes.withUnsafeBufferPointer { hostBuffer in
            native.host = clsp_const_byte_span_t(
                data: hostBuffer.baseAddress,
                length: hostBuffer.count
            )
            try Self.requireSuccess(clsp_core_start(core, &native))
        }
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

    /// Sends one deterministic-CBOR LSP request and awaits its authenticated response.
    public func request(
        messageType: UInt16,
        payload: Data,
        timeout: Duration = .seconds(2)
    ) async throws -> LSPControlEvent {
        guard messageType != 0, payload.count <= 1_100 else {
            throw LSPTransportError.invalidConfiguration
        }
        let deadlineMilliseconds = try Self.milliseconds(
            timeout,
            minimum: 20,
            maximum: 30_000
        )
        let requestID = callbackState.reserveRequestID()
        return try await withCheckedThrowingContinuation { continuation in
            callbackState.install(requestID: requestID) { result in
                continuation.resume(with: result)
            }
            let status = payload.withUnsafeBytes { bytes in
                clsp_core_send_control(
                    core,
                    messageType,
                    requestID,
                    clsp_const_byte_span_t(
                        data: bytes.bindMemory(to: UInt8.self).baseAddress,
                        length: bytes.count
                    ),
                    deadlineMilliseconds
                )
            }
            do {
                try Self.requireSuccess(status)
            } catch {
                callbackState.fail(requestID: requestID, error: error as? LSPTransportError ?? .internalFailure)
                return
            }
            Task.detached { [callbackState] in
                try? await Task.sleep(for: timeout)
                callbackState.fail(requestID: requestID, error: .timeout)
            }
        }
    }

    /// Installs a coarse handler for authenticated unsolicited control events.
    public func setControlEventHandler(
        _ handler: (@Sendable (LSPControlEvent) -> Void)?
    ) {
        callbackState.setEventHandler(handler)
    }

    private static func makeNativeConfiguration(
        _ configuration: LSPTransportConfiguration
    ) throws -> clsp_configuration_t {
        guard configuration.port != 0 else {
            throw LSPTransportError.invalidConfiguration
        }
        let telemetryMilliseconds = try milliseconds(
            configuration.telemetryInterval,
            minimum: 250,
            maximum: UInt32.max
        )
        let handshakeMilliseconds = try milliseconds(
            configuration.handshakeTimeout,
            minimum: 1_000,
            maximum: 30_000
        )

        var native = clsp_configuration_t()
        native.abi_version = Self.abiVersion
        native.structure_size = UInt32(MemoryLayout<clsp_configuration_t>.size)
        native.port = configuration.port
        native.telemetry_interval_milliseconds = telemetryMilliseconds
        native.handshake_timeout_milliseconds = handshakeMilliseconds
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

    private static func milliseconds(
        _ duration: Duration,
        minimum: UInt32,
        maximum: UInt32
    ) throws -> UInt32 {
        let components = duration.components
        guard components.seconds >= 0, components.attoseconds >= 0 else {
            throw LSPTransportError.invalidConfiguration
        }
        let whole = components.seconds.multipliedReportingOverflow(by: 1_000)
        let fraction = components.attoseconds / 1_000_000_000_000_000
        let total = whole.partialValue.addingReportingOverflow(fraction)
        guard !whole.overflow, !total.overflow,
              total.partialValue >= Int64(minimum),
              total.partialValue <= Int64(maximum)
        else {
            throw LSPTransportError.invalidConfiguration
        }
        return UInt32(total.partialValue)
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
        case CLSP_STATUS_INVALID_ENDPOINT:
            throw LSPTransportError.invalidEndpoint
        case CLSP_STATUS_SOCKET_FAILURE:
            throw LSPTransportError.socketFailure
        case CLSP_STATUS_DTLS_FAILURE:
            throw LSPTransportError.dtlsFailure
        case CLSP_STATUS_SPKI_MISMATCH:
            throw LSPTransportError.spkiMismatch
        case CLSP_STATUS_SRTP_FAILURE:
            throw LSPTransportError.srtpFailure
        case CLSP_STATUS_NOT_AUTHENTICATED:
            throw LSPTransportError.notAuthenticated
        case CLSP_STATUS_CONTROL_WINDOW_FULL:
            throw LSPTransportError.controlWindowFull
        case CLSP_STATUS_TIMEOUT:
            throw LSPTransportError.timeout
        default:
            throw LSPTransportError.unknownStatus(Int32(status.rawValue))
        }
    }
}

private final class LSPNativeCallbackState: @unchecked Sendable {
    typealias Completion = @Sendable (Result<LSPControlEvent, LSPTransportError>) -> Void

    private let lock = NSLock()
    private var completions: [UInt64: Completion] = [:]
    private var eventHandler: (@Sendable (LSPControlEvent) -> Void)?

    func reserveRequestID() -> UInt64 {
        lock.withLock {
            var candidate = UInt64.random(in: 1...UInt64.max)
            while completions[candidate] != nil {
                candidate = UInt64.random(in: 1...UInt64.max)
            }
            return candidate
        }
    }

    func install(requestID: UInt64, completion: @escaping Completion) {
        lock.withLock {
            completions[requestID] = completion
        }
    }

    func receive(_ event: LSPControlEvent) {
        let delivery: Completion? = lock.withLock {
            event.requestID == 0 ? nil : completions.removeValue(forKey: event.requestID)
        }
        if let delivery {
            delivery(.success(event))
            return
        }
        let handler = lock.withLock { eventHandler }
        handler?(event)
    }

    func fail(requestID: UInt64, error: LSPTransportError) {
        let delivery = lock.withLock {
            completions.removeValue(forKey: requestID)
        }
        delivery?(.failure(error))
    }

    func setEventHandler(_ handler: (@Sendable (LSPControlEvent) -> Void)?) {
        lock.withLock {
            eventHandler = handler
        }
    }
}

private let lspRetainCallbackContext: @convention(c) (UnsafeMutableRawPointer?) -> Void = { context in
    guard let context else { return }
    _ = Unmanaged<LSPNativeCallbackState>.fromOpaque(context).retain()
}

private let lspReleaseCallbackContext: @convention(c) (UnsafeMutableRawPointer?) -> Void = { context in
    guard let context else { return }
    Unmanaged<LSPNativeCallbackState>.fromOpaque(context).release()
}

private let lspLifecycleCallback: @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafePointer<clsp_lifecycle_event_t>?
) -> Void = { _, _ in
    // Start waits for authenticated completion and telemetry exposes lifecycle.
}

private let lspControlCallback: @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafePointer<clsp_control_event_t>?
) -> Void = { context, nativeEvent in
    guard let context, let nativeEvent else { return }
    let native = nativeEvent.pointee
    let payload: Data
    if native.payload.length == 0 {
        payload = Data()
    } else if let bytes = native.payload.data {
        payload = Data(bytes: bytes, count: native.payload.length)
    } else {
        return
    }
    let event = LSPControlEvent(
        messageType: native.message_type,
        flags: LSPControlFlags(rawValue: native.flags),
        connectionGeneration: native.connection_generation,
        messageID: native.message_id,
        requestID: native.request_id,
        payload: payload
    )
    Unmanaged<LSPNativeCallbackState>.fromOpaque(context).takeUnretainedValue().receive(event)
}

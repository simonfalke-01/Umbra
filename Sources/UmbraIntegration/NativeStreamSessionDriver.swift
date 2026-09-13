import Foundation
import UmbraCore
import UmbraMedia
import UmbraMicrophone
import UmbraServices
import UmbraStreaming

public protocol IntegrationDateProviding: Sendable {
    func now() -> Date
}

public struct SystemIntegrationDateProvider: IntegrationDateProviding, Sendable {
    public init() {}
    public func now() -> Date { Date() }
}

public protocol StreamingSessionControlling: Sendable {
    func start() async throws
    func waitUntilTerminated() async -> Int32
    func close() async
    func requestKeyFrame() async throws
    func hostFeatureFlags() async throws -> UInt32
    func statistics() async throws -> StreamingStatistics
    func send(_ command: StreamInputCommand) throws
}

extension StreamingSession: StreamingSessionControlling {
    public nonisolated func send(_ command: StreamInputCommand) throws {
        switch command {
        case let .keyboard(keyCode, action, modifiers, flags):
            try sendKeyboard(keyCode: keyCode, action: action, modifiers: modifiers, flags: flags)
        case let .mouseMove(deltaX, deltaY):
            try sendMouseMove(deltaX: deltaX, deltaY: deltaY)
        case let .mousePosition(x, y, referenceWidth, referenceHeight):
            try sendMousePosition(x: x, y: y, referenceWidth: referenceWidth, referenceHeight: referenceHeight)
        case let .mouseButton(action, button):
            try sendMouseButton(action: action, button: button)
        case let .scroll(vertical, horizontal):
            try sendScroll(vertical: vertical, horizontal: horizontal)
        case let .touch(pointerID, eventType, x, y, pressure):
            try sendTouch(
                eventType: eventType,
                pointerID: pointerID,
                x: x,
                y: y,
                pressureOrDistance: pressure
            )
        case let .text(value):
            try send(text: value)
        case let .controller(number, activeMask, buttons, leftTrigger, rightTrigger, leftStickX, leftStickY, rightStickX, rightStickY):
            try sendController(
                number: number,
                activeMask: activeMask,
                buttons: buttons,
                leftTrigger: leftTrigger,
                rightTrigger: rightTrigger,
                leftStickX: leftStickX,
                leftStickY: leftStickY,
                rightStickX: rightStickX,
                rightStickY: rightStickY
            )
        case let .controllerArrival(number, activeMask, type, supportedButtons, capabilities):
            try sendControllerArrival(
                number: number,
                activeMask: activeMask,
                type: type,
                supportedButtons: supportedButtons,
                capabilities: capabilities
            )
        case let .controllerTouch(number, eventType, touchpadIndex, pointerID, x, y, pressure):
            try sendControllerTouch(
                number: number,
                eventType: eventType,
                touchpadIndex: touchpadIndex,
                pointerID: pointerID,
                x: x,
                y: y,
                pressure: pressure
            )
        case let .controllerMotion(number, type, x, y, z):
            try sendControllerMotion(number: number, type: type, x: x, y: y, z: z)
        case let .controllerBattery(number, state, percentage):
            try sendControllerBattery(number: number, state: state, percentage: percentage)
        }
    }
}

private final class StartupObservingVideoDecoder: UmbraStreaming.VideoDecoding, UmbraStreaming.HDRMetadataReceiving, @unchecked Sendable {
    private let delegate: any UmbraStreaming.VideoDecoding
    private let lock = NSLock()
    private var reportedFirstSubmitRequest = false
    private let firstSubmitRequestHandler: @Sendable () -> Void

    init(
        delegate: any UmbraStreaming.VideoDecoding,
        firstSubmitRequestHandler: @escaping @Sendable () -> Void
    ) {
        self.delegate = delegate
        self.firstSubmitRequestHandler = firstSubmitRequestHandler
    }

    func configure(format: UmbraStreaming.VideoStreamFormat) -> Bool {
        delegate.configure(format: format)
    }

    func start() { delegate.start() }
    func stop() { delegate.stop() }
    func cleanUp() { delegate.cleanUp() }

    func setHDRMode(
        enabled: Bool,
        metadata: UmbraStreaming.StreamingHDRMetadata?
    ) {
        (delegate as? any UmbraStreaming.HDRMetadataReceiving)?.setHDRMode(
            enabled: enabled,
            metadata: metadata
        )
    }

    func submit(
        frame: UmbraStreaming.CompressedVideoFrame
    ) -> UmbraStreaming.VideoFrameDisposition {
        let shouldReport = lock.withLock { () -> Bool in
            guard !reportedFirstSubmitRequest else { return false }
            reportedFirstSubmitRequest = true
            return true
        }
        if shouldReport { firstSubmitRequestHandler() }
        return delegate.submit(frame: frame)
    }
}

public protocol StreamingSessionCreating: Sendable {
    func makeSession(
        configuration: StreamingConfiguration,
        media: StreamingMediaPipeline,
        events: @escaping @Sendable (StreamingEvent) -> Void
    ) throws -> any StreamingSessionControlling
}

public struct NativeStreamingSessionFactory: StreamingSessionCreating, Sendable {
    public init() {}

    public func makeSession(
        configuration: StreamingConfiguration,
        media: StreamingMediaPipeline,
        events: @escaping @Sendable (StreamingEvent) -> Void
    ) throws -> any StreamingSessionControlling {
        try StreamingSession(
            configuration: configuration,
            videoDecoder: media.videoDecoder,
            audioDecoder: media.audioDecoder,
            eventHandler: events
        )
    }
}

public enum StreamingConfigurationMapper {
    public struct PreparedConfiguration: Sendable, Equatable {
        public var configuration: StreamingConfiguration
        public var result: StreamPreparationResult

        public init(
            configuration: StreamingConfiguration,
            result: StreamPreparationResult
        ) {
            self.configuration = configuration
            self.result = result
        }
    }

    public static func preparedConfiguration(
        for bootstrap: StreamBootstrap,
        availableVideoFormats: Int32,
        negotiator: VideoFormatNegotiator = VideoFormatNegotiator()
    ) throws -> PreparedConfiguration {
        let result = try negotiator.select(
            availableVideoFormats: availableVideoFormats,
            host: bootstrap.host,
            application: bootstrap.application,
            preferences: bootstrap.preferences
        )
        var resolvedBootstrap = bootstrap
        resolvedBootstrap.preferences = result.applying(to: bootstrap.preferences)
        return try PreparedConfiguration(
            configuration: configuration(
                for: resolvedBootstrap,
                selectedVideoFormat: result.selectedVideoFormat
            ),
            result: result
        )
    }

    public static func configuration(
        for bootstrap: StreamBootstrap,
        selectedVideoFormat: Int32
    ) throws -> StreamingConfiguration {
        try bootstrap.preferences.validate()
        guard let exactVideoFormat = MoonlightVideoFormat(rawValue: selectedVideoFormat) else {
            throw UmbraIntegrationError.unsupportedVideoConfiguration(
                bootstrap.preferences.videoCodecPreference
            )
        }
        guard let endpoint = bootstrap.host.activeAddress ?? bootstrap.host.uniqueAddresses.first else {
            throw UmbraIntegrationError.missingHostAddress(bootstrap.host.uuid)
        }
        guard let appVersion = bootstrap.host.appVersion, !appVersion.isEmpty else {
            throw UmbraIntegrationError.missingServerAppVersion(bootstrap.host.uuid)
        }

        var configuration = StreamingConfiguration(
            address: endpoint.hostname,
            serverAppVersion: appVersion,
            width: Int32(bootstrap.preferences.width),
            height: Int32(bootstrap.preferences.height),
            framesPerSecond: Int32(bootstrap.preferences.fps),
            bitrateKbps: Int32(bootstrap.preferences.bitrateKbps),
            selectedVideoFormat: selectedVideoFormat
        )
        configuration.serverGFEVersion = bootstrap.host.gfeVersion
        configuration.rtspSessionURL = bootstrap.rtspSessionURL?.absoluteString
        configuration.serverCodecModeSupport = Int32(bitPattern: bootstrap.host.codecSupport.rawValue)
        let networkConfiguration = networkConfiguration(
            preference: bootstrap.preferences.packetSize,
            reachability: bootstrap.host.activeAddressReachability
        )
        configuration.packetSize = Int32(networkConfiguration.packetSize)
        configuration.remoteMode = networkConfiguration.remoteMode
        configuration.audioConfiguration = audioConfiguration(bootstrap.preferences.audioConfiguration)
        configuration.clientRefreshRateTimes100 = bootstrap.clientRefreshRateX100 ?? 0
        // The native macOS decoder/render path is pinned to VideoToolbox's
        // Rec.601 encoder request, matching the reference Moonlight client.
        configuration.colorSpace = 0
        configuration.fullColorRange = true
        configuration.remoteInputAESKey = bootstrap.remoteInputCredentials.key
        configuration.remoteInputAESIV = bootstrap.remoteInputCredentials.initializationVector
        configuration.videoDecodeQueueCapacity = StreamingConfiguration.clampedVideoDecodeQueueCapacity(
            bootstrap.effectivePolicy.maximumCompressedDecodeQueueFrames
        )
        configuration.inputOptimizationMode = switch bootstrap.effectivePolicy.mode {
        case .latency: .latency
        case .quality: .quality
        }
        configuration.rtspOptimizationMode = if bootstrap.host.isNvidiaServerSoftware {
            .legacy
        } else {
            configuration.inputOptimizationMode
        }
        configuration.rtspFidelityMode = if bootstrap.host.isNvidiaServerSoftware {
            .unspecified
        } else {
            switch bootstrap.effectivePolicy.fidelityPreference {
            case .visuallyLossless: .unspecified
            case .codecLosslessRequired:
                if exactVideoFormat.isTenBit == bootstrap.preferences.enableHDR,
                   hostProvesCodecLossless(exactVideoFormat, support: bootstrap.host.codecSupport) {
                    .codecLosslessRequired
                } else {
                    throw UmbraIntegrationError.codecLosslessUnavailable(
                        "the selected exact codec tuple lacks a Lumen runtime NVENC lossless proof"
                    )
                }
            }
        }
        // VideoToolbox can recover HEVC and AV1 reference-frame loss through the
        // decoder reset/IDR path, matching Moonlight's native macOS renderers.
        configuration.videoCapabilities = 0x04 | 0x40
        configuration.audioCapabilities = 0x10 // arbitrary audio packet duration
        return configuration
    }

    private static func networkConfiguration(
        preference: Int,
        reachability: HostReachability
    ) -> (packetSize: Int, remoteMode: Int32) {
        guard preference == 0 else {
            return (packetSize: preference, remoteMode: 0)
        }
        return switch reachability {
        case .lan: (packetSize: 1_392, remoteMode: 0)
        case .vpn: (packetSize: 1_024, remoteMode: 1)
        case .unknown: (packetSize: 1_392, remoteMode: 2)
        }
    }

    private static func audioConfiguration(_ preference: AudioConfiguration) -> Int32 {
        switch preference {
        case .stereo: (0x3 << 16) | (2 << 8) | 0xCA
        case .surround51: (0x3F << 16) | (6 << 8) | 0xCA
        case .surround71: (0x63F << 16) | (8 << 8) | 0xCA
        }
    }

    private static func hostProvesCodecLossless(
        _ format: MoonlightVideoFormat,
        support: HostCodecSupport
    ) -> Bool {
        switch format {
        case .h264:
            false
        case .h264High8YUV444:
            support.contains(.h264Lossless)
        case .hevc, .hevcMain10, .hevcRext8YUV444, .hevcRext10YUV444:
            support.contains(.hevcLossless)
        case .av1Main8, .av1Main10, .av1High8YUV444, .av1High10YUV444:
            support.contains(.av1Lossless)
        }
    }
}

private final class StreamEventRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let serviceEvents: @Sendable (StreamDriverEvent) -> Void
    private let output: any StreamingEventOutputHandling
    private let diagnosticHandler: @Sendable (String) -> Void
    private let microphone: (any ClientMicrophoneForwarding)?
    private let microphoneRequired: Bool
    private let microphoneRIKey: Data
    private var storedFailure: UmbraIntegrationError?
    private var requiredMicrophoneFailureHandler: (@Sendable () -> Void)?

    init(
        serviceEvents: @escaping @Sendable (StreamDriverEvent) -> Void,
        output: any StreamingEventOutputHandling,
        diagnosticHandler: @escaping @Sendable (String) -> Void,
        microphone: (any ClientMicrophoneForwarding)?,
        microphoneRequired: Bool,
        microphoneRIKey: Data
    ) {
        self.serviceEvents = serviceEvents
        self.output = output
        self.diagnosticHandler = diagnosticHandler
        self.microphone = microphone
        self.microphoneRequired = microphoneRequired
        self.microphoneRIKey = microphoneRIKey
    }

    var failure: UmbraIntegrationError? {
        lock.withLock { storedFailure }
    }

    func installRequiredMicrophoneFailureHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { requiredMicrophoneFailureHandler = handler }
    }


    func handle(_ event: StreamingEvent) {
        if case let .clientMicrophoneGeneration(generation) = event {
            guard let microphone else { return }
            do {
                try microphone.begin(
                    generation: ClientMicrophoneGenerationDescriptor(
                        sessionID: generation.sessionID,
                        salt: generation.salt,
                        serverPort: generation.serverPort,
                        clientPort: generation.clientPort,
                        remoteAddress: generation.remoteAddress,
                        rikey: microphoneRIKey
                    ),
                    warningHandler: { [weak self] message in
                        self?.handleMicrophoneWarning(message)
                    }
                )
                diagnosticHandler(
                    "Client microphone generation started on UDP port \(generation.clientPort)."
                )
            } catch {
                microphone.invalidate()
                let message = "Microphone forwarding is unavailable for this stream: \(error.localizedDescription)"
                handleMicrophoneWarning(message)
            }
            return
        }
        switch event {
        case let .stageStarting(stage, _):
            if let stage = Self.stage(stage) { serviceEvents(.connecting(stage)) }
        case let .stageFailed(stage, _, code):
            let mappedStage = Self.stage(stage) ?? .connection
            lock.withLock { storedFailure = .streamingStageFailed(stage: mappedStage, code: code) }
        case .connectionStarted:
            break
        case let .connectionTerminated(code) where code != 0:
            lock.withLock { storedFailure = .streamTerminated(code: code) }
        case let .connectionStatus(status) where status != 0:
            serviceEvents(.warning("The host reports a poor streaming connection."))
        case let .log(message):
            diagnosticHandler(message)
        case .rumble, .triggerRumble, .motionState, .controllerLED, .adaptiveTriggers, .hdrMode:
            output.handle(event)
        default:
            break
        }
    }

    private func handleMicrophoneWarning(_ message: String) {
        guard microphoneRequired else {
            serviceEvents(.warning(message))
            return
        }
        let handler = lock.withLock { () -> (@Sendable () -> Void)? in
            if storedFailure == nil {
                storedFailure = .clientMicrophoneRequiredUnavailable(message)
            }
            return requiredMicrophoneFailureHandler
        }
        handler?()
    }

    static func stage(_ rawValue: Int) -> SessionStage? {
        switch rawValue {
        case 1: .platformInitialization
        case 2: .nameResolution
        case 3, 10: .audioStreamInitialization
        case 4: .serverHandshake
        case 5, 8: .controlStreamInitialization
        case 6, 9: .videoStreamInitialization
        case 7, 11: .inputStreamInitialization
        default: nil
        }
    }
}

public actor NativeStreamSessionDriver: StreamSessionDriving {
    private enum DriverPhase: Sendable, Equatable {
        case idle
        case preparing(UInt64)
        case starting(UInt64)
        case running(UInt64)
        case tearingDown(UInt64)
    }
    private struct LifecyclePreparationIdentity: Sendable, Equatable {
        let sessionID: UUID
        let preferences: StreamingPreferences
        let effectivePolicy: EffectiveStreamingPolicy
    }

    private struct PreparedSession: Sendable {
        var generation: UInt64
        var sessionID: UUID
        var media: StreamingMediaPipeline
        var configuration: StreamingConfiguration
        var result: StreamPreparationResult
        var effectivePolicy: EffectiveStreamingPolicy
        var microphone: (any ClientMicrophoneForwarding)?
        var microphoneWarning: String?
        var lifecycleIdentity: LifecyclePreparationIdentity
        var lifecyclePreparationTask: Task<Void, Error>
    }

    private let mediaProvider: any StreamingMediaProviding
    private let sessionFactory: any StreamingSessionCreating
    private let output: any StreamingEventOutputHandling
    private let motionPolicy: ControllerMotionPolicy
    private let inputInstaller: (any PlatformInputSinkInstalling)?
    private let lifecycle: any StreamSessionLifecycleCoordinating
    private let microphonePreparer: (any ClientMicrophonePreparing)?
    private let dateProvider: any IntegrationDateProviding
    private let diagnosticHandler: @Sendable (String) -> Void
    private let keyFrameRecoveryInterval: Duration
    private let keyFrameRecoveryAttempts: Int
    private let statisticsPollingInterval: Duration
    private let startupTelemetry: SessionStartupTelemetryRecorder

    private var activeSessionID: UUID?
    private var activeSession: (any StreamingSessionControlling)?
    private var inputSink: PlatformStreamingInputSink?
    private var activeMicrophone: (any ClientMicrophoneForwarding)?
    private var preparedSession: PreparedSession?
    private var teardownInProgress = false
    private var teardownWaiters: [CheckedContinuation<Void, Never>] = []
    private var generation: UInt64 = 0
    private var phase: DriverPhase = .idle
    private var startingLifecyclePreparationTask: Task<Void, Error>?

    public init(
        mediaProvider: any StreamingMediaProviding,
        sessionFactory: any StreamingSessionCreating = NativeStreamingSessionFactory(),
        output: any StreamingEventOutputHandling = DiscardingStreamingEventOutputHandler(),
        motionPolicy: ControllerMotionPolicy? = nil,
        inputInstaller: (any PlatformInputSinkInstalling)? = nil,
        lifecycle: any StreamSessionLifecycleCoordinating = NoOpStreamSessionLifecycleCoordinator(),
        microphonePreparer: (any ClientMicrophonePreparing)? = nil,
        dateProvider: any IntegrationDateProviding = SystemIntegrationDateProvider(),
        diagnosticHandler: @escaping @Sendable (String) -> Void = { _ in },
        keyFrameRecoveryInterval: Duration = .seconds(1),
        keyFrameRecoveryAttempts: Int = 5,
        statisticsPollingInterval: Duration = .seconds(1),
        startupTelemetry: SessionStartupTelemetryRecorder = SessionStartupTelemetryRecorder()
    ) {
        self.mediaProvider = mediaProvider
        self.sessionFactory = sessionFactory
        self.output = output
        self.motionPolicy = motionPolicy
            ?? (output as? any ControllerMotionPolicyProviding)?.controllerMotionPolicy
            ?? ControllerMotionPolicy()
        self.inputInstaller = inputInstaller
        self.lifecycle = lifecycle
        self.microphonePreparer = microphonePreparer
        self.dateProvider = dateProvider
        self.diagnosticHandler = diagnosticHandler
        self.keyFrameRecoveryInterval = keyFrameRecoveryInterval
        self.keyFrameRecoveryAttempts = max(0, keyFrameRecoveryAttempts)
        self.statisticsPollingInterval = statisticsPollingInterval
        self.startupTelemetry = startupTelemetry
    }

    public func run(
        _ bootstrap: StreamBootstrap,
        events: @escaping @Sendable (StreamDriverEvent) -> Void
    ) async throws -> SessionResult {
        guard activeSession == nil, !teardownInProgress else {
            throw UmbraServiceError.sessionInProgress
        }
        guard var preparedSession else {
            throw UmbraIntegrationError.sessionNotPrepared(bootstrap.sessionID)
        }
        guard preparedSession.sessionID == bootstrap.sessionID else {
            throw UmbraIntegrationError.preparedSessionMismatch(
                expected: preparedSession.sessionID,
                actual: bootstrap.sessionID
            )
        }
        guard case .preparing(preparedSession.generation) = phase,
              preparedSession.generation == generation else {
            throw CancellationError()
        }
        self.preparedSession = nil
        phase = .starting(preparedSession.generation)
        startingLifecyclePreparationTask = preparedSession.lifecyclePreparationTask
        preparedSession.configuration.rtspSessionURL = bootstrap.rtspSessionURL?.absoluteString
        let media = preparedSession.media
        let configuration = preparedSession.configuration
        let microphone = preparedSession.microphone
        var effectiveBootstrap = bootstrap
        effectiveBootstrap.preferences = preparedSession.result.applying(to: bootstrap.preferences)
        effectiveBootstrap.effectivePolicy = preparedSession.effectivePolicy

        do {
            try await preparedSession.lifecyclePreparationTask.value
            try ensureCurrent(
                generation: preparedSession.generation,
                phase: .starting(preparedSession.generation)
            )
            startingLifecyclePreparationTask = nil
        } catch {
            startingLifecyclePreparationTask = nil
            preparedSession.lifecyclePreparationTask.cancel()
            media.cleanUp()
            microphone?.invalidate()
            await lifecycle.finishPresentation()
            await lifecycle.finish()
            if teardownInProgress { completeTeardown() }
            throw error
        }
        let relay = StreamEventRelay(
            serviceEvents: events,
            output: output,
            diagnosticHandler: diagnosticHandler,
            microphone: microphone,
            microphoneRequired: effectiveBootstrap.preferences.clientMicrophoneRequired,
            microphoneRIKey: configuration.remoteInputAESKey
        )
        let session: any StreamingSessionControlling
        do {
            let observingMedia = StreamingMediaPipeline(
                videoDecoder: StartupObservingVideoDecoder(
                    delegate: media.videoDecoder,
                    firstSubmitRequestHandler: { [startupTelemetry] in
                        startupTelemetry.record(
                            sessionID: bootstrap.sessionID,
                            stage: .decoderSubmitRequested
                        )
                    }
                ),
                audioDecoder: media.audioDecoder,
                availableVideoFormats: media.availableVideoFormats,
                videoFrameReadiness: media.videoFrameReadiness,
                videoStatisticsProvider: { media.videoStatistics() }
            )
            session = try sessionFactory.makeSession(
                configuration: configuration,
                media: observingMedia,
                events: relay.handle
            )
        } catch {
            startingLifecyclePreparationTask = nil
            media.cleanUp()
            microphone?.invalidate()
            await lifecycle.finishPresentation()
            await lifecycle.finish()
            if teardownInProgress { completeTeardown() }
            throw error
        }
        relay.installRequiredMicrophoneFailureHandler {
            Task { await session.close() }
        }
        let sink = PlatformStreamingInputSink(
            sender: session,
            motionPolicy: motionPolicy,
            failureHandler: { error in
                events(.warning("Input delivery failed: \(error.localizedDescription)"))
            }
        )
        activeSessionID = bootstrap.sessionID
        activeSession = session
        inputSink = sink
        activeMicrophone = microphone
        phase = .running(preparedSession.generation)

        if let warning = preparedSession.microphoneWarning {
            events(.warning(warning))
        }
        await output.beginSession()
        try ensureCurrent(
            generation: preparedSession.generation,
            phase: .running(preparedSession.generation)
        )
        do {
            var keyFrameRecoveryTask: Task<Void, Never>?
            var statisticsTask: Task<Void, Never>?
            defer {
                keyFrameRecoveryTask?.cancel()
                statisticsTask?.cancel()
            }
            // Install the sender before native startup can synchronously deliver and commit
            // its first frame. The stream window stays hidden until that commit, so users
            // cannot target an unstarted sender, while the revealed window is immediately live.
            await inputInstaller?.installInputSink(sink)
            try ensureCurrent(
                generation: preparedSession.generation,
                phase: .running(preparedSession.generation)
            )
            startupTelemetry.record(sessionID: bootstrap.sessionID, stage: .sessionStart)
            try await session.start()
            try ensureCurrent(
                generation: preparedSession.generation,
                phase: .running(preparedSession.generation)
            )
            let statisticsPollingInterval = self.statisticsPollingInterval
            let diagnosticHandler = self.diagnosticHandler
            statisticsTask = Task { [output] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: statisticsPollingInterval)
                        let statistics = try await session.statistics()
                        output.handle(.statistics(statistics))
                        if let videoStatistics = media.videoStatistics() {
                            output.handleVideoStatistics(videoStatistics)
                        }
                    } catch is CancellationError {
                        return
                    } catch {
                        diagnosticHandler(
                            "Streaming statistics query failed; retrying: \(error.localizedDescription)"
                        )
                    }
                }
            }
            keyFrameRecoveryTask = Task {
                guard keyFrameRecoveryAttempts > 0 else { return }
                for attempt in 1 ... keyFrameRecoveryAttempts {
                    do {
                        try await Task.sleep(for: keyFrameRecoveryInterval)
                        guard !media.videoFrameReadiness.hasDecodedFrame else { return }
                        try await session.requestKeyFrame()
                        diagnosticHandler(
                            "Requested recovery keyframe (attempt \(attempt) of \(keyFrameRecoveryAttempts))."
                        )
                    } catch is CancellationError {
                        return
                    } catch {
                        diagnosticHandler(
                            "Recovery keyframe request \(attempt) failed: \(error.localizedDescription)"
                        )
                    }
                }
            }
            if effectiveBootstrap.preferences.absoluteTouchMode {
                let hostFeatureFlags = try await session.hostFeatureFlags()
                try ensureCurrent(
                    generation: preparedSession.generation,
                    phase: .running(preparedSession.generation)
                )
                if hostFeatureFlags & 0x01 == 0 {
                    effectiveBootstrap.preferences.absoluteTouchMode = false
                    diagnosticHandler(
                        "Host does not support direct touch input; using virtual trackpad mode."
                    )
                }
            }
            try await lifecycle.updatePreparation(for: effectiveBootstrap)
            try ensureCurrent(
                generation: preparedSession.generation,
                phase: .running(preparedSession.generation)
            )
            if let failure = relay.failure { throw failure }
            await lifecycle.commitStreaming(for: effectiveBootstrap)
            try ensureCurrent(
                generation: preparedSession.generation,
                phase: .running(preparedSession.generation)
            )
            events(.streaming(dateProvider.now()))
            let terminationCode = await session.waitUntilTerminated()
            try Task.checkCancellation()
            if let failure = relay.failure { throw failure }
            if terminationCode != 0 {
                throw UmbraIntegrationError.streamTerminated(code: terminationCode)
            }
            if clearActiveSession(ifMatching: bootstrap.sessionID) {
                await lifecycle.finishPresentation()
                await output.endSession()
                await inputInstaller?.installInputSink(nil)
                microphone?.finish()
                await session.close()
                await lifecycle.finish()
                completeTeardown()
            } else {
                await waitForTeardownIfNeeded()
            }
            return SessionResult(
                quitHostApplication: bootstrap.preferences.quitAppAfter,
                endedAt: dateProvider.now()
            )
        } catch {
            if clearActiveSession(ifMatching: bootstrap.sessionID) {
                await lifecycle.finishPresentation()
                await output.endSession()
                await inputInstaller?.installInputSink(nil)
                microphone?.finish()
                await session.close()
                await lifecycle.finish()
                completeTeardown()
            } else {
                await waitForTeardownIfNeeded()
            }
            if error is CancellationError { throw error }
            throw relay.failure ?? error
        }
    }

    @discardableResult
    public func prepare(_ bootstrap: StreamBootstrap) async throws -> StreamPreparationResult {
        guard activeSession == nil, !teardownInProgress else {
            throw UmbraServiceError.sessionInProgress
        }
        if let preparedSession, preparedSession.sessionID != bootstrap.sessionID {
            throw UmbraServiceError.sessionInProgress
        }

        generation &+= 1
        let reservedGeneration = generation
        phase = .preparing(reservedGeneration)

        if var preparedSession {
            do {
                var prepared = try StreamingConfigurationMapper.preparedConfiguration(
                    for: bootstrap,
                    availableVideoFormats: preparedSession.media.availableVideoFormats
                )
                preparedSession.generation = reservedGeneration
                preparedSession.configuration = prepared.configuration
                preparedSession.result = prepared.result
                preparedSession.effectivePolicy = bootstrap.effectivePolicy
                self.preparedSession = preparedSession
                let microphonePreparation = try await prepareClientMicrophone(
                    for: bootstrap,
                    existing: preparedSession.microphone
                )
                do {
                    try ensureCurrent(
                        generation: reservedGeneration,
                        phase: .preparing(reservedGeneration)
                    )
                } catch {
                    microphonePreparation.forwarder?.invalidate()
                    throw error
                }
                guard var preparedSession = self.preparedSession else {
                    throw CancellationError()
                }
                applyClientMicrophone(
                    microphonePreparation.forwarder,
                    to: &prepared.configuration
                )
                preparedSession.configuration = prepared.configuration
                preparedSession.result = prepared.result
                preparedSession.effectivePolicy = bootstrap.effectivePolicy
                preparedSession.microphone = microphonePreparation.forwarder
                preparedSession.microphoneWarning = microphonePreparation.warning
                let effectiveBootstrap = Self.effectiveBootstrap(
                    bootstrap,
                    result: prepared.result,
                    effectivePolicy: bootstrap.effectivePolicy
                )
                let lifecycleIdentity = Self.lifecycleIdentity(for: effectiveBootstrap)
                if preparedSession.lifecycleIdentity != lifecycleIdentity {
                    let priorPreparation = preparedSession.lifecyclePreparationTask
                    preparedSession.lifecycleIdentity = lifecycleIdentity
                    preparedSession.lifecyclePreparationTask = Task { [lifecycle] in
                        try await withTaskCancellationHandler {
                            try await priorPreparation.value
                            try Task.checkCancellation()
                            try await lifecycle.updatePreparation(for: effectiveBootstrap)
                        } onCancel: {
                            priorPreparation.cancel()
                        }
                    }
                }
                self.preparedSession = preparedSession
                reportPreparedConfiguration(prepared)
                return prepared.result
            } catch {
                if generation == reservedGeneration {
                    self.preparedSession = nil
                    phase = .idle
                    preparedSession.lifecyclePreparationTask.cancel()
                    preparedSession.media.cleanUp()
                    preparedSession.microphone?.invalidate()
                }
                throw error
            }
        }

        let media: StreamingMediaPipeline
        do {
            media = try mediaProvider.makePipeline(for: bootstrap)
        } catch {
            if generation == reservedGeneration {
                phase = .idle
            }
            throw error
        }
        do {
            let prepared = try StreamingConfigurationMapper.preparedConfiguration(
                for: bootstrap,
                availableVideoFormats: media.availableVideoFormats
            )
            let effectiveBootstrap = Self.effectiveBootstrap(
                bootstrap,
                result: prepared.result,
                effectivePolicy: bootstrap.effectivePolicy
            )
            let lifecycleIdentity = Self.lifecycleIdentity(for: effectiveBootstrap)
            let lifecyclePreparationTask = Task { [lifecycle] in
                try await lifecycle.prepare(for: effectiveBootstrap)
            }
            preparedSession = PreparedSession(
                generation: reservedGeneration,
                sessionID: bootstrap.sessionID,
                media: media,
                configuration: prepared.configuration,
                result: prepared.result,
                effectivePolicy: bootstrap.effectivePolicy,
                microphone: nil,
                microphoneWarning: nil,
                lifecycleIdentity: lifecycleIdentity,
                lifecyclePreparationTask: lifecyclePreparationTask
            )
            let microphonePreparation = try await prepareClientMicrophone(for: bootstrap)
            do {
                try ensureCurrent(
                    generation: reservedGeneration,
                    phase: .preparing(reservedGeneration)
                )
            } catch {
                microphonePreparation.forwarder?.invalidate()
                throw error
            }
            guard var preparedSession else { throw CancellationError() }
            applyClientMicrophone(
                microphonePreparation.forwarder,
                to: &preparedSession.configuration
            )
            preparedSession.microphone = microphonePreparation.forwarder
            preparedSession.microphoneWarning = microphonePreparation.warning
            self.preparedSession = preparedSession
            reportPreparedConfiguration(prepared)
            return prepared.result
        } catch {
            if generation == reservedGeneration {
                self.preparedSession?.lifecyclePreparationTask.cancel()
                self.preparedSession = nil
                phase = .idle
                media.cleanUp()
            }
            throw error
        }
    }

    public func waitUntilPrepared(sessionID: UUID) async throws {
        guard let preparedSession,
              preparedSession.sessionID == sessionID,
              case .preparing(preparedSession.generation) = phase else {
            throw UmbraIntegrationError.sessionNotPrepared(sessionID)
        }
        try await preparedSession.lifecyclePreparationTask.value
        try ensureCurrent(
            generation: preparedSession.generation,
            phase: .preparing(preparedSession.generation)
        )
    }

    public func cancel() async {
        if teardownInProgress {
            await waitForTeardownIfNeeded()
            return
        }
        let phaseBeforeCancellation = phase
        let hadOwnedWork = preparedSession != nil
            || activeSession != nil
            || phaseBeforeCancellation != .idle
        generation &+= 1
        let cancellationGeneration = generation
        phase = .tearingDown(cancellationGeneration)
        let session = activeSession
        let preparedSession = preparedSession
        let microphone = activeMicrophone
        let startingLifecyclePreparationTask = startingLifecyclePreparationTask
        activeSession = nil
        activeSessionID = nil
        inputSink = nil
        activeMicrophone = nil
        self.preparedSession = nil
        self.startingLifecyclePreparationTask = nil
        teardownInProgress = hadOwnedWork
        preparedSession?.lifecyclePreparationTask.cancel()
        startingLifecyclePreparationTask?.cancel()
        if case .starting = phaseBeforeCancellation, session == nil, preparedSession == nil {
            // `run()` owns its local media/lifecycle values until it observes the invalidated
            // generation. Keep the barrier closed until that path acknowledges cleanup.
            await waitForTeardownIfNeeded()
            return
        }
        if let preparedSession {
            _ = try? await preparedSession.lifecyclePreparationTask.value
            await lifecycle.finishPresentation()
            preparedSession.media.cleanUp()
            preparedSession.microphone?.invalidate()
            await lifecycle.finish()
        }
        guard let session else {
            await inputInstaller?.installInputSink(nil)
            if teardownInProgress {
                completeTeardown()
            } else {
                phase = .idle
            }
            return
        }
        await lifecycle.finishPresentation()
        await output.endSession()
        await inputInstaller?.installInputSink(nil)
        microphone?.finish()
        await session.close()
        await lifecycle.finish()
        completeTeardown()
        phase = .idle
    }

    public func currentInputSink() -> PlatformStreamingInputSink? { inputSink }

    private func reportPreparedConfiguration(
        _ prepared: StreamingConfigurationMapper.PreparedConfiguration
    ) {
        let configuration = prepared.configuration
        let refresh = configuration.clientRefreshRateTimes100 > 0
            ? String(configuration.clientRefreshRateTimes100)
            : "unspecified"
        diagnosticHandler(
            "Prepared stream: videoFormat="
                + String(format: "0x%04X", UInt32(bitPattern: prepared.result.selectedVideoFormat))
                + ", HDR=\(prepared.result.isHDR), YUV444=\(prepared.result.isYUV444), "
                + "fidelity=\(prepared.result.fidelity.rawValue), sourceRGBExact="
                + "\(prepared.result.fidelity.preservesSourceRGBExactly), "
                + "packetSize=\(configuration.packetSize), clientRefreshRateX100=\(refresh)."
        )
    }

    private static func effectiveBootstrap(
        _ bootstrap: StreamBootstrap,
        result: StreamPreparationResult,
        effectivePolicy: EffectiveStreamingPolicy
    ) -> StreamBootstrap {
        var effectiveBootstrap = bootstrap
        effectiveBootstrap.preferences = result.applying(to: bootstrap.preferences)
        effectiveBootstrap.effectivePolicy = effectivePolicy
        return effectiveBootstrap
    }

    private static func lifecycleIdentity(
        for bootstrap: StreamBootstrap
    ) -> LifecyclePreparationIdentity {
        LifecyclePreparationIdentity(
            sessionID: bootstrap.sessionID,
            preferences: bootstrap.preferences,
            effectivePolicy: bootstrap.effectivePolicy
        )
    }

    @discardableResult
    private func clearActiveSession(ifMatching sessionID: UUID) -> Bool {
        guard activeSessionID == sessionID else { return false }
        phase = .tearingDown(generation)
        activeSessionID = nil
        activeSession = nil
        inputSink = nil
        activeMicrophone = nil
        teardownInProgress = true
        return true
    }

    private func waitForTeardownIfNeeded() async {
        guard teardownInProgress else { return }
        await withCheckedContinuation { teardownWaiters.append($0) }
    }

    private func completeTeardown() {
        guard teardownInProgress else { return }
        teardownInProgress = false
        phase = .idle
        let waiters = teardownWaiters
        teardownWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func ensureCurrent(
        generation expectedGeneration: UInt64,
        phase expectedPhase: DriverPhase
    ) throws {
        try Task.checkCancellation()
        guard generation == expectedGeneration, phase == expectedPhase else {
            throw CancellationError()
        }
    }

    private func prepareClientMicrophone(
        for bootstrap: StreamBootstrap,
        existing: (any ClientMicrophoneForwarding)? = nil
    ) async throws -> (forwarder: (any ClientMicrophoneForwarding)?, warning: String?) {
        guard bootstrap.preferences.clientMicrophoneEnabled else {
            existing?.invalidate()
            return (nil, nil)
        }
        guard let microphonePreparer else {
            existing?.invalidate()
            let reason = "Microphone forwarding is unavailable in this build."
            if bootstrap.preferences.clientMicrophoneRequired {
                throw UmbraIntegrationError.clientMicrophoneRequiredUnavailable(reason)
            }
            return (nil, reason)
        }
        if let existing { return (existing, nil) }
        guard let endpoint = bootstrap.host.activeAddress ?? bootstrap.host.uniqueAddresses.first else {
            let reason = "Microphone forwarding could not resolve the streaming host."
            if bootstrap.preferences.clientMicrophoneRequired {
                throw UmbraIntegrationError.clientMicrophoneRequiredUnavailable(reason)
            }
            return (nil, reason)
        }
        do {
            return (
                try await microphonePreparer.prepare(
                    host: endpoint.hostname,
                    deviceUID: bootstrap.preferences.clientMicrophoneDeviceUID
                ),
                nil
            )
        } catch {
            if bootstrap.preferences.clientMicrophoneRequired {
                throw UmbraIntegrationError.clientMicrophoneRequiredUnavailable(
                    error.localizedDescription
                )
            }
            return (
                nil,
                "Microphone forwarding is unavailable for this stream: \(error.localizedDescription)"
            )
        }
    }

    private func applyClientMicrophone(
        _ microphone: (any ClientMicrophoneForwarding)?,
        to configuration: inout StreamingConfiguration
    ) {
        configuration.clientMicrophoneRequested = microphone != nil
        configuration.clientMicrophoneClientPort = microphone?.clientPort ?? 0
    }
}

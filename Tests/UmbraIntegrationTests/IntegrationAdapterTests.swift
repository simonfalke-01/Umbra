import AVFAudio
import Foundation
import XCTest
import UmbraCore
import UmbraMedia
import UmbraMicrophone
import UmbraNetworking
import UmbraPairing
import UmbraPlatform
import UmbraServices
@testable import UmbraStreaming
@testable import UmbraIntegration

final class IntegrationAdapterTests: XCTestCase {
    func testAuthenticatedProviderUsesPlainTransportBeforePairing() async throws {
        let plainTransport = IntegrationServerInfoTransport()
        let provider = try AuthenticatedGameStreamClientProvider(
            uniqueID: "test-client",
            identityProvider: FailingIdentityProvider(),
            plainTransport: plainTransport
        )

        let info = try await provider.client(for: nil).fetchServerInfo(
            address: HostAddress(host: "198.51.100.4", port: 47_989),
            secure: false,
            fastFail: true
        )

        XCTAssertEqual(info.uniqueID, "integration-host")
        let recordedRequest = await plainTransport.recordedRequest()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.url?.scheme, "http")
        XCTAssertEqual(request.url?.host, "198.51.100.4")
        XCTAssertEqual(request.url?.port, 47_989)
    }

    func testNativeVideoAdapterPreservesRecoveryRequestForGameStreamRFIIDRHandling() {
        XCTAssertEqual(
            NativeVideoDecoderAdapter.streamingDisposition(
                for: UmbraMedia.VideoFrameDisposition.requestKeyFrame
            ),
            UmbraStreaming.VideoFrameDisposition.requestKeyFrame
        )
    }

    func testNativeVideoAdapterPreservesOwnedEncodedStorageWithoutCopying() throws {
        let byteCount = 4_096
        let allocation = try XCTUnwrap(malloc(byteCount))
        memset(allocation, 0xA5, byteCount)
        let sourceAddress = UInt(bitPattern: allocation)
        let source = Data(bytesNoCopy: allocation, count: byteCount, deallocator: .free)
        let decoder = AddressRecordingNativeVideoDecoder()
        let adapter = NativeVideoDecoderAdapter(decoder: decoder)

        XCTAssertEqual(adapter.submit(frame: UmbraStreaming.CompressedVideoFrame(
            data: source,
            payloadFormat: .videoToolboxLengthPrefixed,
            frameNumber: 7,
            isKeyFrame: false,
            hostProcessingLatencyTenthsOfMillisecond: 0,
            receiveTimeMicroseconds: 0,
            enqueueTimeMicroseconds: 0,
            presentationTimeMicroseconds: 1,
            rtpTimestamp: 0,
            isHDR: false,
            colorSpace: 1
        )), .accepted)
        XCTAssertEqual(decoder.dataAddress, sourceAddress)
        XCTAssertEqual(decoder.dataCount, byteCount)
        XCTAssertEqual(decoder.payloadFormat, .videoToolboxLengthPrefixed)
    }

    func testCredentialFailureIsCachedAcrossBackgroundClientRefreshes() throws {
        let identityProvider = FailingIdentityProvider()
        let provider = try AuthenticatedGameStreamClientProvider(
            uniqueID: "test-client",
            identityProvider: identityProvider
        )
        var pairedHost = StreamHost(uuid: "paired-host", name: "Paired Host")
        pairedHost.serverCertificate = Data([0x01])

        _ = provider.client(for: pairedHost)
        _ = provider.client(for: pairedHost)
        _ = provider.client(for: pairedHost)

        XCTAssertEqual(identityProvider.identityRequestCount, 1)
    }

    func testPairingAdapterForwardsProgressCertificateAndCancellation() async throws {
        let coordinator = FakePairingCoordinator()
        let adapter = NativeHostPairingAdapter(coordinator: coordinator)
        let progress = LockedRecorder<PairingProgress>()
        let host = HostAddress(host: "gaming-mac.local")

        let certificate = try await adapter.pair(
            host: host,
            pin: "1234",
            appVersion: "7.1.0",
            isNVIDIAServerSoftware: false
        ) { progress.append($0) }
        await adapter.cancel(hostID: "persisted-host-id")

        XCTAssertEqual(certificate, Data([0xCA, 0xFE]))
        XCTAssertEqual(progress.values.map(\.stage), [.requestingServerCertificate, .complete])
        XCTAssertEqual(coordinator.requests, [.init(host: host, pin: "1234", appVersion: "7.1.0")])
        XCTAssertEqual(coordinator.cancelCount, 1)
    }

    func testFactoryPairingAdapterUsesConfiguredHostSecurePort() async throws {
        let coordinator = FakePairingCoordinator()
        let receivedPorts = LockedRecorder<UInt16>()
        let adapter = FactoryBackedHostPairingAdapter(
            securePortProvider: { address in address.host == "custom.local" ? 58_484 : 47_984 },
            coordinatorFactory: { _, securePort, _, _ in
                receivedPorts.append(securePort)
                return coordinator
            }
        )

        _ = try await adapter.pair(
            host: HostAddress(host: "custom.local", port: 58_489),
            pin: "1234",
            appVersion: "7.0",
            isNVIDIAServerSoftware: false
        ) { _ in }

        XCTAssertEqual(receivedPorts.values, [58_484])
    }

    func testFactoryPairingAdapterRejectsConcurrentPairingBeforeCreatingAnotherCoordinator() async throws {
        let coordinator = HoldingPairingCoordinator()
        let factoryCalls = LockedRecorder<HostAddress>()
        let adapter = FactoryBackedHostPairingAdapter(
            securePortProvider: { _ in 47_984 },
            coordinatorFactory: { host, _, _, _ in
                factoryCalls.append(host)
                return coordinator
            }
        )
        let firstHost = HostAddress(host: "first.local")
        let firstPairing = Task {
            try await adapter.pair(
                host: firstHost,
                pin: "1234",
                appVersion: "7.1.0",
                isNVIDIAServerSoftware: false
            ) { _ in }
        }
        await coordinator.waitUntilStarted()

        do {
            _ = try await adapter.pair(
                host: HostAddress(host: "second.local"),
                pin: "5678",
                appVersion: "7.1.0",
                isNVIDIAServerSoftware: false
            ) { _ in }
            XCTFail("Concurrent pairing unexpectedly started")
        } catch {
            XCTAssertEqual(error as? PairingError, .alreadyInProgress)
        }

        firstPairing.cancel()
        _ = await firstPairing.result
        XCTAssertEqual(factoryCalls.values, [firstHost])
    }

    func testFactoryPairingAdapterCancelInterruptsActivePairingTask() async {
        let coordinator = HoldingPairingCoordinator()
        let adapter = FactoryBackedHostPairingAdapter(
            securePortProvider: { _ in 47_984 },
            coordinatorFactory: { _, _, _, _ in coordinator }
        )
        let pairing = Task {
            try await adapter.pair(
                host: HostAddress(host: "lumen.test"),
                pin: "1234",
                appVersion: "7.1.0",
                isNVIDIAServerSoftware: false
            ) { _ in }
        }
        await coordinator.waitUntilStarted()

        await adapter.cancel(hostID: "lumen")

        switch await pairing.result {
        case .success:
            XCTFail("Cancelled pairing unexpectedly succeeded")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testFactoryPairingAdapterPreservesCoordinatorCancellationSemantics() async {
        let adapter = FactoryBackedHostPairingAdapter(
            securePortProvider: { _ in 47_984 },
            coordinatorFactory: { _, _, _, _ in CancelledPairingCoordinator() }
        )

        do {
            _ = try await adapter.pair(
                host: HostAddress(host: "lumen.test"),
                pin: "1234",
                appVersion: "7.1.0",
                isNVIDIAServerSoftware: false
            ) { _ in }
            XCTFail("Cancelled coordinator unexpectedly succeeded")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testStreamingConfigurationMapsCustomPacketSizeTargetRefreshColorAndCredentials() throws {
        var preferences = StreamingPreferences(
            width: 2_560,
            height: 1_440,
            fps: 120,
            bitrateKbps: 42_000,
            packetSize: 1_392,
            audioConfiguration: .surround71,
            enableHDR: true
        )
        preferences.validateForTest()
        let bootstrap = try makeBootstrap(
            preferences: preferences,
            clientRefreshRateX100: 6_000
        )

        let configuration = try StreamingConfigurationMapper.configuration(
            for: bootstrap,
            selectedVideoFormat: 0x0200
        )

        XCTAssertEqual(configuration.address, "10.0.0.25")
        XCTAssertEqual(configuration.serverAppVersion, "7.1.431")
        XCTAssertEqual(configuration.serverGFEVersion, "3.28")
        XCTAssertEqual(configuration.rtspSessionURL, "rtsp://10.0.0.25/session")
        XCTAssertEqual(configuration.serverCodecModeSupport, 0x201)
        XCTAssertEqual(configuration.width, 2_560)
        XCTAssertEqual(configuration.height, 1_440)
        XCTAssertEqual(configuration.framesPerSecond, 120)
        XCTAssertEqual(configuration.bitrateKbps, 42_000)
        XCTAssertEqual(configuration.packetSize, 1_392)
        XCTAssertEqual(configuration.remoteMode, 0)
        XCTAssertEqual(configuration.audioConfiguration, (0x63F << 16) | (8 << 8) | 0xCA)
        XCTAssertEqual(configuration.selectedVideoFormat, 0x0200)
        XCTAssertEqual(configuration.clientRefreshRateTimes100, 6_000)
        XCTAssertEqual(configuration.colorSpace, 0)
        XCTAssertTrue(configuration.fullColorRange)
        XCTAssertEqual(configuration.remoteInputAESKey, Data(0..<16))
        XCTAssertEqual(configuration.remoteInputAESIV, Data(16..<32))
        XCTAssertEqual(configuration.videoDecodeQueueCapacity, 2)
        XCTAssertEqual(configuration.rtspOptimizationMode, .quality)
        XCTAssertEqual(configuration.inputOptimizationMode, .quality)
        XCTAssertEqual(configuration.audioCapabilities, 0x10)
        XCTAssertEqual(configuration.videoCapabilities, 0x44)
        XCTAssertEqual(configuration.videoCapabilities & 0x01, 0)
    }

    func testStreamingConfigurationSeparatesLocalInputFromExtensibleHostAdvertisement() throws {
        var latencyPreferences = StreamingPreferences.default
        latencyPreferences.optimizationMode = .latency
        let latencyBootstrap = try makeBootstrap(preferences: latencyPreferences)

        let latency = try StreamingConfigurationMapper.configuration(
            for: latencyBootstrap,
            selectedVideoFormat: 0x0001
        )
        XCTAssertEqual(latency.inputOptimizationMode, .latency)
        XCTAssertEqual(latency.rtspOptimizationMode, .latency)

        var nvidiaBootstrap = latencyBootstrap
        nvidiaBootstrap.host.isNvidiaServerSoftware = true
        let nvidia = try StreamingConfigurationMapper.configuration(
            for: nvidiaBootstrap,
            selectedVideoFormat: 0x0001
        )
        XCTAssertEqual(nvidia.inputOptimizationMode, .latency)
        XCTAssertEqual(nvidia.rtspOptimizationMode, .legacy)
    }

    func testStreamingConfigurationAcceptsReferenceAutomaticBitrateAboveManualLimit() throws {
        let preferences = StreamingPreferences(
            width: 3_840,
            height: 2_160,
            fps: 240
        )

        let configuration = try StreamingConfigurationMapper.configuration(
            for: makeBootstrap(preferences: preferences),
            selectedVideoFormat: 0x0001
        )

        XCTAssertEqual(configuration.bitrateKbps, 160_000)
        XCTAssertFalse(preferences.unlockBitrate)
        XCTAssertTrue(preferences.autoAdjustBitrate)
    }

    func testAutomaticPacketSizeUses1392OnLAN() throws {
        var preferences = StreamingPreferences.default
        preferences.packetSize = 0

        let configuration = try StreamingConfigurationMapper.configuration(
            for: makeBootstrap(preferences: preferences, reachability: .lan),
            selectedVideoFormat: 0x0001
        )

        XCTAssertEqual(configuration.packetSize, 1_392)
        XCTAssertEqual(configuration.remoteMode, 0)
    }

    func testAutomaticPacketSizeUses1024OnVPN() throws {
        var preferences = StreamingPreferences.default
        preferences.packetSize = 0

        let configuration = try StreamingConfigurationMapper.configuration(
            for: makeBootstrap(preferences: preferences, reachability: .vpn),
            selectedVideoFormat: 0x0001
        )

        XCTAssertEqual(configuration.packetSize, 1_024)
        XCTAssertEqual(configuration.remoteMode, 1)
    }

    func testAutomaticPacketSizeUses1392WithAutodetectWhenReachabilityIsUnknown() throws {
        var preferences = StreamingPreferences.default
        preferences.packetSize = 0

        let configuration = try StreamingConfigurationMapper.configuration(
            for: makeBootstrap(preferences: preferences, reachability: .unknown),
            selectedVideoFormat: 0x0001
        )

        XCTAssertEqual(configuration.packetSize, 1_392)
        XCTAssertEqual(configuration.remoteMode, 2)
    }

    func testCustomPacketSizeIsPreservedOnRemoteRouteWithoutAutomaticCap() throws {
        var preferences = StreamingPreferences.default
        preferences.packetSize = 65_507

        let configuration = try StreamingConfigurationMapper.configuration(
            for: makeBootstrap(preferences: preferences, reachability: .vpn),
            selectedVideoFormat: 0x0001
        )

        XCTAssertEqual(configuration.packetSize, 65_507)
        XCTAssertEqual(configuration.remoteMode, 0)
    }

    func testUnknownTargetDisplayRefreshRemainsUnspecified() throws {
        var preferences = StreamingPreferences.default
        preferences.fps = 120

        let configuration = try StreamingConfigurationMapper.configuration(
            for: makeBootstrap(preferences: preferences, clientRefreshRateX100: nil),
            selectedVideoFormat: 0x0001
        )

        XCTAssertEqual(configuration.framesPerSecond, 120)
        XCTAssertEqual(configuration.clientRefreshRateTimes100, 0)
    }

    func testPlatformPacketsMapToGameStreamProtocolConstants() {
        XCTAssertEqual(
            PlatformStreamingInputSink.command(for: .keyboard(.init(
                virtualKey: 0x41,
                action: .down,
                modifiers: [.control, .option],
                isExtended: false
            ))),
            .keyboard(keyCode: Int16(bitPattern: 0x8041), action: 0x03, modifiers: 0x06, flags: 0)
        )
        XCTAssertEqual(
            PlatformStreamingInputSink.command(for: .keyboard(.init(
                virtualKey: 0xDC,
                action: .up,
                modifiers: [],
                isExtended: false,
                flags: 0x01
            ))),
            .keyboard(keyCode: Int16(bitPattern: 0x80DC), action: 0x04, modifiers: 0, flags: 0x01)
        )
        XCTAssertEqual(
            PlatformStreamingInputSink.command(for: .mouseButton(.init(button: .right, action: .up))),
            .mouseButton(action: 0x08, button: 3)
        )
        XCTAssertEqual(
            PlatformStreamingInputSink.command(for: .scroll(.init(axis: .horizontal, delta: -240))),
            .scroll(vertical: 0, horizontal: -240)
        )

        let controller = ControllerPacket(
            playerIndex: 2,
            activeControllerMask: 0b101,
            buttons: [.a, .dpadUp, .paddle1, .misc],
            leftTrigger: 1,
            rightTrigger: 2,
            leftStickX: 3,
            leftStickY: 4,
            rightStickX: 5,
            rightStickY: 6
        )
        XCTAssertEqual(
            PlatformStreamingInputSink.command(for: .controller(controller)),
            .controller(
                number: 2,
                activeMask: 5,
                buttons: 0x211001,
                leftTrigger: 1,
                rightTrigger: 2,
                leftStickX: 3,
                leftStickY: 4,
                rightStickX: 5,
                rightStickY: 6
            )
        )

        let arrival = ControllerArrivalPacket(
            playerIndex: 1,
            activeControllerMask: 3,
            family: .playStation,
            supportedButtons: [.x, .touchpad],
            capabilities: [.analogTriggers, .touchpad, .accelerometer, .dualTouchpad, .adaptiveTriggers],
            vendorName: "Sony",
            productCategory: "DualSense"
        )
        XCTAssertEqual(
            PlatformStreamingInputSink.command(for: .controllerArrival(arrival)),
            .controllerArrival(
                number: 1,
                activeMask: 3,
                type: 2,
                supportedButtons: 0x104000,
                capabilities: 0x119
            )
        )

        let touch = ControllerTouchPacket(
            playerIndex: 1,
            touchpadIndex: 1,
            fingerIndex: 2,
            phase: .moved,
            x: 0.25,
            y: 0.75,
            pressure: 0.5
        )
        XCTAssertEqual(
            PlatformStreamingInputSink.command(for: .controllerTouch(touch)),
            .controllerTouch(
                number: 1,
                eventType: 3,
                touchpadIndex: 1,
                pointerID: 0x102,
                x: 0.25,
                y: 0.75,
                pressure: 0.5
            )
        )
        for (phase, eventType) in [(ControllerTouchPhase.began, UInt8(1)), (.ended, 2), (.moved, 3)] {
            var lifecycleTouch = touch
            lifecycleTouch.phase = phase
            guard case let .controllerTouch(_, mappedType, _, _, _, _, _) =
                PlatformStreamingInputSink.command(for: .controllerTouch(lifecycleTouch))
            else {
                return XCTFail("Expected controller touch command for \(phase)")
            }
            XCTAssertEqual(mappedType, eventType)
        }
    }

    func testInputSinkSubmitsImmediatelyInPacketOrderAndHonorsMotionRequests() async {
        let session = FakeStreamingSession()
        let motion = ControllerMotionPolicy()
        let uptime = FakeUptimeProvider(values: [0, 0.001, 0.02])
        let sink = PlatformStreamingInputSink(sender: session, motionPolicy: motion, uptimeProvider: uptime)

        sink.platformInputDidProduce(.text("first"))
        sink.platformInputDidProduce(.text("second"))
        sink.platformInputDidProduce(.controllerMotion(.init(
            playerIndex: 0,
            kind: .gyroscope,
            x: 1,
            y: 2,
            z: 3
        )))
        motion.setReportRate(100, player: 0, motionType: 2)
        sink.platformInputDidProduce(.controllerMotion(.init(
            playerIndex: 0,
            kind: .gyroscope,
            x: 1,
            y: 2,
            z: 3
        )))
        sink.platformInputDidProduce(.controllerMotion(.init(
            playerIndex: 0,
            kind: .gyroscope,
            x: 4,
            y: 5,
            z: 6
        )))

        let commands = await session.commands
        XCTAssertEqual(commands, [
            .text("first"),
            .text("second"),
            .controllerMotion(number: 0, type: 2, x: 1, y: 2, z: 3),
            .controllerMotion(number: 0, type: 2, x: 4, y: 5, z: 6),
        ])
    }

    func testInputSinkReachesSynchronousSenderBeforeCallbackReturns() throws {
        let session = FakeStreamingSession()
        let sink = PlatformStreamingInputSink(sender: session)
        let command = StreamInputCommand.mouseMove(deltaX: 7, deltaY: -3)

        sink.platformInputDidProduce(.mouseMove(.relative(deltaX: 7, deltaY: -3)))

        XCTAssertEqual(
            session.inputCommands.values,
            [command],
            "Capture-to-native submission must complete inline without a Task or actor scheduling delay."
        )
    }

    func testInputSinkReportsSynchronousSubmissionFailure() {
        let session = FakeStreamingSession(inputSendError: .inputUnavailable)
        let failures = LockedRecorder<String>()
        let sink = PlatformStreamingInputSink(sender: session) {
            failures.append(String(describing: $0))
        }

        sink.platformInputDidProduce(.mouseMove(.relative(deltaX: 1, deltaY: 1)))

        XCTAssertEqual(failures.values, [String(describing: FakeStreamingSessionError.inputUnavailable)])
    }

    func testInputSinkForwardsStartControllerPacketWithoutInterpretingIt() async {
        let session = FakeStreamingSession()
        let sink = PlatformStreamingInputSink(sender: session)
        let packet = ControllerPacket(
            playerIndex: 0,
            activeControllerMask: 1,
            buttons: [.start, .a],
            leftTrigger: 1,
            rightTrigger: 2,
            leftStickX: 3,
            leftStickY: 4,
            rightStickX: 5,
            rightStickY: 6
        )

        sink.platformInputDidProduce(.controller(packet))

        let commands = await session.commands
        XCTAssertEqual(commands, [
            .controller(
                number: 0,
                activeMask: 1,
                buttons: 0x001010,
                leftTrigger: 1,
                rightTrigger: 2,
                leftStickX: 3,
                leftStickY: 4,
                rightStickX: 5,
                rightStickY: 6
            ),
        ])
    }

    func testInputSinkPreservesMouseEdgesAndScrollOrderWithoutStaleMotionReplay() async {
        let session = FakeStreamingSession()
        let sink = PlatformStreamingInputSink(sender: session)

        sink.platformInputDidProduce(.mouseButton(.init(button: .left, action: .down)))
        sink.platformInputDidProduce(.scroll(.init(axis: .vertical, delta: 120)))
        sink.platformInputDidProduce(.mouseMove(.relative(deltaX: 1, deltaY: 2)))
        sink.platformInputDidProduce(.mouseButton(.init(button: .left, action: .up)))

        let commands = await session.commands
        XCTAssertEqual(commands, [
            .mouseButton(action: 0x07, button: 1),
            .scroll(vertical: 120, horizontal: 0),
            .mouseMove(deltaX: 1, deltaY: 2),
            .mouseButton(action: 0x08, button: 1),
        ])
    }

    func testSynchronousInputChannelSerializesSubmissionAndWaitsBeforeDetach() throws {
        let pointer = try XCTUnwrap(OpaquePointer(bitPattern: 1))
        let channel = SynchronousStreamingInputChannel(pointer: pointer)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let sendGroup = DispatchGroup()
        let detachGroup = DispatchGroup()
        let sendErrors = LockedRecorder<String>()

        sendGroup.enter()
        DispatchQueue.global(qos: .userInteractive).async {
            defer { sendGroup.leave() }
            do {
                try channel.submit { _ in
                    entered.signal()
                    release.wait()
                    return 0
                }
            } catch {
                sendErrors.append(String(describing: error))
            }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)

        detachGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            channel.detach()
            detachGroup.leave()
        }
        XCTAssertEqual(
            detachGroup.wait(timeout: .now() + 0.02),
            .timedOut,
            "Teardown must wait for a synchronous native send already in flight."
        )

        release.signal()
        XCTAssertEqual(sendGroup.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(detachGroup.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(sendErrors.values.isEmpty)
        XCTAssertThrowsError(try channel.submit { _ in 0 }) { error in
            XCTAssertEqual(error as? StreamingError, .closed)
        }

        let nextSessionChannel = SynchronousStreamingInputChannel(pointer: pointer)
        var nextSessionSubmitted = false
        XCTAssertNoThrow(try nextSessionChannel.submit { _ in
            nextSessionSubmitted = true
            return 0
        })
        XCTAssertTrue(nextSessionSubmitted, "A detached prior channel must not poison the next stream session.")
    }

    @MainActor
    func testDriverMapsEventsAndCompletesLifecycle() async throws {
        let session = FakeStreamingSession()
        let factory = FakeStreamingSessionFactory(session: session)
        let readinessOrder = LockedRecorder<String>()
        let lifecycle = RecordingLifecycle(onPrepare: { readinessOrder.append("lifecycle") })
        let output = RecordingOutput()
        let inputInstaller = FakeInputInstaller(startProbe: session.startProbe)
        let date = Date(timeIntervalSince1970: 123)
        let diagnostics = LockedRecorder<String>()
        let driver = NativeStreamSessionDriver(
            mediaProvider: FakeMediaProvider(),
            sessionFactory: factory,
            output: output,
            inputInstaller: inputInstaller,
            lifecycle: lifecycle,
            dateProvider: FixedDateProvider(value: date),
            diagnosticHandler: { diagnostics.append($0) }
        )
        let events = LockedRecorder<StreamDriverEvent>()
        let bootstrap = try makeBootstrap()
        try await driver.prepare(bootstrap)

        let run = Task {
            try await driver.run(bootstrap) { event in
                if case .streaming = event { readinessOrder.append("streaming") }
                events.append(event)
            }
        }
        await session.waitUntilStarted()
        factory.emit(.stageStarting(stage: 4, name: "RTSP handshake"))
        factory.emit(.connectionStarted)
        factory.emit(.connectionStatus(1))
        factory.emit(.log("native stream detail"))
        factory.emit(.hdrMode(enabled: true, metadata: nil))
        await session.finishSuccessfully()

        let result = try await run.value
        let prepareCount = await lifecycle.prepareCount
        let finishCount = await lifecycle.finishCount
        let currentInputSink = await driver.currentInputSink()
        let inputInstallations = inputInstaller.installations
        XCTAssertEqual(result.endedAt, date)
        XCTAssertTrue(events.values.contains(.connecting(.serverHandshake)))
        XCTAssertTrue(events.values.contains(.streaming(date)))
        XCTAssertTrue(events.values.contains(.warning("The host reports a poor streaming connection.")))
        XCTAssertTrue(diagnostics.values.contains("native stream detail"))
        XCTAssertEqual(output.values, [.hdrMode(enabled: true, metadata: nil)])
        XCTAssertEqual(prepareCount, 1)
        XCTAssertEqual(finishCount, 1)
        XCTAssertEqual(factory.configuration?.remoteInputAESKey, Data(0..<16))
        XCTAssertNil(currentInputSink)
        XCTAssertEqual(inputInstallations, [true, false])
        XCTAssertFalse(
            inputInstaller.nonNilInstalledAfterStart,
            "Input must be armed before synchronous first-frame callbacks can reveal the stream window."
        )
        XCTAssertEqual(Array(readinessOrder.values.prefix(2)), ["lifecycle", "streaming"])
    }

    func testDriverWarmsLifecycleConcurrentlyButBarsNativeStartUntilReady() async throws {
        let session = FakeStreamingSession()
        let lifecycle = SuspendedPreparationLifecycle()
        let driver = NativeStreamSessionDriver(
            mediaProvider: FakeMediaProvider(),
            sessionFactory: FakeStreamingSessionFactory(session: session),
            lifecycle: lifecycle
        )
        let bootstrap = try makeBootstrap()

        _ = try await driver.prepare(bootstrap)
        await lifecycle.waitUntilPreparationStarted()
        XCTAssertFalse(
            session.startProbe.isStarted,
            "Local warmup must begin during preparation without starting the native session."
        )

        let run = Task { try await driver.run(bootstrap) { _ in } }
        await Task.yield()
        XCTAssertFalse(
            session.startProbe.isStarted,
            "Native callbacks must not race an inactive renderer while warmup is unfinished."
        )

        await lifecycle.releasePreparation()
        await session.waitUntilStarted()
        await session.finishSuccessfully()
        _ = try await run.value
    }

    func testPreparedCancelBlocksImmediateReopenUntilWarmupCleanupAcknowledges() async throws {
        let lifecycle = ManuallyReleasedPreparationLifecycle()
        let driver = NativeStreamSessionDriver(
            mediaProvider: FakeMediaProvider(),
            lifecycle: lifecycle
        )
        let first = try makeBootstrap()
        _ = try await driver.prepare(first)
        await lifecycle.waitUntilPreparationStarted()

        let cancellation = Task { await driver.cancel() }
        await Task.yield()
        do {
            _ = try await driver.prepare(try makeBootstrap())
            XCTFail("Reopen must wait for prepared warmup cleanup.")
        } catch {
            XCTAssertEqual(error as? UmbraServiceError, .sessionInProgress)
        }

        await lifecycle.releasePreparation()
        await cancellation.value
        _ = try await driver.prepare(try makeBootstrap())
        await driver.cancel()
    }

    func testStartingCancelBlocksImmediateReopenUntilRunAcknowledgesCleanup() async throws {
        let lifecycle = ManuallyReleasedPreparationLifecycle()
        let session = FakeStreamingSession()
        let driver = NativeStreamSessionDriver(
            mediaProvider: FakeMediaProvider(),
            sessionFactory: FakeStreamingSessionFactory(session: session),
            lifecycle: lifecycle
        )
        let first = try makeBootstrap()
        _ = try await driver.prepare(first)
        await lifecycle.waitUntilPreparationStarted()
        let run = Task { try await driver.run(first) { _ in } }
        await Task.yield()

        let cancellation = Task { await driver.cancel() }
        await Task.yield()
        do {
            _ = try await driver.prepare(try makeBootstrap())
            XCTFail("Reopen must wait for starting-path cleanup acknowledgement.")
        } catch {
            XCTAssertEqual(error as? UmbraServiceError, .sessionInProgress)
        }

        await lifecycle.releasePreparation()
        _ = try? await run.value
        await cancellation.value
        _ = try await driver.prepare(try makeBootstrap())
        await driver.cancel()
    }

    @MainActor
    func testDriverAcceptsOrderedFeedbackEmittedSynchronouslyInsideSessionStart() async throws {
        let session = FakeStreamingSession(startEvents: [
            .rumble(controller: 0, lowFrequency: UInt16.max, highFrequency: UInt16.max),
            .rumble(controller: 0, lowFrequency: 0, highFrequency: 0),
            .adaptiveTriggers(
                controller: 0,
                flags: 0x0C,
                leftType: 1,
                rightType: 1,
                left: Data([1, 8]),
                right: Data([1, 8])
            ),
            .adaptiveTriggers(
                controller: 0,
                flags: 0,
                leftType: 0,
                rightType: 0,
                left: Data(),
                right: Data()
            ),
        ])
        let controllers = FakeControllerOutputService()
        let output = StreamingSessionOutputAdapter(controllers: controllers)
        let driver = NativeStreamSessionDriver(
            mediaProvider: FakeMediaProvider(),
            sessionFactory: FakeStreamingSessionFactory(session: session),
            output: output
        )
        let bootstrap = try makeBootstrap()
        try await driver.prepare(bootstrap)

        let run = Task { try await driver.run(bootstrap) { _ in } }
        await session.waitUntilStarted()
        await session.finishSuccessfully()
        _ = try await run.value

        XCTAssertEqual(controllers.commands, [
            .rumble(lowFrequency: UInt16.max, highFrequency: UInt16.max),
            .rumble(lowFrequency: 0, highFrequency: 0),
            .adaptiveTriggers(
                left: .feedback(startPosition: Float(1) / 9, strength: 1),
                right: .feedback(startPosition: Float(1) / 9, strength: 1)
            ),
            .adaptiveTriggers(left: .off, right: .off),
        ])
        XCTAssertEqual(controllers.feedbackLifecycleEvents, [
            "begin", "send", "send", "send", "send", "end",
        ])
        XCTAssertFalse(controllers.feedbackSessionActive)
    }

    @MainActor
    func testDriverCancellationClosesSessionAndFinishesLifecycleOnce() async throws {
        let session = FakeStreamingSession()
        let factory = FakeStreamingSessionFactory(session: session)
        let lifecycle = RecordingLifecycle()
        let controllers = FakeControllerOutputService()
        let output = StreamingSessionOutputAdapter(controllers: controllers)
        let driver = NativeStreamSessionDriver(
            mediaProvider: FakeMediaProvider(),
            sessionFactory: factory,
            output: output,
            lifecycle: lifecycle
        )
        let bootstrap = try makeBootstrap()
        try await driver.prepare(bootstrap)
        let run = Task { try await driver.run(bootstrap) { _ in } }
        await session.waitUntilStarted()

        run.cancel()
        await driver.cancel()

        do {
            _ = try await run.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let closeCount = await session.closeCount
        let finishCount = await lifecycle.finishCount
        let currentInputSink = await driver.currentInputSink()
        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(finishCount, 1)
        XCTAssertNil(currentInputSink)
        XCTAssertEqual(controllers.feedbackLifecycleEvents, ["begin", "end"])
        XCTAssertFalse(controllers.feedbackSessionActive)
    }

    @MainActor
    func testDriverFinishesLocalLifecycleBeforeWaitingForNativeClose() async throws {
        let session = FakeStreamingSession()
        await session.setCloseBlocked(true)
        let lifecycle = RecordingLifecycle()
        let driver = NativeStreamSessionDriver(
            mediaProvider: FakeMediaProvider(),
            sessionFactory: FakeStreamingSessionFactory(session: session),
            lifecycle: lifecycle
        )
        let bootstrap = try makeBootstrap()
        try await driver.prepare(bootstrap)
        let run = Task { try await driver.run(bootstrap) { _ in } }
        await session.waitUntilStarted()

        let cancellation = Task { await driver.cancel() }
        await session.waitUntilCloseIsBlocked()

        let presentationFinishCount = await lifecycle.presentationFinishCount
        let finishCount = await lifecycle.finishCount
        XCTAssertEqual(
            presentationFinishCount,
            1,
            "Local window presentation teardown must not wait behind a slow native session close."
        )
        XCTAssertEqual(
            finishCount,
            0,
            "Final audio/resource teardown must remain behind native close and its GameStream cleanup callbacks."
        )
        do {
            _ = try await driver.prepare(makeBootstrap())
            XCTFail("A new stream must not prepare while prior native/audio teardown is incomplete.")
        } catch {
            XCTAssertEqual(error as? UmbraServiceError, .sessionInProgress)
        }

        await session.releaseClose()
        await cancellation.value
        _ = try? await run.value
        let completedFinishCount = await lifecycle.finishCount
        XCTAssertEqual(completedFinishCount, 1)
    }

    @MainActor
    func testDriverSuccessfulCompletionOrdersPresentationCloseThenFinalLifecycle() async throws {
        let order = LockedRecorder<String>()
        let session = FakeStreamingSession(teardownRecorder: order)
        let lifecycle = RecordingLifecycle(
            onPresentationFinish: { order.append("presentation") },
            onFinish: { order.append("finish") }
        )
        let driver = NativeStreamSessionDriver(
            mediaProvider: FakeMediaProvider(),
            sessionFactory: FakeStreamingSessionFactory(session: session),
            lifecycle: lifecycle
        )
        let bootstrap = try makeBootstrap()
        try await driver.prepare(bootstrap)
        let run = Task { try await driver.run(bootstrap) { _ in } }
        await session.waitUntilStarted()
        await session.finishSuccessfully()

        _ = try await run.value

        XCTAssertEqual(order.values, ["presentation", "close", "finish"])
    }

    @MainActor
    func testCompetingCancelWaitsForTheExistingNativeTeardownBarrier() async throws {
        let session = FakeStreamingSession()
        await session.setCloseBlocked(true)
        let driver = NativeStreamSessionDriver(
            mediaProvider: FakeMediaProvider(),
            sessionFactory: FakeStreamingSessionFactory(session: session),
            lifecycle: RecordingLifecycle()
        )
        let bootstrap = try makeBootstrap()
        try await driver.prepare(bootstrap)
        let run = Task { try await driver.run(bootstrap) { _ in } }
        await session.waitUntilStarted()
        await session.finishSuccessfully()
        await session.waitUntilCloseIsBlocked()

        let completion = LockedRecorder<String>()
        let competingCancel = Task {
            await driver.cancel()
            completion.append("cancelled")
        }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(
            completion.values.isEmpty,
            "Cancel must remain a completion barrier while another path owns native teardown."
        )

        await session.releaseClose()
        _ = try await run.value
        await competingCancel.value
        XCTAssertEqual(completion.values, ["cancelled"])
        let closeCount = await session.closeCount
        XCTAssertEqual(closeCount, 1)
    }

    @MainActor
    func testDriverFailureOrdersPresentationCloseThenFinalLifecycle() async throws {
        let order = LockedRecorder<String>()
        let session = FakeStreamingSession(teardownRecorder: order)
        let lifecycle = RecordingLifecycle(
            onPresentationFinish: { order.append("presentation") },
            onFinish: { order.append("finish") }
        )
        let driver = NativeStreamSessionDriver(
            mediaProvider: FakeMediaProvider(),
            sessionFactory: FakeStreamingSessionFactory(session: session),
            lifecycle: lifecycle
        )
        let bootstrap = try makeBootstrap()
        try await driver.prepare(bootstrap)
        let run = Task { try await driver.run(bootstrap) { _ in } }
        await session.waitUntilStarted()
        await session.finish(with: -1)

        do {
            _ = try await run.value
            XCTFail("Expected stream termination failure")
        } catch {
            XCTAssertEqual(error as? UmbraIntegrationError, .streamTerminated(code: -1))
        }
        XCTAssertEqual(order.values, ["presentation", "close", "finish"])
    }

    @MainActor
    func testDriverSubmitsReleasePacketsBeforeClosingSession() async throws {
        let session = FakeStreamingSession()
        let installer = ReleaseOnUninstallInputInstaller()
        let driver = NativeStreamSessionDriver(
            mediaProvider: FakeMediaProvider(),
            sessionFactory: FakeStreamingSessionFactory(session: session),
            inputInstaller: installer,
            lifecycle: RecordingLifecycle()
        )
        let bootstrap = try makeBootstrap()
        try await driver.prepare(bootstrap)
        let run = Task { try await driver.run(bootstrap) { _ in } }
        await session.waitUntilStarted()
        await session.finishSuccessfully()
        _ = try await run.value

        let events = await session.teardownEvents
        XCTAssertEqual(events.suffix(2), ["send", "close"])
        let commands = await session.commands
        XCTAssertTrue(commands.contains {
            guard case let .keyboard(_, action, _, _) = $0 else { return false }
            return action == 0x04
        })
    }

    func testDriverRetriesKeyframesUntilVideoToolboxProducesOutput() async throws {
        let session = FakeStreamingSession()
        let factory = FakeStreamingSessionFactory(session: session)
        let readiness = VideoFrameReadiness()
        let driver = NativeStreamSessionDriver(
            mediaProvider: FakeMediaProvider(videoFrameReadiness: readiness),
            sessionFactory: factory,
            keyFrameRecoveryInterval: .milliseconds(1),
            keyFrameRecoveryAttempts: 5
        )
        let bootstrap = try makeBootstrap()
        try await driver.prepare(bootstrap)
        let run = Task { try await driver.run(bootstrap) { _ in } }
        await session.waitUntilStarted()

        for _ in 0..<100 {
            if await session.keyFrameRequestCount >= 2 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let requestsBeforeDecode = await session.keyFrameRequestCount
        XCTAssertGreaterThanOrEqual(requestsBeforeDecode, 2)

        readiness.markDecodedFrame()
        try await Task.sleep(for: .milliseconds(10))
        let requestsAfterDecode = await session.keyFrameRequestCount
        XCTAssertLessThan(requestsAfterDecode, 5)

        await session.finishSuccessfully()
        _ = try await run.value
    }

    func testDriverFallsBackToVirtualTrackpadWhenHostLacksDirectTouch() async throws {
        let session = FakeStreamingSession()
        await session.setHostFeatureFlags(0)
        let lifecycle = RecordingLifecycle()
        let diagnostics = LockedRecorder<String>()
        let driver = NativeStreamSessionDriver(
            mediaProvider: FakeMediaProvider(),
            sessionFactory: FakeStreamingSessionFactory(session: session),
            lifecycle: lifecycle,
            diagnosticHandler: { diagnostics.append($0) }
        )
        var bootstrap = try makeBootstrap()
        bootstrap.preferences.absoluteTouchMode = true
        try await driver.prepare(bootstrap)

        let run = Task { try await driver.run(bootstrap) { _ in } }
        await session.waitUntilStarted()
        await session.finishSuccessfully()
        _ = try await run.value

        let prepared = await lifecycle.lastBootstrap
        XCTAssertEqual(prepared?.preferences.absoluteTouchMode, false)
        XCTAssertTrue(diagnostics.values.contains {
            $0.contains("using virtual trackpad mode")
        })
    }

    func testDriverLifecycleReceivesPreparedVideoFallbacksForDirectCallers() async throws {
        let session = FakeStreamingSession()
        let lifecycle = RecordingLifecycle()
        let driver = NativeStreamSessionDriver(
            mediaProvider: FakeMediaProvider(),
            sessionFactory: FakeStreamingSessionFactory(session: session),
            lifecycle: lifecycle
        )
        var preferences = StreamingPreferences.default
        preferences.enableHDR = true
        preferences.enableYUV444 = true
        preferences.autoAdjustBitrate = true
        preferences.bitrateKbps = 99_000
        let bootstrap = try makeBootstrap(preferences: preferences)
        let result = try await driver.prepare(bootstrap)

        let run = Task { try await driver.run(bootstrap) { _ in } }
        await session.waitUntilStarted()
        await session.finishSuccessfully()
        _ = try await run.value

        let prepared = await lifecycle.lastBootstrap
        XCTAssertFalse(result.isHDR)
        XCTAssertFalse(result.isYUV444)
        XCTAssertEqual(prepared?.preferences.enableHDR, false)
        XCTAssertEqual(prepared?.preferences.enableYUV444, false)
        XCTAssertEqual(
            prepared?.preferences.bitrateKbps,
            StreamingPreferences.defaultBitrateKbps(
                width: preferences.width,
                height: preferences.height,
                fps: preferences.fps,
                yuv444: false
            )
        )
    }

    @MainActor
    func testDriverPropagatesDirectTouchCapabilityQueryFailure() async throws {
        let session = FakeStreamingSession()
        await session.setHostFeatureFlagsFailure(true)
        let lifecycle = RecordingLifecycle()
        let diagnostics = LockedRecorder<String>()
        let controllers = FakeControllerOutputService()
        let output = StreamingSessionOutputAdapter(controllers: controllers)
        let driver = NativeStreamSessionDriver(
            mediaProvider: FakeMediaProvider(),
            sessionFactory: FakeStreamingSessionFactory(session: session),
            output: output,
            lifecycle: lifecycle,
            diagnosticHandler: { diagnostics.append($0) }
        )
        var bootstrap = try makeBootstrap()
        bootstrap.preferences.absoluteTouchMode = true
        try await driver.prepare(bootstrap)

        do {
            _ = try await driver.run(bootstrap) { _ in }
            XCTFail("Expected the capability query failure to propagate")
        } catch {
            XCTAssertEqual(error as? FakeStreamingSessionError, .featureFlagsUnavailable)
        }

        let prepared = await lifecycle.lastBootstrap
        XCTAssertEqual(
            prepared?.preferences.absoluteTouchMode,
            true,
            "Hidden renderer preparation is allowed before the host capability query fails."
        )
        XCTAssertFalse(diagnostics.values.contains {
            $0.contains("virtual trackpad mode")
        })
        XCTAssertEqual(controllers.feedbackLifecycleEvents, ["begin", "end"])
        XCTAssertFalse(controllers.feedbackSessionActive)
    }

    func testDriverRetriesStatisticsAfterTransientQueryFailure() async throws {
        let session = FakeStreamingSession()
        await session.setStatisticsFailuresRemaining(1)
        let output = RecordingOutput()
        let diagnostics = LockedRecorder<String>()
        let videoStatistics = MediaPipelineStatistics(
            submittedFrames: 120,
            decodedFrames: 119,
            presentedFrames: 0,
            droppedFrames: 1,
            decoderErrors: 1,
            queueDepth: 2,
            decodeFramesPerSecond: 118.5,
            presentationFramesPerSecond: 0,
            averageDecodeLatencyMilliseconds: 1.25
        )
        let driver = NativeStreamSessionDriver(
            mediaProvider: FakeMediaProvider(videoStatistics: videoStatistics),
            sessionFactory: FakeStreamingSessionFactory(session: session),
            output: output,
            diagnosticHandler: { diagnostics.append($0) },
            statisticsPollingInterval: .milliseconds(1)
        )

        let bootstrap = try makeBootstrap()
        try await driver.prepare(bootstrap)
        let run = Task { try await driver.run(bootstrap) { _ in } }
        await session.waitUntilStarted()
        for _ in 0..<200 {
            if await session.statisticsRequestCount >= 2,
               output.values.contains(where: {
                   if case .statistics = $0 { return true }
                   return false
               }),
               output.videoStatistics.contains(videoStatistics) {
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        await session.finishSuccessfully()
        _ = try await run.value

        let statisticsRequestCount = await session.statisticsRequestCount
        XCTAssertGreaterThanOrEqual(statisticsRequestCount, 2)
        XCTAssertTrue(output.values.contains(where: {
            if case .statistics = $0 { return true }
            return false
        }))
        XCTAssertTrue(output.videoStatistics.contains(videoStatistics))
        XCTAssertTrue(diagnostics.values.contains {
            $0.contains("Streaming statistics query failed; retrying")
        })
    }

    func testClientMicrophoneIsNegotiatedOnlyAfterPreparationAndEndsBeforeSessionClose() async throws {
        let teardown = LockedRecorder<String>()
        let session = FakeStreamingSession(
            startEvents: [
                .clientMicrophoneGeneration(StreamingClientMicrophoneGeneration(
                    sessionID: Data(repeating: 0x11, count: 16),
                    salt: Data(repeating: 0x22, count: 16),
                    serverPort: 50_012,
                    clientPort: 54_321,
                    remoteAddress: "192.0.2.42"
                )),
            ],
            teardownRecorder: teardown
        )
        let factory = FakeStreamingSessionFactory(session: session)
        let microphone = FakeClientMicrophoneForwarder(clientPort: 54_321, teardown: teardown)
        let preparer = FakeClientMicrophonePreparer(result: .success(microphone))
        let driver = NativeStreamSessionDriver(
            mediaProvider: FakeMediaProvider(),
            sessionFactory: factory,
            microphonePreparer: preparer
        )
        var preferences = StreamingPreferences.default
        preferences.clientMicrophoneEnabled = true
        let bootstrap = try makeBootstrap(preferences: preferences)

        try await driver.prepare(bootstrap)
        let run = Task { try await driver.run(bootstrap) { _ in } }
        await session.waitUntilStarted()
        await session.finishSuccessfully()
        _ = try await run.value

        XCTAssertEqual(preparer.hosts, ["10.0.0.25"])
        XCTAssertTrue(factory.configuration?.clientMicrophoneRequested == true)
        XCTAssertEqual(factory.configuration?.clientMicrophoneClientPort, 54_321)
        XCTAssertEqual(microphone.generations.count, 1)
        XCTAssertEqual(microphone.generations.first?.rikey, Data(0..<16))
        XCTAssertEqual(microphone.finishCount, 1)
        XCTAssertEqual(teardown.values, ["microphone-end", "close"])
    }

    func testClientMicrophonePreparationFailureWarnsWithoutRequestingRTSPOrFailingStream() async throws {
        let session = FakeStreamingSession()
        let factory = FakeStreamingSessionFactory(session: session)
        let preparer = FakeClientMicrophonePreparer(
            result: .failure(ClientMicrophonePreparationError.permissionDenied(.denied))
        )
        let driver = NativeStreamSessionDriver(
            mediaProvider: FakeMediaProvider(),
            sessionFactory: factory,
            microphonePreparer: preparer
        )
        var preferences = StreamingPreferences.default
        preferences.clientMicrophoneEnabled = true
        let bootstrap = try makeBootstrap(preferences: preferences)
        let events = LockedRecorder<StreamDriverEvent>()

        try await driver.prepare(bootstrap)
        let run = Task { try await driver.run(bootstrap) { events.append($0) } }
        await session.waitUntilStarted()
        await session.finishSuccessfully()
        _ = try await run.value

        XCTAssertFalse(factory.configuration?.clientMicrophoneRequested == true)
        XCTAssertEqual(factory.configuration?.clientMicrophoneClientPort, 0)
        XCTAssertTrue(events.values.contains { event in
            if case let .warning(message) = event {
                return message.contains("Microphone forwarding is unavailable")
            }
            return false
        })
    }

    func testRequiredClientMicrophonePreparationFailureStopsBeforeSessionCreation() async throws {
        let factory = FakeStreamingSessionFactory(session: FakeStreamingSession())
        let driver = NativeStreamSessionDriver(
            mediaProvider: FakeMediaProvider(),
            sessionFactory: factory,
            microphonePreparer: FakeClientMicrophonePreparer(
                result: .failure(ClientMicrophonePreparationError.permissionDenied(.denied))
            )
        )
        var preferences = StreamingPreferences.default
        preferences.clientMicrophoneEnabled = true
        preferences.clientMicrophoneRequired = true
        let bootstrap = try makeBootstrap(preferences: preferences)

        do {
            _ = try await driver.prepare(bootstrap)
            XCTFail("Required microphone failure must stop before stream creation.")
        } catch let error as UmbraIntegrationError {
            guard case .clientMicrophoneRequiredUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertNil(factory.configuration)
    }

    func testRequiredClientMicrophoneRuntimeFailureTerminatesTheSession() async throws {
        let session = FakeStreamingSession(startEvents: [
            .clientMicrophoneGeneration(StreamingClientMicrophoneGeneration(
                sessionID: Data(repeating: 0x11, count: 16),
                salt: Data(repeating: 0x22, count: 16),
                serverPort: 50_012,
                clientPort: 54_321,
                remoteAddress: "192.0.2.42"
            )),
        ])
        let microphone = FakeClientMicrophoneForwarder(clientPort: 54_321)
        let driver = NativeStreamSessionDriver(
            mediaProvider: FakeMediaProvider(),
            sessionFactory: FakeStreamingSessionFactory(session: session),
            microphonePreparer: FakeClientMicrophonePreparer(result: .success(microphone))
        )
        var preferences = StreamingPreferences.default
        preferences.clientMicrophoneEnabled = true
        preferences.clientMicrophoneRequired = true
        let bootstrap = try makeBootstrap(preferences: preferences)

        try await driver.prepare(bootstrap)
        let run = Task { try await driver.run(bootstrap) { _ in } }
        await session.waitUntilStarted()
        microphone.emitWarning("Microphone capture stopped unexpectedly.")

        do {
            _ = try await run.value
            XCTFail("Required microphone runtime failure must terminate the stream.")
        } catch let error as UmbraIntegrationError {
            guard case .clientMicrophoneRequiredUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let closeCount = await session.closeCount
        XCTAssertGreaterThanOrEqual(closeCount, 1)
    }

    @MainActor
    func testOutputAdapterRoutesControllerFeedbackAndMotionPolicy() async {
        let controllers = FakeControllerOutputService()
        let motionEnabler = FakeMotionEnabler()
        let policy = ControllerMotionPolicy()
        let hdr = LockedRecorder<Bool>()
        let statistics = LockedRecorder<StreamTransportStatistics>()
        let output = StreamingSessionOutputAdapter(
            controllers: controllers,
            motionEnabler: motionEnabler,
            motionPolicy: policy,
            hdrHandler: { enabled, _ in hdr.append(enabled) },
            statisticsHandler: { statistics.append($0) }
        )
        await output.beginSession()

        output.handle(.rumble(controller: 1, lowFrequency: 10, highFrequency: 20))
        output.handle(.triggerRumble(controller: 1, left: 30, right: 40))
        output.handle(.controllerLED(controller: 1, red: 1, green: 2, blue: 3))
        output.handle(.motionState(controller: 1, type: 2, reportRateHz: 100))
        output.handle(.adaptiveTriggers(
            controller: 1,
            flags: 0x0C,
            leftType: 1,
            rightType: 2,
            left: Data([3, 4]),
            right: Data([2, 7, 8])
        ))
        output.handle(.hdrMode(enabled: true, metadata: nil))
        let transportStatistics = StreamTransportStatistics(
            estimatedRTTMilliseconds: 12,
            estimatedRTTVarianceMilliseconds: 2,
            pendingVideoFrames: 1,
            pendingAudioFrames: 2,
            pendingAudioDurationMilliseconds: 10,
            audioPackets: 100,
            audioFECRecovered: 1,
            audioFECFailed: 0,
            videoPackets: 200,
            videoFECRecovered: 2,
            videoFECFailed: 0
        )
        output.handle(.statistics(transportStatistics))
        await output.drainCallbacks()

        XCTAssertEqual(controllers.commands, [
            .rumble(lowFrequency: 10, highFrequency: 20),
            .triggerRumble(left: 30, right: 40),
            .led(red: 1, green: 2, blue: 3),
            .adaptiveTriggers(
                left: .feedback(startPosition: Float(3) / 9, strength: Float(4) / 8),
                right: .weapon(startPosition: Float(2) / 9, endPosition: Float(7) / 9, strength: 1)
            ),
        ])
        XCTAssertEqual(controllers.players, [1, 1, 1, 1])
        XCTAssertEqual(motionEnabler.values, [false, true])
        XCTAssertTrue(policy.hasEnabledMotion)
        XCTAssertEqual(hdr.values, [true])
        XCTAssertEqual(statistics.values, [transportStatistics])
        await output.endSession()
        XCTAssertEqual(motionEnabler.values, [false, true, false])
        XCTAssertFalse(policy.hasEnabledMotion)
        let lateMotion = ControllerMotionPacket(
            playerIndex: 1,
            kind: .gyroscope,
            x: 1,
            y: 2,
            z: 3
        )
        XCTAssertFalse(policy.shouldForward(lateMotion, at: 1))
        let session = FakeStreamingSession()
        let sink = PlatformStreamingInputSink(
            sender: session,
            motionPolicy: policy,
            uptimeProvider: FakeUptimeProvider(values: [1, 2])
        )
        sink.platformInputDidProduce(.controllerMotion(lateMotion))
        let commandsAfterTeardown = await session.commands
        XCTAssertTrue(commandsAfterTeardown.isEmpty)

        output.handle(.motionState(controller: 1, type: 2, reportRateHz: 120))
        output.handle(.rumble(controller: 1, lowFrequency: UInt16.max, highFrequency: UInt16.max))
        await output.drainCallbacks()
        XCTAssertFalse(policy.hasEnabledMotion, "late callbacks must not re-enable motion after teardown")
        XCTAssertEqual(motionEnabler.values, [false, true, false])
        XCTAssertEqual(controllers.commands.count, 4)

        await output.beginSession()
        XCTAssertFalse(policy.hasEnabledMotion, "the next session must start without stale motion requests")
        XCTAssertEqual(motionEnabler.values.last, false)
        var nextSessionMotion = lateMotion
        nextSessionMotion.x = 4
        sink.platformInputDidProduce(.controllerMotion(nextSessionMotion))
        let commandsAtNextSessionStart = await session.commands
        XCTAssertTrue(commandsAtNextSessionStart.isEmpty)
        await output.endSession()
    }

    @MainActor
    func testOutputAdapterPreservesNativeCallbackSubmissionOrderThroughFeedbackOff() async {
        let controllers = FakeControllerOutputService()
        let output = StreamingSessionOutputAdapter(controllers: controllers)
        let callbackQueue = DispatchQueue(label: "test.umbra.controller-output-callbacks")
        await output.beginSession()

        await withCheckedContinuation { continuation in
            callbackQueue.async {
                output.handle(.rumble(
                    controller: 0,
                    lowFrequency: UInt16.max,
                    highFrequency: UInt16.max
                ))
                output.handle(.rumble(controller: 0, lowFrequency: 0, highFrequency: 0))
                output.handle(.adaptiveTriggers(
                    controller: 0,
                    flags: 0x0C,
                    leftType: 1,
                    rightType: 1,
                    left: Data([1, 8]),
                    right: Data([1, 8])
                ))
                output.handle(.adaptiveTriggers(
                    controller: 0,
                    flags: 0,
                    leftType: 0,
                    rightType: 0,
                    left: Data(),
                    right: Data()
                ))
                continuation.resume()
            }
        }
        await output.drainCallbacks()

        XCTAssertEqual(controllers.commands, [
            .rumble(lowFrequency: UInt16.max, highFrequency: UInt16.max),
            .rumble(lowFrequency: 0, highFrequency: 0),
            .adaptiveTriggers(
                left: .feedback(startPosition: Float(1) / 9, strength: 1),
                right: .feedback(startPosition: Float(1) / 9, strength: 1)
            ),
            .adaptiveTriggers(left: .off, right: .off),
        ])
        await output.endSession()
    }

    func testLifecycleMapsWindowModeAndReleasesResources() async throws {
        let keepAwake = FakeKeepAwakeController()
        let window = FakeWindowController()
        let audio = FakeAudioLifecycleController()
        let platform = FakePlatformLifecycleController()
        let lifecycle = NativeStreamSessionLifecycleCoordinator(
            keepAwake: keepAwake,
            window: window,
            audio: audio,
            platform: platform
        )
        var preferences = StreamingPreferences.default
        preferences.windowMode = .fullscreenDesktop
        preferences.keepAwake = true

        try await lifecycle.prepare(for: makeBootstrap(preferences: preferences))
        await lifecycle.applicationActiveStateChanged(false)
        await lifecycle.finish()

        let keepAwakeStates = await keepAwake.states
        let presentations = await window.presentations
        let audioActiveStates = audio.activeStates
        let audioStopCount = audio.stopCount
        let platformStartCount = await platform.startCount
        let platformStopCount = await platform.stopCount
        XCTAssertEqual(keepAwakeStates, [true, false])
        XCTAssertEqual(presentations, [.borderlessFullscreen])
        XCTAssertEqual(audioActiveStates, [true, false])
        XCTAssertEqual(audioStopCount, 1)
        XCTAssertEqual(platformStartCount, 1)
        XCTAssertEqual(platformStopCount, 1)
    }

    func testCompositeLifecycleSeparatesPresentationAndFinalPhasesInReverseOrder() async throws {
        let order = LockedRecorder<String>()
        let first = RecordingLifecycle(
            onPresentationFinish: { order.append("first-presentation") },
            onFinish: { order.append("first-finish") }
        )
        let second = RecordingLifecycle(
            onPresentationFinish: { order.append("second-presentation") },
            onFinish: { order.append("second-finish") }
        )
        let lifecycle = CompositeStreamSessionLifecycleCoordinator([first, second])

        try await lifecycle.prepare(for: makeBootstrap())
        await lifecycle.finishPresentation()
        await lifecycle.finish()

        XCTAssertEqual(order.values, [
            "second-presentation",
            "first-presentation",
            "second-finish",
            "first-finish",
        ])
    }

    func testCompositePrepareFailureRollsBackPresentationWithoutPrematureFinalCleanup() async throws {
        let prepared = RecordingLifecycle()
        let lifecycle = CompositeStreamSessionLifecycleCoordinator([
            prepared,
            FailingLifecycle(),
        ])

        do {
            try await lifecycle.prepare(for: makeBootstrap())
            XCTFail("Expected lifecycle preparation failure")
        } catch {
            XCTAssertEqual(error as? FakeStreamingSessionError, .featureFlagsUnavailable)
        }

        let presentationFinishCount = await prepared.presentationFinishCount
        let finishCount = await prepared.finishCount
        XCTAssertEqual(presentationFinishCount, 1)
        XCTAssertEqual(
            finishCount,
            0,
            "Final media cleanup must remain deferred until the native session close boundary."
        )
    }

    func testMediaProviderRejectsUnavailableAudioOutput() throws {
        let capabilities = UmbraMedia.AppleStreamingCapabilities(
            hasMetalDevice: true,
            supportsHardwareH264: true,
            supportsHardwareHEVC: true,
            supportsHardwareAV1: false,
            hasDefaultAudioOutput: false,
            supportsNativeAudioOutput: false,
            audioOutputChannelCount: 0
        )
        let provider = AppleStreamingMediaProvider(
            capabilities: capabilities,
            renderer: FakeVideoRenderer(),
            audioDecoder: nil
        )

        XCTAssertThrowsError(try provider.makePipeline(for: makeBootstrap())) { error in
            XCTAssertEqual(error as? UmbraIntegrationError, .audioOutputUnavailable)
        }
    }

    func testNativeAudioFailedConfigureStopsPreparedRendererExactlyOnce() throws {
        let renderer = WarmupTrackingPCMRenderer()
        let provider = AppleStreamingMediaProvider(
            capabilities: audioCapableAppleStreamingCapabilities(),
            renderer: FakeVideoRenderer(),
            audioRendererFactory: { _ in renderer }
        )
        let pipeline = try provider.makePipeline(for: makeBootstrap())
        let callbacks = StreamingCallbackTestHarness(
            videoDecoder: pipeline.videoDecoder,
            audioDecoder: pipeline.audioDecoder
        )

        XCTAssertEqual(renderer.startCount, 1)
        XCTAssertEqual(callbacks.audioInit(
            audioConfiguration: (0x3 << 16) | (2 << 8) | 0xCA,
            sampleRate: 48_000,
            channelCount: 2,
            streamCount: 0,
            coupledStreamCount: 1,
            samplesPerFrame: 240,
            mapping: [0, 1],
            flags: 0
        ), -1)
        XCTAssertEqual(renderer.stopCount, 1)

        callbacks.audioCleanup()
        XCTAssertEqual(renderer.stopCount, 1, "Cleanup after failed configure must be idempotent.")
    }

    func testNativeAudioConfigureUsesWarmRendererWithoutSecondFactoryOrStart() throws {
        let renderer = WarmupTrackingPCMRenderer()
        let factoryConfigurations = LockedRecorder<PCMRendererConfiguration>()
        let provider = AppleStreamingMediaProvider(
            capabilities: audioCapableAppleStreamingCapabilities(),
            renderer: FakeVideoRenderer(),
            audioRendererFactory: { configuration in
                factoryConfigurations.append(configuration)
                return renderer
            }
        )
        let pipeline = try provider.makePipeline(for: makeBootstrap())
        let callbacks = StreamingCallbackTestHarness(
            videoDecoder: pipeline.videoDecoder,
            audioDecoder: pipeline.audioDecoder
        )

        XCTAssertEqual(factoryConfigurations.values.count, 1)
        XCTAssertEqual(renderer.startCount, 1)
        XCTAssertEqual(callbacks.audioInit(
            audioConfiguration: (0x3 << 16) | (2 << 8) | 0xCA,
            sampleRate: 48_000,
            channelCount: 2,
            streamCount: 1,
            coupledStreamCount: 1,
            samplesPerFrame: 240,
            mapping: [0, 1],
            flags: 0
        ), 0)
        XCTAssertEqual(factoryConfigurations.values.count, 1)
        XCTAssertEqual(renderer.startCount, 1)

        callbacks.audioCleanup()
        callbacks.audioCleanup()
        XCTAssertEqual(renderer.stopCount, 1)
    }

    func testNativeAudioBufferingPolicyIsModeSpecific() throws {
        for (mode, outputDuration, preRollDuration) in [
            (StreamOptimizationMode.latency, 0.005, 0.010),
            (StreamOptimizationMode.quality, 0.015, 0.030),
        ] {
            var preferences = StreamingPreferences.default
            preferences.optimizationMode = mode
            let factoryConfigurations = LockedRecorder<PCMRendererConfiguration>()
            let provider = AppleStreamingMediaProvider(
                capabilities: audioCapableAppleStreamingCapabilities(),
                renderer: FakeVideoRenderer(),
                audioRendererFactory: { configuration in
                    factoryConfigurations.append(configuration)
                    return WarmupTrackingPCMRenderer(configuration: configuration)
                }
            )

            let pipeline = try provider.makePipeline(for: makeBootstrap(preferences: preferences))
            let configuration = try XCTUnwrap(factoryConfigurations.values.first)
            XCTAssertEqual(configuration.outputBufferDuration, outputDuration, accuracy: 0.000_001)
            XCTAssertEqual(configuration.minimumPreRollDuration, preRollDuration, accuracy: 0.000_001)
            pipeline.cleanUp()
        }
    }

    func testNativeAudioBootstrapCancellationStopsPreparedRendererExactlyOnce() async throws {
        let renderer = WarmupTrackingPCMRenderer()
        let provider = AppleStreamingMediaProvider(
            capabilities: audioCapableAppleStreamingCapabilities(),
            renderer: FakeVideoRenderer(),
            audioRendererFactory: { _ in renderer }
        )
        let driver = NativeStreamSessionDriver(mediaProvider: provider)

        try await driver.prepare(makeBootstrap())
        XCTAssertEqual(renderer.startCount, 1)
        XCTAssertEqual(renderer.stopCount, 0)

        await driver.cancel()
        XCTAssertEqual(renderer.stopCount, 1)

        await driver.cancel()
        XCTAssertEqual(renderer.stopCount, 1, "Repeated cancellation must not detach twice.")
    }

    func testUnusedNativeAudioPipelineStopsPreparedRendererExactlyOnce() throws {
        let renderer = WarmupTrackingPCMRenderer()
        let provider = AppleStreamingMediaProvider(
            capabilities: audioCapableAppleStreamingCapabilities(),
            renderer: FakeVideoRenderer(),
            audioRendererFactory: { _ in renderer }
        )
        var pipeline: StreamingMediaPipeline? = try provider.makePipeline(for: makeBootstrap())

        XCTAssertNotNil(pipeline)
        XCTAssertEqual(renderer.startCount, 1)
        XCTAssertEqual(renderer.stopCount, 0)

        pipeline = nil
        XCTAssertEqual(renderer.stopCount, 1)
    }

    func testNativeAudioControllerRetainsIncompleteTeardownUntilSubsequentAttachRetry() {
        let audioController = NativeAudioSessionController()
        var renderer: ControllableTeardownPCMRenderer? = ControllableTeardownPCMRenderer(
            teardownComplete: false
        )
        weak let retainedRenderer = renderer
        audioController.attach(renderer!)

        audioController.detach(renderer!)
        XCTAssertEqual(renderer?.stopCount, 1)
        XCTAssertEqual(audioController.retainedRendererCount, 1)

        renderer = nil
        XCTAssertNotNil(retainedRenderer, "Incomplete AudioQueue teardown must retain a durable owner.")
        XCTAssertEqual(audioController.stop(), .retryRequired)
        XCTAssertEqual(retainedRenderer?.stopCount, 2)
        XCTAssertEqual(audioController.retainedRendererCount, 1)

        retainedRenderer?.setTeardownComplete(true)
        let replacement = ControllableTeardownPCMRenderer(teardownComplete: true)
        audioController.attach(replacement)

        XCTAssertNil(retainedRenderer, "A later attach must retry and release completed teardown.")
        XCTAssertEqual(audioController.retainedRendererCount, 1)
        audioController.detach(replacement)
        XCTAssertEqual(audioController.retainedRendererCount, 0)
    }

    func testNativeAudioControllerSerializesConcurrentAttachAndFocusChange() {
        let audioController = NativeAudioSessionController()
        let renderer = BlockingFocusPCMRenderer()
        let attachFinished = DispatchSemaphore(value: 0)
        let focusChangeFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            audioController.attach(renderer)
            attachFinished.signal()
        }
        XCTAssertEqual(
            renderer.firstFocusCallEntered.wait(timeout: .now() + 1),
            .success
        )

        DispatchQueue.global(qos: .userInitiated).async {
            audioController.setApplicationActive(false)
            focusChangeFinished.signal()
        }
        XCTAssertEqual(
            focusChangeFinished.wait(timeout: .now() + 0.050),
            .timedOut,
            "The newer focus state must wait behind the in-flight attach update."
        )

        renderer.releaseFirstFocusCall()
        XCTAssertEqual(attachFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(focusChangeFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(renderer.activeStates, [true, false])
        audioController.detach(renderer)
    }

    func testLumenHDRMetadataPacksExactMDCVAndContentLightBlobs() throws {
        let source = StreamingHDRMetadata(
            redX: 35_400,
            redY: 14_600,
            greenX: 8_500,
            greenY: 39_850,
            blueX: 6_550,
            blueY: 2_300,
            whiteX: 15_635,
            whiteY: 16_450,
            maximumDisplayLuminanceNits: 1_000,
            minimumDisplayLuminanceTenThousandthsOfNit: 50,
            maximumContentLightLevelNits: 900,
            maximumFrameAverageLightLevelNits: 400,
            maximumFullFrameLuminanceNits: 600
        )

        let metadata = HDRStaticMetadata(streaming: source)

        XCTAssertEqual(metadata.minimumLuminanceNits, 0.005)
        XCTAssertEqual(metadata.maximumLuminanceNits, 1_000)
        XCTAssertEqual(metadata.maximumContentLightLevelNits, 900)
        XCTAssertEqual(metadata.maximumFrameAverageLightLevelNits, 400)
        XCTAssertEqual(metadata.masteringDisplayColorVolume?.count, 24)
        XCTAssertEqual(
            metadata.contentLightLevelInfo,
            Data([0x03, 0x84, 0x01, 0x90])
        )
        let display = try XCTUnwrap(metadata.masteringDisplayColorVolume)
        XCTAssertEqual(Array(display.prefix(4)), [0x21, 0x34, 0x9B, 0xAA])
        XCTAssertEqual(Array(display.suffix(8)), [0x00, 0x98, 0x96, 0x80, 0x00, 0x00, 0x00, 0x32])
    }

    func testIntegrationErrorsProvideExactSessionFailureClassification() {
        let cases: [(UmbraIntegrationError, SessionFailureKind, SessionStage, Int?)] = [
            (.missingHostAddress("host"), .hostUnavailable, .nameResolution, nil),
            (.missingServerAppVersion("host"), .connectionFailed, .serverHandshake, nil),
            (.unsupportedVideoConfiguration(.hevc), .decoderUnavailable, .platformInitialization, nil),
            (.unsupportedRendererConfiguration(.vulkan), .rendererUnavailable, .platformInitialization, nil),
            (.videoRendererUnavailable, .rendererUnavailable, .platformInitialization, nil),
            (.audioDecoderUnavailable, .audioUnavailable, .audioStreamInitialization, nil),
            (.audioOutputUnavailable, .audioUnavailable, .audioStreamInitialization, nil),
            (.mediaConfigurationFailed("bad audio layout"), .audioUnavailable, .audioStreamInitialization, nil),
            (.streamingStageFailed(stage: .videoStreamInitialization, code: -12), .connectionFailed, .videoStreamInitialization, -12),
            (.streamTerminated(code: -9), .streamTerminated, .connection, -9),
            (.inputQueueOverflow, .connectionFailed, .inputStreamInitialization, nil),
        ]

        for (error, kind, stage, code) in cases {
            let failure = error.sessionFailure
            XCTAssertEqual(failure.kind, kind, "Unexpected kind for \(error)")
            XCTAssertEqual(failure.stage, stage, "Unexpected stage for \(error)")
            XCTAssertEqual(failure.errorCode, code, "Unexpected code for \(error)")
            XCTAssertFalse(failure.message.isEmpty)
        }
    }

    func testDriverPreparationReusesMediaAndRefreshesConfigurationForSameSession() async throws {
        let mediaProvider = RecordingMediaProvider()
        let session = FakeStreamingSession()
        let factory = FakeStreamingSessionFactory(session: session)
        let driver = NativeStreamSessionDriver(
            mediaProvider: mediaProvider,
            sessionFactory: factory
        )
        let initial = try makeBootstrap()
        try await driver.prepare(initial)

        var refreshed = initial
        refreshed.host.activeAddress = NetworkEndpoint(hostname: "10.0.0.99", port: 48_010)
        refreshed.host.appVersion = "9.9.9"
        refreshed.rtspSessionURL = URL(string: "rtsp://10.0.0.99/refreshed")
        try await driver.prepare(refreshed)

        XCTAssertEqual(mediaProvider.makeCount, 1)
        let run = Task { try await driver.run(refreshed) { _ in } }
        await session.waitUntilStarted()
        await session.finishSuccessfully()
        _ = try await run.value

        XCTAssertEqual(factory.configuration?.address, "10.0.0.99")
        XCTAssertEqual(factory.configuration?.serverAppVersion, "9.9.9")
        XCTAssertEqual(factory.configuration?.rtspSessionURL, "rtsp://10.0.0.99/refreshed")
        XCTAssertEqual(mediaProvider.makeCount, 1)
        XCTAssertEqual(mediaProvider.videoCleanUpCount, 0)
        XCTAssertEqual(mediaProvider.audioCleanUpCount, 0)
    }

    func testDriverRetainsPreparedPolicyThroughMediaPreparationAndRun() async throws {
        let mediaProvider = RecordingMediaProvider()
        let session = FakeStreamingSession()
        let factory = FakeStreamingSessionFactory(session: session)
        let lifecycle = RecordingLifecycle()
        let driver = NativeStreamSessionDriver(
            mediaProvider: mediaProvider,
            sessionFactory: factory,
            lifecycle: lifecycle
        )
        var policyPreferences = StreamingPreferences.default
        policyPreferences.optimizationMode = .latency
        policyPreferences.enableVSync = false
        policyPreferences.framePacing = false
        let preparedPolicy = EffectiveStreamingPolicy.resolve(for: policyPreferences)
        var bootstrap = try makeBootstrap()
        bootstrap.effectivePolicy = preparedPolicy

        try await driver.prepare(bootstrap)
        var runBootstrap = bootstrap
        runBootstrap.effectivePolicy = .resolve(for: .default)
        let run = Task { try await driver.run(runBootstrap) { _ in } }
        await session.waitUntilStarted()
        await session.finishSuccessfully()
        _ = try await run.value

        let lifecycleBootstrap = await lifecycle.lastBootstrap
        XCTAssertEqual(mediaProvider.lastBootstrap?.effectivePolicy, preparedPolicy)
        XCTAssertEqual(lifecycleBootstrap?.effectivePolicy, preparedPolicy)
        XCTAssertEqual(factory.configuration?.videoDecodeQueueCapacity, 1)
        XCTAssertEqual(factory.configuration?.inputOptimizationMode, .latency)
        XCTAssertEqual(factory.configuration?.rtspOptimizationMode, .latency)
    }

    func testDriverPreparationRetryUsesTheRetryPolicyQueueCapacityExactly() async throws {
        let mediaProvider = RecordingMediaProvider()
        let session = FakeStreamingSession()
        let factory = FakeStreamingSessionFactory(session: session)
        let driver = NativeStreamSessionDriver(
            mediaProvider: mediaProvider,
            sessionFactory: factory
        )
        let initial = try makeBootstrap()
        try await driver.prepare(initial)

        var latencyPreferences = initial.preferences
        latencyPreferences.optimizationMode = .latency
        var retry = initial
        retry.preferences = latencyPreferences
        retry.effectivePolicy = .resolve(for: latencyPreferences)
        try await driver.prepare(retry)

        var runBootstrap = retry
        runBootstrap.effectivePolicy = .resolve(for: .default)
        let run = Task { try await driver.run(runBootstrap) { _ in } }
        await session.waitUntilStarted()
        await session.finishSuccessfully()
        _ = try await run.value

        XCTAssertEqual(mediaProvider.makeCount, 1)
        XCTAssertEqual(factory.configuration?.videoDecodeQueueCapacity, 1)
    }

    func testDriverPreparationReusesMediaButRenegotiatesRefreshedHostCapabilities() async throws {
        let available = GameStreamVideoFormat.hevc.rawValue | GameStreamVideoFormat.av1Main8.rawValue
        let mediaProvider = RecordingMediaProvider(availableVideoFormats: available)
        let session = FakeStreamingSession()
        let factory = FakeStreamingSessionFactory(session: session)
        let driver = NativeStreamSessionDriver(
            mediaProvider: mediaProvider,
            sessionFactory: factory
        )
        var initial = try makeBootstrap()
        initial.host.codecSupport = [.hevc]
        let first = try await driver.prepare(initial)

        var refreshed = initial
        refreshed.host.codecSupport = [.av1Main8]
        let second = try await driver.prepare(refreshed)

        XCTAssertEqual(first.selectedVideoFormat, GameStreamVideoFormat.hevc.rawValue)
        XCTAssertEqual(second.selectedVideoFormat, GameStreamVideoFormat.av1Main8.rawValue)
        XCTAssertEqual(mediaProvider.makeCount, 1)

        let run = Task { try await driver.run(refreshed) { _ in } }
        await session.waitUntilStarted()
        await session.finishSuccessfully()
        _ = try await run.value

        XCTAssertEqual(factory.configuration?.selectedVideoFormat, GameStreamVideoFormat.av1Main8.rawValue)
        XCTAssertEqual(mediaProvider.makeCount, 1)
    }

    func testDriverCancelCleansUnconsumedPreparedPipelineAndAllowsRetry() async throws {
        let mediaProvider = RecordingMediaProvider()
        let driver = NativeStreamSessionDriver(mediaProvider: mediaProvider)
        let bootstrap = try makeBootstrap()

        try await driver.prepare(bootstrap)
        await driver.cancel()
        XCTAssertEqual(mediaProvider.videoCleanUpCount, 1)
        XCTAssertEqual(mediaProvider.audioCleanUpCount, 1)

        try await driver.prepare(bootstrap)
        XCTAssertEqual(mediaProvider.makeCount, 2)
        await driver.cancel()
        XCTAssertEqual(mediaProvider.videoCleanUpCount, 2)
        XCTAssertEqual(mediaProvider.audioCleanUpCount, 2)
    }

    func testDriverCleansPreparedPipelineWhenConfigurationFails() async throws {
        let mediaProvider = RecordingMediaProvider()
        let driver = NativeStreamSessionDriver(mediaProvider: mediaProvider)
        var bootstrap = try makeBootstrap()
        bootstrap.host.activeAddress = nil

        do {
            try await driver.prepare(bootstrap)
            XCTFail("Expected configuration preparation to fail")
        } catch {
            XCTAssertEqual(error as? UmbraIntegrationError, .missingHostAddress("host-1"))
        }

        XCTAssertEqual(mediaProvider.makeCount, 1)
        XCTAssertEqual(mediaProvider.videoCleanUpCount, 1)
        XCTAssertEqual(mediaProvider.audioCleanUpCount, 1)
    }

    func testDriverRejectsRunWithoutMatchingPreparation() async throws {
        let mediaProvider = RecordingMediaProvider()
        let driver = NativeStreamSessionDriver(mediaProvider: mediaProvider)
        let bootstrap = try makeBootstrap()

        do {
            _ = try await driver.run(bootstrap) { _ in }
            XCTFail("Expected an unprepared run to fail")
        } catch {
            XCTAssertEqual(error as? UmbraIntegrationError, .sessionNotPrepared(bootstrap.sessionID))
        }

        try await driver.prepare(bootstrap)
        var other = bootstrap
        other.sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        do {
            _ = try await driver.run(other) { _ in }
            XCTFail("Expected mismatched preparation to fail")
        } catch {
            XCTAssertEqual(
                error as? UmbraIntegrationError,
                .preparedSessionMismatch(expected: bootstrap.sessionID, actual: other.sessionID)
            )
        }
        await driver.cancel()
        XCTAssertEqual(mediaProvider.videoCleanUpCount, 1)
        XCTAssertEqual(mediaProvider.audioCleanUpCount, 1)
    }

    private func audioCapableAppleStreamingCapabilities() -> UmbraMedia.AppleStreamingCapabilities {
        UmbraMedia.AppleStreamingCapabilities(
            hasMetalDevice: true,
            supportsHardwareH264: true,
            supportsHardwareHEVC: true,
            supportsHardwareAV1: false,
            hasDefaultAudioOutput: true,
            supportsNativeAudioOutput: true,
            audioOutputChannelCount: 2
        )
    }

    private func makeBootstrap(
        preferences: StreamingPreferences = .default,
        reachability: HostReachability = .lan,
        clientRefreshRateX100: Int32? = nil
    ) throws -> StreamBootstrap {
        var host = StreamHost(
            uuid: "host-1",
            name: "Gaming Mac",
            activeAddress: NetworkEndpoint(hostname: "10.0.0.25"),
            activeAddressReachability: reachability,
            gfeVersion: "3.28",
            appVersion: "7.1.431",
            codecSupport: HostCodecSupport(rawValue: 0x201)
        )
        let application = StreamApplication(id: 7, name: "Game")
        host.applications = [application]
        return StreamBootstrap(
            sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            host: host,
            application: application,
            preferences: preferences,
            clientRefreshRateX100: clientRefreshRateX100,
            rtspSessionURL: URL(string: "rtsp://10.0.0.25/session"),
            remoteInputCredentials: try RemoteInputCredentials(
                key: Data(0..<16),
                initializationVector: Data(16..<32)
            )
        )
    }
}

private actor IntegrationServerInfoTransport: HTTPTransport {
    private var request: URLRequest?

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        self.request = request
        let body = Data("""
        <root status_code="200">
          <hostname>Integration Host</hostname><uniqueid>integration-host</uniqueid>
          <PairStatus>0</PairStatus><currentgame>0</currentgame>
          <state>LUMEN_SERVER_FREE</state>
        </root>
        """.utf8)
        return (
            body,
            HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": String(body.count)]
            )!
        )
    }

    func recordedRequest() -> URLRequest? { request }
}

private final class FakePairingCoordinator: PairingHandshakeCoordinating, @unchecked Sendable {
    struct Request: Equatable {
        let host: HostAddress
        let pin: String
        let appVersion: String
    }

    private let lock = NSLock()
    private var storedRequests: [Request] = []
    private var storedCancelCount = 0

    var requests: [Request] { lock.withLock { storedRequests } }
    var cancelCount: Int { lock.withLock { storedCancelCount } }

    func pair(
        host: HostAddress,
        pin: String,
        appVersion: String,
        onProgress: @escaping @Sendable (PairingProgress) -> Void
    ) async throws -> PairedHostIdentity {
        lock.withLock { storedRequests.append(.init(host: host, pin: pin, appVersion: appVersion)) }
        onProgress(.init(stage: .requestingServerCertificate, message: "certificate"))
        onProgress(.init(stage: .complete, message: "complete"))
        return PairedHostIdentity(serverCertificateDER: Data([0xCA, 0xFE]))
    }

    func cancel() {
        lock.withLock { storedCancelCount += 1 }
    }
}

private actor HoldingPairingCoordinator: PairingHandshakeCoordinating {
    private var started = false

    func pair(
        host: HostAddress,
        pin: String,
        appVersion: String,
        onProgress: @escaping @Sendable (PairingProgress) -> Void
    ) async throws -> PairedHostIdentity {
        started = true
        try await Task.sleep(for: .seconds(60))
        throw PairingError.cancelled
    }

    nonisolated func cancel() {}

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }
}

private final class CancelledPairingCoordinator: PairingHandshakeCoordinating, @unchecked Sendable {
    func pair(
        host: HostAddress,
        pin: String,
        appVersion: String,
        onProgress: @escaping @Sendable (PairingProgress) -> Void
    ) async throws -> PairedHostIdentity {
        throw PairingError.cancelled
    }

    func cancel() {}
}

private final class FailingIdentityProvider: ClientIdentityProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var storedIdentityRequestCount = 0

    var identityRequestCount: Int { lock.withLock { storedIdentityRequestCount } }

    func identity() throws -> ClientIdentity {
        lock.withLock { storedIdentityRequestCount += 1 }
        throw PairingError.identityUnavailable("interaction denied")
    }
}

private final class LockedRecorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []
    var values: [Value] { lock.withLock { storage } }
    func append(_ value: Value) { lock.withLock { storage.append(value) } }
}

private final class FakeClientMicrophoneForwarder: ClientMicrophoneForwarding, @unchecked Sendable {
    let clientPort: UInt16
    private let lock = NSLock()
    private let teardown: LockedRecorder<String>?
    private var storedGenerations: [ClientMicrophoneGenerationDescriptor] = []
    private var storedFinishCount = 0
    private var storedWarningHandler: (@Sendable (String) -> Void)?

    init(clientPort: UInt16, teardown: LockedRecorder<String>? = nil) {
        self.clientPort = clientPort
        self.teardown = teardown
    }

    var generations: [ClientMicrophoneGenerationDescriptor] {
        lock.withLock { storedGenerations }
    }

    var finishCount: Int { lock.withLock { storedFinishCount } }

    func begin(
        generation: ClientMicrophoneGenerationDescriptor,
        warningHandler: @escaping @Sendable (String) -> Void
    ) throws {
        lock.withLock {
            storedGenerations.append(generation)
            storedWarningHandler = warningHandler
        }
    }

    func emitWarning(_ message: String) {
        lock.withLock { storedWarningHandler }?(message)
    }

    func finish() {
        lock.withLock { storedFinishCount += 1 }
        teardown?.append("microphone-end")
    }

    func invalidate() {}
}

private final class FakeClientMicrophonePreparer: ClientMicrophonePreparing, @unchecked Sendable {
    private let lock = NSLock()
    private let result: Result<FakeClientMicrophoneForwarder, Error>
    private var storedHosts: [String] = []

    init(result: Result<FakeClientMicrophoneForwarder, Error>) {
        self.result = result
    }

    var hosts: [String] { lock.withLock { storedHosts } }

    func prepare(host: String) async throws -> any ClientMicrophoneForwarding {
        lock.withLock { storedHosts.append(host) }
        return try result.get()
    }
}

private enum FakeStreamingSessionError: Error, Equatable {
    case featureFlagsUnavailable
    case statisticsUnavailable
    case inputUnavailable
}

private final class FakeStreamingEventEmitter: @unchecked Sendable {
    private let lock = NSLock()
    private let startEvents: [StreamingEvent]
    private var handler: (@Sendable (StreamingEvent) -> Void)?

    init(startEvents: [StreamingEvent]) {
        self.startEvents = startEvents
    }

    func install(_ handler: @escaping @Sendable (StreamingEvent) -> Void) {
        lock.withLock { self.handler = handler }
    }

    func emitStartEvents() {
        let installedHandler: (@Sendable (StreamingEvent) -> Void)? = lock.withLock { self.handler }
        for event in startEvents { installedHandler?(event) }
    }
}

private actor FakeStreamingSession: StreamingSessionControlling {
    nonisolated let startProbe = StreamingStartProbe()
    nonisolated let eventEmitter: FakeStreamingEventEmitter
    nonisolated let teardownRecorder: LockedRecorder<String>?
    nonisolated let inputSendError: FakeStreamingSessionError?
    nonisolated let inputCommands = LockedRecorder<StreamInputCommand>()
    nonisolated let teardownEventRecorder = LockedRecorder<String>()
    var commands: [StreamInputCommand] { inputCommands.values }
    private(set) var closeCount = 0
    private(set) var keyFrameRequestCount = 0
    var teardownEvents: [String] { teardownEventRecorder.values }
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var terminationContinuation: CheckedContinuation<Int32, Never>?
    private var terminationResult: Int32?
    private var closeBlocked = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var featureFlags: UInt32 = 0x03
    private var shouldFailFeatureFlags = false
    private var statisticsFailuresRemaining = 0
    private(set) var statisticsRequestCount = 0

    init(
        startEvents: [StreamingEvent] = [],
        teardownRecorder: LockedRecorder<String>? = nil,
        inputSendError: FakeStreamingSessionError? = nil
    ) {
        eventEmitter = FakeStreamingEventEmitter(startEvents: startEvents)
        self.teardownRecorder = teardownRecorder
        self.inputSendError = inputSendError
    }

    func start() async throws {
        eventEmitter.emitStartEvents()
        started = true
        startProbe.markStarted()
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
    }

    func waitUntilTerminated() async -> Int32 {
        if let terminationResult { return terminationResult }
        return await withCheckedContinuation { terminationContinuation = $0 }
    }

    func close() async {
        closeCount += 1
        if closeBlocked {
            await withCheckedContinuation { closeWaiters.append($0) }
        }
        teardownRecorder?.append("close")
        teardownEventRecorder.append("close")
        finish(with: 0)
    }

    func requestKeyFrame() async throws { keyFrameRequestCount += 1 }

    func hostFeatureFlags() async throws -> UInt32 {
        if shouldFailFeatureFlags { throw FakeStreamingSessionError.featureFlagsUnavailable }
        return featureFlags
    }

    func statistics() async throws -> StreamingStatistics {
        statisticsRequestCount += 1
        if statisticsFailuresRemaining > 0 {
            statisticsFailuresRemaining -= 1
            throw FakeStreamingSessionError.statisticsUnavailable
        }
        return StreamingStatistics(
            estimatedRTTMilliseconds: 12,
            estimatedRTTVarianceMilliseconds: 2,
            pendingVideoFrames: 1,
            pendingAudioFrames: 2,
            pendingAudioDurationMilliseconds: 10,
            audioPackets: 100,
            audioFECRecovered: 1,
            audioFECFailed: 0,
            videoPackets: 200,
            videoFECRecovered: 2,
            videoFECFailed: 0
        )
    }

    func setHostFeatureFlags(_ flags: UInt32) { featureFlags = flags }

    func setHostFeatureFlagsFailure(_ shouldFail: Bool) {
        shouldFailFeatureFlags = shouldFail
    }

    func setStatisticsFailuresRemaining(_ count: Int) {
        statisticsFailuresRemaining = max(0, count)
    }

    nonisolated func send(_ command: StreamInputCommand) throws {
        if let inputSendError { throw inputSendError }
        teardownEventRecorder.append("send")
        inputCommands.append(command)
    }

    func setCloseBlocked(_ blocked: Bool) {
        closeBlocked = blocked
    }

    func releaseClose() {
        closeBlocked = false
        closeWaiters.forEach { $0.resume() }
        closeWaiters.removeAll()
    }

    func waitUntilCloseIsBlocked() async {
        while closeWaiters.isEmpty { await Task.yield() }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func finishSuccessfully() {
        finish(with: 0)
    }

    func finish(with result: Int32) {
        terminationResult = result
        terminationContinuation?.resume(returning: result)
        terminationContinuation = nil
    }
}

private final class FakeStreamingSessionFactory: StreamingSessionCreating, @unchecked Sendable {
    private let lock = NSLock()
    private let session: FakeStreamingSession
    private var storedConfiguration: StreamingConfiguration?
    private var handler: (@Sendable (StreamingEvent) -> Void)?

    init(session: FakeStreamingSession) { self.session = session }

    var configuration: StreamingConfiguration? { lock.withLock { storedConfiguration } }

    func makeSession(
        configuration: StreamingConfiguration,
        media: StreamingMediaPipeline,
        events: @escaping @Sendable (StreamingEvent) -> Void
    ) throws -> any StreamingSessionControlling {
        lock.withLock {
            storedConfiguration = configuration
            handler = events
        }
        session.eventEmitter.install(events)
        return session
    }

    func emit(_ event: StreamingEvent) {
        lock.withLock { handler }?(event)
    }
}

private struct FakeMediaProvider: StreamingMediaProviding, Sendable {
    let videoFrameReadiness: VideoFrameReadiness
    let videoStatistics: MediaPipelineStatistics?

    init(
        videoFrameReadiness: VideoFrameReadiness = VideoFrameReadiness(),
        videoStatistics: MediaPipelineStatistics? = nil
    ) {
        self.videoFrameReadiness = videoFrameReadiness
        self.videoStatistics = videoStatistics
    }

    func makePipeline(for bootstrap: StreamBootstrap) throws -> StreamingMediaPipeline {
        StreamingMediaPipeline(
            videoDecoder: FakeStreamingVideoDecoder(),
            audioDecoder: FakeStreamingAudioDecoder(),
            availableVideoFormats: 0x0001,
            videoFrameReadiness: videoFrameReadiness,
            videoStatisticsProvider: { videoStatistics }
        )
    }
}

private final class RecordingMediaProvider: StreamingMediaProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let availableVideoFormats: Int32
    private var storedMakeCount = 0
    private var storedVideoCleanUpCount = 0
    private var storedAudioCleanUpCount = 0
    private var storedLastBootstrap: StreamBootstrap?

    var makeCount: Int { lock.withLock { storedMakeCount } }
    var videoCleanUpCount: Int { lock.withLock { storedVideoCleanUpCount } }
    var audioCleanUpCount: Int { lock.withLock { storedAudioCleanUpCount } }
    var lastBootstrap: StreamBootstrap? { lock.withLock { storedLastBootstrap } }

    init(availableVideoFormats: Int32 = GameStreamVideoFormat.h264.rawValue) {
        self.availableVideoFormats = availableVideoFormats
    }

    func makePipeline(for bootstrap: StreamBootstrap) throws -> StreamingMediaPipeline {
        lock.withLock {
            storedMakeCount += 1
            storedLastBootstrap = bootstrap
        }
        return StreamingMediaPipeline(
            videoDecoder: CleanupTrackingVideoDecoder { [weak self] in
                self?.recordVideoCleanUp()
            },
            audioDecoder: CleanupTrackingAudioDecoder { [weak self] in
                self?.recordAudioCleanUp()
            },
            availableVideoFormats: availableVideoFormats
        )
    }

    private func recordVideoCleanUp() {
        lock.withLock { storedVideoCleanUpCount += 1 }
    }

    private func recordAudioCleanUp() {
        lock.withLock { storedAudioCleanUpCount += 1 }
    }
}

private final class CleanupTrackingVideoDecoder: UmbraStreaming.VideoDecoding, @unchecked Sendable {
    private let onCleanUp: @Sendable () -> Void

    init(onCleanUp: @escaping @Sendable () -> Void) {
        self.onCleanUp = onCleanUp
    }

    func configure(format: UmbraStreaming.VideoStreamFormat) -> Bool { true }
    func start() {}
    func stop() {}
    func cleanUp() { onCleanUp() }
    func submit(frame: UmbraStreaming.CompressedVideoFrame) -> UmbraStreaming.VideoFrameDisposition { .accepted }
}

private final class AddressRecordingNativeVideoDecoder: UmbraMedia.VideoDecoding, @unchecked Sendable {
    private let lock = NSLock()
    private var storedFrame: UmbraMedia.CompressedVideoFrame?
    private var storedDataAddress: UInt?

    var dataAddress: UInt? { lock.withLock { storedDataAddress } }
    var dataCount: Int? { lock.withLock { storedFrame?.data.count } }
    var payloadFormat: UmbraMedia.EncodedVideoPayloadFormat? {
        lock.withLock { storedFrame?.payloadFormat }
    }

    func configure(format: UmbraMedia.VideoStreamFormat) -> Bool { true }
    func start() {}
    func stop() {}
    func cleanUp() {}

    func submit(frame: UmbraMedia.CompressedVideoFrame) -> UmbraMedia.VideoFrameDisposition {
        let address = frame.data.withUnsafeBytes { bytes in
            bytes.baseAddress.map(UInt.init(bitPattern:))
        }
        lock.withLock {
            storedFrame = frame
            storedDataAddress = address
        }
        return .accepted
    }
}

private final class CleanupTrackingAudioDecoder: UmbraStreaming.AudioDecoding, @unchecked Sendable {
    private let onCleanUp: @Sendable () -> Void

    init(onCleanUp: @escaping @Sendable () -> Void) {
        self.onCleanUp = onCleanUp
    }

    func configure(format: UmbraStreaming.OpusStreamFormat) -> Bool { true }
    func start() {}
    func stop() {}
    func cleanUp() { onCleanUp() }
    func submit(packet: UmbraStreaming.CompressedAudioPacket) {}
}

private final class FakeStreamingVideoDecoder: UmbraStreaming.VideoDecoding, @unchecked Sendable {
    func configure(format: UmbraStreaming.VideoStreamFormat) -> Bool { true }
    func start() {}
    func stop() {}
    func cleanUp() {}
    func submit(frame: UmbraStreaming.CompressedVideoFrame) -> UmbraStreaming.VideoFrameDisposition { .accepted }
}

private final class FakeStreamingAudioDecoder: UmbraStreaming.AudioDecoding, @unchecked Sendable {
    func configure(format: UmbraStreaming.OpusStreamFormat) -> Bool { true }
    func start() {}
    func stop() {}
    func cleanUp() {}
    func submit(packet: UmbraStreaming.CompressedAudioPacket) {}
}

private actor RecordingLifecycle: StreamSessionLifecycleCoordinating {
    private(set) var prepareCount = 0
    private(set) var presentationFinishCount = 0
    private(set) var finishCount = 0
    private(set) var lastBootstrap: StreamBootstrap?
    private let onPrepare: @Sendable () -> Void
    private let onPresentationFinish: @Sendable () -> Void
    private let onFinish: @Sendable () -> Void

    init(
        onPrepare: @escaping @Sendable () -> Void = {},
        onPresentationFinish: @escaping @Sendable () -> Void = {},
        onFinish: @escaping @Sendable () -> Void = {}
    ) {
        self.onPrepare = onPrepare
        self.onPresentationFinish = onPresentationFinish
        self.onFinish = onFinish
    }

    func prepare(for bootstrap: StreamBootstrap) async throws {
        prepareCount += 1
        lastBootstrap = bootstrap
        onPrepare()
    }
    func updatePreparation(for bootstrap: StreamBootstrap) async throws {
        lastBootstrap = bootstrap
    }
    func finishPresentation() async {
        presentationFinishCount += 1
        onPresentationFinish()
    }
    func finish() async {
        finishCount += 1
        onFinish()
    }
}

private actor SuspendedPreparationLifecycle: StreamSessionLifecycleCoordinating {
    private var preparationStarted = false
    private var preparationReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func prepare(for bootstrap: StreamBootstrap) async throws {
        preparationStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        if !preparationReleased {
            await withTaskCancellationHandler {
                await withCheckedContinuation { releaseWaiters.append($0) }
            } onCancel: {
                Task { await self.releasePreparation() }
            }
        }
        try Task.checkCancellation()
    }

    func finish() async {}

    func waitUntilPreparationStarted() async {
        if preparationStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releasePreparation() {
        preparationReleased = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private actor ManuallyReleasedPreparationLifecycle: StreamSessionLifecycleCoordinating {
    private var preparationStarted = false
    private var preparationReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func prepare(for bootstrap: StreamBootstrap) async throws {
        preparationStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        if !preparationReleased {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        try Task.checkCancellation()
    }

    func finish() async {}

    func waitUntilPreparationStarted() async {
        if preparationStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releasePreparation() {
        preparationReleased = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private struct FailingLifecycle: StreamSessionLifecycleCoordinating {
    func prepare(for bootstrap: StreamBootstrap) async throws {
        throw FakeStreamingSessionError.featureFlagsUnavailable
    }

    func finish() async {}
}

private final class RecordingOutput: StreamingEventOutputHandling, @unchecked Sendable {
    private let recorder = LockedRecorder<StreamingEvent>()
    private let videoStatisticsRecorder = LockedRecorder<MediaPipelineStatistics>()
    var values: [StreamingEvent] { recorder.values }
    var videoStatistics: [MediaPipelineStatistics] { videoStatisticsRecorder.values }
    func handle(_ event: StreamingEvent) { recorder.append(event) }
    func handleVideoStatistics(_ statistics: MediaPipelineStatistics) {
        videoStatisticsRecorder.append(statistics)
    }
}

private struct FixedDateProvider: IntegrationDateProviding, Sendable {
    let value: Date
    func now() -> Date { value }
}

private final class FakeUptimeProvider: IntegrationUptimeProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval]
    init(values: [TimeInterval]) { self.values = values }
    func uptime() -> TimeInterval {
        lock.withLock { values.isEmpty ? 0 : values.removeFirst() }
    }
}

private final class FakeVideoRenderer: UmbraMedia.MetalVideoRendering, @unchecked Sendable {
    func enqueue(_ frame: UmbraMedia.DecodedVideoFrame) {}
    func flush() {}
}

@MainActor
private final class FakeControllerOutputService: ControllerOutputServicing, ControllerFeedbackSessionControlling {
    private(set) var commands: [ControllerOutputCommand] = []
    private(set) var players: [UInt8] = []
    private(set) var feedbackSessionActive = false
    private(set) var feedbackLifecycleEvents: [String] = []

    func beginFeedbackSession() {
        feedbackSessionActive = true
        feedbackLifecycleEvents.append("begin")
    }

    func endFeedbackSession() {
        feedbackSessionActive = false
        feedbackLifecycleEvents.append("end")
    }

    func send(_ command: ControllerOutputCommand, toPlayer playerIndex: UInt8) -> ControllerOutputResult {
        guard feedbackSessionActive else { return .failed("feedback inactive") }
        commands.append(command)
        players.append(playerIndex)
        feedbackLifecycleEvents.append("send")
        return .applied
    }
}

@MainActor
private final class FakeMotionEnabler: ControllerMotionEnabling {
    private(set) var values: [Bool] = []
    func setMotionReportingEnabled(_ enabled: Bool) { values.append(enabled) }
}

@MainActor
private final class FakeKeepAwakeController: KeepAwakeControlling {
    private(set) var states: [Bool] = []
    func setActive(_ active: Bool, reason: String) { states.append(active) }
}

@MainActor
private final class FakeWindowController: StreamWindowModeControlling {
    private(set) var presentations: [WindowPresentation] = []
    func request(_ presentation: WindowPresentation) { presentations.append(presentation) }
}

private final class FakeAudioLifecycleController: StreamAudioLifecycleControlling, @unchecked Sendable {
    private(set) var activeStates: [Bool] = []
    private(set) var stopCount = 0
    func setApplicationActive(_ active: Bool) { activeStates.append(active) }
    func stop() -> PCMRendererTeardownStatus {
        stopCount += 1
        return .complete
    }
}

private final class WarmupTrackingPCMRenderer: PCMRendering, @unchecked Sendable {
    let configuration: PCMRendererConfiguration
    private let lock = NSLock()
    private var storedStartCount = 0
    private var storedStopCount = 0
    private var storedApplicationActiveStates: [Bool] = []

    init(configuration: PCMRendererConfiguration = PCMRendererConfiguration()) {
        self.configuration = configuration
    }

    var startCount: Int { lock.withLock { storedStartCount } }
    var stopCount: Int { lock.withLock { storedStopCount } }
    var applicationActiveStates: [Bool] { lock.withLock { storedApplicationActiveStates } }

    func start() throws {
        lock.withLock { storedStartCount += 1 }
    }

    func stop() -> PCMRendererTeardownStatus {
        lock.withLock { storedStopCount += 1 }
        return .complete
    }

    func enqueue(_ buffer: UmbraMedia.DecodedAudioBuffer) {}
    func flush() {}

    func setApplicationActive(_ active: Bool) {
        lock.withLock { storedApplicationActiveStates.append(active) }
    }
}

private final class ControllableTeardownPCMRenderer: PCMRendering, @unchecked Sendable {
    let configuration = PCMRendererConfiguration()
    private let lock = NSLock()
    private var teardownComplete: Bool
    private var storedStopCount = 0

    init(teardownComplete: Bool) {
        self.teardownComplete = teardownComplete
    }

    var stopCount: Int { lock.withLock { storedStopCount } }

    func setTeardownComplete(_ complete: Bool) {
        lock.withLock { teardownComplete = complete }
    }

    func start() throws {}

    func stop() -> PCMRendererTeardownStatus {
        lock.withLock {
            storedStopCount += 1
            return teardownComplete ? .complete : .retryRequired
        }
    }

    func enqueue(_ buffer: UmbraMedia.DecodedAudioBuffer) {}
    func flush() {}
    func setApplicationActive(_ active: Bool) {}
}

private final class BlockingFocusPCMRenderer: PCMRendering, @unchecked Sendable {
    let configuration = PCMRendererConfiguration()
    let firstFocusCallEntered = DispatchSemaphore(value: 0)
    private let firstFocusCallRelease = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var shouldBlockNextFocusCall = true
    private var storedActiveStates: [Bool] = []

    var activeStates: [Bool] { lock.withLock { storedActiveStates } }

    func releaseFirstFocusCall() {
        firstFocusCallRelease.signal()
    }

    func start() throws {}
    func stop() -> PCMRendererTeardownStatus { .complete }
    func enqueue(_ buffer: UmbraMedia.DecodedAudioBuffer) {}
    func flush() {}

    func setApplicationActive(_ active: Bool) {
        let shouldBlock = lock.withLock {
            defer { shouldBlockNextFocusCall = false }
            return shouldBlockNextFocusCall
        }
        if shouldBlock {
            firstFocusCallEntered.signal()
            firstFocusCallRelease.wait()
        }
        lock.withLock { storedActiveStates.append(active) }
    }
}

@MainActor
private final class FakePlatformLifecycleController: StreamPlatformLifecycleControlling {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
}

@MainActor
private final class FakeInputInstaller: PlatformInputSinkInstalling {
    private(set) var installations: [Bool] = []
    private(set) var nonNilInstalledAfterStart = false
    private let startProbe: StreamingStartProbe?

    init(startProbe: StreamingStartProbe? = nil) {
        self.startProbe = startProbe
    }

    func installInputSink(_ sink: (any PlatformInputPacketSink)?) {
        installations.append(sink != nil)
        if sink != nil { nonNilInstalledAfterStart = startProbe?.isStarted ?? true }
    }
}

@MainActor
private final class ReleaseOnUninstallInputInstaller: PlatformInputSinkInstalling {
    private var sink: (any PlatformInputPacketSink)?

    func installInputSink(_ sink: (any PlatformInputPacketSink)?) {
        if sink == nil {
            self.sink?.platformInputDidProduce(.keyboard(KeyboardPacket(
                virtualKey: 0x41,
                action: .up,
                modifiers: [],
                isExtended: false
            )))
        }
        self.sink = sink
    }
}

private final class StreamingStartProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false

    var isStarted: Bool { lock.withLock { started } }
    func markStarted() { lock.withLock { started = true } }
}

private extension StreamingPreferences {
    mutating func validateForTest() {
        XCTAssertNoThrow(try validate())
    }
}

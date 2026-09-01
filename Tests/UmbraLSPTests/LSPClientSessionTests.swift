import XCTest
import UmbraCore
import UmbraMedia
import UmbraNetworking
@testable import UmbraLSP
@testable import UmbraLSPTransport

final class LSPClientSessionTests: XCTestCase {
    func testPINPairingWireUsesExactFrozenMaps() throws {
        let clientID = UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!
        let sessionID = UUID(uuidString: "ffeeddcc-bbaa-9988-7766-554433221100")!
        let permissions: LSPPermission = [.browseApplications, .input, .controllerOutput]
        let begin = try LSPControlWire.pairBegin(
            clientID: clientID,
            clientIdentityKey: Data(repeating: 0x11, count: 32),
            clientName: "Umbra",
            clientPairingNonce: Data(repeating: 0x22, count: 16),
            scryptSalt: Data(repeating: 0x33, count: 16),
            clientPublicValue: Data([0x04]) + Data(repeating: 0x44, count: 64),
            requestedPermissions: permissions
        )
        let beginValues = try DeterministicCBOR.exactMap(DeterministicCBOR.decode(begin), count: 9)
        XCTAssertEqual(beginValues[0], .unsigned(1))
        XCTAssertEqual(beginValues[1], .unsigned(1))
        XCTAssertEqual(beginValues[2], .bytes(LSPControlWire.uuidBytes(clientID)))
        XCTAssertEqual(beginValues[4], .text("Umbra"))
        XCTAssertEqual(beginValues[8], .unsigned(UInt64(permissions.rawValue)))

        let pollValues = try DeterministicCBOR.exactMap(
            DeterministicCBOR.decode(try LSPControlWire.pairPoll(sessionID: sessionID)),
            count: 3
        )
        XCTAssertEqual(pollValues, [
            .unsigned(1),
            .unsigned(1),
            .bytes(LSPControlWire.uuidBytes(sessionID)),
        ])

        let finishValues = try DeterministicCBOR.exactMap(
            DeterministicCBOR.decode(try LSPControlWire.pairFinish(
                sessionID: sessionID,
                approvalGeneration: 7,
                clientConfirmation: Data(repeating: 0x55, count: 32),
                clientSignature: Data(repeating: 0x66, count: 64)
            )),
            count: 6
        )
        XCTAssertEqual(finishValues[3], .unsigned(7))
        XCTAssertEqual(finishValues[4], .bytes(Data(repeating: 0x55, count: 32)))
        XCTAssertEqual(finishValues[5], .bytes(Data(repeating: 0x66, count: 64)))

        let errorPayload = try DeterministicCBOR.encode(.map([
            .init(key: 1, value: .unsigned(1)),
            .init(key: 2, value: .unsigned(UInt64(LSPControlStatus.busy.rawValue))),
        ]))
        let errorEvent = LSPControlEvent(
            messageType: LSPControlMessageType.pairPending.rawValue,
            flags: [.response, .errorResponse],
            connectionGeneration: 1,
            messageID: 1,
            requestID: 1,
            payload: errorPayload
        )
        XCTAssertEqual(
            try LSPControlWire.controlError(from: errorEvent, expectedType: .pairPending),
            .busy
        )
        XCTAssertThrowsError(try LSPControlWire.controlError(from: errorEvent, expectedType: .pairResult))
    }

    func testPINPairingDiscoveryRequiresExactLowercaseIdentityAndSPKI() throws {
        let hostID = "00112233445566778899aabbccddeeff"
        let spki = String(repeating: "ab", count: 32)
        let valid = DiscoveredHostService(
            name: "Gaming PC",
            type: "_lumen-stream._udp",
            domain: "local.",
            txtRecord: [
                "v": "1",
                "pair": "pin1",
                "id": hostID,
                "spki": spki,
                "caps": "input,video",
                "port": "1",
            ]
        )
        let resolved = ResolvedBonjourServiceEndpoint(
            targetHost: "actual-srv-target.local",
            port: 49_999,
            serviceName: valid.name,
            serviceType: valid.type,
            domain: valid.domain,
            changeToken: valid.changeToken
        )
        let candidate = try XCTUnwrap(LSPDiscovery.pairingHost(
            from: valid,
            resolvedEndpoint: resolved
        ))
        XCTAssertEqual(candidate.host, "actual-srv-target.local")
        XCTAssertEqual(candidate.port, 49_999)
        XCTAssertEqual(candidate.serverSPKISHA256, Data(repeating: 0xab, count: 32))
        XCTAssertEqual(
            candidate.provisionalSPKIFingerprint,
            String(repeating: "ABABABAB ", count: 7) + "ABABABAB"
        )

        var uppercase = valid
        uppercase.txtRecord["spki"] = spki.uppercased()
        XCTAssertNil(LSPDiscovery.pairingHost(from: uppercase, resolvedEndpoint: resolved))
        var invitationMode = valid
        invitationMode.txtRecord["pair"] = "invite1"
        XCTAssertNil(LSPDiscovery.pairingHost(from: invitationMode, resolvedEndpoint: resolved))
        var missingVersion = valid
        missingVersion.txtRecord.removeValue(forKey: "v")
        XCTAssertNil(LSPDiscovery.pairingHost(from: missingVersion, resolvedEndpoint: resolved))
        var staleResolution = resolved
        staleResolution.changeToken = 999
        XCTAssertNil(LSPDiscovery.pairingHost(from: valid, resolvedEndpoint: staleResolution))
    }

    func testTerminationObserverLatchesFirstEventAndDeliversItToLateHandlers() {
        let observer = LSPTerminationObserver()
        XCTAssertTrue(observer.emit(.streamEnded(reason: 7)))
        XCTAssertFalse(observer.emit(.failed(.internalFailure)))

        let received = LSPTestLockedBox<LSPClientSessionTermination?>(nil)
        observer.set { event in received.value = event }
        XCTAssertEqual(received.value, .streamEnded(reason: 7))
        XCTAssertTrue(observer.hasTerminalEvent)
    }

    func testHardwareOffersExposeOnlyProvenHDRAndYUV444Tuples() {
        let capabilities = AppleStreamingCapabilities(
            hasMetalDevice: true,
            supportsHardwareH264: true,
            supportsHardwareHEVC: true,
            supportsHardwareAV1: true,
            hasDefaultAudioOutput: true,
            supportsNativeAudioOutput: true,
            audioOutputChannelCount: 2,
            supportsHardwareHEVCMain10: true,
            supportsHardwareAV1Main10: true,
            supportedHardwareYUV444FormatMask: MoonlightVideoFormat.hevcRext10YUV444.rawValue
        )
        let offers = LSPVideoOffer.hardwareOffers(
            capabilities: capabilities,
            width: 3_840,
            height: 2_160,
            refreshNumerator: 120,
            refreshDenominator: 1,
            preferredBitsPerSecond: 80_000_000,
            maximumBitsPerSecond: 100_000_000,
            codecPreference: .automatic,
            enableHDR: true,
            hdrTransferPreference: .automatic,
            enableYUV444: true
        )

        XCTAssertEqual(offers.count, 2)
        XCTAssertTrue(offers.allSatisfy { $0.codec == .hevc })
        XCTAssertTrue(offers.allSatisfy { $0.profile == .hevcRangeExtensions })
        XCTAssertTrue(offers.allSatisfy { $0.pixelFormat == .yuv44410Bit })
        XCTAssertEqual(Set(offers.map(\.color.transferCharacteristics)), Set([16, 18]))
    }

    func testSessionStartsIdleWithStableInjectedIdentity() async throws {
        let identity = LSPClientIdentity.generate()
        let session = try LSPClientSession(identity: identity)
        let state = await session.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(try identity.publicKeyRawRepresentation.count, 32)
    }

    func testStartEncodesOrderedAdaptiveAudioOffersAndMaximumPayload() throws {
        let request = LSPInputStartRequest(
            applicationID: "desktop",
            audioOffers: LSPAudioOffer.adaptiveDefaults,
            offeredMaximumUDPPayload: 1_472,
            videoOffers: [Self.h264Offer]
        )
        let values = try DeterministicCBOR.exactMap(
            DeterministicCBOR.decode(try LSPControlWire.start(request)),
            count: 16
        )
        guard case .array(let offers) = values[7] else {
            return XCTFail("START audio offers must be an array")
        }
        let first = try DeterministicCBOR.exactMap(offers[0], count: 5)
        XCTAssertEqual(first[0], .unsigned(2))
        XCTAssertEqual(first[1], .unsigned(480))
        XCTAssertEqual(values[8], .unsigned(1_472))
        XCTAssertEqual(values[9], .null)
        XCTAssertEqual(values[10], .unsigned(0))
        let videoOffers = try XCTUnwrap({ if case .array(let value) = values[11] { value } else { nil } }())
        let video = try DeterministicCBOR.exactMap(videoOffers[0], count: 18)
        XCTAssertEqual(video[0], .unsigned(3))
        XCTAssertEqual(video[1], .unsigned(1))
        XCTAssertEqual(video[9], .unsigned(1))
        XCTAssertEqual(video[15], .boolean(true))
        XCTAssertEqual(video[16], .boolean(true))
        XCTAssertEqual(values[15], .unsigned(50_000))

        var excessiveBudget = request
        excessiveBudget.maximumCaptureToPresentMicroseconds = 1_000_001
        XCTAssertThrowsError(try LSPControlWire.start(excessiveBudget))
        var undersizedBitrate = Self.h264Offer
        undersizedBitrate.preferredBitsPerSecond = 999
        undersizedBitrate.maximumBitsPerSecond = 999
        excessiveBudget.maximumCaptureToPresentMicroseconds = 50_000
        excessiveBudget.videoOffers = [undersizedBitrate]
        XCTAssertThrowsError(try LSPControlWire.start(excessiveBudget))
    }

    func testStartEncodesExactRequiredMicrophoneOffer() throws {
        let request = LSPInputStartRequest(
            applicationID: "desktop",
            audioOffers: LSPAudioOffer.adaptiveDefaults,
            microphoneOffer: LSPMicrophoneOffer(
                maximumBitrate: 64_000,
                inbandFEC: true,
                dtx: true,
                required: true
            ),
            videoOffers: [Self.h264Offer]
        )
        let values = try DeterministicCBOR.exactMap(
            DeterministicCBOR.decode(try LSPControlWire.start(request)),
            count: 16
        )
        let microphone = try DeterministicCBOR.exactMap(values[9], count: 6)
        XCTAssertEqual(microphone[0], .unsigned(1))
        XCTAssertEqual(microphone[1], .unsigned(960))
        XCTAssertEqual(microphone[2], .unsigned(64_000))
        XCTAssertEqual(microphone[5], .boolean(true))
    }

    private static let h264Offer = LSPVideoOffer(
        codec: .h264,
        profile: .h264High,
        width: 1_920,
        height: 1_080,
        refreshNumerator: 60,
        refreshDenominator: 1,
        preferredBitsPerSecond: 20_000_000,
        maximumBitsPerSecond: 20_000_000
    )

    func testAV1PQVideoConfigCarriesCanonicalOBUAndHDRMetadata() throws {
        let sessionID = UUID()
        let selection = Self.videoSelection(
            codec: 3,
            profile: 6,
            pixelFormat: 2,
            primaries: 9,
            transfer: 16,
            matrix: 9
        )
        let hdr = DeterministicCBORValue.map([
            34_000, 16_000, 13_250, 34_500, 7_500, 3_000, 15_635, 16_450,
            1_000, 50, 1_000, 400, 1_000,
        ].enumerated().map { .init(key: UInt64($0.offset + 1), value: .unsigned(UInt64($0.element))) })
        let payload = try DeterministicCBOR.encode(.map([
            .init(key: 1, value: .unsigned(3)),
            .init(key: 2, value: .bytes(LSPControlWire.uuidBytes(sessionID))),
            .init(key: 3, value: .unsigned(7)),
            .init(key: 4, value: selection),
            .init(key: 5, value: .map([
                .init(key: 1, value: .unsigned(3)),
                .init(key: 2, value: .array([.bytes(Data([0x0a, 0x01, 0x00]))])),
            ])),
            .init(key: 6, value: .unsigned(100)),
            .init(key: 7, value: .unsigned(1)),
            .init(key: 8, value: hdr),
        ]))

        let request = try LSPControlWire.videoConfig(from: .init(
            messageType: LSPControlMessageType.videoConfig.rawValue,
            flags: [.acknowledgementRequired],
            connectionGeneration: 1,
            messageID: 1,
            requestID: 2,
            payload: payload
        ))

        XCTAssertEqual(request.codecConfiguration.codec, .av1)
        XCTAssertEqual(request.nativeConfiguration.payloadFormat, LSPVideoPayloadFormat.av1LowOverheadOBU.rawValue)
        XCTAssertEqual(request.nativeConfiguration.transferCharacteristics, 16)
        XCTAssertEqual(request.hdrMetadata?.maximumDisplayLuminance, 1_000)

        var missingHDR = try DeterministicCBOR.exactMap(DeterministicCBOR.decode(payload), count: 8)
        missingHDR[7] = .null
        let missingHDRPayload = try DeterministicCBOR.encode(.map(missingHDR.enumerated().map {
            .init(key: UInt64($0.offset + 1), value: $0.element)
        }))
        XCTAssertThrowsError(try LSPControlWire.videoConfig(from: .init(
            messageType: LSPControlMessageType.videoConfig.rawValue,
            flags: [.acknowledgementRequired],
            connectionGeneration: 1,
            messageID: 1,
            requestID: 2,
            payload: missingHDRPayload
        )))
    }

    func testVideoConfigV3ParsesExactRepairAndCodecMapsAndEncodesExactFiveKeyAck() throws {
        let sessionID = UUID()
        let selection = DeterministicCBORValue.map((1...30).map { key in
            let value: DeterministicCBORValue = switch key {
            case 1: .unsigned(3)
            case 2: .unsigned(9)
            case 3: .unsigned(10)
            case 4: .unsigned(110)
            case 5: .unsigned(90_000)
            case 6, 7, 13, 14, 15, 16, 20, 21, 22: .unsigned(1)
            case 8: .unsigned(1_920)
            case 9: .unsigned(1_080)
            case 10: .unsigned(60)
            case 11: .unsigned(1)
            case 12: .unsigned(20_000_000)
            case 17: .boolean(false)
            case 18: .unsigned(1_200)
            case 19: .unsigned(3)
            case 23: .unsigned(2)
            case 24: .unsigned(3)
            case 25: .unsigned(4)
            case 26: .unsigned(5)
            case 27: .map([
                .init(key: 1, value: .unsigned(20)),
                .init(key: 2, value: .unsigned(111)),
                .init(key: 3, value: .unsigned(5_000)),
                .init(key: 4, value: .unsigned(15)),
            ])
            case 28: .map([
                .init(key: 1, value: .unsigned(30)),
                .init(key: 2, value: .unsigned(112)),
                .init(key: 3, value: .unsigned(110)),
            ])
            case 29: .unsigned(33_333)
            case 30: .unsigned(1_000_000)
            default: .unsigned(1)
            }
            return .init(key: UInt64(key), value: value)
        })
        let payload = try DeterministicCBOR.encode(.map([
            .init(key: 1, value: .unsigned(3)),
            .init(key: 2, value: .bytes(LSPControlWire.uuidBytes(sessionID))),
            .init(key: 3, value: .unsigned(7)),
            .init(key: 4, value: selection),
            .init(key: 5, value: .map([
                .init(key: 1, value: .unsigned(1)),
                .init(key: 2, value: .array([.bytes(Data([0x67])), .bytes(Data([0x68]))])),
            ])),
            .init(key: 6, value: .unsigned(100)),
            .init(key: 7, value: .unsigned(1)),
            .init(key: 8, value: .null),
        ]))
        let request = try LSPControlWire.videoConfig(from: LSPControlEvent(
            messageType: LSPControlMessageType.videoConfig.rawValue,
            flags: [.acknowledgementRequired],
            connectionGeneration: 1,
            messageID: 1,
            requestID: 2,
            payload: payload
        ))
        XCTAssertEqual(request.nativeConfiguration.maximumFrameAgeMicroseconds, 33_333)
        XCTAssertEqual(request.nativeConfiguration.maximumAccessUnitBytes, 1_000_000)
        XCTAssertEqual(request.nativeConfiguration.recoveryEpoch, 1)
        XCTAssertEqual(request.nativeConfiguration.flexFECMaximumGroupPackets, 15)
        XCTAssertEqual(request.nativeConfiguration.rtxAssociatedPayloadType, 110)
        XCTAssertEqual(request.codecConfiguration.codec, .h264)
        let ack = try DeterministicCBOR.exactMap(
            DeterministicCBOR.decode(try LSPControlWire.videoConfigAck(
                status: .success,
                sessionID: sessionID,
                videoGeneration: 9,
                decoderCredit: 3
            )),
            count: 5
        )
        XCTAssertEqual(ack[0], .unsigned(3))
        XCTAssertEqual(ack[4], .unsigned(3))

        for invalidVersion in [UInt64(1), 2, 4] {
            var invalidValues = try DeterministicCBOR.exactMap(DeterministicCBOR.decode(payload), count: 8)
            invalidValues[0] = .unsigned(invalidVersion)
            let invalidPayload = try DeterministicCBOR.encode(.map(invalidValues.enumerated().map {
                .init(key: UInt64($0.offset + 1), value: $0.element)
            }))
            XCTAssertThrowsError(try LSPControlWire.videoConfig(from: LSPControlEvent(
                messageType: LSPControlMessageType.videoConfig.rawValue,
                flags: [.acknowledgementRequired],
                connectionGeneration: 1,
                messageID: 1,
                requestID: 2,
                payload: invalidPayload
            )))
        }

        var invalidSelection = try DeterministicCBOR.exactMap(selection, count: 30)
        invalidSelection[23] = .unsigned(6)
        var invalidExtensionValues = try DeterministicCBOR.exactMap(DeterministicCBOR.decode(payload), count: 8)
        invalidExtensionValues[3] = .map(invalidSelection.enumerated().map {
            .init(key: UInt64($0.offset + 1), value: $0.element)
        })
        let invalidExtensionPayload = try DeterministicCBOR.encode(.map(invalidExtensionValues.enumerated().map {
            .init(key: UInt64($0.offset + 1), value: $0.element)
        }))
        XCTAssertThrowsError(try LSPControlWire.videoConfig(from: LSPControlEvent(
            messageType: LSPControlMessageType.videoConfig.rawValue,
            flags: [.acknowledgementRequired],
            connectionGeneration: 1,
            messageID: 1,
            requestID: 2,
            payload: invalidExtensionPayload
        )))

        var excessiveAgeSelection = try DeterministicCBOR.exactMap(selection, count: 30)
        excessiveAgeSelection[28] = .unsigned(1_000_001)
        var excessiveAgeConfig = try DeterministicCBOR.exactMap(DeterministicCBOR.decode(payload), count: 8)
        excessiveAgeConfig[3] = .map(excessiveAgeSelection.enumerated().map {
            .init(key: UInt64($0.offset + 1), value: $0.element)
        })
        XCTAssertThrowsError(try LSPControlWire.videoConfig(from: .init(
            messageType: LSPControlMessageType.videoConfig.rawValue,
            flags: [.acknowledgementRequired],
            connectionGeneration: 1,
            messageID: 1,
            requestID: 2,
            payload: try DeterministicCBOR.encode(.map(excessiveAgeConfig.enumerated().map {
                .init(key: UInt64($0.offset + 1), value: $0.element)
            }))
        )))
    }

    func testPathProbeIntentAndAcknowledgementUseExactThreeKeySchemas() throws {
        let payload = try LSPControlWire.pathProbe(probeID: 77, udpPayloadSize: 1_400)
        let intent = try LSPControlWire.pathProbe(from: LSPControlEvent(
            messageType: LSPControlMessageType.pathProbe.rawValue,
            flags: [.acknowledgementRequired],
            connectionGeneration: 1,
            messageID: 9,
            requestID: 10,
            payload: payload
        ))
        XCTAssertEqual(intent, .init(probeID: 77, udpPayloadSize: 1_400))

        let acknowledgement = try LSPControlWire.pathProbeAck(from: LSPControlEvent(
            messageType: LSPControlMessageType.pathProbeAck.rawValue,
            flags: [.response],
            connectionGeneration: 1,
            messageID: 10,
            requestID: 10,
            payload: try LSPControlWire.pathProbeAck(probeID: 77, receivedSize: 1_400)
        ))
        XCTAssertEqual(acknowledgement, intent)
        XCTAssertThrowsError(try LSPControlWire.pathProbe(probeID: 0, udpPayloadSize: 1_400))
    }

    func testStreamEndedRequiresExactAuthenticatedSessionEvent() throws {
        let sessionID = UUID()
        let payload = try DeterministicCBOR.encode(.map([
            .init(key: 1, value: .unsigned(1)),
            .init(key: 2, value: .bytes(LSPControlWire.uuidBytes(sessionID))),
            .init(key: 3, value: .unsigned(2)),
        ]))
        let event = LSPControlEvent(
            messageType: LSPControlMessageType.streamEnded.rawValue,
            flags: [],
            connectionGeneration: 1,
            messageID: 9,
            requestID: 0,
            payload: payload
        )
        XCTAssertEqual(try LSPControlWire.streamEnded(from: event), .init(sessionID: sessionID, reason: 2))
        var invalid = event
        invalid.requestID = 1
        XCTAssertThrowsError(try LSPControlWire.streamEnded(from: invalid))
    }

    func testAttachUsesClientSelectedSuccessorTokenInExactFiveKeyMap() throws {
        let current = Data(repeating: 0x11, count: 32)
        let successor = Data(repeating: 0x22, count: 32)
        let encoded = try LSPControlWire.attach(.init(
            sessionID: UUID(),
            attachToken: current,
            intentID: UUID(),
            successorAttachToken: successor
        ))
        let values = try DeterministicCBOR.exactMap(DeterministicCBOR.decode(encoded), count: 5)
        XCTAssertEqual(values[0], .unsigned(1))
        XCTAssertEqual(values[2], .bytes(current))
        XCTAssertEqual(values[4], .bytes(successor))
        XCTAssertThrowsError(try LSPControlWire.attach(.init(
            sessionID: UUID(),
            attachToken: current,
            intentID: UUID(),
            successorAttachToken: current
        )))
    }

    private static func videoSelection(
        codec: UInt64,
        profile: UInt64,
        pixelFormat: UInt64,
        primaries: UInt64,
        transfer: UInt64,
        matrix: UInt64
    ) -> DeterministicCBORValue {
        .map((1...30).map { key in
            let value: DeterministicCBORValue = switch key {
            case 1: .unsigned(3)
            case 2: .unsigned(9)
            case 3: .unsigned(10)
            case 4: .unsigned(110)
            case 5: .unsigned(90_000)
            case 6: .unsigned(codec)
            case 7: .unsigned(profile)
            case 8: .unsigned(1_920)
            case 9: .unsigned(1_080)
            case 10: .unsigned(60)
            case 11: .unsigned(1)
            case 12: .unsigned(20_000_000)
            case 13: .unsigned(pixelFormat)
            case 14: .unsigned(primaries)
            case 15: .unsigned(transfer)
            case 16: .unsigned(matrix)
            case 17: .boolean(false)
            case 18: .unsigned(1_200)
            case 19: .unsigned(3)
            case 20, 21, 22: .unsigned(1)
            case 23: .unsigned(2)
            case 24: .unsigned(3)
            case 25: .unsigned(4)
            case 26: .unsigned(5)
            case 27, 28: .null
            case 29: .unsigned(33_333)
            case 30: .unsigned(1_000_000)
            default: .unsigned(1)
            }
            return .init(key: UInt64(key), value: value)
        })
    }
}

private final class LSPTestLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

import Foundation
import UmbraCore
import UmbraMedia
import UmbraServices
import XCTest
@testable import UmbraIntegration

final class VideoFormatNegotiatorTests: XCTestCase {
    private let negotiator = VideoFormatNegotiator()

    func testSunshineSCMMapsExplicitlyToEveryMoonlightClientFormat() {
        XCTAssertEqual(
            VideoFormatNegotiator.clientFormatMask(for: .allKnown),
            MoonlightVideoFormat.knownMask
        )
        XCTAssertNotEqual(
            Int32(bitPattern: HostCodecSupport.hevcRext8YUV444.rawValue),
            MoonlightVideoFormat.hevcRext8YUV444.rawValue
        )
    }

    func testMaxLumaCapabilityCanProveBaseHEVCWithoutSCMBit() throws {
        let selection = try negotiator.select(
            availableVideoFormats: MoonlightVideoFormat.hevc.rawValue,
            host: host(support: [], maxLumaPixelsHEVC: 8_294_400),
            application: application,
            preferences: .default
        )

        XCTAssertEqual(selection.selectedVideoFormat, MoonlightVideoFormat.hevc.rawValue)
    }

    func testAutomaticSDRUsesPinnedHEVCThenH264ThenAV1Priority() throws {
        let allBase = MoonlightVideoFormat.h264.rawValue
            | MoonlightVideoFormat.hevc.rawValue
            | MoonlightVideoFormat.av1Main8.rawValue
        let selection = try negotiator.select(
            availableVideoFormats: allBase,
            host: host(support: [.h264, .hevc, .av1Main8]),
            application: application,
            preferences: .default
        )

        XCTAssertEqual(selection.selectedVideoFormat, MoonlightVideoFormat.hevc.rawValue)
        XCTAssertFalse(selection.isHDR)

        let h264 = try negotiator.select(
            availableVideoFormats: allBase,
            host: host(support: [.h264, .av1Main8]),
            application: application,
            preferences: .default
        )
        let av1 = try negotiator.select(
            availableVideoFormats: allBase,
            host: host(support: [.av1Main8]),
            application: application,
            preferences: .default
        )
        XCTAssertEqual(h264.selectedVideoFormat, MoonlightVideoFormat.h264.rawValue)
        XCTAssertEqual(av1.selectedVideoFormat, MoonlightVideoFormat.av1Main8.rawValue)
    }

    func testAutomaticSoftwareUsesPinnedH264ThenHEVCPriority() throws {
        var preferences = StreamingPreferences.default
        preferences.videoDecoderPreference = .software
        let selection = try negotiator.select(
            availableVideoFormats: MoonlightVideoFormat.h264.rawValue
                | MoonlightVideoFormat.hevc.rawValue,
            host: host(support: [.h264, .hevc]),
            application: application,
            preferences: preferences
        )

        XCTAssertEqual(selection.selectedVideoFormat, MoonlightVideoFormat.h264.rawValue)

        let hevc = try negotiator.select(
            availableVideoFormats: MoonlightVideoFormat.hevc.rawValue,
            host: host(support: [.hevc]),
            application: application,
            preferences: preferences
        )
        XCTAssertEqual(hevc.selectedVideoFormat, MoonlightVideoFormat.hevc.rawValue)
    }

    func testAutomaticHDRPrefersHEVCMain10ThenAV1Main10() throws {
        var preferences = StreamingPreferences.default
        preferences.enableHDR = true
        let available = MoonlightVideoFormat.hevcMain10.rawValue
            | MoonlightVideoFormat.av1Main10.rawValue

        let hevc = try negotiator.select(
            availableVideoFormats: available,
            host: host(support: [.hevcMain10, .av1Main10]),
            application: application,
            preferences: preferences
        )
        let av1 = try negotiator.select(
            availableVideoFormats: available,
            host: host(support: [.av1Main10]),
            application: application,
            preferences: preferences
        )

        XCTAssertEqual(hevc.selectedVideoFormat, MoonlightVideoFormat.hevcMain10.rawValue)
        XCTAssertTrue(hevc.isHDR)
        XCTAssertEqual(av1.selectedVideoFormat, MoonlightVideoFormat.av1Main10.rawValue)
        XCTAssertTrue(av1.isHDR)
    }

    func testHDRTransferPreferenceDoesNotChangeLegacyMoonlightNegotiation() throws {
        var preferences = StreamingPreferences.default
        preferences.enableHDR = true
        let available = MoonlightVideoFormat.hevcMain10.rawValue
            | MoonlightVideoFormat.av1Main10.rawValue
        let streamHost = host(support: [.hevcMain10, .av1Main10])

        preferences.hdrTransferPreference = .automatic
        let automatic = try negotiator.select(
            availableVideoFormats: available,
            host: streamHost,
            application: application,
            preferences: preferences
        )
        preferences.hdrTransferPreference = .pq
        let pq = try negotiator.select(
            availableVideoFormats: available,
            host: streamHost,
            application: application,
            preferences: preferences
        )
        preferences.hdrTransferPreference = .hlg
        let hlg = try negotiator.select(
            availableVideoFormats: available,
            host: streamHost,
            application: application,
            preferences: preferences
        )

        XCTAssertEqual(pq, automatic)
        XCTAssertEqual(hlg, automatic)
    }

    func testAutomaticHDRUsesAV1Main10BeforeEightBitHEVCFallback() throws {
        var preferences = StreamingPreferences.default
        preferences.enableHDR = true
        let selection = try negotiator.select(
            availableVideoFormats: MoonlightVideoFormat.hevc.rawValue
                | MoonlightVideoFormat.av1Main10.rawValue,
            host: host(support: [.hevc, .av1Main10]),
            application: application,
            preferences: preferences
        )

        XCTAssertEqual(selection.selectedVideoFormat, MoonlightVideoFormat.av1Main10.rawValue)
        XCTAssertTrue(selection.isHDR)
    }

    func testHDRIsNotBlockedByLegacyApplicationCertificationFlag() throws {
        var preferences = StreamingPreferences.default
        preferences.enableHDR = true
        let uncertifiedDesktop = StreamApplication(
            id: 1,
            name: "Desktop",
            hdrSupported: false
        )

        let selection = try negotiator.select(
            availableVideoFormats: MoonlightVideoFormat.hevcMain10.rawValue,
            host: host(support: [.hevcMain10]),
            application: uncertifiedDesktop,
            preferences: preferences
        )

        XCTAssertEqual(selection.selectedVideoFormat, MoonlightVideoFormat.hevcMain10.rawValue)
        XCTAssertTrue(selection.isHDR)
    }

    func testHDRFallsBackToAvailableEightBitFormatAndReportsSDR() throws {
        var preferences = StreamingPreferences.default
        preferences.enableHDR = true
        let selection = try negotiator.select(
            availableVideoFormats: MoonlightVideoFormat.hevc.rawValue,
            host: host(support: [.hevc]),
            application: application,
            preferences: preferences
        )

        XCTAssertEqual(selection.selectedVideoFormat, MoonlightVideoFormat.hevc.rawValue)
        XCTAssertFalse(selection.isHDR)
    }

    func testForcedHEVCFallsBackToH264AndStillRejectsNoCommonFormat() throws {
        var preferences = StreamingPreferences.default
        preferences.videoCodecPreference = .hevc

        let fallback = try negotiator.select(
            availableVideoFormats: MoonlightVideoFormat.h264.rawValue,
            host: host(support: [.h264]),
            application: application,
            preferences: preferences
        )
        XCTAssertEqual(fallback.selectedVideoFormat, MoonlightVideoFormat.h264.rawValue)

        XCTAssertThrowsError(try negotiator.select(
            availableVideoFormats: MoonlightVideoFormat.av1Main8.rawValue,
            host: host(support: [.av1Main8]),
            application: application,
            preferences: preferences
        )) { error in
            XCTAssertEqual(error as? UmbraIntegrationError, .unsupportedVideoConfiguration(.hevc))
        }
    }

    func testForcedAV1FallsBackToHEVCThenH264AndRejectsNoCommonFormat() throws {
        var preferences = StreamingPreferences.default
        preferences.videoCodecPreference = .av1
        let available = MoonlightVideoFormat.h264.rawValue | MoonlightVideoFormat.hevc.rawValue

        let hevc = try negotiator.select(
            availableVideoFormats: available,
            host: host(support: [.h264, .hevc]),
            application: application,
            preferences: preferences
        )
        XCTAssertEqual(hevc.selectedVideoFormat, MoonlightVideoFormat.hevc.rawValue)

        let h264 = try negotiator.select(
            availableVideoFormats: MoonlightVideoFormat.h264.rawValue,
            host: host(support: [.h264]),
            application: application,
            preferences: preferences
        )
        XCTAssertEqual(h264.selectedVideoFormat, MoonlightVideoFormat.h264.rawValue)

        XCTAssertThrowsError(try negotiator.select(
            availableVideoFormats: 0x0020,
            host: host(support: [.h264]),
            application: application,
            preferences: preferences
        )) { error in
            XCTAssertEqual(error as? UmbraIntegrationError, .unsupportedVideoConfiguration(.av1))
        }
    }

    func testYUV444RequiresExplicitProofAndRetainsYUV420Fallback() throws {
        var preferences = StreamingPreferences.default
        preferences.enableYUV444 = true
        let available = MoonlightVideoFormat.hevc.rawValue
            | MoonlightVideoFormat.hevcRext8YUV444.rawValue
        let provenHost = host(support: [.hevc, .hevcRext8YUV444])

        let proven = try negotiator.select(
            availableVideoFormats: available,
            host: provenHost,
            application: application,
            preferences: preferences
        )
        let fallback = try negotiator.select(
            availableVideoFormats: MoonlightVideoFormat.hevc.rawValue,
            host: provenHost,
            application: application,
            preferences: preferences
        )

        XCTAssertEqual(proven.selectedVideoFormat, MoonlightVideoFormat.hevcRext8YUV444.rawValue)
        XCTAssertTrue(proven.isYUV444)
        XCTAssertEqual(fallback.selectedVideoFormat, MoonlightVideoFormat.hevc.rawValue)
        XCTAssertFalse(fallback.isYUV444)
    }

    func testYUV444PreferenceCanOutrankCodecFamilyButNotHDRDepth() throws {
        var preferences = StreamingPreferences.default
        preferences.enableYUV444 = true
        let yuvSelection = try negotiator.select(
            availableVideoFormats: MoonlightVideoFormat.hevc.rawValue
                | MoonlightVideoFormat.av1High8YUV444.rawValue,
            host: host(support: [.hevc, .av1High8YUV444]),
            application: application,
            preferences: preferences
        )
        XCTAssertEqual(
            yuvSelection.selectedVideoFormat,
            MoonlightVideoFormat.av1High8YUV444.rawValue
        )

        preferences.enableHDR = true
        let hdrSelection = try negotiator.select(
            availableVideoFormats: MoonlightVideoFormat.hevcRext8YUV444.rawValue
                | MoonlightVideoFormat.av1Main10.rawValue,
            host: host(support: [.hevcRext8YUV444, .av1Main10]),
            application: application,
            preferences: preferences
        )
        XCTAssertEqual(hdrSelection.selectedVideoFormat, MoonlightVideoFormat.av1Main10.rawValue)
        XCTAssertTrue(hdrSelection.isHDR)
        XCTAssertFalse(hdrSelection.isYUV444)
    }

    func testUnknownClientBitsAreIgnoredAndCannotBecomeSelection() {
        XCTAssertThrowsError(try negotiator.select(
            availableVideoFormats: 0x0020,
            host: host(support: .allKnown),
            application: application,
            preferences: .default
        ))
    }

    func testCodecLosslessRequiresHostProofAndPrefersTenBit444() throws {
        var preferences = StreamingPreferences.default
        preferences.fidelityPreference = .codecLosslessRequired
        preferences.enableHDR = true
        let available = MoonlightVideoFormat.hevc.rawValue
            | MoonlightVideoFormat.hevcMain10.rawValue
            | MoonlightVideoFormat.hevcRext10YUV444.rawValue
        let selection = try negotiator.select(
            availableVideoFormats: available,
            host: host(support: [.hevc, .hevcMain10, .hevcRext10YUV444, .hevcLossless]),
            application: application,
            preferences: preferences
        )

        XCTAssertEqual(selection.selectedVideoFormat, MoonlightVideoFormat.hevcRext10YUV444.rawValue)
        XCTAssertEqual(selection.fidelity, .codecLosslessYUV44410Bit)
        XCTAssertFalse(selection.fidelity.preservesSourceRGBExactly)

        XCTAssertThrowsError(try negotiator.select(
            availableVideoFormats: available,
            host: host(support: [.hevc, .hevcMain10, .hevcRext10YUV444]),
            application: application,
            preferences: preferences
        )) { error in
            guard case .codecLosslessUnavailable = error as? UmbraIntegrationError else {
                return XCTFail("Expected explicit codec-lossless rejection, got \(error)")
            }
        }
    }

    func testCodecLosslessSDRSelectsOnlyProvenEightBitTuple() throws {
        var preferences = StreamingPreferences.default
        preferences.fidelityPreference = .codecLosslessRequired
        let selection = try negotiator.select(
            availableVideoFormats: MoonlightVideoFormat.hevc.rawValue
                | MoonlightVideoFormat.hevcMain10.rawValue
                | MoonlightVideoFormat.hevcRext8YUV444.rawValue
                | MoonlightVideoFormat.hevcRext10YUV444.rawValue,
            host: host(support: [
                .hevc, .hevcMain10, .hevcRext8YUV444, .hevcRext10YUV444, .hevcLossless,
            ]),
            application: application,
            preferences: preferences
        )

        XCTAssertEqual(selection.selectedVideoFormat, MoonlightVideoFormat.hevcRext8YUV444.rawValue)
        XCTAssertEqual(selection.fidelity, .codecLosslessYUV4448Bit)
        XCTAssertFalse(selection.isHDR)
    }

    func testCodecLosslessNeverUsesH264420AndLatencyRejectsThePreference() throws {
        var preferences = StreamingPreferences.default
        preferences.fidelityPreference = .codecLosslessRequired
        XCTAssertThrowsError(try negotiator.select(
            availableVideoFormats: MoonlightVideoFormat.h264.rawValue,
            host: host(support: [.h264, .h264Lossless]),
            application: application,
            preferences: preferences
        ))

        preferences.optimizationMode = .latency
        XCTAssertThrowsError(try preferences.validate())
        XCTAssertThrowsError(try negotiator.select(
            availableVideoFormats: MoonlightVideoFormat.h264High8YUV444.rawValue,
            host: host(support: [.h264High8YUV444, .h264Lossless]),
            application: application,
            preferences: preferences
        ))
    }

    func testConfigurationMapperRejectsCombinedAndUnknownSelectedMasks() throws {
        let bootstrap = try makeBootstrap()
        for invalid in [Int32(0x0101), Int32(0x0020)] {
            XCTAssertThrowsError(try StreamingConfigurationMapper.configuration(
                for: bootstrap,
                selectedVideoFormat: invalid
            )) { error in
                XCTAssertEqual(
                    error as? UmbraIntegrationError,
                    .unsupportedVideoConfiguration(.automatic)
                )
            }
        }
    }

    func testDefaultQualityAndLatencyEmitNoFidelityExtension() throws {
        var quality = try makeBootstrap()
        quality.effectivePolicy = .resolve(for: quality.preferences)
        XCTAssertEqual(
            try StreamingConfigurationMapper.configuration(
                for: quality,
                selectedVideoFormat: MoonlightVideoFormat.hevc.rawValue
            ).rtspFidelityMode,
            .unspecified
        )

        quality.preferences.optimizationMode = .latency
        quality.effectivePolicy = .resolve(for: quality.preferences)
        XCTAssertEqual(
            try StreamingConfigurationMapper.configuration(
                for: quality,
                selectedVideoFormat: MoonlightVideoFormat.hevc.rawValue
            ).rtspFidelityMode,
            .unspecified
        )
    }

    func testConfigurationMapperCannotBypassExactLosslessProof() throws {
        var bootstrap = try makeBootstrap()
        bootstrap.preferences.fidelityPreference = .codecLosslessRequired
        bootstrap.effectivePolicy = .resolve(for: bootstrap.preferences)
        XCTAssertThrowsError(try StreamingConfigurationMapper.configuration(
            for: bootstrap,
            selectedVideoFormat: MoonlightVideoFormat.hevc.rawValue
        ))

        bootstrap.host.codecSupport.insert(.hevcLossless)
        XCTAssertEqual(
            try StreamingConfigurationMapper.configuration(
                for: bootstrap,
                selectedVideoFormat: MoonlightVideoFormat.hevc.rawValue
            ).rtspFidelityMode,
            .codecLosslessRequired
        )
    }

    private var application: StreamApplication {
        StreamApplication(id: 1, name: "Desktop", hdrSupported: true)
    }

    private func host(
        support: HostCodecSupport,
        maxLumaPixelsHEVC: Int = 0
    ) -> StreamHost {
        StreamHost(
            uuid: "host",
            name: "Host",
            applications: [application],
            maxLumaPixelsHEVC: maxLumaPixelsHEVC,
            codecSupport: support
        )
    }

    private func makeBootstrap() throws -> StreamBootstrap {
        var streamHost = host(support: [.h264, .hevc])
        streamHost.activeAddress = NetworkEndpoint(hostname: "192.168.1.2")
        streamHost.appVersion = "8.0.0"
        return StreamBootstrap(
            sessionID: UUID(),
            host: streamHost,
            application: application,
            preferences: .default,
            rtspSessionURL: nil,
            remoteInputCredentials: try RemoteInputCredentials(
                key: Data(repeating: 1, count: 16),
                initializationVector: Data(repeating: 2, count: 16)
            )
        )
    }
}

private extension HostCodecSupport {
    static let allKnown: HostCodecSupport = [
        .h264,
        .hevc,
        .hevcMain10,
        .av1Main8,
        .av1Main10,
        .h264High8YUV444,
        .hevcRext8YUV444,
        .hevcRext10YUV444,
        .av1High8YUV444,
        .av1High10YUV444,
    ]
}

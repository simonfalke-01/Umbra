import CryptoKit
import Foundation
import UmbraCore
@testable import UmbraIntegration
import UmbraMedia
import XCTest

final class LumenVDDGate5ContractTests: XCTestCase {
    private static let producerCommit = "60de5c1126108f2981cf269308dcf979ac4e829b"

    func testBundledGate5FixturePinsExactLumenProducerBytes() throws {
        let fixtureURL = try XCTUnwrap(Bundle.module.url(
            forResource: "lumen_vdd_gate5_contract_60de5c11",
            withExtension: "json"
        ))
        let provenanceURL = try XCTUnwrap(Bundle.module.url(
            forResource: "lumen_vdd_gate5_contract_60de5c11.provenance",
            withExtension: "json"
        ))
        let fixtureData = try Data(contentsOf: fixtureURL)
        let provenance = try JSONDecoder().decode(
            Gate5FixtureProvenance.self,
            from: Data(contentsOf: provenanceURL)
        )

        XCTAssertEqual(provenance.upstreamRepository, "Lumen")
        XCTAssertEqual(provenance.upstreamCommit, Self.producerCommit)
        XCTAssertEqual(provenance.upstreamPath, "docs/protocols/vectors/vdd_gate5_contract.json")
        XCTAssertEqual(Data(SHA256.hash(data: fixtureData)).hexadecimal, provenance.sha256)

        if let sourceRoot = ProcessInfo.processInfo.environment["LUMEN_SOURCE_ROOT"] {
            let upstream = URL(fileURLWithPath: sourceRoot)
                .appendingPathComponent(provenance.upstreamPath)
            XCTAssertEqual(try Data(contentsOf: upstream), fixtureData)
        }
    }

    func testBundledGate5ModesMatchUmbraAdmissionWithoutExternalSourceRoot() throws {
        let fixture = try loadFixture()
        XCTAssertEqual(fixture.schema, "lumen-vdd-gate5/1")
        XCTAssertEqual(fixture.producer.repository, "Lumen")
        XCTAssertEqual(
            fixture.producer.sourceBaseline,
            "c581323405375a82c9243181a1361ac22fcc1b40"
        )
        XCTAssertEqual(fixture.contract.minimumWidth, StreamingPreferences.minimumStreamWidth)
        XCTAssertEqual(fixture.contract.maximumWidth, StreamingPreferences.maximumStreamWidth)
        XCTAssertEqual(fixture.contract.minimumHeight, StreamingPreferences.minimumStreamHeight)
        XCTAssertEqual(fixture.contract.maximumHeight, StreamingPreferences.maximumStreamHeight)
        XCTAssertEqual(fixture.contract.minimumRefreshHz, StreamingPreferences.minimumFrameRate)
        XCTAssertEqual(fixture.contract.maximumRefreshHz, StreamingPreferences.maximumFrameRate)
        XCTAssertEqual(fixture.contract.sdr, .init(
            bitsPerChannel: 8,
            textureFormat: "bgra8",
            surfaceColorSpace: "srgb"
        ))
        XCTAssertEqual(fixture.contract.hdr10, .init(
            bitsPerChannel: 10,
            textureFormat: "rgba16_float",
            surfaceColorSpace: "scrgb"
        ))

        for mode in fixture.modes {
            XCTAssertEqual(canEmitExactMode(mode), mode.admitted, mode.id)
        }
    }

    func testAuthenticatedCaptureStateVocabularyIsTypedAndFailClosed() throws {
        let fixture = try loadFixture()
        let decoded = try fixture.contract.captureStates.map(
            LumenVDDCaptureState.authenticatedStatusField
        )
        XCTAssertEqual(decoded, LumenVDDCaptureState.allCases)
        XCTAssertFalse(LumenVDDCaptureState.inactive.isDegraded)
        XCTAssertFalse(LumenVDDCaptureState.direct.isDegraded)
        XCTAssertFalse(LumenVDDCaptureState.fallback.isDegraded)
        XCTAssertTrue(LumenVDDCaptureState.quarantined.isDegraded)
        XCTAssertTrue(LumenVDDCaptureState.unavailable.isDegraded)
        XCTAssertThrowsError(try LumenVDDCaptureState.authenticatedStatusField("online"))
    }

    private func loadFixture() throws -> Gate5Fixture {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "lumen_vdd_gate5_contract_60de5c11",
            withExtension: "json"
        ))
        return try JSONDecoder().decode(Gate5Fixture.self, from: Data(contentsOf: url))
    }

    private func canEmitExactMode(_ mode: Gate5Mode) -> Bool {
        var preferences = StreamingPreferences.default
        preferences.width = mode.width
        preferences.height = mode.height
        preferences.setFrameRate(
            numerator: mode.refreshNumerator,
            denominator: mode.refreshDenominator
        )
        preferences.enableHDR = mode.dynamicRange == "hdr10"
        preferences.hdrTransferPreference = .pq

        guard let offer = try? ProtocolV3StartRequestMapper.makeOffer(
            applicationID: 1,
            resume: false,
            preferences: preferences,
            capabilities: fullyCapableClient,
            startIntentID: Data(1...16),
            traceID: Data(17...32)
        ),
              offer.fields[4]?.unsignedValue == UInt64(mode.width),
              offer.fields[5]?.unsignedValue == UInt64(mode.height),
              offer.fields[6]?.unsignedValue == UInt64(mode.refreshNumerator),
              offer.fields[7]?.unsignedValue == UInt64(mode.refreshDenominator) else {
            return false
        }
        let hasExactDepth = offer.fields[9]?.arrayValue?.contains { value in
            value.mapValue?[3]?.unsignedValue == UInt64(mode.bitsPerChannel)
        } == true
        let hasExpectedHDR = mode.dynamicRange == "hdr10"
            ? offer.fields[14]?.arrayValue?.isEmpty == false
            : offer.fields[14]?.arrayValue?.isEmpty == true
        return hasExactDepth && hasExpectedHDR
    }

    private var fullyCapableClient: AppleStreamingCapabilities {
        AppleStreamingCapabilities(
            hasMetalDevice: true,
            supportsHardwareH264: true,
            supportsHardwareHEVC: true,
            supportsHardwareAV1: true,
            hasDefaultAudioOutput: true,
            supportsNativeAudioOutput: true,
            audioOutputChannelCount: 2,
            supportsHardwareHEVCMain10: true,
            supportsHardwareAV1Main10: true
        )
    }
}

private struct Gate5FixtureProvenance: Decodable {
    let upstreamRepository: String
    let upstreamCommit: String
    let upstreamPath: String
    let sha256: String

    private enum CodingKeys: String, CodingKey {
        case upstreamRepository = "upstream_repository"
        case upstreamCommit = "upstream_commit"
        case upstreamPath = "upstream_path"
        case sha256
    }
}

private struct Gate5Fixture: Decodable {
    struct Producer: Decodable {
        let repository: String
        let sourceBaseline: String

        private enum CodingKeys: String, CodingKey {
            case repository
            case sourceBaseline = "source_baseline"
        }
    }

    struct Contract: Decodable {
        let minimumWidth: Int
        let maximumWidth: Int
        let minimumHeight: Int
        let maximumHeight: Int
        let minimumRefreshHz: Int
        let maximumRefreshHz: Int
        let sdr: Gate5Format
        let hdr10: Gate5Format
        let captureStates: [String]

        private enum CodingKeys: String, CodingKey {
            case minimumWidth = "minimum_width"
            case maximumWidth = "maximum_width"
            case minimumHeight = "minimum_height"
            case maximumHeight = "maximum_height"
            case minimumRefreshHz = "minimum_refresh_hz"
            case maximumRefreshHz = "maximum_refresh_hz"
            case sdr
            case hdr10
            case captureStates = "capture_states"
        }
    }

    let schema: String
    let producer: Producer
    let contract: Contract
    let modes: [Gate5Mode]
}

private struct Gate5Format: Decodable, Equatable {
    let bitsPerChannel: Int
    let textureFormat: String
    let surfaceColorSpace: String

    private enum CodingKeys: String, CodingKey {
        case bitsPerChannel = "bits_per_channel"
        case textureFormat = "texture_format"
        case surfaceColorSpace = "surface_color_space"
    }
}

private struct Gate5Mode: Decodable {
    let id: String
    let width: Int
    let height: Int
    let refreshNumerator: Int
    let refreshDenominator: Int
    let dynamicRange: String
    let bitsPerChannel: Int
    let admitted: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case width
        case height
        case refreshNumerator = "refresh_numerator"
        case refreshDenominator = "refresh_denominator"
        case dynamicRange = "dynamic_range"
        case bitsPerChannel = "bits_per_channel"
        case admitted
    }
}

private extension Data {
    var hexadecimal: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

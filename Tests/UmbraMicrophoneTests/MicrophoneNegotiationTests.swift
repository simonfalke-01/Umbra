import XCTest
@testable import UmbraMicrophone

final class MicrophoneNegotiationTests: XCTestCase {
    func testExactDescribeCapabilityIsAcceptedAmongOtherSDPAttributes() {
        let sdp =
            "v=0\r\n" +
            "a=ordinary:value\r\n" +
            MicrophoneNegotiation.describeCapabilitySDP +
            "a=another:value\r\n"

        XCTAssertEqual(MicrophoneNegotiation.parseDescribeCapability(from: sdp), .version1)
        XCTAssertEqual(MicrophoneNegotiation.setupStreamIdentifier, "streamid=lumen-mic/1/0")
        XCTAssertEqual(
            MicrophoneNegotiation.announceSelectionSDP,
            "a=x-lumen-mic.enabled:1\r\n" +
                "a=x-lumen-mic.version:1\r\n" +
                "a=x-lumen-mic.codec:opus\r\n" +
                "a=x-lumen-mic.sampleRate:48000\r\n" +
                "a=x-lumen-mic.channels:1\r\n" +
                "a=x-lumen-mic.packetDurationMs:20\r\n" +
                "a=x-lumen-mic.fec:opus-inband\r\n"
        )
    }

    func testDescribeCapabilityRequiresEveryExactUniqueKnownAttribute() {
        let exact = MicrophoneNegotiation.describeCapabilitySDP
        let malformed = [
            exact.replacingOccurrences(of: "a=x-lumen-mic.version:1\r\n", with: ""),
            exact.replacingOccurrences(of: "codec:opus", with: "codec:aac"),
            exact + "a=x-lumen-mic.version:1\r\n",
            exact + "a=x-lumen-mic.future:1\r\n",
            exact.replacingOccurrences(of: "crypto:aes-256-gcm", with: "crypto"),
            exact.replacingOccurrences(of: "channels:1", with: "channels:1 "),
            "v=0\r\n",
        ]

        for candidate in malformed {
            XCTAssertNil(
                MicrophoneNegotiation.parseDescribeCapability(from: candidate),
                "unexpectedly accepted: \(candidate)"
            )
        }
    }

    func testSetupCredentialsRequireOneStrictLowercaseHexValuePerHeader() throws {
        let credentials = try MicrophoneSetupCredentials(
            sessionHeaderValues: ["000102030405060708090a0b0c0d0e0f"],
            saltHeaderValues: ["101112131415161718191a1b1c1d1e1f"]
        )
        XCTAssertEqual(credentials.sessionID.bytes, Array(0x00...0x0f))
        XCTAssertEqual(credentials.salt.bytes, Array(0x10...0x1f))

        XCTAssertThrowsError(
            try MicrophoneSetupCredentials(sessionHeaderValues: [], saltHeaderValues: [validSaltHex])
        ) { XCTAssertEqual($0 as? MicrophoneCredentialError, .missingSessionHeader) }
        XCTAssertThrowsError(
            try MicrophoneSetupCredentials(
                sessionHeaderValues: [validSessionHex, validSessionHex],
                saltHeaderValues: [validSaltHex]
            )
        ) { XCTAssertEqual($0 as? MicrophoneCredentialError, .duplicateSessionHeader) }
        XCTAssertThrowsError(
            try MicrophoneSetupCredentials(sessionHeaderValues: [validSessionHex], saltHeaderValues: [])
        ) { XCTAssertEqual($0 as? MicrophoneCredentialError, .missingSaltHeader) }
        XCTAssertThrowsError(
            try MicrophoneSetupCredentials(
                sessionHeaderValues: [validSessionHex],
                saltHeaderValues: [validSaltHex, validSaltHex]
            )
        ) { XCTAssertEqual($0 as? MicrophoneCredentialError, .duplicateSaltHeader) }
    }

    func testSessionAndSaltRejectWrongLengthUppercaseAndNonHex() {
        for invalid in [
            "000102030405060708090a0b0c0d0e",
            "000102030405060708090a0b0c0d0e0f00",
            "000102030405060708090A0b0c0d0e0f",
            "000102030405060708090g0b0c0d0e0f",
            "000102030405060708090a0b0c0d0e0é",
        ] {
            XCTAssertThrowsError(try MicrophoneSessionID(lowercaseHex: invalid)) {
                XCTAssertEqual($0 as? MicrophoneCredentialError, .invalidSessionHex)
            }
            XCTAssertThrowsError(try MicrophoneSalt(lowercaseHex: invalid)) {
                XCTAssertEqual($0 as? MicrophoneCredentialError, .invalidSaltHex)
            }
        }
    }

    private let validSessionHex = "000102030405060708090a0b0c0d0e0f"
    private let validSaltHex = "101112131415161718191a1b1c1d1e1f"
}

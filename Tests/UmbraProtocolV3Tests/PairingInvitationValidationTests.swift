import Foundation
import Testing
@testable import UmbraProtocolV3

@Test func invitationReportsExpiredAndFutureLifetimesSeparately() throws {
    var bytes = Data(hexadecimal: invitationHex)
    bytes.replaceSubrange(144..<152, with: UInt64(1_700_000_000).bigEndianBytes)
    bytes.replaceSubrange(152..<160, with: UInt64(1_700_000_300).bigEndianBytes)

    #expect(throws: ProtocolV3WireError.invalidField("v3 invitation expired")) {
        _ = try ProtocolV3PairingInvitation.decode(bytes, nowUnixSeconds: 1_700_000_301)
    }
    #expect(throws: ProtocolV3WireError.invalidField("v3 invitation not active")) {
        _ = try ProtocolV3PairingInvitation.decode(bytes, nowUnixSeconds: 1_699_999_999)
    }
}

private extension Data {
    init(hexadecimal: String) {
        self.init()
        var index = hexadecimal.startIndex
        while index < hexadecimal.endIndex {
            let end = hexadecimal.index(index, offsetBy: 2)
            append(UInt8(hexadecimal[index..<end], radix: 16)!)
            index = end
        }
    }
}

private extension UInt64 {
    var bigEndianBytes: Data {
        var value = bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}

private let invitationHex = "554c4933010000ac00babb9e00030003000102030405060708090a0b0c0d0e0fa0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebf24f6ed6acbfe1009c030d7ca567c33ca808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f29acbae141bccaf0b22e1a94d34d0bc7361e526d0bfe12c89794bc9322966dd7000000006553f100000000006553f22c000000000000017f000e0000766563746f722e6578616d706c65"

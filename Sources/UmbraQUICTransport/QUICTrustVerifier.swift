import CryptoKit
import Foundation

enum QUICLeafSPKIVerifier {
    enum VerificationError: Error, Equatable {
        case malformedCertificate
        case pinMismatch
    }

    static func verify(certificateDER: Data, expectedSHA256: Data) throws -> Data {
        guard expectedSHA256.count == SHA256.Digest.byteCount else {
            throw VerificationError.pinMismatch
        }
        let spki = try subjectPublicKeyInfo(in: certificateDER)
        let digest = Data(SHA256.hash(data: spki))
        guard constantTimeEqual(digest, expectedSHA256) else {
            throw VerificationError.pinMismatch
        }
        return digest
    }

    static func subjectPublicKeyInfo(in certificateDER: Data) throws -> Data {
        let bytes = [UInt8](certificateDER)
        let certificate = try readTLV(bytes, at: 0)
        guard certificate.tag == 0x30,
              certificate.endIndex == bytes.count
        else {
            throw VerificationError.malformedCertificate
        }

        let tbs = try readTLV(bytes, at: certificate.valueStart)
        guard tbs.tag == 0x30, tbs.endIndex <= certificate.endIndex else {
            throw VerificationError.malformedCertificate
        }

        var cursor = tbs.valueStart
        if cursor < tbs.endIndex, bytes[cursor] == 0xA0 {
            cursor = try readTLV(bytes, at: cursor).endIndex
        }

        // serialNumber, signature, issuer, validity, subject precede subjectPublicKeyInfo.
        for _ in 0..<5 {
            let field = try readTLV(bytes, at: cursor)
            guard field.endIndex <= tbs.endIndex else {
                throw VerificationError.malformedCertificate
            }
            cursor = field.endIndex
        }

        let spki = try readTLV(bytes, at: cursor)
        guard spki.tag == 0x30, spki.endIndex <= tbs.endIndex else {
            throw VerificationError.malformedCertificate
        }
        return Data(bytes[spki.startIndex..<spki.endIndex])
    }

    private struct TLV {
        let tag: UInt8
        let startIndex: Int
        let valueStart: Int
        let endIndex: Int
    }

    private static func readTLV(_ bytes: [UInt8], at index: Int) throws -> TLV {
        guard index >= 0, index + 2 <= bytes.count else {
            throw VerificationError.malformedCertificate
        }
        let tag = bytes[index]
        let firstLength = bytes[index + 1]
        var valueStart: Int
        var valueLength: Int

        if firstLength & 0x80 == 0 {
            valueStart = index + 2
            valueLength = Int(firstLength)
        } else {
            let lengthByteCount = Int(firstLength & 0x7F)
            guard lengthByteCount > 0,
                  lengthByteCount <= MemoryLayout<Int>.size,
                  index + 2 + lengthByteCount <= bytes.count,
                  bytes[index + 2] != 0
            else {
                throw VerificationError.malformedCertificate
            }
            valueStart = index + 2 + lengthByteCount
            valueLength = 0
            for offset in 0..<lengthByteCount {
                let byte = Int(bytes[index + 2 + offset])
                guard valueLength <= (Int.max - byte) / 256 else {
                    throw VerificationError.malformedCertificate
                }
                valueLength = valueLength * 256 + byte
            }
            guard valueLength >= 128 else {
                throw VerificationError.malformedCertificate
            }
        }

        guard valueLength <= bytes.count - valueStart else {
            throw VerificationError.malformedCertificate
        }
        return TLV(
            tag: tag,
            startIndex: index,
            valueStart: valueStart,
            endIndex: valueStart + valueLength
        )
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }
}

import CommonCrypto
import Foundation
import Security

protocol PairingRandomSource: Sendable {
    func bytes(count: Int) throws -> Data
}

struct SecurePairingRandomSource: PairingRandomSource {
    func bytes(count: Int) throws -> Data {
        guard count >= 0 else {
            throw PairingError.identityUnavailable("A negative random byte count was requested")
        }
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw PairingError.randomGeneration(status: status)
        }
        return data
    }
}

enum PairingCryptography {
    static func digest(_ data: Data, using algorithm: PairingDigest) -> Data {
        switch algorithm {
        case .sha1:
            var result = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
            data.withUnsafeBytes { bytes in
                _ = CC_SHA1(bytes.baseAddress, CC_LONG(data.count), &result)
            }
            return Data(result)
        case .sha256:
            var result = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            data.withUnsafeBytes { bytes in
                _ = CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &result)
            }
            return Data(result)
        }
    }

    static func pinKey(salt: Data, pin: String, using algorithm: PairingDigest) -> Data {
        var saltedPIN = salt
        saltedPIN.append(contentsOf: pin.utf8)
        return digest(saltedPIN, using: algorithm).prefix(16)
    }

    static func aesECB(_ input: Data, key: Data, operation: CCOperation) throws -> Data {
        guard key.count == kCCKeySizeAES128 else {
            throw PairingError.cryptography(operation: "AES-128 key validation", status: kCCParamError)
        }
        guard !input.isEmpty, input.count.isMultiple(of: kCCBlockSizeAES128) else {
            throw PairingError.cryptography(operation: "AES-ECB block validation", status: kCCAlignmentError)
        }

        var output = Data(count: input.count)
        let outputCapacity = output.count
        var outputLength = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(
                        operation,
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyBytes.baseAddress,
                        key.count,
                        nil,
                        inputBytes.baseAddress,
                        input.count,
                        outputBytes.baseAddress,
                        outputCapacity,
                        &outputLength
                    )
                }
            }
        }
        guard status == kCCSuccess, outputLength == input.count else {
            throw PairingError.cryptography(operation: "AES-ECB", status: Int(status))
        }
        output.count = outputLength
        return output
    }

    static func encrypt(_ plaintext: Data, key: Data) throws -> Data {
        try aesECB(plaintext, key: key, operation: CCOperation(kCCEncrypt))
    }

    static func decrypt(_ ciphertext: Data, key: Data) throws -> Data {
        try aesECB(ciphertext, key: key, operation: CCOperation(kCCDecrypt))
    }

    static func sign(_ message: Data, with privateKey: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            message as CFData,
            &error
        ) as Data? else {
            throw PairingError.identityUnavailable(error?.takeRetainedValue().localizedDescription ?? "RSA signing failed")
        }
        return signature
    }

    static func verify(_ signature: Data, message: Data, publicKey: SecKey) -> Bool {
        SecKeyVerifySignature(
            publicKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            message as CFData,
            signature as CFData,
            nil
        )
    }

    static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

enum PairingCertificate {
    static func der(from certificateData: Data) throws -> Data {
        if certificateData.starts(with: Data("-----BEGIN CERTIFICATE-----".utf8)) {
            guard let text = String(data: certificateData, encoding: .utf8) else {
                throw PairingError.invalidCertificate("PEM is not valid UTF-8")
            }
            let base64 = text
                .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
                .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
                .components(separatedBy: .whitespacesAndNewlines)
                .joined()
            guard let der = Data(base64Encoded: base64), SecCertificateCreateWithData(nil, der as CFData) != nil else {
                throw PairingError.invalidCertificate("PEM payload is not an X.509 certificate")
            }
            return der
        }
        guard SecCertificateCreateWithData(nil, certificateData as CFData) != nil else {
            throw PairingError.invalidCertificate("DER payload is not an X.509 certificate")
        }
        return certificateData
    }

    static func pem(from der: Data) -> Data {
        let body = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return Data("-----BEGIN CERTIFICATE-----\n\(body)\n-----END CERTIFICATE-----\n".utf8)
    }

    static func certificate(from data: Data) throws -> SecCertificate {
        let der = try der(from: data)
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw PairingError.invalidCertificate("Security.framework rejected the certificate")
        }
        return certificate
    }

    static func publicKey(from data: Data) throws -> SecKey {
        let certificate = try certificate(from: data)
        guard let key = SecCertificateCopyKey(certificate) else {
            throw PairingError.invalidCertificate("Certificate does not contain a public key")
        }
        return key
    }

    static func signature(from certificateData: Data) throws -> Data {
        let bytes = [UInt8](try der(from: certificateData))
        var outer = DERReader(bytes)
        let certificateSequence = try outer.read(tag: 0x30)
        guard outer.isAtEnd else {
            throw PairingError.invalidCertificate("Trailing bytes follow the X.509 certificate")
        }
        var certificate = DERReader(certificateSequence)
        _ = try certificate.readAny(expectedTag: 0x30)
        _ = try certificate.readAny(expectedTag: 0x30)
        let signatureBitString = try certificate.read(tag: 0x03)
        guard certificate.isAtEnd,
              signatureBitString.first == 0,
              signatureBitString.count > 1
        else {
            throw PairingError.invalidCertificate("Certificate signature BIT STRING is malformed")
        }
        return Data(signatureBitString.dropFirst())
    }

    static func makeSelfSigned(
        privateKey: SecKey,
        commonName: String = "NVIDIA GameStream Client",
        serialNumber: Data,
        notBefore: Date,
        notAfter: Date
    ) throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicKeyBytes = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?
        else {
            throw PairingError.identityUnavailable("RSA public key export failed")
        }

        let algorithmIdentifier = DER.sequence(
            DER.oid([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B]),
            DER.null
        )
        let rsaIdentifier = DER.sequence(
            DER.oid([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]),
            DER.null
        )
        let subjectPublicKeyInfo = DER.sequence(rsaIdentifier, DER.bitString(publicKeyBytes))
        let encodedName = DER.sequence(
            DER.set(
                DER.sequence(
                    DER.oid([0x55, 0x04, 0x03]),
                    DER.utf8String(commonName)
                )
            )
        )
        let validity = DER.sequence(DER.time(notBefore), DER.time(notAfter))
        let tbsCertificate = DER.sequence(
            DER.explicit(tag: 0, DER.integer(Data([2]))),
            DER.integer(serialNumber),
            algorithmIdentifier,
            encodedName,
            validity,
            encodedName,
            subjectPublicKeyInfo
        )
        let signature = try PairingCryptography.sign(tbsCertificate, with: privateKey)
        let certificateDER = DER.sequence(tbsCertificate, algorithmIdentifier, DER.bitString(signature))
        guard SecCertificateCreateWithData(nil, certificateDER as CFData) != nil else {
            throw PairingError.invalidCertificate("Generated self-signed certificate was rejected")
        }
        return certificateDER
    }
}

private struct DERReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var isAtEnd: Bool { offset == bytes.count }

    mutating func read(tag expectedTag: UInt8) throws -> [UInt8] {
        try readAny(expectedTag: expectedTag)
    }

    mutating func readAny(expectedTag: UInt8) throws -> [UInt8] {
        guard offset < bytes.count, bytes[offset] == expectedTag else {
            throw PairingError.invalidCertificate("Unexpected ASN.1 tag")
        }
        offset += 1
        let length = try readLength()
        guard length >= 0, offset + length <= bytes.count else {
            throw PairingError.invalidCertificate("ASN.1 length exceeds certificate data")
        }
        defer { offset += length }
        return Array(bytes[offset..<(offset + length)])
    }

    private mutating func readLength() throws -> Int {
        guard offset < bytes.count else {
            throw PairingError.invalidCertificate("Missing ASN.1 length")
        }
        let first = bytes[offset]
        offset += 1
        if first & 0x80 == 0 { return Int(first) }
        let byteCount = Int(first & 0x7F)
        guard byteCount > 0, byteCount <= 4, offset + byteCount <= bytes.count else {
            throw PairingError.invalidCertificate("Unsupported ASN.1 length")
        }
        var length = 0
        for _ in 0..<byteCount {
            length = (length << 8) | Int(bytes[offset])
            offset += 1
        }
        return length
    }
}

private enum DER {
    static let null = Data([0x05, 0x00])

    static func sequence(_ values: Data...) -> Data { tagged(0x30, joined(values)) }
    static func set(_ values: Data...) -> Data { tagged(0x31, joined(values)) }
    static func oid(_ body: [UInt8]) -> Data { tagged(0x06, Data(body)) }
    static func utf8String(_ value: String) -> Data { tagged(0x0C, Data(value.utf8)) }
    static func explicit(tag: UInt8, _ value: Data) -> Data { tagged(0xA0 | tag, value) }

    static func integer(_ bytes: Data) -> Data {
        var normalized = Data(bytes.drop(while: { $0 == 0 }))
        if normalized.isEmpty { normalized = Data([0]) }
        if normalized[normalized.startIndex] & 0x80 != 0 { normalized.insert(0, at: 0) }
        return tagged(0x02, normalized)
    }

    static func bitString(_ value: Data) -> Data {
        var body = Data([0])
        body.append(value)
        return tagged(0x03, body)
    }

    static func time(_ date: Date) -> Data {
        let calendar = Calendar(identifier: .gregorian)
        let year = calendar.component(.year, from: date)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = year < 2050 ? "yyMMddHHmmss'Z'" : "yyyyMMddHHmmss'Z'"
        return tagged(year < 2050 ? 0x17 : 0x18, Data(formatter.string(from: date).utf8))
    }

    private static func joined(_ values: [Data]) -> Data {
        values.reduce(into: Data()) { $0.append($1) }
    }

    private static func tagged(_ tag: UInt8, _ value: Data) -> Data {
        var result = Data([tag])
        result.append(length(value.count))
        result.append(value)
        return result
    }

    private static func length(_ value: Int) -> Data {
        if value < 0x80 { return Data([UInt8(value)]) }
        var remaining = value
        var bytes: [UInt8] = []
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
}

extension Data {
    init(pairingHex value: String) throws {
        guard value.count.isMultiple(of: 2) else {
            throw PairingError.invalidCertificate("Hexadecimal data has an odd length")
        }
        var result = Data(capacity: value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else {
                throw PairingError.invalidCertificate("Hexadecimal data contains an invalid character")
            }
            result.append(byte)
            index = next
        }
        self = result
    }

    var pairingHex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

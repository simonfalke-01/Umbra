import COpenSSL
import Foundation

public enum MicrophoneCryptoError: Error, Equatable, Sendable {
    case invalidRIKeyByteCount(Int)
    case keyDerivationFailed
    case encryptionFailed
    case authenticationFailed
}

enum MicrophoneKeyDerivation {
    static let information = Array("lumen/client-microphone/client-to-host/v1".utf8)
    static let outputByteCount = 36

    enum HMACStep: Equatable, Sendable {
        case extract
        case expandBlock1
        case expandBlock2
    }

    enum CleanupStage: Equatable, Hashable, Sendable {
        case pseudorandomKey
        case firstBlock
        case secondInput
        case secondBlock
        case output
    }

    typealias HMAC = (_ step: HMACStep, _ key: [UInt8], _ data: [UInt8]) throws -> [UInt8]
    typealias CleanupObserver = (_ stage: CleanupStage, _ cleansedBytes: [UInt8]) -> Void

    static func derive(rikey: [UInt8], salt: MicrophoneSalt) throws -> MicrophoneKeyMaterial {
        try derive(
            rikey: rikey,
            salt: salt,
            hmac: { _, key, data in try hmacSHA256(key: key, data: data) },
            cleanupObserver: nil
        )
    }

    static func derive(
        rikey: [UInt8],
        salt: MicrophoneSalt,
        hmac: HMAC,
        cleanupObserver: CleanupObserver?
    ) throws -> MicrophoneKeyMaterial {
        guard rikey.count == 16 else {
            throw MicrophoneCryptoError.invalidRIKeyByteCount(rikey.count)
        }

        var pseudorandomKey = try hmac(.extract, salt.bytes, rikey)
        defer { cleanse(&pseudorandomKey, stage: .pseudorandomKey, observer: cleanupObserver) }

        var firstBlock = try hmac(.expandBlock1, pseudorandomKey, information + [1])
        defer { cleanse(&firstBlock, stage: .firstBlock, observer: cleanupObserver) }

        var secondInput = firstBlock
        secondInput.append(contentsOf: information)
        secondInput.append(2)
        defer { cleanse(&secondInput, stage: .secondInput, observer: cleanupObserver) }

        var secondBlock = try hmac(.expandBlock2, pseudorandomKey, secondInput)
        defer { cleanse(&secondBlock, stage: .secondBlock, observer: cleanupObserver) }

        var output = firstBlock
        output.append(contentsOf: secondBlock.prefix(outputByteCount - firstBlock.count))
        defer { cleanse(&output, stage: .output, observer: cleanupObserver) }
        return MicrophoneKeyMaterial(bytes: output)
    }

    static func hmacSHA256(key: [UInt8], data: [UInt8]) throws -> [UInt8] {
        let digestByteCount = 32
        var output = [UInt8](repeating: 0, count: digestByteCount)
        var outputByteCount = 0

        let result = key.withUnsafeBytes { keyBuffer in
            data.withUnsafeBytes { dataBuffer in
                output.withUnsafeMutableBytes { outputBuffer in
                    "HMAC".withCString { algorithm in
                        "SHA256".withCString { digest in
                            EVP_Q_mac(
                                nil,
                                algorithm,
                                nil,
                                digest,
                                nil,
                                keyBuffer.baseAddress,
                                keyBuffer.count,
                                dataBuffer.bindMemory(to: UInt8.self).baseAddress,
                                dataBuffer.count,
                                outputBuffer.bindMemory(to: UInt8.self).baseAddress,
                                digestByteCount,
                                &outputByteCount
                            )
                        }
                    }
                }
            }
        }

        guard result != nil, outputByteCount == digestByteCount else {
            secureZero(&output)
            throw MicrophoneCryptoError.keyDerivationFailed
        }
        return output
    }

    private static func cleanse(
        _ bytes: inout [UInt8],
        stage: CleanupStage,
        observer: CleanupObserver?
    ) {
        secureZero(&bytes)
        observer?(stage, bytes)
    }
}

final class MicrophoneKeyMaterial {
    static let keyByteCount = 32
    static let noncePrefixByteCount = 4

    private let storage: SecureBytes

    init(bytes: [UInt8]) {
        precondition(bytes.count == Self.keyByteCount + Self.noncePrefixByteCount)
        storage = SecureBytes(bytes)
    }

    func withKeyAndNoncePrefix<Result>(
        _ body: (UnsafeRawBufferPointer, UnsafeRawBufferPointer) throws -> Result
    ) rethrows -> Result {
        try storage.withUnsafeBytes { bytes in
            let key = UnsafeRawBufferPointer(rebasing: bytes[..<Self.keyByteCount])
            let prefix = UnsafeRawBufferPointer(rebasing: bytes[Self.keyByteCount...])
            return try body(key, prefix)
        }
    }
}

private final class SecureBytes {
    private let pointer: UnsafeMutablePointer<UInt8>
    private let count: Int

    init(_ bytes: [UInt8]) {
        precondition(!bytes.isEmpty)
        count = bytes.count
        pointer = .allocate(capacity: count)
        bytes.withUnsafeBufferPointer { source in
            pointer.initialize(from: source.baseAddress!, count: count)
        }
    }

    func withUnsafeBytes<Result>(_ body: (UnsafeRawBufferPointer) throws -> Result) rethrows -> Result {
        try body(UnsafeRawBufferPointer(start: pointer, count: count))
    }

    deinit {
        OPENSSL_cleanse(pointer, count)
        pointer.deinitialize(count: count)
        pointer.deallocate()
    }
}

enum OpenSSLAESGCM {
    static let nonceByteCount = 12
    static let tagByteCount = 16

    static func seal(
        plaintext: [UInt8],
        authenticatedData: [UInt8],
        key: UnsafeRawBufferPointer,
        nonce: [UInt8]
    ) throws -> (ciphertext: [UInt8], tag: [UInt8]) {
        guard key.count == MicrophoneKeyMaterial.keyByteCount,
              nonce.count == nonceByteCount,
              let context = EVP_CIPHER_CTX_new() else {
            throw MicrophoneCryptoError.encryptionFailed
        }
        defer { EVP_CIPHER_CTX_free(context) }

        guard EVP_EncryptInit_ex(context, EVP_aes_256_gcm(), nil, nil, nil) == 1,
              EVP_CIPHER_CTX_ctrl(context, EVP_CTRL_GCM_SET_IVLEN, Int32(nonceByteCount), nil) == 1 else {
            throw MicrophoneCryptoError.encryptionFailed
        }

        let initialized = nonce.withUnsafeBytes { nonceBuffer in
            EVP_EncryptInit_ex(
                context,
                nil,
                nil,
                key.bindMemory(to: UInt8.self).baseAddress,
                nonceBuffer.bindMemory(to: UInt8.self).baseAddress
            )
        }
        guard initialized == 1 else { throw MicrophoneCryptoError.encryptionFailed }

        var written: Int32 = 0
        let aadResult = authenticatedData.withUnsafeBytes { buffer in
            EVP_EncryptUpdate(
                context,
                nil,
                &written,
                buffer.bindMemory(to: UInt8.self).baseAddress,
                Int32(buffer.count)
            )
        }
        guard aadResult == 1 else { throw MicrophoneCryptoError.encryptionFailed }

        var ciphertext = [UInt8](repeating: 0, count: max(plaintext.count, 1))
        var ciphertextByteCount: Int32 = 0
        if !plaintext.isEmpty {
            let payloadResult = plaintext.withUnsafeBytes { plaintextBuffer in
                ciphertext.withUnsafeMutableBytes { ciphertextBuffer in
                    EVP_EncryptUpdate(
                        context,
                        ciphertextBuffer.bindMemory(to: UInt8.self).baseAddress,
                        &ciphertextByteCount,
                        plaintextBuffer.bindMemory(to: UInt8.self).baseAddress,
                        Int32(plaintextBuffer.count)
                    )
                }
            }
            guard payloadResult == 1 else { throw MicrophoneCryptoError.encryptionFailed }
        }

        var finalByteCount: Int32 = 0
        let finalResult = ciphertext.withUnsafeMutableBytes { buffer in
            EVP_EncryptFinal_ex(
                context,
                buffer.bindMemory(to: UInt8.self).baseAddress?.advanced(by: Int(ciphertextByteCount)),
                &finalByteCount
            )
        }
        guard finalResult == 1 else { throw MicrophoneCryptoError.encryptionFailed }
        ciphertext.removeSubrange(Int(ciphertextByteCount + finalByteCount)..<ciphertext.count)

        var tag = [UInt8](repeating: 0, count: tagByteCount)
        let tagResult = tag.withUnsafeMutableBytes { buffer in
            EVP_CIPHER_CTX_ctrl(
                context,
                EVP_CTRL_GCM_GET_TAG,
                Int32(tagByteCount),
                buffer.baseAddress
            )
        }
        guard tagResult == 1 else { throw MicrophoneCryptoError.encryptionFailed }
        return (ciphertext, tag)
    }

    static func open(
        ciphertext: [UInt8],
        tag: [UInt8],
        authenticatedData: [UInt8],
        key: UnsafeRawBufferPointer,
        nonce: [UInt8]
    ) throws -> [UInt8] {
        guard key.count == MicrophoneKeyMaterial.keyByteCount,
              nonce.count == nonceByteCount,
              tag.count == tagByteCount,
              let context = EVP_CIPHER_CTX_new() else {
            throw MicrophoneCryptoError.authenticationFailed
        }
        defer { EVP_CIPHER_CTX_free(context) }

        guard EVP_DecryptInit_ex(context, EVP_aes_256_gcm(), nil, nil, nil) == 1,
              EVP_CIPHER_CTX_ctrl(context, EVP_CTRL_GCM_SET_IVLEN, Int32(nonceByteCount), nil) == 1 else {
            throw MicrophoneCryptoError.authenticationFailed
        }

        let initialized = nonce.withUnsafeBytes { nonceBuffer in
            EVP_DecryptInit_ex(
                context,
                nil,
                nil,
                key.bindMemory(to: UInt8.self).baseAddress,
                nonceBuffer.bindMemory(to: UInt8.self).baseAddress
            )
        }
        guard initialized == 1 else { throw MicrophoneCryptoError.authenticationFailed }

        var written: Int32 = 0
        let aadResult = authenticatedData.withUnsafeBytes { buffer in
            EVP_DecryptUpdate(
                context,
                nil,
                &written,
                buffer.bindMemory(to: UInt8.self).baseAddress,
                Int32(buffer.count)
            )
        }
        guard aadResult == 1 else { throw MicrophoneCryptoError.authenticationFailed }

        var plaintext = [UInt8](repeating: 0, count: max(ciphertext.count, 1))
        var plaintextByteCount: Int32 = 0
        if !ciphertext.isEmpty {
            let payloadResult = ciphertext.withUnsafeBytes { ciphertextBuffer in
                plaintext.withUnsafeMutableBytes { plaintextBuffer in
                    EVP_DecryptUpdate(
                        context,
                        plaintextBuffer.bindMemory(to: UInt8.self).baseAddress,
                        &plaintextByteCount,
                        ciphertextBuffer.bindMemory(to: UInt8.self).baseAddress,
                        Int32(ciphertextBuffer.count)
                    )
                }
            }
            guard payloadResult == 1 else { throw MicrophoneCryptoError.authenticationFailed }
        }

        let tagResult = tag.withUnsafeBytes { buffer in
            EVP_CIPHER_CTX_ctrl(
                context,
                EVP_CTRL_GCM_SET_TAG,
                Int32(tagByteCount),
                UnsafeMutableRawPointer(mutating: buffer.baseAddress)
            )
        }
        guard tagResult == 1 else { throw MicrophoneCryptoError.authenticationFailed }

        var finalByteCount: Int32 = 0
        let finalResult = plaintext.withUnsafeMutableBytes { buffer in
            EVP_DecryptFinal_ex(
                context,
                buffer.bindMemory(to: UInt8.self).baseAddress?.advanced(by: Int(plaintextByteCount)),
                &finalByteCount
            )
        }
        guard finalResult == 1 else {
            secureZero(&plaintext)
            throw MicrophoneCryptoError.authenticationFailed
        }
        plaintext.removeSubrange(Int(plaintextByteCount + finalByteCount)..<plaintext.count)
        return plaintext
    }
}

private func secureZero(_ bytes: inout [UInt8]) {
    bytes.withUnsafeMutableBytes { buffer in
        guard let address = buffer.baseAddress else { return }
        OPENSSL_cleanse(address, buffer.count)
    }
}

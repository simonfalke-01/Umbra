import Foundation

public enum MicrophoneGenerationState: Equatable, Sendable {
    case awaitingHello
    case active
    case ended
    case invalidated
    case exhausted
    case failed
}

public enum MicrophoneGenerationError: Error, Equatable, Sendable {
    case helloAlreadySent
    case helloRequired
    case generationClosed(MicrophoneGenerationState)
    case emptyOpusPacket
    case opusPacketTooLarge(Int)
    case packetSequenceExhausted
}

/// Single microphone generation. Public construction always begins at sequence and timestamp zero.
public final class MicrophoneGeneration: @unchecked Sendable {
    public static let samplesPerPacket: UInt32 = 960

    private let lock = NSLock()
    private let sessionID: MicrophoneSessionID
    private var keyMaterial: MicrophoneKeyMaterial?
    private var storedState: MicrophoneGenerationState = .awaitingHello
    private var storedNextPacketSequence: UInt64?
    private var storedTimestamp48kHz: UInt32

    public convenience init(credentials: MicrophoneSetupCredentials, rikey: [UInt8]) throws {
        try self.init(credentials: credentials, rikey: rikey, initialSequence: 0, initialTimestamp48kHz: 0)
    }

    init(
        credentials: MicrophoneSetupCredentials,
        rikey: [UInt8],
        initialSequence: UInt64,
        initialTimestamp48kHz: UInt32
    ) throws {
        sessionID = credentials.sessionID
        keyMaterial = try MicrophoneKeyDerivation.derive(rikey: rikey, salt: credentials.salt)
        storedNextPacketSequence = initialSequence
        storedTimestamp48kHz = initialTimestamp48kHz
    }

    public var state: MicrophoneGenerationState {
        lock.withLock { storedState }
    }

    public var nextPacketSequence: UInt64? {
        lock.withLock { storedNextPacketSequence }
    }

    public var timestamp48kHz: UInt32 {
        lock.withLock { storedTimestamp48kHz }
    }

    public func hello() throws -> LMC1Datagram {
        try lock.withLock {
            switch storedState {
            case .awaitingHello:
                let datagram = try seal(type: .hello, flags: 0, plaintext: [])
                if storedState != .exhausted {
                    storedState = .active
                }
                return datagram
            case .active:
                throw MicrophoneGenerationError.helloAlreadySent
            default:
                throw MicrophoneGenerationError.generationClosed(storedState)
            }
        }
    }

    public func audio(opusPacket: [UInt8]) throws -> LMC1Datagram {
        try lock.withLock {
            try requireActive()
            guard !opusPacket.isEmpty else {
                throw MicrophoneGenerationError.emptyOpusPacket
            }
            guard opusPacket.count <= LMC1Datagram.maximumCiphertextByteCount else {
                throw MicrophoneGenerationError.opusPacketTooLarge(opusPacket.count)
            }
            return try seal(type: .audio, flags: 0, plaintext: opusPacket)
        }
    }

    public func silence() throws -> LMC1Datagram {
        try lock.withLock {
            try requireActive()
            return try seal(type: .audio, flags: LMC1Datagram.silenceFlag, plaintext: [])
        }
    }

    public func reset() throws -> LMC1Datagram {
        try lock.withLock {
            try requireActive()
            return try seal(type: .reset, flags: 0, plaintext: [])
        }
    }

    public func end() throws -> LMC1Datagram {
        try lock.withLock {
            try requireActive()
            let datagram = try seal(type: .end, flags: 0, plaintext: [])
            storedState = .ended
            storedNextPacketSequence = nil
            keyMaterial = nil
            return datagram
        }
    }

    /// Ends local ownership without transmitting END, for RTSP loss or forced teardown.
    public func invalidate() {
        lock.withLock {
            guard storedState == .awaitingHello || storedState == .active else { return }
            storedState = .invalidated
            storedNextPacketSequence = nil
            keyMaterial = nil
        }
    }

    private func requireActive() throws {
        switch storedState {
        case .awaitingHello:
            throw MicrophoneGenerationError.helloRequired
        case .active:
            return
        default:
            throw MicrophoneGenerationError.generationClosed(storedState)
        }
    }

    private func seal(type: LMC1PacketType, flags: UInt8, plaintext: [UInt8]) throws -> LMC1Datagram {
        guard let sequence = storedNextPacketSequence else {
            throw MicrophoneGenerationError.packetSequenceExhausted
        }
        guard let keyMaterial else {
            throw MicrophoneGenerationError.generationClosed(storedState)
        }

        let header = LMC1Datagram.header(
            type: type,
            flags: flags,
            sessionID: sessionID,
            packetSequence: sequence,
            timestamp48kHz: storedTimestamp48kHz,
            plaintextByteCount: plaintext.count
        )
        var nonce = [UInt8](repeating: 0, count: OpenSSLAESGCM.nonceByteCount)
        defer {
            _ = nonce.withUnsafeMutableBytes {
                $0.initializeMemory(as: UInt8.self, repeating: 0)
            }
        }

        let sealed: (ciphertext: [UInt8], tag: [UInt8])
        do {
            sealed = try keyMaterial.withKeyAndNoncePrefix { key, prefix in
                for index in 0..<MicrophoneKeyMaterial.noncePrefixByteCount {
                    nonce[index] = prefix[index]
                }
                for index in 0..<MemoryLayout<UInt64>.size {
                    let shift = UInt64((7 - index) * 8)
                    nonce[MicrophoneKeyMaterial.noncePrefixByteCount + index] =
                        UInt8(truncatingIfNeeded: sequence >> shift)
                }
                return try OpenSSLAESGCM.seal(
                    plaintext: plaintext,
                    authenticatedData: header,
                    key: key,
                    nonce: nonce
                )
            }
        } catch {
            storedState = .failed
            storedNextPacketSequence = nil
            self.keyMaterial = nil
            throw error
        }

        let datagram: LMC1Datagram
        do {
            datagram = try LMC1Datagram(validating: header + sealed.ciphertext + sealed.tag)
        } catch {
            storedState = .failed
            storedNextPacketSequence = nil
            self.keyMaterial = nil
            throw error
        }
        if type == .audio {
            storedTimestamp48kHz &+= Self.samplesPerPacket
        }
        if sequence == UInt64.max {
            storedState = .exhausted
            storedNextPacketSequence = nil
            self.keyMaterial = nil
        } else {
            storedNextPacketSequence = sequence + 1
        }
        return datagram
    }
}

/// Integration boundary for a connected UDP transport. Implementations must send one
/// complete datagram atomically and must not fragment it.
public protocol MicrophoneDatagramSending: Sendable {
    func send(_ datagram: LMC1Datagram) throws
}

/// Serializes generation and UDP send order across capture and teardown callers.
public final class MicrophoneDatagramTransmitter: @unchecked Sendable {
    private let lock = NSLock()
    public let generation: MicrophoneGeneration
    private let sender: any MicrophoneDatagramSending

    public init(generation: MicrophoneGeneration, sender: any MicrophoneDatagramSending) {
        self.generation = generation
        self.sender = sender
    }

    public func start() throws {
        try transmit { try generation.hello() }
    }

    public func sendAudio(opusPacket: [UInt8]) throws {
        try transmit { try generation.audio(opusPacket: opusPacket) }
    }

    public func sendSilence() throws {
        try transmit { try generation.silence() }
    }

    public func reset() throws {
        try transmit { try generation.reset() }
    }

    public func end() throws {
        try transmit { try generation.end() }
    }

    public func invalidate() {
        lock.withLock { generation.invalidate() }
    }

    private func transmit(_ makeDatagram: () throws -> LMC1Datagram) throws {
        try lock.withLock {
            let datagram = try makeDatagram()
            do {
                try sender.send(datagram)
            } catch {
                generation.invalidate()
                throw error
            }
        }
    }
}

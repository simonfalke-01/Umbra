import Foundation

enum QUICWireCodec {
    static let controlHeaderByteCount = 24
    static let datagramHeaderByteCount = QUICTransportProfile.datagramHeaderByteCount
    static let maximumControlPayloadByteCount = 1_048_576

    enum WireError: Error, Equatable {
        case malformed
        case unsupportedRoute
        case oversized
    }

    struct ControlFrame: Equatable, Sendable {
        let flags: UInt8
        let type: UInt16
        let requestID: UInt64
        let payload: Data
    }

    struct MediaDatagram: Equatable, Sendable {
        let sessionID: Data
        let channel: UInt8
        let kind: UInt8
        let flags: UInt8
        let semanticSequence: UInt64
        let objectID: UInt64
        let payload: Data
    }

    static func controlHeader(
        flags: UInt8,
        type: UInt16,
        requestID: UInt64,
        payloadByteCount: Int
    ) throws -> Data {
        guard type != 0,
              flags & ~UInt8(0x07) == 0,
              flags & 0x02 == 0 || flags & 0x01 != 0,
              requestID == 0
                ? (flags & 0x03 == 0 && isEventType(type, requestID: requestID))
                : !isEventType(type, requestID: requestID)
        else {
            throw WireError.malformed
        }
        guard payloadByteCount > 0,
              payloadByteCount <= maximumControlPayloadByteCount,
              payloadByteCount <= Int(UInt32.max)
        else {
            throw WireError.oversized
        }
        var header = Data(capacity: controlHeaderByteCount)
        header.append(contentsOf: [0x55, 0x4C, 0x43, 0x33, 3, flags]) // ULC3
        append(type, to: &header)
        append(requestID, to: &header)
        append(UInt32(payloadByteCount), to: &header)
        append(UInt32(0), to: &header)
        return header
    }

    static func datagramHeader(
        sessionID: Data,
        channel: UInt8,
        kind: UInt8,
        flags: UInt8,
        sequence: UInt64,
        objectID: UInt64,
        payloadByteCount: Int
    ) throws -> Data {
        guard sessionID.count == 16, sequence != 0, flags == 0 else {
            throw WireError.malformed
        }
        guard outboundRouteAllowed(channel: channel, kind: kind) else {
            throw WireError.unsupportedRoute
        }
        guard payloadByteCount > 0,
              payloadByteCount <= QUICTransportProfile.semanticDatagramByteCount - datagramHeaderByteCount,
              payloadByteCount <= Int(UInt16.max)
        else {
            throw WireError.oversized
        }
        var header = Data(capacity: datagramHeaderByteCount)
        header.append(contentsOf: [0x55, 0x4C, 0x4D, 0x33, 3, channel, kind, flags]) // ULM3
        append(UInt16(datagramHeaderByteCount), to: &header)
        append(UInt16(payloadByteCount), to: &header)
        header.append(sessionID)
        append(sequence, to: &header)
        append(objectID, to: &header)
        return header
    }

    static func decodeDatagram(_ data: Data) throws -> MediaDatagram {
        let base = data.startIndex
        guard data.count >= datagramHeaderByteCount,
              data.prefix(4) == Data([0x55, 0x4C, 0x4D, 0x33]),
              data[base + 4] == 3,
              readUInt16(data, base + 8) == datagramHeaderByteCount,
              inboundRouteAllowed(channel: data[base + 5], kind: data[base + 6]),
              flagsAllowed(channel: data[base + 5], kind: data[base + 6], flags: data[base + 7])
        else {
            throw WireError.malformed
        }
        let payloadLength = Int(readUInt16(data, base + 10))
        guard payloadLength > 0,
              data.count == datagramHeaderByteCount + payloadLength,
              data.count <= QUICTransportProfile.semanticDatagramByteCount
        else {
            throw WireError.oversized
        }
        let sequence = readUInt64(data, base + 28)
        guard sequence != 0 else { throw WireError.malformed }
        let message = MediaDatagram(
            sessionID: Data(data[(base + 12)..<(base + 28)]),
            channel: data[base + 5],
            kind: data[base + 6],
            flags: data[base + 7],
            semanticSequence: sequence,
            objectID: readUInt64(data, base + 36),
            payload: Data(data[(base + 44)..<data.endIndex])
        )
        try validateInboundPayload(message)
        return message
    }

    static func inboundLane(channel: UInt8, kind: UInt8) throws -> QUICSemanticLane {
        switch (channel, kind) {
        case (1, 2), (1, 3), (1, 4): .inputState
        case (2, 1): .video
        case (3, 1): .audio
        case (5, 1): .hostEvents
        default: throw WireError.unsupportedRoute
        }
    }

    static func validateOutboundPayload(
        channel: UInt8,
        kind: UInt8,
        objectID: UInt64,
        payload: Data
    ) throws {
        switch (channel, kind) {
        case (1, 1):
            guard payload.count >= 32 else { throw WireError.malformed }
            guard payload.count <= QUICTransportProfile.semanticDatagramByteCount - datagramHeaderByteCount else {
                throw WireError.oversized
            }
            let base = payload.startIndex
            let blockLength = Int(readUInt16(payload, base + 16))
            let edgeCount = Int(readUInt16(payload, base + 18))
            let stateFormat = readUInt16(payload, base + 20)
            guard blockLength >= 112, payload.count >= 32 + blockLength else {
                throw WireError.malformed
            }
            let stateBase = base + 32
            let controllerCount = Int(payload[stateBase + 84])
            let touchCount = Int(payload[stateBase + 85])
            let marker = payload[stateBase + 87]
            let controllerByteCount: Int
            switch stateFormat {
            case 2 where marker == 0:
                controllerByteCount = 64
            case 3 where marker == 3:
                controllerByteCount = 56
            default:
                throw WireError.malformed
            }
            guard edgeCount <= 64,
                  readUInt16(payload, base + 22) == 2,
                  readUInt64(payload, base + 24) == 0,
                  blockLength == 112 + controllerCount * controllerByteCount + touchCount * 32,
                  payload.count == 32 + blockLength + edgeCount * 32,
                  objectID != 0
            else {
                throw WireError.malformed
            }
            if edgeCount > 0 {
                let edgeBase = base + 32 + blockLength
                let firstEdgeID = readUInt64(payload, edgeBase)
                guard firstEdgeID != 0 else { throw WireError.malformed }
                for index in 1..<edgeCount {
                    let expected = firstEdgeID.addingReportingOverflow(UInt64(index))
                    guard !expected.overflow,
                          readUInt64(payload, edgeBase + index * 32) == expected.partialValue else {
                        throw WireError.malformed
                    }
                }
                let final = firstEdgeID.addingReportingOverflow(UInt64(edgeCount - 1))
                guard !final.overflow,
                      readUInt64(payload, base + 8) == final.partialValue else {
                    throw WireError.malformed
                }
            }
        case (2, 3):
            try validateVideoFeedback(payload, objectID: objectID)
        case (4, 1):
            try validateAudioPayload(payload, objectID: objectID)
        default:
            throw WireError.unsupportedRoute
        }
    }

    private static func validateInboundPayload(_ message: MediaDatagram) throws {
        switch (message.channel, message.kind) {
        case (1, 2):
            let base = message.payload.startIndex
            guard message.payload.count == 48,
                  message.objectID == readUInt64(message.payload, base + 8),
                  readUInt64(message.payload, base + 40) == 0
            else {
                throw WireError.malformed
            }
        case (1, 3):
            let base = message.payload.startIndex
            guard message.payload.count == 16,
                  (1...3).contains(message.payload[base + 8]),
                  message.payload[(base + 9)..<message.payload.endIndex].allSatisfy({ $0 == 0 })
            else {
                throw WireError.malformed
            }
        case (1, 4):
            try validateControllerFeedback(message)
        case (2, 1):
            try validateVideoFragment(message)
        case (3, 1):
            try validateAudioPayload(message.payload, objectID: message.objectID)
        case (5, 1):
            try validateRTTTelemetry(message)
        default:
            throw WireError.unsupportedRoute
        }
    }

    private static func validateVideoFragment(_ message: MediaDatagram) throws {
        let payload = message.payload
        let base = payload.startIndex
        guard payload.count > 64 else { throw WireError.malformed }
        let frameSize = UInt64(readUInt32(payload, base + 32))
        let fragmentOffset = UInt64(readUInt32(payload, base + 36))
        let fragmentIndex = readUInt16(payload, base + 40)
        let fragmentCount = readUInt16(payload, base + 42)
        let fragmentByteCount = UInt64(payload.count - 64)
        let end = fragmentOffset.addingReportingOverflow(fragmentByteCount)
        let final = message.flags & 0x04 != 0
        guard message.objectID != 0,
              frameSize > 0,
              frameSize <= 64 * 1_048_576,
              fragmentCount > 0,
              fragmentIndex < fragmentCount,
              payload[(base + 44)..<(base + 53)].allSatisfy({ $0 == 0 }),
              payload[(base + 60)..<(base + 64)].allSatisfy({ $0 == 0 }),
              !end.overflow,
              end.partialValue <= frameSize,
              final == (fragmentIndex == fragmentCount - 1),
              final ? end.partialValue == frameSize : end.partialValue < frameSize
        else {
            throw WireError.malformed
        }
    }

    private static func validateControllerFeedback(_ message: MediaDatagram) throws {
        let payload = message.payload
        let base = payload.startIndex
        guard payload.count == 40 else { throw WireError.malformed }
        let inputGeneration = readUInt32(payload, base)
        let controllerGeneration = readUInt32(payload, base + 4)
        let controller = payload[base + 8]
        let command = payload[base + 9]
        let valueLength = Int(readUInt16(payload, base + 10))
        guard inputGeneration != 0,
              message.objectID == UInt64(inputGeneration),
              controllerGeneration != 0,
              controller < 16,
              (1...5).contains(command),
              payload[(base + 36)..<(base + 40)].allSatisfy({ $0 == 0 })
        else {
            throw WireError.malformed
        }
        let expectedLength: Int
        switch command {
        case 1, 2:
            expectedLength = 4
        case 3:
            expectedLength = 4
            guard (1...2).contains(payload[base + 12]),
                  payload[base + 13] == 0,
                  readUInt16(payload, base + 14) <= 2_000 else {
                throw WireError.malformed
            }
        case 4:
            expectedLength = 3
        case 5:
            expectedLength = 24
            guard payload[base + 12] & ~UInt8(0x0C) == 0,
                  payload[base + 15] == 0 else {
                throw WireError.malformed
            }
        default:
            throw WireError.malformed
        }
        guard valueLength == expectedLength,
              payload[(base + 12 + valueLength)..<(base + 36)].allSatisfy({ $0 == 0 }) else {
            throw WireError.malformed
        }
    }

    private static func validateRTTTelemetry(_ message: MediaDatagram) throws {
        let payload = message.payload
        let base = payload.startIndex
        guard payload.count == 24 else { throw WireError.malformed }
        let generation = readUInt64(payload, base)
        let smoothedRTT = readUInt32(payload, base + 8)
        let minimumRTT = readUInt32(payload, base + 12)
        let variation = readUInt32(payload, base + 16)
        guard generation != 0,
              message.semanticSequence == generation,
              message.objectID == generation,
              (1...1_000_000).contains(smoothedRTT),
              (1...smoothedRTT).contains(minimumRTT),
              variation <= 1_000_000,
              readUInt32(payload, base + 20) == 0 else {
            throw WireError.malformed
        }
    }

    private static func validateVideoFeedback(_ payload: Data, objectID: UInt64) throws {
        let base = payload.startIndex
        guard payload.count >= 32 else { throw WireError.malformed }
        let action = payload[base + 16]
        let rangeCount = Int(payload[base + 17])
        let deadlineMissMicroseconds = readUInt32(payload, base + 20)
        guard objectID != 0,
              (1...5).contains(action),
              rangeCount <= 16,
              readUInt16(payload, base + 18) == 0,
              deadlineMissMicroseconds <= 1_000_000,
              action == 1 || action == 3 || deadlineMissMicroseconds == 0,
              readUInt64(payload, base + 24) == 0,
              payload.count == 32 + rangeCount * 4,
              action == 2 || rangeCount == 0
        else {
            throw WireError.malformed
        }
        var previousEnd = 0
        for index in 0..<rangeCount {
            let offset = base + 32 + index * 4
            let first = Int(readUInt16(payload, offset))
            let count = Int(readUInt16(payload, offset + 2))
            guard count > 0, first >= previousEnd else { throw WireError.malformed }
            previousEnd = first + count
            guard previousEnd <= 65_535 else { throw WireError.malformed }
        }
    }

    private static func validateAudioPayload(_ payload: Data, objectID: UInt64) throws {
        let base = payload.startIndex
        guard payload.count >= 48 else { throw WireError.malformed }
        let samplePosition = readUInt64(payload, base + 8)
        let channels = payload[base + 22]
        let flags = payload[base + 25]
        let streamCount = payload[base + 26]
        let coupledCount = payload[base + 27]
        let packetEmpty = payload.count == 48
        guard objectID == samplePosition,
              readUInt16(payload, base + 20) > 0,
              (1...8).contains(channels),
              payload[base + 24] == 1,
              flags & ~UInt8(0x07) == 0,
              streamCount > 0,
              coupledCount <= streamCount,
              payload[(base + 28 + Int(channels))..<(base + 36)].allSatisfy({ $0 == 0xFF }),
              readUInt64(payload, base + 40) == 0,
              !packetEmpty || flags & 0x05 != 0
        else {
            throw WireError.malformed
        }
    }

    private static func outboundRouteAllowed(channel: UInt8, kind: UInt8) -> Bool {
        switch (channel, kind) {
        case (1, 1), (2, 3), (4, 1): true
        default: false
        }
    }

    private static func inboundRouteAllowed(channel: UInt8, kind: UInt8) -> Bool {
        switch (channel, kind) {
        case (1, 2), (1, 3), (1, 4), (2, 1), (3, 1), (5, 1): true
        default: false
        }
    }

    private static func flagsAllowed(channel: UInt8, kind: UInt8, flags: UInt8) -> Bool {
        guard channel == 2, kind == 1 else { return flags == 0 }
        let allowedVideoFlags: UInt8 = 0b0011_0101
        return flags & ~allowedVideoFlags == 0
    }

    static func isEventType(_ type: UInt16, requestID: UInt64) -> Bool {
        type == 0x0132 || type == 0x0133 || (type == 0x0200 && requestID == 0)
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var encoded = value.bigEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        data[offset..<(offset + 2)].reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
    }

    private static func readUInt64(_ data: Data, _ offset: Int) -> UInt64 {
        data[offset..<(offset + 8)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}

final class QUICControlFrameDecoder: @unchecked Sendable {
    private var storage = Data()
    private var cursor = 0

    func append(_ data: Data) throws -> [QUICWireCodec.ControlFrame] {
        guard !data.isEmpty else { return [] }
        guard data.count <= QUICWireCodec.maximumControlPayloadByteCount + QUICWireCodec.controlHeaderByteCount,
              storage.count - cursor <= QUICWireCodec.maximumControlPayloadByteCount +
                QUICWireCodec.controlHeaderByteCount - data.count
        else {
            throw QUICWireCodec.WireError.oversized
        }
        storage.append(data)
        var frames = [QUICWireCodec.ControlFrame]()
        while storage.count - cursor >= QUICWireCodec.controlHeaderByteCount {
            let header = storage[cursor..<(cursor + QUICWireCodec.controlHeaderByteCount)]
            guard header.prefix(4) == Data([0x55, 0x4C, 0x43, 0x33]),
                  header[header.startIndex + 4] == 3,
                  header[header.startIndex + 5] & ~UInt8(0x07) == 0,
                  header[header.startIndex + 5] & 0x02 == 0 ||
                    header[header.startIndex + 5] & 0x01 != 0,
                  header.suffix(4) == Data(repeating: 0, count: 4)
            else {
                throw QUICWireCodec.WireError.malformed
            }
            let type = header[(header.startIndex + 6)..<(header.startIndex + 8)]
                .reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
            let requestID = header[(header.startIndex + 8)..<(header.startIndex + 16)]
                .reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let payloadLength = header[(header.startIndex + 16)..<(header.startIndex + 20)]
                .reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard type != 0,
                  requestID == 0
                    ? (header[header.startIndex + 5] & 0x03 == 0 &&
                        QUICWireCodec.isEventType(type, requestID: requestID))
                    : !QUICWireCodec.isEventType(type, requestID: requestID),
                  payloadLength > 0,
                  payloadLength <= QUICWireCodec.maximumControlPayloadByteCount
            else {
                throw QUICWireCodec.WireError.malformed
            }
            let payloadStart = cursor + QUICWireCodec.controlHeaderByteCount
            let payloadEnd = payloadStart + Int(payloadLength)
            guard payloadEnd <= storage.count else { break }
            frames.append(
                .init(
                    flags: header[header.startIndex + 5],
                    type: type,
                    requestID: requestID,
                    payload: storage[payloadStart..<payloadEnd]
                )
            )
            cursor = payloadEnd
        }
        if cursor == storage.count {
            storage.removeAll(keepingCapacity: true)
            cursor = 0
        } else if cursor >= 64 * 1_024 {
            storage.removeSubrange(0..<cursor)
            cursor = 0
        }
        return frames
    }
}

public final class QUICReceiveSequenceTracker: @unchecked Sendable {
    public enum Verdict: Equatable, Sendable {
        case accepted
        case duplicate
        case staleOrWrapped
    }

    private let lock = NSLock()
    private final class Window {
        var highest: UInt64
        var words: [UInt64]

        init(highest: UInt64, words: [UInt64]) {
            self.highest = highest
            self.words = words
        }
    }
    private var windows = [UInt8: Window]()

    public init() {}

    public func observe(channel: UInt8, sequence: UInt64) -> Verdict {
        observe(channel: channel, sequence: sequence, objectID: nil)
    }

    public func observe(channel: UInt8, sequence: UInt64, objectID: UInt64?) -> Verdict {
        lock.withLock {
            let exhaustionThreshold = UInt64.max - 1_023
            guard sequence != 0, sequence < exhaustionThreshold else { return .staleOrWrapped }
            _ = objectID // Surfaced to the consumer; replay acceptance is sequence-authoritative.
            guard let window = windows[channel] else {
                var words = [UInt64](repeating: 0, count: 16)
                words[0] = 1
                windows[channel] = Window(highest: sequence, words: words)
                return .accepted
            }
            if sequence > window.highest {
                shift(&window.words, by: sequence - window.highest)
                window.highest = sequence
                window.words[0] |= 1
                return .accepted
            }
            let age = window.highest - sequence
            guard age < 1_024 else { return .staleOrWrapped }
            let wordIndex = Int(age / 64)
            let mask = UInt64(1) << UInt64(age % 64)
            guard window.words[wordIndex] & mask == 0 else { return .duplicate }
            window.words[wordIndex] |= mask
            return .accepted
        }
    }

    public func reset() {
        lock.withLock {
            windows.removeAll(keepingCapacity: false)
        }
    }

    func debugWindowStorageAddress(channel: UInt8) -> UInt? {
        lock.withLock {
            windows[channel]?.words.withUnsafeBufferPointer {
                $0.baseAddress.map { UInt(bitPattern: $0) }
            }
        }
    }

    private func shift(_ words: inout [UInt64], by distance: UInt64) {
        guard distance < 1_024 else {
            for index in words.indices { words[index] = 0 }
            return
        }
        let wordShift = Int(distance / 64)
        let bitShift = Int(distance % 64)
        for destination in stride(from: 15, through: 0, by: -1) {
            let source = destination - wordShift
            var value: UInt64 = 0
            if source >= 0 {
                value = words[source] << bitShift
                if bitShift > 0, source > 0 {
                    value |= words[source - 1] >> (64 - bitShift)
                }
            }
            words[destination] = value
        }
    }
}

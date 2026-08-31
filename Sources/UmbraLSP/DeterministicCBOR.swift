import Foundation

enum DeterministicCBORError: Error, Equatable {
    case malformed
    case nonCanonical
    case unsupported
    case resourceLimit
}

indirect enum DeterministicCBORValue: Equatable {
    case unsigned(UInt64)
    case bytes(Data)
    case text(String)
    case boolean(Bool)
    case null
    case array([DeterministicCBORValue])
    case map([DeterministicCBORPair])
}

struct DeterministicCBORPair: Equatable {
    var key: UInt64
    var value: DeterministicCBORValue
}

enum DeterministicCBOR {
    static func encode(_ value: DeterministicCBORValue) throws -> Data {
        var output = Data()
        try append(value, to: &output, depth: 0)
        guard output.count <= 1_152 else {
            throw DeterministicCBORError.resourceLimit
        }
        return output
    }

    static func decode(_ data: Data) throws -> DeterministicCBORValue {
        guard data.count <= 1_152 else {
            throw DeterministicCBORError.resourceLimit
        }
        var cursor = 0
        let value = try parse(data, cursor: &cursor, depth: 0)
        guard cursor == data.count else {
            throw DeterministicCBORError.malformed
        }
        guard try encode(value) == data else {
            throw DeterministicCBORError.nonCanonical
        }
        return value
    }

    static func exactMap(
        _ value: DeterministicCBORValue,
        count: Int
    ) throws -> [DeterministicCBORValue] {
        guard case .map(let pairs) = value, pairs.count == count else {
            throw DeterministicCBORError.malformed
        }
        for (index, pair) in pairs.enumerated() where pair.key != UInt64(index + 1) {
            throw DeterministicCBORError.malformed
        }
        return pairs.map(\.value)
    }

    private static func append(
        _ value: DeterministicCBORValue,
        to output: inout Data,
        depth: Int
    ) throws {
        guard depth <= 3 else {
            throw DeterministicCBORError.resourceLimit
        }
        switch value {
        case .unsigned(let integer):
            appendArgument(integer, major: 0, to: &output)
        case .bytes(let bytes):
            guard bytes.count <= 1_024 else { throw DeterministicCBORError.resourceLimit }
            appendArgument(UInt64(bytes.count), major: 2, to: &output)
            output.append(bytes)
        case .text(let text):
            let bytes = Data(text.utf8)
            guard bytes.count <= 512 else { throw DeterministicCBORError.resourceLimit }
            appendArgument(UInt64(bytes.count), major: 3, to: &output)
            output.append(bytes)
        case .boolean(let value):
            output.append(value ? 0xF5 : 0xF4)
        case .null:
            output.append(0xF6)
        case .array(let values):
            guard values.count <= 64 else { throw DeterministicCBORError.resourceLimit }
            appendArgument(UInt64(values.count), major: 4, to: &output)
            for value in values {
                try append(value, to: &output, depth: depth + 1)
            }
        case .map(let pairs):
            guard pairs.count <= 32 else { throw DeterministicCBORError.resourceLimit }
            for index in pairs.indices where index > 0 && pairs[index - 1].key >= pairs[index].key {
                throw DeterministicCBORError.nonCanonical
            }
            appendArgument(UInt64(pairs.count), major: 5, to: &output)
            for pair in pairs {
                appendArgument(pair.key, major: 0, to: &output)
                try append(pair.value, to: &output, depth: depth + 1)
            }
        }
    }

    private static func appendArgument(_ argument: UInt64, major: UInt8, to output: inout Data) {
        let prefix = major << 5
        switch argument {
        case 0..<24:
            output.append(prefix | UInt8(argument))
        case 24...UInt64(UInt8.max):
            output.append(prefix | 24)
            output.append(UInt8(argument))
        case 256...UInt64(UInt16.max):
            output.append(prefix | 25)
            appendBigEndian(UInt16(argument), to: &output)
        case 65_536...UInt64(UInt32.max):
            output.append(prefix | 26)
            appendBigEndian(UInt32(argument), to: &output)
        default:
            output.append(prefix | 27)
            appendBigEndian(argument, to: &output)
        }
    }

    private static func appendBigEndian<T: FixedWidthInteger>(_ value: T, to output: inout Data) {
        var encoded = value.bigEndian
        withUnsafeBytes(of: &encoded) { output.append(contentsOf: $0) }
    }

    private static func parse(
        _ data: Data,
        cursor: inout Int,
        depth: Int
    ) throws -> DeterministicCBORValue {
        guard depth <= 3, cursor < data.count else {
            throw DeterministicCBORError.malformed
        }
        let initial = data[cursor]
        cursor += 1
        let major = initial >> 5
        let additional = initial & 0x1F
        if major == 7 {
            if additional == 20 { return .boolean(false) }
            if additional == 21 { return .boolean(true) }
            if additional == 22 { return .null }
            throw DeterministicCBORError.unsupported
        }
        let argument = try parseArgument(additional, data: data, cursor: &cursor)
        switch major {
        case 0:
            return .unsigned(argument)
        case 2:
            let bytes = try slice(data, cursor: &cursor, count: argument, maximum: 1_024)
            return .bytes(bytes)
        case 3:
            let bytes = try slice(data, cursor: &cursor, count: argument, maximum: 512)
            guard let text = String(data: bytes, encoding: .utf8), Data(text.utf8) == bytes else {
                throw DeterministicCBORError.malformed
            }
            return .text(text)
        case 4:
            guard argument <= 64 else { throw DeterministicCBORError.resourceLimit }
            var values: [DeterministicCBORValue] = []
            values.reserveCapacity(Int(argument))
            for _ in 0..<argument {
                values.append(try parse(data, cursor: &cursor, depth: depth + 1))
            }
            return .array(values)
        case 5:
            guard argument <= 32 else { throw DeterministicCBORError.resourceLimit }
            var pairs: [DeterministicCBORPair] = []
            pairs.reserveCapacity(Int(argument))
            for _ in 0..<argument {
                let keyValue = try parse(data, cursor: &cursor, depth: depth + 1)
                guard case .unsigned(let key) = keyValue,
                      pairs.last.map({ $0.key < key }) ?? true
                else {
                    throw DeterministicCBORError.nonCanonical
                }
                pairs.append(.init(key: key, value: try parse(data, cursor: &cursor, depth: depth + 1)))
            }
            return .map(pairs)
        default:
            throw DeterministicCBORError.unsupported
        }
    }

    private static func parseArgument(
        _ additional: UInt8,
        data: Data,
        cursor: inout Int
    ) throws -> UInt64 {
        switch additional {
        case 0..<24:
            return UInt64(additional)
        case 24:
            let value = try read(data, cursor: &cursor, as: UInt8.self)
            guard value >= 24 else { throw DeterministicCBORError.nonCanonical }
            return UInt64(value)
        case 25:
            let value = try read(data, cursor: &cursor, as: UInt16.self)
            guard value > UInt8.max else { throw DeterministicCBORError.nonCanonical }
            return UInt64(value)
        case 26:
            let value = try read(data, cursor: &cursor, as: UInt32.self)
            guard value > UInt16.max else { throw DeterministicCBORError.nonCanonical }
            return UInt64(value)
        case 27:
            let value = try read(data, cursor: &cursor, as: UInt64.self)
            guard value > UInt32.max else { throw DeterministicCBORError.nonCanonical }
            return value
        default:
            throw DeterministicCBORError.unsupported
        }
    }

    private static func read<T: FixedWidthInteger>(
        _ data: Data,
        cursor: inout Int,
        as type: T.Type
    ) throws -> T {
        let byteCount = MemoryLayout<T>.size
        guard cursor <= data.count - byteCount else { throw DeterministicCBORError.malformed }
        var value: T = 0
        for _ in 0..<byteCount {
            value = (value << 8) | T(data[cursor])
            cursor += 1
        }
        return value
    }

    private static func slice(
        _ data: Data,
        cursor: inout Int,
        count: UInt64,
        maximum: Int
    ) throws -> Data {
        guard count <= UInt64(maximum), count <= UInt64(Int.max) else {
            throw DeterministicCBORError.resourceLimit
        }
        let length = Int(count)
        guard cursor <= data.count - length else { throw DeterministicCBORError.malformed }
        defer { cursor += length }
        return data.subdata(in: cursor..<(cursor + length))
    }
}

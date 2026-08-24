import Foundation

public enum ProtocolV3WireError: Error, Equatable, Sendable {
    case invalidField(String)
    case malformed
    case sizeLimit
    case cryptography
}

public indirect enum ProtocolV3CBORValue: Equatable, Sendable {
    case unsigned(UInt64)
    case negative(UInt64)
    case bytes(Data)
    case text(String)
    case array([Self])
    case map([UInt64: Self])
    case boolean(Bool)
    case null

    public var unsignedValue: UInt64? { if case let .unsigned(value) = self { value } else { nil } }
    public var bytesValue: Data? { if case let .bytes(value) = self { value } else { nil } }
    public var textValue: String? { if case let .text(value) = self { value } else { nil } }
    public var arrayValue: [Self]? { if case let .array(value) = self { value } else { nil } }
    public var mapValue: [UInt64: Self]? { if case let .map(value) = self { value } else { nil } }
    public var booleanValue: Bool? { if case let .boolean(value) = self { value } else { nil } }
}

public struct ProtocolV3CBORCodec: Sendable {
    public init() {}

    public func encode(_ value: ProtocolV3CBORValue) throws -> Data {
        var output = Data()
        try encode(value, depth: 0, output: &output)
        guard output.count <= 1_048_576 else { throw ProtocolV3WireError.sizeLimit }
        return output
    }

    public func decode(_ data: Data) throws -> ProtocolV3CBORValue {
        guard !data.isEmpty, data.count <= 1_048_576 else { throw ProtocolV3WireError.sizeLimit }
        var cursor = data.startIndex
        let value = try decode(data, cursor: &cursor, depth: 0)
        guard cursor == data.endIndex, try encode(value) == data else { throw ProtocolV3WireError.malformed }
        return value
    }

    private func encode(_ value: ProtocolV3CBORValue, depth: Int, output: inout Data) throws {
        guard output.count <= 1_048_576 else { throw ProtocolV3WireError.sizeLimit }
        switch value {
        case let .unsigned(number): appendHead(major: 0, value: number, output: &output)
        case let .negative(argument): appendHead(major: 1, value: argument, output: &output)
        case let .bytes(bytes):
            guard bytes.count <= 1_048_576 else { throw ProtocolV3WireError.sizeLimit }
            appendHead(major: 2, value: UInt64(bytes.count), output: &output); output.append(bytes)
        case let .text(text):
            guard text.utf8.count <= 65_535 else { throw ProtocolV3WireError.sizeLimit }
            appendHead(major: 3, value: UInt64(text.utf8.count), output: &output); output.append(contentsOf: text.utf8)
        case let .array(values):
            guard depth < 8, values.count <= 4_096 else { throw ProtocolV3WireError.sizeLimit }
            appendHead(major: 4, value: UInt64(values.count), output: &output)
            for value in values { try encode(value, depth: depth + 1, output: &output) }
        case let .map(values):
            guard depth < 8, values.count <= 128 else { throw ProtocolV3WireError.sizeLimit }
            appendHead(major: 5, value: UInt64(values.count), output: &output)
            for key in values.keys.sorted() {
                appendHead(major: 0, value: key, output: &output)
                try encode(values[key]!, depth: depth + 1, output: &output)
            }
        case let .boolean(value): output.append(value ? 0xf5 : 0xf4)
        case .null: output.append(0xf6)
        }
    }

    private func decode(_ data: Data, cursor: inout Int, depth: Int) throws -> ProtocolV3CBORValue {
        let (major, argument) = try head(data, cursor: &cursor)
        switch major {
        case 0: return .unsigned(argument)
        case 1: return .negative(argument)
        case 2:
            let count = try bounded(argument, maximum: 1_048_576)
            return .bytes(try take(data, cursor: &cursor, count: count))
        case 3:
            let count = try bounded(argument, maximum: 65_535)
            guard let text = String(data: try take(data, cursor: &cursor, count: count), encoding: .utf8) else {
                throw ProtocolV3WireError.malformed
            }
            return .text(text)
        case 4:
            guard depth < 8 else { throw ProtocolV3WireError.sizeLimit }
            let count = try bounded(argument, maximum: 4_096)
            return .array(try (0..<count).map { _ in try decode(data, cursor: &cursor, depth: depth + 1) })
        case 5:
            guard depth < 8 else { throw ProtocolV3WireError.sizeLimit }
            let count = try bounded(argument, maximum: 128)
            var map: [UInt64: ProtocolV3CBORValue] = [:]
            var priorKey: UInt64?
            for _ in 0..<count {
                let (keyMajor, key) = try head(data, cursor: &cursor)
                guard keyMajor == 0, priorKey.map({ key > $0 }) ?? true else { throw ProtocolV3WireError.malformed }
                priorKey = key
                map[key] = try decode(data, cursor: &cursor, depth: depth + 1)
            }
            return .map(map)
        case 7 where argument == 20: return .boolean(false)
        case 7 where argument == 21: return .boolean(true)
        case 7 where argument == 22: return .null
        default: throw ProtocolV3WireError.malformed
        }
    }

    private func head(_ data: Data, cursor: inout Int) throws -> (UInt8, UInt64) {
        guard cursor < data.endIndex else { throw ProtocolV3WireError.malformed }
        let first = data[cursor]; cursor += 1
        let major = first >> 5
        let additional = first & 0x1f
        if additional < 24 { return (major, UInt64(additional)) }
        let count: Int
        switch additional { case 24: count = 1; case 25: count = 2; case 26: count = 4; case 27: count = 8; default: throw ProtocolV3WireError.malformed }
        let bytes = try take(data, cursor: &cursor, count: count)
        let value = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let minimum: UInt64 = switch count { case 1: 24; case 2: 256; case 4: 65_536; default: 4_294_967_296 }
        guard value >= minimum else { throw ProtocolV3WireError.malformed }
        return (major, value)
    }

    private func appendHead(major: UInt8, value: UInt64, output: inout Data) {
        let prefix = major << 5
        switch value {
        case 0..<24: output.append(prefix | UInt8(value))
        case 24...UInt64(UInt8.max): output.append(prefix | 24); output.append(UInt8(value))
        case 256...UInt64(UInt16.max): output.append(prefix | 25); append(UInt16(value), output: &output)
        case 65_536...UInt64(UInt32.max): output.append(prefix | 26); append(UInt32(value), output: &output)
        default: output.append(prefix | 27); append(value, output: &output)
        }
    }

    private func append<T: FixedWidthInteger>(_ value: T, output: inout Data) {
        var encoded = value.bigEndian
        withUnsafeBytes(of: &encoded) { output.append(contentsOf: $0) }
    }

    private func take(_ data: Data, cursor: inout Int, count: Int) throws -> Data {
        guard count >= 0, cursor <= data.endIndex - count else { throw ProtocolV3WireError.malformed }
        defer { cursor += count }
        return data[cursor..<(cursor + count)]
    }

    private func bounded(_ value: UInt64, maximum: Int) throws -> Int {
        guard value <= UInt64(maximum), let count = Int(exactly: value) else { throw ProtocolV3WireError.sizeLimit }
        return count
    }
}

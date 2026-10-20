import Darwin
import Dispatch
import Foundation
import UmbraServices

public protocol RichPresenceManaging: Sendable {
    /// Enqueues a presence update and returns without waiting for Discord.
    func update(applicationName: String, startedAt: Date)
    /// Enqueues a presence clear and returns without waiting for Discord.
    func clear()
}

enum DiscordIPCOpcode: UInt32 {
    case handshake = 0
    case frame = 1
}

enum DiscordIPCFrame {
    static func encode(opcode: DiscordIPCOpcode, payload: [String: Any]) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        var encodedOpcode = opcode.rawValue.littleEndian
        var encodedLength = UInt32(json.count).littleEndian
        var frame = Data(bytes: &encodedOpcode, count: MemoryLayout<UInt32>.size)
        frame.append(Data(bytes: &encodedLength, count: MemoryLayout<UInt32>.size))
        frame.append(json)
        return frame
    }
}

protocol DiscordIPCTransporting: Sendable {
    func send(frames: [Data]) throws
}

struct UnixDiscordIPCTransport: DiscordIPCTransporting, Sendable {
    let environment: [String: String]
    let temporaryDirectory: String
    let homeDirectory: String

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        temporaryDirectory: String = NSTemporaryDirectory(),
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) {
        self.environment = environment
        self.temporaryDirectory = temporaryDirectory
        self.homeDirectory = homeDirectory
    }

    func send(frames: [Data]) throws {
        let descriptor = try connectToDiscord()
        defer { Darwin.close(descriptor) }
        for (index, frame) in frames.enumerated() {
            try writeAll(frame, to: descriptor)
            if index == 0 {
                // Discord acknowledges the handshake with a READY dispatch. Waiting on
                // this background queue avoids racing SET_ACTIVITY ahead of that state.
                try readReadyFrame(from: descriptor)
            }
        }
    }

    func candidateSocketPaths() -> [String] {
        var directories = [
            environment["XDG_RUNTIME_DIR"],
            environment["TMPDIR"],
            environment["TMP"],
            environment["TEMP"],
            temporaryDirectory,
            "/tmp",
            "\(homeDirectory)/Library/Application Support/discord",
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        var seen = Set<String>()
        directories = directories.filter { !$0.isEmpty && seen.insert($0).inserted }
        return directories.flatMap { directory in
            (0..<10).map { "\(directory)/discord-ipc-\($0)" }
        }
    }

    private func connectToDiscord() throws -> Int32 {
        for path in candidateSocketPaths() where FileManager.default.fileExists(atPath: path) {
            if let descriptor = connect(path: path) { return descriptor }
        }
        throw POSIXError(.ENOENT)
    }

    private func connect(path: String) -> Int32? {
        let pathBytes = Array(path.utf8CString)
        var address = sockaddr_un()
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }

        var noSignal: Int32 = 1
        _ = withUnsafePointer(to: &noSignal) {
            Darwin.setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                $0,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
        var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
        _ = withUnsafePointer(to: &timeout) {
            Darwin.setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_SNDTIMEO,
                $0,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        _ = withUnsafePointer(to: &timeout) {
            Darwin.setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_RCVTIMEO,
                $0,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }

        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &address.sun_path) { tuplePointer in
            tuplePointer.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { destination in
                pathBytes.withUnsafeBufferPointer { source in
                    destination.initialize(from: source.baseAddress!, count: source.count)
                }
            }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        return descriptor
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
    }

    private func readReadyFrame(from descriptor: Int32) throws {
        let header = try read(count: 8, from: descriptor)
        let opcode = Self.decodeUInt32(header.prefix(4))
        let payloadLength = Self.decodeUInt32(header.dropFirst(4))
        guard opcode == DiscordIPCOpcode.frame.rawValue, payloadLength <= 1_048_576 else {
            throw POSIXError(.EPROTO)
        }
        _ = try read(count: Int(payloadLength), from: descriptor)
    }

    private func read(count: Int, from descriptor: Int32) throws -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < count {
                let received = Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    count - offset
                )
                if received > 0 {
                    offset += received
                } else if received < 0, errno == EINTR {
                    continue
                } else if received == 0 {
                    throw POSIXError(.ECONNRESET)
                } else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
        return data
    }

    private static func decodeUInt32<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        bytes.prefix(4).enumerated().reduce(UInt32.zero) { result, pair in
            result | (UInt32(pair.element) << UInt32(pair.offset * 8))
        }
    }
}

/// Local Discord IPC integration. It never starts Discord, performs network
/// requests, or reads user/account data. Failures are intentionally discarded.
public final class DiscordRichPresenceService: RichPresenceManaging, @unchecked Sendable {
    /// The application ID used by the client's upstream Rich Presence integration.
    public static let gameStreamApplicationID = "594668102021677159"

    private let clientID: String
    private let transport: any DiscordIPCTransporting
    private let queue = DispatchQueue(label: "app.umbra.discord-rich-presence", qos: .utility)

    public convenience init(clientID: String = gameStreamApplicationID) {
        self.init(clientID: clientID, transport: UnixDiscordIPCTransport())
    }

    init(clientID: String, transport: any DiscordIPCTransporting) {
        self.clientID = clientID
        self.transport = transport
    }

    public func update(applicationName: String, startedAt: Date = Date()) {
        let name = Self.normalizedApplicationName(applicationName)
        guard !name.isEmpty else { return }
        queue.async { [clientID, transport] in
            let handshake: [String: Any] = ["v": 1, "client_id": clientID]
            let activity: [String: Any] = [
                "details": "Streaming \(name)",
                "state": "Remote game stream",
                "timestamps": ["start": Int64(startedAt.timeIntervalSince1970)],
            ]
            let command: [String: Any] = [
                "cmd": "SET_ACTIVITY",
                "args": [
                    "pid": ProcessInfo.processInfo.processIdentifier,
                    "activity": activity,
                ],
                "nonce": UUID().uuidString,
            ]
            guard let frames = try? [
                DiscordIPCFrame.encode(opcode: .handshake, payload: handshake),
                DiscordIPCFrame.encode(opcode: .frame, payload: command),
            ] else { return }
            try? transport.send(frames: frames)
        }
    }

    public func clear() {
        queue.async { [clientID, transport] in
            let handshake: [String: Any] = ["v": 1, "client_id": clientID]
            let command: [String: Any] = [
                "cmd": "SET_ACTIVITY",
                "args": [
                    "pid": ProcessInfo.processInfo.processIdentifier,
                    "activity": NSNull(),
                ],
                "nonce": UUID().uuidString,
            ]
            guard let frames = try? [
                DiscordIPCFrame.encode(opcode: .handshake, payload: handshake),
                DiscordIPCFrame.encode(opcode: .frame, payload: command),
            ] else { return }
            try? transport.send(frames: frames)
        }
    }

    func waitForPendingOperations() {
        queue.sync {}
    }

    private static func normalizedApplicationName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(110))
    }
}

/// Adapts Rich Presence to the stream lifecycle and guarantees that a disabled
/// preference never opens a Discord IPC socket.
public actor DiscordRichPresenceLifecycleCoordinator: StreamSessionLifecycleCoordinating {
    private let presence: any RichPresenceManaging
    private var active = false

    public init(presence: any RichPresenceManaging = DiscordRichPresenceService()) {
        self.presence = presence
    }

    public func prepare(for bootstrap: StreamBootstrap) async throws {
    }

    public func commitStreaming(for bootstrap: StreamBootstrap) async {
        guard bootstrap.preferences.richPresence else { return }
        presence.update(applicationName: bootstrap.application.name, startedAt: Date())
        active = true
    }

    public func finishPresentation() async {
        guard active else { return }
        active = false
        presence.clear()
    }

    public func finish() async {}
}

/// Runs lifecycle components in order and unwinds already-prepared components
/// if a later component fails.
public struct CompositeStreamSessionLifecycleCoordinator: StreamSessionLifecycleCoordinating, Sendable {
    private let coordinators: [any StreamSessionLifecycleCoordinating]

    public init(_ coordinators: [any StreamSessionLifecycleCoordinating]) {
        self.coordinators = coordinators
    }

    public func prepare(for bootstrap: StreamBootstrap) async throws {
        var prepared: [any StreamSessionLifecycleCoordinating] = []
        do {
            for coordinator in coordinators {
                try await coordinator.prepare(for: bootstrap)
                prepared.append(coordinator)
            }
        } catch {
            // The driver still owns native close and final media/resource cleanup.
            for coordinator in prepared.reversed() {
                await coordinator.finishPresentation()
            }
            throw error
        }
    }

    public func finishPresentation() async {
        for coordinator in coordinators.reversed() {
            await coordinator.finishPresentation()
        }
    }

    public func updatePreparation(for bootstrap: StreamBootstrap) async throws {
        for coordinator in coordinators {
            try await coordinator.updatePreparation(for: bootstrap)
        }
    }

    public func commitStreaming(for bootstrap: StreamBootstrap) async {
        for coordinator in coordinators {
            await coordinator.commitStreaming(for: bootstrap)
        }
    }

    public func finish() async {
        for coordinator in coordinators.reversed() {
            await coordinator.finish()
        }
    }
}

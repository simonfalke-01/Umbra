import Darwin
import Foundation
import UmbraCLIExecution

enum LSPCLIOwnerCommand: String, Codable, Sendable {
    case attach
    case stop
    case quit
    case telemetry
}

struct LSPCLIOwnerRequest: Codable, Sendable {
    var command: LSPCLIOwnerCommand
    var hostID: UUID
}

struct LSPCLIOwnerResponse: Codable, Sendable {
    var error: String?
    var stopKind: String?
    var telemetry: LSPCLIOwnerTelemetry?
}

struct LSPCLIOwnerTelemetry: Codable, Sendable {
    var lifecycle: String
    var receivedDatagrams: UInt64
    var transmittedDatagrams: UInt64
    var droppedDatagrams: UInt64
    var authenticationFailures: UInt64
    var currentUDPPayloadSize: UInt16
    var reconnectPhase: String?
}

enum LSPCLIOwnerIPCError: Error, LocalizedError {
    case unavailable
    case insecureEndpoint
    case invalidMessage
    case remote(String)
    case system(Int32)

    var errorDescription: String? {
        switch self {
        case .unavailable: "The long-lived LSP owner is not running."
        case .insecureEndpoint: "The LSP owner endpoint failed same-user permission validation."
        case .invalidMessage: "The LSP owner returned an invalid bounded response."
        case .remote(let message): message
        case .system(let code): "Local LSP owner IPC failed with errno \(code)."
        }
    }
}

final class LSPCLIOwnerEndpoint: @unchecked Sendable {
    typealias Handler = @Sendable (LSPCLIOwnerRequest) async -> LSPCLIOwnerResponse
    typealias ResponseSentHandler = @Sendable (
        LSPCLIOwnerRequest,
        LSPCLIOwnerResponse
    ) async -> Void

    private let path: String
    private let descriptor: Int32
    private let handler: Handler
    private let task: Task<Void, Never>
    private let lock = NSLock()
    private var stopped = false

    init(
        hostID: UUID,
        handler: @escaping Handler,
        responseSentHandler: ResponseSentHandler? = nil
    ) throws {
        path = try Self.endpointPath(hostID: hostID, createParent: true)
        self.handler = handler
        descriptor = try Self.makeListener(path: path)
        task = Task.detached(priority: .utility) {
            [path, descriptor, handler, responseSentHandler] in
            while !Task.isCancelled {
                let client = Darwin.accept(descriptor, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    return
                }
                await Self.serve(
                    client: client,
                    expectedHostID: hostID,
                    handler: handler,
                    responseSentHandler: responseSentHandler
                )
            }
            _ = unlink(path)
        }
    }

    deinit { stop() }

    func stop() {
        let shouldStop = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            stopped = true
            return true
        }
        guard shouldStop else { return }
        task.cancel()
        _ = Darwin.shutdown(descriptor, SHUT_RDWR)
        _ = Darwin.close(descriptor)
        _ = unlink(path)
    }

    static func request(hostID: UUID, command: LSPCLIOwnerCommand) async throws -> LSPCLIOwnerResponse {
        try await Task.detached(priority: .userInitiated) {
            let path = try endpointPath(hostID: hostID, createParent: false)
            try validateSocket(path)
            let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw LSPCLIOwnerIPCError.system(errno) }
            defer { _ = Darwin.close(descriptor) }
            var address = try unixAddress(path)
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connected == 0 else {
                throw errno == ENOENT || errno == ECONNREFUSED
                    ? LSPCLIOwnerIPCError.unavailable : LSPCLIOwnerIPCError.system(errno)
            }
            let request = try JSONEncoder().encode(LSPCLIOwnerRequest(command: command, hostID: hostID))
            try writeAll(request, descriptor: descriptor)
            _ = Darwin.shutdown(descriptor, SHUT_WR)
            let response = try readBounded(descriptor: descriptor)
            return try JSONDecoder().decode(LSPCLIOwnerResponse.self, from: response)
        }.value
    }

    static func endpointExists(hostID: UUID) -> Bool {
        guard let path = try? endpointPath(hostID: hostID, createParent: false) else { return false }
        return (try? validateSocket(path)) != nil
    }

    private static func serve(
        client: Int32,
        expectedHostID: UUID,
        handler: Handler,
        responseSentHandler: ResponseSentHandler?
    ) async {
        defer { _ = Darwin.close(client) }
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(client, &peerUID, &peerGID) == 0, peerUID == geteuid() else { return }
        do {
            let data = try readBounded(descriptor: client)
            let request = try JSONDecoder().decode(LSPCLIOwnerRequest.self, from: data)
            guard request.hostID == expectedHostID else { throw LSPCLIOwnerIPCError.invalidMessage }
            let response = await handler(request)
            try writeAll(try JSONEncoder().encode(response), descriptor: client)
            guard Darwin.shutdown(client, SHUT_WR) == 0 else {
                throw LSPCLIOwnerIPCError.system(errno)
            }
            await responseSentHandler?(request, response)
        } catch {
            let response = LSPCLIOwnerResponse(error: error.localizedDescription, stopKind: nil, telemetry: nil)
            if let data = try? JSONEncoder().encode(response) { try? writeAll(data, descriptor: client) }
        }
    }

    private static func makeListener(path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw LSPCLIOwnerIPCError.system(errno) }
        do {
            if FileManager.default.fileExists(atPath: path) {
                try validateOwnedPath(path, requireSocket: true)
                _ = unlink(path)
            }
            var address = try unixAddress(path)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw LSPCLIOwnerIPCError.system(errno) }
            guard chmod(path, S_IRUSR | S_IWUSR) == 0 else { throw LSPCLIOwnerIPCError.system(errno) }
            guard Darwin.listen(descriptor, 4) == 0 else { throw LSPCLIOwnerIPCError.system(errno) }
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            _ = unlink(path)
            throw error
        }
    }

    private static func endpointPath(hostID: UUID, createParent: Bool) throws -> String {
        let parent = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("umbra-lsp-owner-\(geteuid())", isDirectory: true)
        if createParent {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            guard chmod(parent.path, S_IRWXU) == 0 else { throw LSPCLIOwnerIPCError.system(errno) }
        }
        try validateOwnedPath(parent.path, requireSocket: false)
        return parent.appendingPathComponent("\(hostID.uuidString.lowercased()).sock").path
    }

    private static func validateSocket(_ path: String) throws {
        try validateOwnedPath(path, requireSocket: true)
        var status = stat()
        guard lstat(path, &status) == 0,
              status.st_uid == geteuid(),
              status.st_mode & 0o077 == 0 else {
            throw errno == ENOENT ? LSPCLIOwnerIPCError.unavailable : LSPCLIOwnerIPCError.insecureEndpoint
        }
    }

    private static func validateOwnedPath(_ path: String, requireSocket: Bool) throws {
        var status = stat()
        guard lstat(path, &status) == 0 else {
            throw errno == ENOENT ? LSPCLIOwnerIPCError.unavailable : LSPCLIOwnerIPCError.system(errno)
        }
        let kind = status.st_mode & S_IFMT
        guard status.st_uid == geteuid(),
              (requireSocket ? kind == S_IFSOCK : kind == S_IFDIR),
              status.st_mode & 0o077 == 0 else {
            throw LSPCLIOwnerIPCError.insecureEndpoint
        }
    }

    private static func unixAddress(_ path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8)
        var address = sockaddr_un()
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw LSPCLIOwnerIPCError.invalidMessage
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            destination.copyBytes(from: bytes)
        }
        return address
    }

    private static func readBounded(descriptor: Int32) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { return result }
            if count < 0 {
                if errno == EINTR { continue }
                throw LSPCLIOwnerIPCError.system(errno)
            }
            guard result.count + count <= 4_096 else { throw LSPCLIOwnerIPCError.invalidMessage }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw LSPCLIOwnerIPCError.system(errno)
                }
                offset += written
            }
        }
    }
}

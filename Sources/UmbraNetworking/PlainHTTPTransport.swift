@preconcurrency import Foundation
import Darwin

/// A deliberately small HTTP/1 client for GameStream's unauthenticated plain-HTTP phase.
///
/// App Transport Security correctly rejects arbitrary cleartext URLSession loads. GameStream,
/// however, requires a plain `/serverinfo` discovery request before a host certificate exists.
/// This transport keeps that compatibility exception out of ATS: it accepts only explicit GET
/// requests, never follows redirects, never consults proxies or cookie stores, and closes every
/// connection after one bounded response. HTTPS must continue to use `URLSessionTransport`.
public struct BoundedPlainHTTPTransport: HTTPTransport, Sendable {
    public struct Limits: Equatable, Sendable {
        public var maximumHeaderBytes: Int
        public var maximumRequestBytes: Int
        public var defaultMaximumBodyBytes: Int
        public var serverInfoMaximumBodyBytes: Int
        public var applicationListMaximumBodyBytes: Int
        public var applicationAssetMaximumBodyBytes: Int
        public var pairingMaximumBodyBytes: Int
        public var maximumConnectDuration: TimeInterval
        public var maximumWriteDuration: TimeInterval
        public var maximumReadDuration: TimeInterval
        public var maximumTotalDuration: TimeInterval

        public init(
            maximumHeaderBytes: Int = 32 * 1_024,
            maximumRequestBytes: Int = 64 * 1_024,
            defaultMaximumBodyBytes: Int = 1 * 1_024 * 1_024,
            serverInfoMaximumBodyBytes: Int = 512 * 1_024,
            applicationListMaximumBodyBytes: Int = 4 * 1_024 * 1_024,
            applicationAssetMaximumBodyBytes: Int = 16 * 1_024 * 1_024,
            pairingMaximumBodyBytes: Int = 512 * 1_024,
            maximumConnectDuration: TimeInterval = 3,
            maximumWriteDuration: TimeInterval = 2,
            maximumReadDuration: TimeInterval = 24 * 60 * 60,
            maximumTotalDuration: TimeInterval = 24 * 60 * 60
        ) {
            self.maximumHeaderBytes = maximumHeaderBytes
            self.maximumRequestBytes = maximumRequestBytes
            self.defaultMaximumBodyBytes = defaultMaximumBodyBytes
            self.serverInfoMaximumBodyBytes = serverInfoMaximumBodyBytes
            self.applicationListMaximumBodyBytes = applicationListMaximumBodyBytes
            self.applicationAssetMaximumBodyBytes = applicationAssetMaximumBodyBytes
            self.pairingMaximumBodyBytes = pairingMaximumBodyBytes
            self.maximumConnectDuration = maximumConnectDuration
            self.maximumWriteDuration = maximumWriteDuration
            self.maximumReadDuration = maximumReadDuration
            self.maximumTotalDuration = maximumTotalDuration
        }

        fileprivate func validate() throws {
            guard maximumHeaderBytes >= 1_024,
                  maximumRequestBytes >= 1_024,
                  defaultMaximumBodyBytes >= 0,
                  serverInfoMaximumBodyBytes >= 0,
                  applicationListMaximumBodyBytes >= 0,
                  applicationAssetMaximumBodyBytes >= 0,
                  pairingMaximumBodyBytes >= 0,
                  maximumConnectDuration > 0,
                  maximumWriteDuration > 0,
                  maximumReadDuration > 0,
                  maximumTotalDuration > 0,
                  maximumConnectDuration.isFinite,
                  maximumWriteDuration.isFinite,
                  maximumReadDuration.isFinite,
                  maximumTotalDuration.isFinite
            else {
                throw UmbraNetworkingError.invalidRequest("plain HTTP transport limits are invalid")
            }
        }

        fileprivate func maximumBodyBytes(for path: String) -> Int {
            switch path.lowercased() {
            case "/serverinfo": serverInfoMaximumBodyBytes
            case "/applist": applicationListMaximumBodyBytes
            case "/appasset": applicationAssetMaximumBodyBytes
            case "/pair", "/unpair": pairingMaximumBodyBytes
            default: defaultMaximumBodyBytes
            }
        }
    }

    private let limits: Limits

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try limits.validate()
        let prepared = try PreparedPlainHTTPRequest(request: request, limits: limits)
        let operation = try PlainHTTPConnection(prepared: prepared)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try operation.run() })
                }
            }
        } onCancel: {
            operation.cancel()
        }
    }
}

/// Routes only cleartext GameStream requests to the bounded POSIX transport. The secure leg is
/// supplied by the caller so exact certificate pinning and client-certificate authentication stay
/// on the existing URLSession implementation.
public struct SchemeSelectingHTTPTransport: HTTPTransport, Sendable {
    private let plainTransport: any HTTPTransport
    private let secureTransport: any HTTPTransport

    public init(
        plainTransport: any HTTPTransport = BoundedPlainHTTPTransport(),
        secureTransport: any HTTPTransport
    ) {
        self.plainTransport = plainTransport
        self.secureTransport = secureTransport
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        switch request.url?.scheme?.lowercased() {
        case "http":
            try await plainTransport.data(for: request)
        case "https":
            try await secureTransport.data(for: request)
        default:
            throw UmbraNetworkingError.invalidRequest("HTTP transport requires an explicit http or https URL")
        }
    }
}

private struct PreparedPlainHTTPRequest: Sendable {
    let url: URL
    let address: HostAddress
    let serializedRequest: Data
    let maximumHeaderBytes: Int
    let maximumBodyBytes: Int
    let connectDuration: TimeInterval
    let writeDuration: TimeInterval
    let readDuration: TimeInterval
    let totalDuration: TimeInterval

    init(request: URLRequest, limits: BoundedPlainHTTPTransport.Limits) throws {
        guard request.httpMethod?.uppercased() == "GET",
              request.httpBody == nil,
              request.httpBodyStream == nil,
              let url = request.url,
              url.scheme?.lowercased() == "http",
              url.user == nil,
              url.password == nil,
              url.fragment == nil,
              let rawHost = url.host,
              !rawHost.isEmpty,
              let explicitPort = url.port,
              (1...65_535).contains(explicitPort)
        else {
            throw UmbraNetworkingError.invalidRequest(
                "plain HTTP transport accepts only bodyless GET requests with an explicit host and port"
            )
        }
        guard request.timeoutInterval.isFinite,
              request.timeoutInterval > 0,
              request.timeoutInterval <= limits.maximumTotalDuration
        else {
            throw UmbraNetworkingError.invalidRequest(
                "plain HTTP request timeout is outside the configured total-duration bound"
            )
        }

        let host = Self.normalizedHost(rawHost)
        guard !host.isEmpty,
              !host.contains("\r"),
              !host.contains("\n"),
              !host.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
        else {
            throw UmbraNetworkingError.invalidRequest("plain HTTP host is invalid")
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw UmbraNetworkingError.invalidRequest("plain HTTP URL could not be parsed")
        }
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        let target = components.percentEncodedQuery.map { "\(path)?\($0)" } ?? path
        guard target.first == "/",
              !target.contains("\r"),
              !target.contains("\n"),
              target.utf8.allSatisfy({ $0 >= 0x20 && $0 < 0x7f })
        else {
            throw UmbraNetworkingError.invalidRequest("plain HTTP request target is invalid")
        }

        let permittedHeaders = request.allHTTPHeaderFields ?? [:]
        for (name, value) in permittedHeaders {
            guard name.caseInsensitiveCompare("Connection") == .orderedSame,
                  value.caseInsensitiveCompare("close") == .orderedSame
            else {
                throw UmbraNetworkingError.invalidRequest(
                    "plain HTTP transport permits only the Connection: close request header"
                )
            }
        }

        let hostField: String
        if host.contains(":") {
            let encodedScope = host.replacingOccurrences(of: "%", with: "%25")
            hostField = "[\(encodedScope)]:\(explicitPort)"
        } else {
            hostField = "\(host):\(explicitPort)"
        }
        let wire = "GET \(target) HTTP/1.1\r\nHost: \(hostField)\r\nConnection: close\r\n\r\n"
        guard let serialized = wire.data(using: .ascii) else {
            throw UmbraNetworkingError.invalidRequest("plain HTTP request is not ASCII")
        }
        guard serialized.count <= limits.maximumRequestBytes else {
            throw UmbraNetworkingError.invalidRequest("plain HTTP request exceeds the configured size bound")
        }

        self.url = url
        self.address = HostAddress(host: host, port: UInt16(explicitPort))
        self.serializedRequest = serialized
        self.maximumHeaderBytes = limits.maximumHeaderBytes
        self.maximumBodyBytes = limits.maximumBodyBytes(for: path)
        self.connectDuration = min(request.timeoutInterval, limits.maximumConnectDuration)
        self.writeDuration = min(request.timeoutInterval, limits.maximumWriteDuration)
        self.readDuration = min(request.timeoutInterval, limits.maximumReadDuration)
        self.totalDuration = request.timeoutInterval
    }

    private static func normalizedHost(_ host: String) -> String {
        var result = host
        if result.hasPrefix("[") && result.hasSuffix("]") {
            result.removeFirst()
            result.removeLast()
        }
        return result.replacingOccurrences(of: "%25", with: "%", options: [.caseInsensitive])
    }
}

private final class PlainHTTPConnection: @unchecked Sendable {
    private let prepared: PreparedPlainHTTPRequest
    private let stateLock = NSLock()
    private var cancelled = false
    private var finished = false
    private let cancellationRead: Int32
    private let cancellationWrite: Int32

    init(prepared: PreparedPlainHTTPRequest) throws {
        self.prepared = prepared
        var descriptors = [Int32](repeating: -1, count: 2)
        guard pipe(&descriptors) == 0 else {
            throw URLError(.cannotCreateFile)
        }
        cancellationRead = descriptors[0]
        cancellationWrite = descriptors[1]
        _ = fcntl(cancellationRead, F_SETFL, fcntl(cancellationRead, F_GETFL) | O_NONBLOCK)
        _ = fcntl(cancellationWrite, F_SETFL, fcntl(cancellationWrite, F_GETFL) | O_NONBLOCK)
    }

    deinit {
        if cancellationRead >= 0 { Darwin.close(cancellationRead) }
        if cancellationWrite >= 0 { Darwin.close(cancellationWrite) }
    }

    func cancel() {
        stateLock.lock()
        let shouldSignal = !cancelled && !finished
        cancelled = true
        stateLock.unlock()
        if shouldSignal, cancellationWrite >= 0 {
            var byte: UInt8 = 1
            _ = Darwin.write(cancellationWrite, &byte, 1)
        }
    }

    func run() throws -> (Data, HTTPURLResponse) {
        defer {
            stateLock.lock()
            finished = true
            stateLock.unlock()
        }
        try checkCancellation()
        let totalDeadline = MonotonicDeadline(after: prepared.totalDuration)
        let connectDeadline = totalDeadline.clamped(to: prepared.connectDuration)
        let addresses = try resolve(deadline: connectDeadline)
        defer { freeaddrinfo(addresses) }
        let descriptor = try connect(addresses: addresses, deadline: connectDeadline)
        defer { Darwin.close(descriptor) }

        let writeDeadline = totalDeadline.clamped(to: prepared.writeDuration)
        try writeAll(prepared.serializedRequest, descriptor: descriptor, deadline: writeDeadline)
        let readDeadline = totalDeadline.clamped(to: prepared.readDuration)
        return try readResponse(descriptor: descriptor, deadline: readDeadline)
    }

    private func resolve(deadline: MonotonicDeadline) throws -> UnsafeMutablePointer<addrinfo> {
        let box = try AddressResolutionBox(host: prepared.address.host, port: prepared.address.port)
        box.start()
        do {
            try waitForRead(descriptor: box.readDescriptor, deadline: deadline)
            return try box.takeResult()
        } catch {
            box.abandon()
            throw error
        }
    }

    private func connect(
        addresses: UnsafeMutablePointer<addrinfo>,
        deadline: MonotonicDeadline
    ) throws -> Int32 {
        var current: UnsafeMutablePointer<addrinfo>? = addresses
        var sawAddress = false
        while let info = current {
            try checkCancellation()
            sawAddress = true
            let candidate = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if candidate >= 0 {
                _ = fcntl(candidate, F_SETFL, fcntl(candidate, F_GETFL) | O_NONBLOCK)
                var noSignal: Int32 = 1
                _ = setsockopt(candidate, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
                let result = Darwin.connect(candidate, info.pointee.ai_addr, info.pointee.ai_addrlen)
                if result == 0 {
                    return candidate
                }
                if errno == EINPROGRESS {
                    do {
                        try wait(descriptor: candidate, events: Int16(POLLOUT), deadline: deadline)
                        var socketError: Int32 = 0
                        var size = socklen_t(MemoryLayout.size(ofValue: socketError))
                        guard getsockopt(candidate, SOL_SOCKET, SO_ERROR, &socketError, &size) == 0,
                              socketError == 0
                        else {
                            Darwin.close(candidate)
                            current = info.pointee.ai_next
                            continue
                        }
                        return candidate
                    } catch is CancellationError {
                        Darwin.close(candidate)
                        throw CancellationError()
                    } catch let error as URLError where error.code == .timedOut {
                        Darwin.close(candidate)
                        throw error
                    } catch {
                        Darwin.close(candidate)
                    }
                } else {
                    Darwin.close(candidate)
                }
            }
            current = info.pointee.ai_next
        }
        if deadline.hasExpired { throw URLError(.timedOut) }
        throw URLError(sawAddress ? .cannotConnectToHost : .dnsLookupFailed)
    }

    private func writeAll(_ data: Data, descriptor: Int32, deadline: MonotonicDeadline) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                try checkCancellation()
                let count = Darwin.write(descriptor, base.advanced(by: offset), rawBuffer.count - offset)
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    try wait(descriptor: descriptor, events: Int16(POLLOUT), deadline: deadline)
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw URLError(.networkConnectionLost)
                }
            }
        }
    }

    private func readResponse(
        descriptor: Int32,
        deadline: MonotonicDeadline
    ) throws -> (Data, HTTPURLResponse) {
        var received = Data()
        var parsedHead: ParsedHTTPHead?
        var expectedTotal: Int?
        var scratch = [UInt8](repeating: 0, count: 16 * 1_024)

        while true {
            try checkCancellation()
            try wait(descriptor: descriptor, events: Int16(POLLIN), deadline: deadline)
            let count = Darwin.read(descriptor, &scratch, scratch.count)
            if count > 0 {
                received.append(contentsOf: scratch[0..<count])
                if parsedHead == nil {
                    if received.count > prepared.maximumHeaderBytes,
                       received.range(of: Self.headerTerminator) == nil {
                        throw UmbraNetworkingError.httpResponseTooLarge(limit: prepared.maximumHeaderBytes)
                    }
                    if let end = received.range(of: Self.headerTerminator)?.upperBound {
                        guard end <= prepared.maximumHeaderBytes else {
                            throw UmbraNetworkingError.httpResponseTooLarge(limit: prepared.maximumHeaderBytes)
                        }
                        let head = try ParsedHTTPHead.parse(received[..<end])
                        parsedHead = head
                        if let length = head.contentLength {
                            guard length <= prepared.maximumBodyBytes else {
                                throw UmbraNetworkingError.httpResponseTooLarge(limit: prepared.maximumBodyBytes)
                            }
                            expectedTotal = end + length
                        }
                    }
                }
                if let head = parsedHead,
                   let headerEnd = received.range(of: Self.headerTerminator)?.upperBound {
                    let bodyCount = received.count - headerEnd
                    guard bodyCount <= prepared.maximumBodyBytes else {
                        throw UmbraNetworkingError.httpResponseTooLarge(limit: prepared.maximumBodyBytes)
                    }
                    if let expectedTotal, received.count >= expectedTotal {
                        guard received.count == expectedTotal else {
                            throw UmbraNetworkingError.httpProtocolViolation(
                                "response exceeded its declared Content-Length"
                            )
                        }
                        return try makeResponse(head: head, body: received[headerEnd..<expectedTotal])
                    }
                }
            } else if count == 0 {
                guard let head = parsedHead,
                      let headerEnd = received.range(of: Self.headerTerminator)?.upperBound
                else {
                    throw UmbraNetworkingError.invalidHTTPResponse
                }
                if let expectedTotal, received.count != expectedTotal {
                    throw UmbraNetworkingError.httpProtocolViolation(
                        "connection closed before the declared Content-Length was received"
                    )
                }
                return try makeResponse(head: head, body: received[headerEnd...])
            } else if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                continue
            } else {
                throw URLError(.networkConnectionLost)
            }
        }
    }

    private func makeResponse(
        head: ParsedHTTPHead,
        body: Data.SubSequence
    ) throws -> (Data, HTTPURLResponse) {
        guard let response = HTTPURLResponse(
            url: prepared.url,
            statusCode: head.statusCode,
            httpVersion: head.version,
            headerFields: head.headerFields
        ) else {
            throw UmbraNetworkingError.invalidHTTPResponse
        }
        return (Data(body), response)
    }

    private func waitForRead(descriptor: Int32, deadline: MonotonicDeadline) throws {
        try wait(descriptor: descriptor, events: Int16(POLLIN), deadline: deadline)
    }

    private func wait(descriptor: Int32, events: Int16, deadline: MonotonicDeadline) throws {
        while true {
            try checkCancellation()
            let milliseconds = try deadline.remainingMilliseconds()
            var descriptors = [
                pollfd(fd: descriptor, events: events, revents: 0),
                pollfd(fd: cancellationRead, events: Int16(POLLIN), revents: 0),
            ]
            let count = poll(&descriptors, nfds_t(descriptors.count), milliseconds)
            if count > 0 {
                if cancellationRead >= 0, descriptors[1].revents != 0 {
                    throw CancellationError()
                }
                let returned = descriptors[0].revents
                if returned & events != 0 || returned & Int16(POLLHUP) != 0 {
                    return
                }
                if returned & Int16(POLLERR | POLLNVAL) != 0 {
                    throw URLError(.networkConnectionLost)
                }
            } else if count == 0 {
                throw URLError(.timedOut)
            } else if errno != EINTR {
                throw URLError(.networkConnectionLost)
            }
        }
    }

    private func checkCancellation() throws {
        stateLock.lock()
        let isCancelled = cancelled
        stateLock.unlock()
        if isCancelled { throw CancellationError() }
    }

    private static let headerTerminator = Data([13, 10, 13, 10])
}

private final class AddressResolutionBox: @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private let lock = NSLock()
    private var result: Result<UnsafeMutablePointer<addrinfo>, Error>?
    private var isAbandoned = false
    let readDescriptor: Int32
    private let writeDescriptor: Int32

    init(host: String, port: UInt16) throws {
        self.host = host
        self.port = port
        var descriptors = [Int32](repeating: -1, count: 2)
        guard pipe(&descriptors) == 0 else {
            throw URLError(.cannotCreateFile)
        }
        readDescriptor = descriptors[0]
        writeDescriptor = descriptors[1]
    }

    deinit {
        lock.lock()
        if case let .success(addresses) = result { freeaddrinfo(addresses) }
        lock.unlock()
        if readDescriptor >= 0 { Darwin.close(readDescriptor) }
        if writeDescriptor >= 0 { Darwin.close(writeDescriptor) }
    }

    func start() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var hints = addrinfo(
                ai_flags: 0,
                ai_family: AF_UNSPEC,
                ai_socktype: SOCK_STREAM,
                ai_protocol: IPPROTO_TCP,
                ai_addrlen: 0,
                ai_canonname: nil,
                ai_addr: nil,
                ai_next: nil
            )
            var addresses: UnsafeMutablePointer<addrinfo>?
            let code = getaddrinfo(host, String(port), &hints, &addresses)
            let produced: Result<UnsafeMutablePointer<addrinfo>, Error>
            if code == 0, let addresses {
                produced = .success(addresses)
            } else {
                produced = .failure(URLError(.dnsLookupFailed))
            }

            lock.lock()
            if isAbandoned {
                if case let .success(addresses) = produced { freeaddrinfo(addresses) }
                lock.unlock()
                return
            }
            result = produced
            lock.unlock()
            if writeDescriptor >= 0 {
                var byte: UInt8 = 1
                _ = Darwin.write(writeDescriptor, &byte, 1)
            }
        }
    }

    func takeResult() throws -> UnsafeMutablePointer<addrinfo> {
        lock.lock()
        defer { lock.unlock() }
        guard let result else { throw URLError(.dnsLookupFailed) }
        self.result = nil
        return try result.get()
    }

    func abandon() {
        lock.lock()
        isAbandoned = true
        if case let .success(addresses) = result { freeaddrinfo(addresses) }
        result = nil
        lock.unlock()
    }
}

private struct ParsedHTTPHead {
    let version: String
    let statusCode: Int
    let headerFields: [String: String]
    let contentLength: Int?

    static func parse(_ bytes: Data.SubSequence) throws -> ParsedHTTPHead {
        let data = Data(bytes)
        guard data.count >= 4,
              data.suffix(4) == Data([13, 10, 13, 10]),
              let text = String(data: data.dropLast(4), encoding: .isoLatin1)
        else {
            throw UmbraNetworkingError.httpProtocolViolation("header is not CRLF-delimited Latin-1")
        }
        for index in data.indices {
            if data[index] == 10, (index == data.startIndex || data[data.index(before: index)] != 13) {
                throw UmbraNetworkingError.httpProtocolViolation("header contains a bare line feed")
            }
            if data[index] == 13 {
                let next = data.index(after: index)
                if next == data.endIndex || data[next] != 10 {
                    throw UmbraNetworkingError.httpProtocolViolation("header contains a bare carriage return")
                }
            }
        }

        let lines = text.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw UmbraNetworkingError.invalidHTTPResponse
        }
        guard statusLine.unicodeScalars.allSatisfy({ scalar in
            scalar.value == 9 || scalar.value >= 0x20 && scalar.value != 0x7f
        }) else {
            throw UmbraNetworkingError.httpProtocolViolation("status line contains a control byte")
        }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard statusParts.count >= 2,
              statusParts[0] == "HTTP/1.1" || statusParts[0] == "HTTP/1.0",
              statusParts[1].count == 3,
              statusParts[1].allSatisfy({ $0.isASCII && $0.isNumber }),
              let status = Int(statusParts[1]),
              (100...599).contains(status),
              !(100...199).contains(status)
        else {
            throw UmbraNetworkingError.httpProtocolViolation("status line is invalid or informational")
        }

        var fields: [String: String] = [:]
        var contentLength: Int?
        for line in lines.dropFirst() {
            guard !line.isEmpty,
                  line.first != " ", line.first != "\t",
                  let colon = line.firstIndex(of: ":")
            else {
                throw UmbraNetworkingError.httpProtocolViolation("header line is empty, folded, or missing a colon")
            }
            let name = String(line[..<colon])
            let rawValue = line[line.index(after: colon)...]
            guard !name.isEmpty, name.utf8.allSatisfy(Self.isTokenByte) else {
                throw UmbraNetworkingError.httpProtocolViolation("header name is invalid")
            }
            guard rawValue.unicodeScalars.allSatisfy({ scalar in
                scalar.value == 9 || scalar.value >= 0x20 && scalar.value != 0x7f
            }) else {
                throw UmbraNetworkingError.httpProtocolViolation("header value contains a control byte")
            }
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowerName = name.lowercased()
            if lowerName == "content-length" {
                guard contentLength == nil,
                      !value.isEmpty,
                      value.allSatisfy(\.isNumber),
                      let parsed = Int(value), parsed >= 0
                else {
                    throw UmbraNetworkingError.httpProtocolViolation(
                        "Content-Length is duplicated, conflicting, or invalid"
                    )
                }
                contentLength = parsed
            } else if lowerName == "transfer-encoding" {
                throw UmbraNetworkingError.httpProtocolViolation(
                    "Transfer-Encoding is not accepted by the close-delimited GameStream client"
                )
            }
            if let existing = fields[name] {
                fields[name] = "\(existing), \(value)"
            } else {
                fields[name] = value
            }
        }
        return ParsedHTTPHead(
            version: String(statusParts[0]),
            statusCode: status,
            headerFields: fields,
            contentLength: contentLength
        )
    }

    private static func isTokenByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 48...57, 65...90, 97...122,
             33, 35, 36, 37, 38, 39, 42, 43, 45, 46, 94, 95, 96, 124, 126:
            true
        default:
            false
        }
    }
}

private struct MonotonicDeadline {
    private let nanoseconds: UInt64

    init(after duration: TimeInterval) {
        nanoseconds = Self.addingClamped(Self.now, Self.nanoseconds(for: duration))
    }

    private init(nanoseconds: UInt64) {
        self.nanoseconds = nanoseconds
    }

    var hasExpired: Bool { Self.now >= nanoseconds }

    func clamped(to duration: TimeInterval) -> MonotonicDeadline {
        let candidate = Self.addingClamped(Self.now, Self.nanoseconds(for: duration))
        return MonotonicDeadline(nanoseconds: min(nanoseconds, candidate))
    }

    func remainingMilliseconds() throws -> Int32 {
        let now = Self.now
        guard now < nanoseconds else { throw URLError(.timedOut) }
        let remaining = nanoseconds - now
        let roundedInput = remaining.addingReportingOverflow(999_999)
        let roundedUp = (roundedInput.overflow ? UInt64.max : roundedInput.partialValue) / 1_000_000
        return Int32(min(roundedUp, UInt64(Int32.max)))
    }

    private static var now: UInt64 {
        var value = timespec()
        clock_gettime(CLOCK_MONOTONIC, &value)
        return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
    }

    private static func nanoseconds(for duration: TimeInterval) -> UInt64 {
        let scaled = max(0, duration) * 1_000_000_000
        guard scaled < Double(UInt64.max) else { return UInt64.max }
        return UInt64(scaled)
    }

    private static func addingClamped(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? UInt64.max : result.partialValue
    }
}

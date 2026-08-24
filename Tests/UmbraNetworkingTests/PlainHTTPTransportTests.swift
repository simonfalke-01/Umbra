import Darwin
import Foundation
import XCTest
@testable import UmbraNetworking

final class PlainHTTPTransportTests: XCTestCase {
    func testFragmentedHeadersAndCoalescedBodyAreReadExactly() async throws {
        let server = try LoopbackHTTPServer(responseFragments: [
            Data("HTTP/1.1 200 OK\r\nContent-Len".utf8),
            Data("gth: 11\r\nX-Test: yes\r\n\r\nhello ".utf8),
            Data("world".utf8),
        ])
        let request = try makeRequest(port: server.port, path: "/serverinfo?uniqueid=test")

        let (body, response) = try await BoundedPlainHTTPTransport().data(for: request)

        XCTAssertEqual(body, Data("hello world".utf8))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.value(forHTTPHeaderField: "X-Test"), "yes")
        let requestText = try XCTUnwrap(server.requestText)
        XCTAssertTrue(requestText.hasPrefix("GET /serverinfo?uniqueid=test HTTP/1.1\r\n"))
        XCTAssertTrue(requestText.contains("Host: 127.0.0.1:\(server.port)\r\n"))
        XCTAssertTrue(requestText.hasSuffix("Connection: close\r\n\r\n"))
    }

    func testCloseDelimitedBodyIsSupported() async throws {
        let server = try LoopbackHTTPServer(responseFragments: [
            Data("HTTP/1.0 200 OK\r\nConnection: close\r\n\r\nlegacy".utf8),
        ])

        let (body, _) = try await BoundedPlainHTTPTransport().data(
            for: makeRequest(port: server.port, path: "/serverinfo")
        )

        XCTAssertEqual(body, Data("legacy".utf8))
    }

    func testRedirectIsReturnedWithoutFollowingIt() async throws {
        let server = try LoopbackHTTPServer(responseFragments: [
            Data("HTTP/1.1 302 Found\r\nLocation: http://example.invalid/\r\nContent-Length: 0\r\n\r\n".utf8),
        ])

        let (_, response) = try await BoundedPlainHTTPTransport().data(
            for: makeRequest(port: server.port, path: "/serverinfo")
        )

        XCTAssertEqual(response.statusCode, 302)
        XCTAssertEqual(server.acceptedConnectionCount, 1)
    }

    func testConflictingOrRepeatedContentLengthIsRejected() async throws {
        for headers in [
            "Content-Length: 1\r\nContent-Length: 2",
            "Content-Length: 1, 2",
            "Content-Length: +1",
        ] {
            let server = try LoopbackHTTPServer(responseFragments: [
                Data("HTTP/1.1 200 OK\r\n\(headers)\r\n\r\nx".utf8),
            ])
            await assertProtocolViolation(server: server)
        }
    }

    func testTransferEncodingAndRequestSmugglingShapesAreRejected() async throws {
        let responses = [
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
            "HTTP/1.1 200 OK\nContent-Length: 0\n\n",
            "HTTP/1.1 200 OK\r\n folded: value\r\n\r\n",
            "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n",
        ]
        for response in responses {
            let server = try LoopbackHTTPServer(responseFragments: [Data(response.utf8)])
            await assertProtocolViolation(server: server)
        }
    }

    func testEndpointBodyLimitIsEnforcedBeforeAllocation() async throws {
        let server = try LoopbackHTTPServer(responseFragments: [
            Data("HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\n".utf8),
        ])
        let limits = BoundedPlainHTTPTransport.Limits(serverInfoMaximumBodyBytes: 8)

        do {
            _ = try await BoundedPlainHTTPTransport(limits: limits).data(
                for: makeRequest(port: server.port, path: "/serverinfo")
            )
            XCTFail("expected endpoint body cap")
        } catch let error as UmbraNetworkingError {
            XCTAssertEqual(error, .httpResponseTooLarge(limit: 8))
        }
    }

    func testHeaderLimitIsEnforcedWithoutTerminator() async throws {
        let server = try LoopbackHTTPServer(responseFragments: [
            Data("HTTP/1.1 200 OK\r\nX-Fill: \("x".repeating(count: 2_000))".utf8),
        ])
        let limits = BoundedPlainHTTPTransport.Limits(maximumHeaderBytes: 1_024)

        do {
            _ = try await BoundedPlainHTTPTransport(limits: limits).data(
                for: makeRequest(port: server.port, path: "/serverinfo")
            )
            XCTFail("expected header cap")
        } catch let error as UmbraNetworkingError {
            XCTAssertEqual(error, .httpResponseTooLarge(limit: 1_024))
        }
    }

    func testPrematureEOFIsRejected() async throws {
        let server = try LoopbackHTTPServer(responseFragments: [
            Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nabc".utf8),
        ])
        await assertProtocolViolation(server: server)
    }

    func testCancellationInterruptsPendingReadAndCloseIsIdempotent() async throws {
        let server = try LoopbackHTTPServer(
            responseFragments: [Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".utf8)],
            responseDelay: 5
        )
        let request = try makeRequest(port: server.port, path: "/serverinfo", timeout: 10)
        let task = Task {
            try await BoundedPlainHTTPTransport().data(for: request)
        }
        try await Task.sleep(for: .milliseconds(50))
        let start = ContinuousClock.now
        task.cancel()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        }
    }

    func testMonotonicTotalReadDeadlineIsEnforced() async throws {
        let server = try LoopbackHTTPServer(
            responseFragments: [Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".utf8)],
            responseDelay: 1
        )

        do {
            _ = try await BoundedPlainHTTPTransport().data(
                for: makeRequest(port: server.port, path: "/serverinfo", timeout: 0.1)
            )
            XCTFail("expected timeout")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        }
    }

    func testRejectsNonGETBodyAndImplicitPortRequests() async throws {
        var post = URLRequest(url: URL(string: "http://127.0.0.1:47989/serverinfo")!)
        post.httpMethod = "POST"
        var body = URLRequest(url: URL(string: "http://127.0.0.1:47989/serverinfo")!)
        body.httpMethod = "GET"
        body.httpBody = Data([1])
        var implicit = URLRequest(url: URL(string: "http://127.0.0.1/serverinfo")!)
        implicit.httpMethod = "GET"

        for request in [post, body, implicit] {
            do {
                _ = try await BoundedPlainHTTPTransport().data(for: request)
                XCTFail("expected request rejection")
            } catch is UmbraNetworkingError {
                continue
            }
        }
    }

    func testRejectsUnboundedRequestTimeout() async throws {
        var request = try makeRequest(port: 47_989, path: "/serverinfo")
        request.timeoutInterval = TimeInterval.greatestFiniteMagnitude

        do {
            _ = try await BoundedPlainHTTPTransport().data(for: request)
            XCTFail("expected timeout bound rejection")
        } catch let error as UmbraNetworkingError {
            guard case .invalidRequest = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testRejectsOversizedGETBeforeConnecting() async throws {
        let request = try makeRequest(
            port: 47_989,
            path: "/serverinfo?value=\("x".repeating(count: 2_000))"
        )
        let limits = BoundedPlainHTTPTransport.Limits(maximumRequestBytes: 1_024)

        do {
            _ = try await BoundedPlainHTTPTransport(limits: limits).data(for: request)
            XCTFail("expected request-size rejection")
        } catch let error as UmbraNetworkingError {
            guard case .invalidRequest = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testSchemeSelectorKeepsHTTPAndHTTPSOnSeparateTransports() async throws {
        let plain = RecordingTransport(statusCode: 201)
        let secure = RecordingTransport(statusCode: 202)
        let selector = SchemeSelectingHTTPTransport(plainTransport: plain, secureTransport: secure)
        let http = try makeRequest(port: 47_989, path: "/serverinfo")
        var https = URLRequest(url: URL(string: "https://127.0.0.1:47984/serverinfo")!)
        https.httpMethod = "GET"

        let (_, plainResponse) = try await selector.data(for: http)
        let (_, secureResponse) = try await selector.data(for: https)

        XCTAssertEqual(plainResponse.statusCode, 201)
        XCTAssertEqual(secureResponse.statusCode, 202)
        let plainCount = await plain.requestCount
        let secureCount = await secure.requestCount
        XCTAssertEqual(plainCount, 1)
        XCTAssertEqual(secureCount, 1)
    }

    func testIPv6LoopbackWhenAvailable() async throws {
        guard let server = try LoopbackHTTPServer.ipv6(responseFragments: [
            Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok".utf8),
        ]) else {
            throw XCTSkip("IPv6 loopback is unavailable")
        }
        var components = URLComponents()
        components.scheme = "http"
        components.host = "[::1]"
        components.port = Int(server.port)
        components.path = "/serverinfo"
        var request = URLRequest(url: try XCTUnwrap(components.url), timeoutInterval: 2)
        request.httpMethod = "GET"

        let (body, _) = try await BoundedPlainHTTPTransport().data(for: request)

        XCTAssertEqual(body, Data("ok".utf8))
        XCTAssertTrue(try XCTUnwrap(server.requestText).contains("Host: [::1]:\(server.port)\r\n"))
    }

    /// Explicitly opt-in because this touches a real public host. It performs only the read-only
    /// GameStream discovery request and never pairs, launches, cancels, or configures anything.
    func testOptInPublicServerInfoSmoke() async throws {
        guard ProcessInfo.processInfo.environment["UMBRA_RUN_PUBLIC_SERVERINFO_SMOKE"] == "1" else {
            throw XCTSkip("set UMBRA_RUN_PUBLIC_SERVERINFO_SMOKE=1 to run the public read-only probe")
        }
        let host = ProcessInfo.processInfo.environment["UMBRA_PUBLIC_GAMESTREAM_HOST"] ?? "165.173.23.160"
        let client = GameStreamClient(
            transport: SchemeSelectingHTTPTransport(
                secureTransport: URLSessionTransport()
            ),
            requestBuilder: GameStreamRequestBuilder(
                uniqueID: "umbra-read-only-smoke",
                useTrueUniqueID: true
            )
        )

        let info = try await client.fetchServerInfo(
            address: HostAddress(host: host, port: 47_989),
            secure: false,
            fastFail: true
        )

        XCTAssertFalse(info.uniqueID.isEmpty)
        XCTAssertFalse(info.name.isEmpty)
    }

    private func assertProtocolViolation(server: LoopbackHTTPServer) async {
        do {
            _ = try await BoundedPlainHTTPTransport().data(
                for: makeRequest(port: server.port, path: "/serverinfo")
            )
            XCTFail("expected protocol violation")
        } catch is UmbraNetworkingError {
            return
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    private func makeRequest(
        port: UInt16,
        path: String,
        timeout: TimeInterval = 2
    ) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        if let question = path.firstIndex(of: "?") {
            components.path = String(path[..<question])
            components.percentEncodedQuery = String(path[path.index(after: question)...])
        } else {
            components.path = path
        }
        var request = URLRequest(url: try XCTUnwrap(components.url), timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("close", forHTTPHeaderField: "Connection")
        return request
    }
}

private actor RecordingTransport: HTTPTransport {
    private let statusCode: Int
    private(set) var requestCount = 0

    init(statusCode: Int) {
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        return (
            Data(),
            HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
        )
    }
}

private final class LoopbackHTTPServer: @unchecked Sendable {
    let port: UInt16
    private let listener: Int32
    private let responseFragments: [Data]
    private let responseDelay: TimeInterval
    private let lock = NSLock()
    private var _requestText: String?
    private var _acceptedConnectionCount = 0

    var requestText: String? {
        lock.lock()
        defer { lock.unlock() }
        return _requestText
    }

    var acceptedConnectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _acceptedConnectionCount
    }

    convenience init(responseFragments: [Data], responseDelay: TimeInterval = 0) throws {
        try self.init(family: AF_INET, responseFragments: responseFragments, responseDelay: responseDelay)
    }

    static func ipv6(responseFragments: [Data]) throws -> LoopbackHTTPServer? {
        do {
            return try LoopbackHTTPServer(family: AF_INET6, responseFragments: responseFragments, responseDelay: 0)
        } catch {
            return nil
        }
    }

    private init(family: Int32, responseFragments: [Data], responseDelay: TimeInterval) throws {
        let descriptor = socket(family, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { throw URLError(.cannotCreateFile) }
        listener = descriptor
        self.responseFragments = responseFragments
        self.responseDelay = responseDelay
        var reuse: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
        var noSignal: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))

        if family == AF_INET {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard result == 0 else {
                Darwin.close(descriptor)
                throw URLError(.cannotOpenFile)
            }
        } else {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = 0
            address.sin6_addr = in6addr_loopback
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
            guard result == 0 else {
                Darwin.close(descriptor)
                throw URLError(.cannotOpenFile)
            }
        }
        guard listen(descriptor, 1) == 0 else {
            Darwin.close(descriptor)
            throw URLError(.cannotOpenFile)
        }

        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        guard withUnsafeMutablePointer(to: &storage, { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }) == 0 else {
            Darwin.close(descriptor)
            throw URLError(.cannotOpenFile)
        }
        if family == AF_INET {
            port = withUnsafePointer(to: storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
            }
        } else {
            port = withUnsafePointer(to: storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin6_port) }
            }
        }

        DispatchQueue.global(qos: .userInitiated).async { [self] in serveOne() }
    }

    deinit {
        Darwin.close(listener)
    }

    private func serveOne() {
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return }
        defer { Darwin.close(client) }
        var noSignal: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        lock.lock()
        _acceptedConnectionCount += 1
        lock.unlock()

        var request = Data()
        var scratch = [UInt8](repeating: 0, count: 1_024)
        while request.range(of: Data([13, 10, 13, 10])) == nil, request.count < 64 * 1_024 {
            let count = Darwin.read(client, &scratch, scratch.count)
            if count <= 0 { break }
            request.append(contentsOf: scratch[0..<count])
        }
        lock.lock()
        _requestText = String(data: request, encoding: .ascii)
        lock.unlock()

        if responseDelay > 0 { Thread.sleep(forTimeInterval: responseDelay) }
        for fragment in responseFragments {
            fragment.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(client, base.advanced(by: offset), bytes.count - offset)
                    if count <= 0 { break }
                    offset += count
                }
            }
        }
    }
}

private extension String {
    func repeating(count: Int) -> String {
        String(repeating: self, count: count)
    }
}

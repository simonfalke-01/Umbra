@preconcurrency import Foundation
@preconcurrency import Security
import UmbraNetworking

public enum PairingRequestScheme: String, Sendable {
    case http
    case https
}

public enum PairingRequestEndpoint: String, Sendable {
    case pair
    case unpair
}

public struct PairingTranscriptRequest: @unchecked Sendable {
    public let host: HostAddress
    public let scheme: PairingRequestScheme
    public let endpoint: PairingRequestEndpoint
    public let parameters: [String: String]
    public let pinnedServerCertificateDER: Data?
    public let clientIdentity: ClientIdentity

    public init(
        host: HostAddress,
        scheme: PairingRequestScheme,
        endpoint: PairingRequestEndpoint,
        parameters: [String: String],
        pinnedServerCertificateDER: Data?,
        clientIdentity: ClientIdentity
    ) {
        self.host = host
        self.scheme = scheme
        self.endpoint = endpoint
        self.parameters = parameters
        self.pinnedServerCertificateDER = pinnedServerCertificateDER
        self.clientIdentity = clientIdentity
    }
}

public struct PairingTranscriptResponse: Equatable, Sendable {
    public let statusCode: Int
    public let values: [String: String]

    public init(statusCode: Int = 200, values: [String: String]) {
        self.statusCode = statusCode
        self.values = values
    }

    public subscript(_ key: String) -> String? { values[key] }
}

public protocol PairingHTTPTranscript: Sendable {
    func exchange(_ request: PairingTranscriptRequest) async throws -> PairingTranscriptResponse
}

public struct URLSessionPairingHTTPTranscript: PairingHTTPTranscript, Sendable {
    /// Moonlight waits indefinitely for host-side PIN entry. URLSession has no
    /// explicit infinite request timeout, so use a one-day bound while keeping
    /// Task cancellation immediate. This avoids poisoning Sunshine's pending
    /// pairing map during normal human confirmation delays.
    public static let defaultPINConfirmationTimeout: TimeInterval = 24 * 60 * 60

    private let plainTransport: any HTTPTransport
    private let securePort: UInt16
    private let uniqueID: String
    private let requestTimeout: TimeInterval
    private let pinConfirmationTimeout: TimeInterval
    private let uuidProvider: @Sendable () -> UUID

    public init(
        plainTransport: any HTTPTransport = BoundedPlainHTTPTransport(),
        securePort: UInt16 = HostAddress.defaultHTTPSPort,
        uniqueID: String,
        useTrueUniqueID: Bool = true,
        requestTimeout: TimeInterval = 5,
        pinConfirmationTimeout: TimeInterval = URLSessionPairingHTTPTranscript.defaultPINConfirmationTimeout,
        uuidProvider: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.plainTransport = plainTransport
        self.securePort = securePort
        self.uniqueID = useTrueUniqueID ? uniqueID : GameStreamRequestBuilder.legacyNVIDIAUniqueID
        self.requestTimeout = requestTimeout
        self.pinConfirmationTimeout = pinConfirmationTimeout
        self.uuidProvider = uuidProvider
    }

    public func exchange(_ transcriptRequest: PairingTranscriptRequest) async throws -> PairingTranscriptResponse {
        let request = try makeURLRequest(from: transcriptRequest)
        let data: Data
        let response: HTTPURLResponse
        switch transcriptRequest.scheme {
        case .http:
            (data, response) = try await plainTransport.data(for: request)
        case .https:
            guard let pinnedCertificate = transcriptRequest.pinnedServerCertificateDER else {
                throw PairingError.invalidCertificate("HTTPS pairing requires a pinned host certificate")
            }
            (data, response) = try await secureExchange(
                request,
                pinnedCertificate: pinnedCertificate,
                clientIdentity: transcriptRequest.clientIdentity
            )
        }
        guard (200..<300).contains(response.statusCode) else {
            throw UmbraNetworkingError.httpStatus(response.statusCode)
        }
        return try PairingXMLResponseParser.parse(data)
    }

    private func makeURLRequest(from request: PairingTranscriptRequest) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = request.scheme.rawValue
        components.host = request.host.host.contains(":") && !request.host.host.hasPrefix("[")
            ? "[\(request.host.host)]"
            : request.host.host
        components.port = Int(request.scheme == .https ? securePort : request.host.port)
        components.path = "/\(request.endpoint.rawValue)"
        components.queryItems = [
            URLQueryItem(name: "uniqueid", value: uniqueID),
            URLQueryItem(name: "uuid", value: uuidProvider().uuidString.replacingOccurrences(of: "-", with: "").lowercased()),
        ] + request.parameters.sorted(by: { $0.key < $1.key }).map(URLQueryItem.init)
        guard let url = components.url else {
            throw UmbraNetworkingError.invalidRequest("could not build pairing URL")
        }
        var urlRequest = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: request.parameters["phrase"] == "getservercert"
                ? pinConfirmationTimeout
                : requestTimeout
        )
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("close", forHTTPHeaderField: "Connection")
        return urlRequest
    }

    private func secureExchange(
        _ request: URLRequest,
        pinnedCertificate: Data,
        clientIdentity: ClientIdentity
    ) async throws -> (Data, HTTPURLResponse) {
        let delegate = try PairingURLSessionDelegate(
            pinnedCertificateDER: pinnedCertificate,
            clientIdentity: clientIdentity
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, rawResponse) = try await session.data(for: request)
        guard let response = rawResponse as? HTTPURLResponse else {
            throw UmbraNetworkingError.invalidHTTPResponse
        }
        return (data, response)
    }
}

private final class PairingURLSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let pinnedCertificateDER: Data
    private let clientCredential: URLCredential

    init(pinnedCertificateDER: Data, clientIdentity: ClientIdentity) throws {
        self.pinnedCertificateDER = pinnedCertificateDER
        self.clientCredential = try clientIdentity.makeURLCredential()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let trust = challenge.protectionSpace.serverTrust,
                  let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                  let leaf = chain.first,
                  (SecCertificateCopyData(leaf) as Data) == pinnedCertificateDER
            else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        case NSURLAuthenticationMethodClientCertificate:
            completionHandler(.useCredential, clientCredential)
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

private final class PairingXMLResponseParser: NSObject, XMLParserDelegate {
    private var currentElement: String?
    private var buffer = ""
    private(set) var statusCode = 200
    private(set) var values: [String: String] = [:]
    private(set) var parseError: Error?

    static func parse(_ data: Data) throws -> PairingTranscriptResponse {
        let delegate = PairingXMLResponseParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw UmbraNetworkingError.malformedXML(
                delegate.parseError?.localizedDescription ?? parser.parserError?.localizedDescription ?? "pairing response could not be parsed"
            )
        }
        return PairingTranscriptResponse(statusCode: delegate.statusCode, values: delegate.values)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if let value = attributeDict["status_code"], let status = Int(value) {
            statusCode = status
        }
        currentElement = elementName.lowercased()
        buffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = elementName.lowercased()
        if currentElement == name {
            values[name] = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        currentElement = nil
        buffer = ""
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
    }
}

private extension URLQueryItem {
    init(_ element: (key: String, value: String)) {
        self.init(name: element.key, value: element.value)
    }
}

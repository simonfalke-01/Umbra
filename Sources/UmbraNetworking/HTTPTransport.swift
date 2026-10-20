@preconcurrency import Foundation
@preconcurrency import Security

public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public protocol ServerTrustEvaluating: Sendable {
    func evaluate(serverTrust: SecTrust, host: String) -> Bool
}

public struct SystemTrustEvaluator: ServerTrustEvaluating {
    public init() {}

    public func evaluate(serverTrust: SecTrust, host: String) -> Bool {
        SecTrustEvaluateWithError(serverTrust, nil)
    }
}

/// Pins the exact DER bytes of the leaf certificate, matching the client's host-certificate model.
/// The self-signed GameStream certificate may fail normal PKI validation, so equality with the
/// certificate captured by the pairing flow is the authoritative check.
public struct PinnedCertificateEvaluator: ServerTrustEvaluating {
    public let certificateDER: Data

    public init(certificateDER: Data) {
        self.certificateDER = certificateDER
    }

    public func evaluate(serverTrust: SecTrust, host: String) -> Bool {
        guard let certificates = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
              let certificate = certificates.first
        else { return false }
        return (SecCertificateCopyData(certificate) as Data) == certificateDER
    }
}

public final class URLSessionTransport: NSObject, HTTPTransport, URLSessionDelegate, @unchecked Sendable {
    private let trustEvaluator: (any ServerTrustEvaluating)?
    private let clientCredential: URLCredential?
    private var session: URLSession!

    public init(
        configuration: URLSessionConfiguration = .ephemeral,
        trustEvaluator: (any ServerTrustEvaluating)? = nil,
        clientCredential: URLCredential? = nil
    ) {
        self.trustEvaluator = trustEvaluator
        self.clientCredential = clientCredential
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.connectionProxyDictionary = [:]
        super.init()
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    deinit {
        session?.invalidateAndCancel()
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw UmbraNetworkingError.invalidHTTPResponse
        }
        return (data, response)
    }

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodClientCertificate:
            if let clientCredential {
                completionHandler(.useCredential, clientCredential)
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
            return
        case NSURLAuthenticationMethodServerTrust:
            break
        default:
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        guard let trustEvaluator else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        if trustEvaluator.evaluate(serverTrust: trust, host: challenge.protectionSpace.host) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

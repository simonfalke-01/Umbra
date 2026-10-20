import Foundation
import UmbraCore
import UmbraNetworking
import UmbraPairing
import UmbraServices

/// Produces GameStream clients with the certificate and mutual-TLS behavior
/// required after pairing. Lumen receives its real unique ID while NVIDIA
/// GameStream retains the legacy ID behavior expected by GeForce Experience.
public struct AuthenticatedGameStreamClientProvider: GameStreamClientProviding, @unchecked Sendable {
    public let uniqueID: String
    private let credentialCache: ClientCredentialCache
    private let plainTransport: any HTTPTransport

    public init(
        uniqueID: String,
        identityProvider: any ClientIdentityProviding = FileBackedClientIdentityProvider(),
        plainTransport: any HTTPTransport = BoundedPlainHTTPTransport()
    ) throws {
        self.uniqueID = uniqueID
        self.credentialCache = ClientCredentialCache(identityProvider: identityProvider)
        self.plainTransport = plainTransport
    }

    public func client(for host: StreamHost?) -> any GameStreamServing {
        let trustEvaluator: (any ServerTrustEvaluating)?
        if let certificate = host?.serverCertificate, !certificate.isEmpty {
            trustEvaluator = PinnedCertificateEvaluator(certificateDER: certificate)
        } else {
            trustEvaluator = nil
        }

        let secureTransport: any HTTPTransport
        if host?.serverCertificate.isEmpty == false {
            switch credentialCache.resolveOnce() {
            case let .success(credential):
                secureTransport = URLSessionTransport(
                    trustEvaluator: trustEvaluator,
                    clientCredential: credential
                )
            case let .failure(error):
                secureTransport = FailingCredentialTransport(error: error)
            }
        } else {
            secureTransport = URLSessionTransport(trustEvaluator: trustEvaluator)
        }

        return GameStreamClient(
            transport: SchemeSelectingHTTPTransport(
                plainTransport: plainTransport,
                secureTransport: secureTransport
            ),
            requestBuilder: GameStreamRequestBuilder(
                uniqueID: uniqueID,
                useTrueUniqueID: host.map { !$0.isNvidiaServerSoftware } ?? false
            )
        )
    }
}

private final class ClientCredentialCache: @unchecked Sendable {
    private enum State {
        case unresolved
        case available(URLCredential)
        case unavailable(UmbraNetworkingError)
    }

    private let identityProvider: any ClientIdentityProviding
    private let lock = NSLock()
    private var state: State = .unresolved

    init(identityProvider: any ClientIdentityProviding) {
        self.identityProvider = identityProvider
    }

    func resolveOnce() -> Result<URLCredential, UmbraNetworkingError> {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .unresolved:
            do {
                let credential = try identityProvider.identity().makeURLCredential()
                state = .available(credential)
                return .success(credential)
            } catch {
                let failure = UmbraNetworkingError.clientIdentityUnavailable(error.localizedDescription)
                // Host polling creates clients every few seconds. Remember a corrupt or
                // unavailable identity for this process instead of repeating filesystem work.
                state = .unavailable(failure)
                return .failure(failure)
            }
        case let .available(credential):
            return .success(credential)
        case let .unavailable(error):
            return .failure(error)
        }
    }
}

private struct FailingCredentialTransport: HTTPTransport, Sendable {
    let error: UmbraNetworkingError

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw error
    }
}

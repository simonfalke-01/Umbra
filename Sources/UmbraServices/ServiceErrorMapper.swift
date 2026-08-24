import Foundation
import UmbraCore
import UmbraNetworking

public enum ServiceErrorMapper {
    public static func map(
        _ error: Error,
        operation: ServiceOperation,
        hostID: String? = nil
    ) -> UmbraServiceError {
        if let serviceError = error as? UmbraServiceError { return serviceError }
        if error is CancellationError { return .cancelled }
        if let provider = error as? any SessionFailureProviding {
            return .streamFailure(provider.sessionFailure)
        }
        if let validation = error as? ModelValidationError {
            return .invalidInput(field: validation.field, message: validation.reason)
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return .cancelled
            case .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
                 .clientCertificateRejected, .clientCertificateRequired,
                 .secureConnectionFailed, .userAuthenticationRequired:
                return .authenticationFailed(urlError.localizedDescription)
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                 .networkConnectionLost, .notConnectedToInternet, .timedOut:
                return .hostUnavailable(hostID: hostID, message: urlError.localizedDescription)
            default:
                return .underlying(operation: operation, message: urlError.localizedDescription)
            }
        }
        if let networking = error as? UmbraNetworkingError {
            switch networking {
            case let .invalidAddress(value):
                return .invalidInput(field: "host address", message: value)
            case let .invalidPort(value):
                return .invalidInput(field: "port", message: value)
            case let .invalidMACAddress(value):
                return .invalidInput(field: "MAC address", message: value)
            case let .invalidRequest(message), let .invalidApplication(message):
                return .invalidInput(field: operation.rawValue, message: message)
            case let .serverResponse(statusCode, message):
                if statusCode == 401 || statusCode == 403 {
                    return .authenticationFailed(message)
                }
                return .protocolFailure(operation: operation, statusCode: statusCode, message: message)
            case let .httpStatus(statusCode):
                if statusCode == 401 || statusCode == 403 {
                    return .authenticationFailed("The host rejected Umbra's client credentials.")
                }
                return .protocolFailure(
                    operation: operation,
                    statusCode: statusCode,
                    message: HTTPURLResponse.localizedString(forStatusCode: statusCode)
                )
            case let .certificateRejected(host):
                return .authenticationFailed("The TLS certificate presented by \(host) did not match the paired certificate.")
            case let .clientIdentityUnavailable(message):
                return .authenticationFailed(message)
            case .malformedXML, .missingRootElement, .invalidHTTPResponse,
                 .httpProtocolViolation, .httpResponseTooLarge:
                return .protocolFailure(operation: operation, statusCode: nil, message: networking.localizedDescription)
            case .pairingUnsupported:
                return .pairingUnavailable
            }
        }
        return .underlying(operation: operation, message: error.localizedDescription)
    }
}

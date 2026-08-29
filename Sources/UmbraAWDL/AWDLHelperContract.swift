import Foundation

public enum AWDLHelperContract {
    public static let machServiceName = "app.umbra.Umbra.AWDLHelper"
    public static let launchDaemonPlistName = "app.umbra.Umbra.AWDLHelper.plist"
    public static let applicationBundleIdentifier = "app.umbra.Umbra"
    public static let helperBundleIdentifier = "app.umbra.Umbra.AWDLHelper"
    public static let interfaceName = "awdl0"

    enum ReplyKey {
        static let success = "success"
        static let interfaceState = "interfaceState"
        static let leaseIdentifier = "leaseIdentifier"
        static let priorState = "priorState"
        static let error = "error"
    }
}

@objc public protocol AWDLPrivilegedHelperXPC {
    func status(reply: @escaping (NSDictionary) -> Void)
    func down(leaseIdentifier: String, reply: @escaping (NSDictionary) -> Void)
    func up(leaseIdentifier: String, reply: @escaping (NSDictionary) -> Void)
}

public enum AWDLInterfaceState: String, Codable, Equatable, Sendable {
    case up
    case down
}

public struct AWDLHelperStatus: Equatable, Sendable {
    public let interfaceState: AWDLInterfaceState
    public let leaseIdentifier: String?
    public let priorState: AWDLInterfaceState?

    public init(
        interfaceState: AWDLInterfaceState,
        leaseIdentifier: String?,
        priorState: AWDLInterfaceState?
    ) {
        self.interfaceState = interfaceState
        self.leaseIdentifier = leaseIdentifier
        self.priorState = priorState
    }
}

public enum AWDLHelperError: LocalizedError, Equatable, Sendable {
    case unavailable(String)
    case invalidReply
    case invalidLeaseIdentifier
    case busy
    case interfaceUnavailable
    case operationFailed(String)
    case registrationAlreadyAttempted

    public var errorDescription: String? {
        switch self {
        case let .unavailable(message):
            "The AWDL helper is unavailable: \(message)"
        case .invalidReply:
            "The AWDL helper returned an invalid response."
        case .invalidLeaseIdentifier:
            "The AWDL helper rejected an invalid lease identifier."
        case .busy:
            "The AWDL helper is already owned by another stream."
        case .interfaceUnavailable:
            "The awdl0 interface is unavailable."
        case let .operationFailed(message):
            "The AWDL helper operation failed: \(message)"
        case .registrationAlreadyAttempted:
            "AWDL helper registration was already requested on this installation."
        }
    }
}

extension AWDLHelperStatus {
    static func reply(success: Bool = true, error: String? = nil) -> NSDictionary {
        var reply: [String: Any] = [AWDLHelperContract.ReplyKey.success: success]
        if let error { reply[AWDLHelperContract.ReplyKey.error] = error }
        return reply as NSDictionary
    }

    func reply() -> NSDictionary {
        var reply: [String: Any] = [
            AWDLHelperContract.ReplyKey.success: true,
            AWDLHelperContract.ReplyKey.interfaceState: interfaceState.rawValue,
        ]
        if let leaseIdentifier {
            reply[AWDLHelperContract.ReplyKey.leaseIdentifier] = leaseIdentifier
        }
        if let priorState {
            reply[AWDLHelperContract.ReplyKey.priorState] = priorState.rawValue
        }
        return reply as NSDictionary
    }

    static func decode(_ reply: NSDictionary) throws -> AWDLHelperStatus {
        guard reply[AWDLHelperContract.ReplyKey.success] as? Bool == true,
              let rawState = reply[AWDLHelperContract.ReplyKey.interfaceState] as? String,
              let interfaceState = AWDLInterfaceState(rawValue: rawState) else {
            if let message = reply[AWDLHelperContract.ReplyKey.error] as? String {
                if message == "busy" { throw AWDLHelperError.busy }
                if message == "invalid lease identifier" {
                    throw AWDLHelperError.invalidLeaseIdentifier
                }
                throw AWDLHelperError.operationFailed(message)
            }
            throw AWDLHelperError.invalidReply
        }
        let leaseIdentifier = reply[AWDLHelperContract.ReplyKey.leaseIdentifier] as? String
        let priorState = (reply[AWDLHelperContract.ReplyKey.priorState] as? String)
            .flatMap(AWDLInterfaceState.init(rawValue:))
        return AWDLHelperStatus(
            interfaceState: interfaceState,
            leaseIdentifier: leaseIdentifier,
            priorState: priorState
        )
    }
}

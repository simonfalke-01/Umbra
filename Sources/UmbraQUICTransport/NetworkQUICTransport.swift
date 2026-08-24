import Foundation

@available(macOS 13.0, *)
public final class NetworkQUICTransport: QUICTransportProtocol, @unchecked Sendable {
    private let core: QUICTransportCore

    public var eventHandler: (@Sendable (QUICTransportEvent) -> Void)? {
        get { core.eventHandler }
        set { core.eventHandler = newValue }
    }

    public var authenticationHandler: (@Sendable (QUICApplicationAuthenticationHandoff) -> Void)? {
        get { core.authenticationHandler }
        set { core.authenticationHandler = newValue }
    }

    public init(configuration: QUICTransportConfiguration) throws {
        core = try QUICTransportCore(
            configuration: configuration,
            adapter: NWQUICNetworkAdapter()
        )
    }

    public func start() throws { try core.start() }
    public func send(_ request: QUICOutboundRequest) { core.send(request) }
    public func setActiveSessionID(_ sessionID: Data?) throws {
        try core.setActiveSessionID(sessionID)
    }
    public func applicationHelloDidComplete(success: Bool) {
        core.applicationHelloDidComplete(success: success)
    }
    public func applicationAuthenticationDidComplete(success: Bool) {
        core.applicationAuthenticationDidComplete(success: success)
    }
    public func acceptInboundBulk(requestID: UInt64, objectID: UInt64) {
        core.acceptInboundBulk(requestID: requestID, objectID: objectID)
    }
    public func rejectInboundBulk(requestID: UInt64, objectID: UInt64) {
        core.rejectInboundBulk(requestID: requestID, objectID: objectID)
    }
    public func cancel() { core.cancel() }
}

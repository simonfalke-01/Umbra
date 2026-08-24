import Foundation

struct QUICNetworkSubmission: Sendable {
    let id: UInt64
    let lane: QUICSemanticLane
    let header: Data
    let payload: Data
    let deadlineNanoseconds: UInt64
}

enum QUICNetworkAdapterEvent: Sendable {
    case peerVerificationStarted
    case peerVerified(Data)
    case peerVerificationFailed
    case ready(alpn: String, usableDatagramByteCount: Int)
    case datagramCapacityChanged(Int)
    case waiting(String)
    case recovered
    case pathChanged(QUICMigrationObservation)
    case controlBytes(Data)
    case datagram(Data)
    case bulkHeader(QUICInboundBulkHeader)
    case bulkObject(QUICInboundBulkObject)
    case bulkFailure(QUICInboundBulkFailure)
    case malformed(String)
    case failed(String)
    case cancelled
}

protocol QUICNetworkAdapter: AnyObject, Sendable {
    var eventHandler: (@Sendable (QUICNetworkAdapterEvent) -> Void)? { get set }
    func start(configuration: QUICTransportConfiguration)
    func submit(
        _ submission: QUICNetworkSubmission,
        completion: @escaping @Sendable (String?) -> Void
    )
    func setInboundBulkEnabled(_ enabled: Bool)
    func decideInboundBulk(requestID: UInt64, objectID: UInt64, accept: Bool)
    func cancel()
}

protocol QUICDeadlineToken: AnyObject, Sendable {
    func cancel()
}

protocol QUICDeadlineScheduling: Sendable {
    func schedule(
        deadlineNanoseconds: UInt64,
        _ action: @escaping @Sendable () -> Void
    ) -> any QUICDeadlineToken
}

final class DispatchQUICDeadlineToken: QUICDeadlineToken, @unchecked Sendable {
    private let lock = NSLock()
    private var item: DispatchWorkItem?

    init(item: DispatchWorkItem) { self.item = item }

    func cancel() {
        lock.withLock {
            item?.cancel()
            item = nil
        }
    }
}

struct DispatchQUICDeadlineScheduler: QUICDeadlineScheduling {
    let queue: DispatchQueue

    func schedule(
        deadlineNanoseconds: UInt64,
        _ action: @escaping @Sendable () -> Void
    ) -> any QUICDeadlineToken {
        let item = DispatchWorkItem(block: action)
        queue.asyncAfter(deadline: .init(uptimeNanoseconds: deadlineNanoseconds), execute: item)
        return DispatchQUICDeadlineToken(item: item)
    }
}

import Foundation

public final class QUICSendScheduler: @unchecked Sendable {
    private struct Item {
        let send: QUICScheduledSend
        let supersessionKey: UInt64?
    }

    private struct LaneQueue {
        private var storage = [Item]()
        private var head = 0
        private var latestIndex = [UInt64: Int]()
        private(set) var byteCount = 0
        var count: Int { storage.count - head }
        var isEmpty: Bool { head == storage.count }
        var retainedSlotCount: Int { storage.count }

        mutating func append(_ item: Item) {
            storage.append(item)
            byteCount += item.send.payload.count
            if let key = item.supersessionKey { latestIndex[key] = storage.count - 1 }
        }

        mutating func replaceLatest(key: UInt64, with item: Item) -> Item? {
            guard let index = latestIndex[key], index >= head else { return nil }
            let old = storage[index]
            byteCount += item.send.payload.count - old.send.payload.count
            storage[index] = item
            return old
        }

        func latest(key: UInt64) -> Item? {
            guard let index = latestIndex[key], index >= head else { return nil }
            return storage[index]
        }

        mutating func popFirst() -> Item? {
            guard head < storage.count else { return nil }
            let item = storage[head]
            head += 1
            byteCount -= item.send.payload.count
            if let key = item.supersessionKey, latestIndex[key] == head - 1 {
                latestIndex.removeValue(forKey: key)
            }
            if head == storage.count {
                storage.removeAll(keepingCapacity: true)
                latestIndex.removeAll(keepingCapacity: true)
                head = 0
            } else if head >= 64, head * 2 >= storage.count {
                storage = Array(storage[head...])
                head = 0
                latestIndex.removeAll(keepingCapacity: true)
                for (index, item) in storage.enumerated() {
                    if let key = item.supersessionKey { latestIndex[key] = index }
                }
            }
            return item
        }

        mutating func cancelAll() -> ArraySlice<Item> {
            let result = storage[head...]
            storage = []
            latestIndex = [:]
            head = 0
            byteCount = 0
            return result
        }
    }

    private let lock = NSLock()
    private let mode: QUICOptimizationMode
    private let limits: QUICSchedulerLimits
    private let maximumAges: [QUICSemanticLane: UInt64]
    private var queues = Dictionary(uniqueKeysWithValues: QUICSemanticLane.allCases.map { ($0, LaneQueue()) })
    private var queuedCount = 0
    private var queuedBytes = 0
    private var inFlight = [UInt64: QUICScheduledSend]()
    private var nextID: UInt64 = 1
    private var nextSequence = Dictionary(uniqueKeysWithValues: QUICSemanticLane.allCases.map { ($0, UInt64(1)) })
    private var cancelled = false
    private var datagramPayloadCap: Int?

    public convenience init(mode: QUICOptimizationMode, limits: QUICSchedulerLimits? = nil) throws {
        try self.init(mode: mode, limits: limits, testingInitialSemanticSequence: 1)
    }

    init(
        mode: QUICOptimizationMode,
        limits: QUICSchedulerLimits? = nil,
        testingInitialSemanticSequence: UInt64
    ) throws {
        let profile = QUICTransportProfile.immutable(mode)
        let resolved = limits ?? profile.schedulerLimits
        guard resolved.isValid, profile.isValid else { throw QUICTransportError.invalidConfiguration }
        self.mode = mode
        self.limits = resolved
        maximumAges = profile.timeouts.maximumLaneAgeNanoseconds
        nextSequence = Dictionary(
            uniqueKeysWithValues: QUICSemanticLane.allCases.map {
                ($0, testingInitialSemanticSequence)
            }
        )
    }

    public func updateUsableDatagramPayloadSize(_ count: Int) {
        lock.withLock { datagramPayloadCap = count > 0 ? count : nil }
    }

    public func enqueue(_ request: QUICOutboundRequest, nowNanoseconds now: UInt64) -> QUICEnqueueResult {
        lock.withLock {
            let id = nextIdentifier()
            guard !cancelled else { return reject(id, request.lane, .cancelled) }
            guard !request.payload.isEmpty,
                  request.lane.delivery == .latestDatagram || request.supersessionKey == nil,
                  request.lane.delivery != .latestDatagram || request.supersessionKey != nil,
                  metadataMatches(request.wireMetadata, lane: request.lane)
            else {
                return reject(id, request.lane, .rejectedInvalidRequest)
            }

            let age = maximumAges[request.lane]!
            let sum = now.addingReportingOverflow(age)
            let ageDeadline = sum.overflow ? UInt64.max : sum.partialValue
            let deadline = min(request.deadlineNanoseconds ?? .max, ageDeadline)
            guard deadline > now else { return reject(id, request.lane, .expired) }
            if request.lane.delivery != .reliableOrdered,
               let cap = datagramPayloadCap,
               request.payload.count > cap
            {
                return reject(id, request.lane, .datagramTooLarge(maximumPayloadBytes: cap))
            }
            guard let sequence = semanticSequenceCandidate(request.lane) else {
                return reject(id, request.lane, .sequenceExhausted)
            }

            var send = QUICScheduledSend(
                id: id,
                lane: request.lane,
                payload: request.payload,
                deadlineNanoseconds: deadline,
                enqueuedAtNanoseconds: now,
                semanticSequence: sequence,
                wireMetadata: request.wireMetadata
            )
            var dispositions = [QUICSendDisposition]()
            if request.lane.delivery == .latestDatagram,
               let key = request.supersessionKey,
               var queue = queues[request.lane],
               let old = queue.latest(key: key)
            {
                send = QUICScheduledSend(
                    id: send.id,
                    lane: send.lane,
                    payload: send.payload,
                    deadlineNanoseconds: send.deadlineNanoseconds,
                    enqueuedAtNanoseconds: send.enqueuedAtNanoseconds,
                    semanticSequence: old.send.semanticSequence,
                    wireMetadata: send.wireMetadata
                )
                _ = queue.replaceLatest(
                    key: key,
                    with: Item(send: send, supersessionKey: request.supersessionKey)
                )
                queues[request.lane] = queue
                queuedBytes += send.payload.count - old.send.payload.count
                dispositions.append(.init(id: old.send.id, lane: request.lane, outcome: .superseded(by: id)))
                return .init(acceptedID: id, dispositions: dispositions)
            }
            let item = Item(send: send, supersessionKey: request.supersessionKey)
            guard makeCapacity(for: send, dispositions: &dispositions) else {
                dispositions.append(.init(id: id, lane: request.lane, outcome: .rejectedQueueFull))
                return .init(acceptedID: nil, dispositions: dispositions)
            }
            commitSemanticSequence(request.lane)
            queues[request.lane, default: LaneQueue()].append(item)
            queuedCount += 1
            queuedBytes += request.payload.count
            return .init(acceptedID: id, dispositions: dispositions)
        }
    }

    public func dequeue(
        nowNanoseconds now: UInt64,
        eligibleLanes: Set<QUICSemanticLane> = Set(QUICSemanticLane.allCases)
    ) -> QUICSchedulerDrain {
        lock.withLock {
            var dispositions = [QUICSendDisposition]()
            guard !cancelled, inFlight.count < limits.maximumInFlightSends else {
                return .init(send: nil, dispositions: dispositions)
            }
            while let lane = QUICSemanticLane.schedulerOrder.first(where: {
                eligibleLanes.contains($0) && !(queues[$0]?.isEmpty ?? true)
            }), var queue = queues[lane], let item = queue.popFirst() {
                queues[lane] = queue
                queuedCount -= 1
                queuedBytes -= item.send.payload.count
                if item.send.deadlineNanoseconds! <= now {
                    dispositions.append(.init(id: item.send.id, lane: lane, outcome: .expired))
                    continue
                }
                if lane.delivery != .reliableOrdered,
                   let cap = datagramPayloadCap,
                   item.send.payload.count > cap
                {
                    dispositions.append(.init(id: item.send.id, lane: lane, outcome: .datagramTooLarge(maximumPayloadBytes: cap)))
                    continue
                }
                inFlight[item.send.id] = item.send
                return .init(send: item.send, dispositions: dispositions)
            }
            return .init(send: nil, dispositions: dispositions)
        }
    }

    public func complete(id: UInt64, failureDescription: String? = nil) -> QUICSendDisposition? {
        lock.withLock {
            guard let send = inFlight.removeValue(forKey: id) else { return nil }
            return .init(
                id: id,
                lane: send.lane,
                outcome: failureDescription.map(QUICSendOutcome.transportFailure) ?? .submittedToNetwork
            )
        }
    }

    public func cancel() -> [QUICSendDisposition] {
        lock.withLock {
            guard !cancelled else { return [] }
            cancelled = true
            var result = [QUICSendDisposition]()
            for lane in QUICSemanticLane.schedulerOrder {
                guard var queue = queues[lane] else { continue }
                for item in queue.cancelAll() {
                    result.append(.init(id: item.send.id, lane: lane, outcome: .cancelled))
                }
                queues[lane] = queue
            }
            for send in inFlight.values.sorted(by: { $0.id < $1.id }) {
                result.append(.init(id: send.id, lane: send.lane, outcome: .cancelled))
            }
            queuedCount = 0
            queuedBytes = 0
            inFlight = [:]
            return result
        }
    }

    public func snapshot() -> QUICSchedulerSnapshot {
        lock.withLock {
            .init(
                isCancelled: cancelled,
                queuedMessageCount: queuedCount,
                queuedByteCount: queuedBytes,
                inFlightMessageCount: inFlight.count,
                usableDatagramPayloadSize: datagramPayloadCap,
                retainedQueueSlotCount: queues.values.reduce(into: 0) {
                    $0 += $1.retainedSlotCount
                }
            )
        }
    }

    func discardQueued(lanes: Set<QUICSemanticLane>) -> [QUICSendDisposition] {
        lock.withLock {
            var result = [QUICSendDisposition]()
            for lane in lanes {
                guard var queue = queues[lane] else { continue }
                for item in queue.cancelAll() {
                    queuedCount -= 1
                    queuedBytes -= item.send.payload.count
                    result.append(.init(id: item.send.id, lane: lane, outcome: .cancelled))
                }
                queues[lane] = queue
            }
            return result
        }
    }

    private func metadataMatches(_ metadata: QUICOutboundWireMetadata?, lane: QUICSemanticLane) -> Bool {
        guard let metadata else { return true }
        switch metadata {
        case .control:
            return lane.delivery == .reliableOrdered && lane != .bulk
        case .datagram(let session, _, _, _, _):
            return lane.delivery != .reliableOrdered && session.count == 16
        }
    }

    private func nextIdentifier() -> UInt64 {
        let value = nextID
        if nextID != .max { nextID += 1 }
        return value
    }

    private func semanticSequenceCandidate(_ lane: QUICSemanticLane) -> UInt64? {
        let exhaustionThreshold = UInt64.max - 1_023
        guard let value = nextSequence[lane], value < exhaustionThreshold else { return nil }
        return value
    }

    private func commitSemanticSequence(_ lane: QUICSemanticLane) {
        nextSequence[lane]! += 1
    }

    private func reject(_ id: UInt64, _ lane: QUICSemanticLane, _ outcome: QUICSendOutcome) -> QUICEnqueueResult {
        .init(acceptedID: nil, dispositions: [.init(id: id, lane: lane, outcome: outcome)])
    }

    private func makeCapacity(for send: QUICScheduledSend, dispositions: inout [QUICSendDisposition]) -> Bool {
        guard let laneLimit = limits.perLane[send.lane],
              send.payload.count <= laneLimit.byteCount,
              send.payload.count <= limits.totalByteCount
        else {
            return false
        }
        while exceedsCapacity(send, laneLimit) {
            guard mode == .latency,
                  let victimLane = QUICSemanticLane.schedulerOrder.reversed().first(where: {
                      $0.schedulerPriority > send.lane.schedulerPriority && !(queues[$0]?.isEmpty ?? true)
                  }),
                  var queue = queues[victimLane],
                  let victim = queue.popFirst()
            else {
                return false
            }
            queues[victimLane] = queue
            queuedCount -= 1
            queuedBytes -= victim.send.payload.count
            dispositions.append(.init(id: victim.send.id, lane: victimLane, outcome: .cancelled))
        }
        return true
    }

    private func exceedsCapacity(_ send: QUICScheduledSend, _ laneLimit: QUICLaneQueueLimit) -> Bool {
        let queue = queues[send.lane] ?? LaneQueue()
        return queuedCount + 1 > limits.totalMessageCount ||
            queuedBytes + send.payload.count > limits.totalByteCount ||
            queue.count + 1 > laneLimit.messageCount ||
            queue.byteCount + send.payload.count > laneLimit.byteCount
    }
}

import Foundation
import UmbraCore
import UmbraLSPTransport
import XCTest
@testable import UmbraLSP

final class LSPProductPairingTests: XCTestCase {
    func testPairingBeginAndCompletionAreSingleFlightAndSnapshotDiscovery() async throws {
        let fixture = try PairingProductFixture()
        defer { fixture.cleanup() }
        let tracker = PairingOperationTracker(suspendBegin: true, suspendVerification: true)
        let product = fixture.product(operations: operations(tracker: tracker))
        let mutations = PairingMutationRecorder()
        await product.setPairingDiscoveryMutationHandler { mutations.record($0) }
        let original = candidate(host: "srv-a.local", port: 48_030, spkiByte: 0x11, token: 1)
        var changed = original
        changed.hostID = UUID(uuidString: "10213243-5465-7687-98a9-bacbdcedfe0f")!
        changed.host = "srv-b.local"
        changed.port = 49_999
        changed.serverSPKISHA256 = Data(repeating: 0x22, count: 32)
        changed.discoveryChangeToken = 2
        let changedCandidate = changed
        let changedHostID = changedCandidate.hostID
        _ = await product.registerDiscoveredPairingHost(original)

        let firstBegin = Task { try await product.beginPairing(hostID: original.hostID) }
        await waitUntil { await tracker.beginCount == 1 }
        let secondBegin = Task { try await product.beginPairing(hostID: original.hostID) }
        for _ in 0..<10 { await Task.yield() }
        let beginCount = await tracker.beginCount
        let displayedCandidate = await product.registerDiscoveredPairingHost(changedCandidate)
        XCTAssertEqual(beginCount, 1)
        XCTAssertEqual(displayedCandidate, original)
        await tracker.releaseBegin()
        let firstPrompt = try await firstBegin.value
        let secondPrompt = try await secondBegin.value
        XCTAssertEqual(firstPrompt, secondPrompt)
        XCTAssertEqual(firstPrompt.host, original)

        let firstCompletion = Task { try await product.completePairing(hostID: original.hostID) }
        await waitUntil { await tracker.verificationCount == 1 }
        let secondCompletion = Task { try await product.completePairing(hostID: original.hostID) }
        for _ in 0..<10 { await Task.yield() }
        let verificationCount = await tracker.verificationCount
        XCTAssertEqual(verificationCount, 1)
        await tracker.releaseVerification()
        let firstHost = try await firstCompletion.value
        let secondHost = try await secondCompletion.value
        XCTAssertEqual(firstHost, secondHost)
        XCTAssertEqual(firstHost.address, original.host)
        XCTAssertEqual(firstHost.port, original.port)
        XCTAssertEqual(firstHost.discoveryDomain, original.domain)
        XCTAssertEqual(firstHost.interfaceName, original.interfaceName)
        let completedVerificationCount = await tracker.verificationCount
        XCTAssertEqual(completedVerificationCount, 1)
        XCTAssertEqual(mutations.values, [
            .replaced(oldHostID: original.hostID, host: changedCandidate),
        ])

        let nextBegin = Task { try await product.beginPairing(hostID: changedHostID) }
        await waitUntil { await tracker.beginCount == 2 }
        await tracker.releaseBegin()
        let nextPrompt = try await nextBegin.value
        XCTAssertEqual(nextPrompt.host, changedCandidate)
        await product.cancelPairing(hostID: changedHostID)
    }

    func testCancelledBeginResultIsNeverReturnedAndNativeOwnerIsReleased() async throws {
        let fixture = try PairingProductFixture()
        defer { fixture.cleanup() }
        let tracker = PairingOperationTracker(suspendBegin: true, suspendVerification: false)
        let product = fixture.product(operations: operations(tracker: tracker))
        let discovered = candidate(host: "srv.local", port: 48_030, spkiByte: 0x55, token: 1)
        _ = await product.registerDiscoveredPairingHost(discovered)

        let begin = Task { try await product.beginPairing(hostID: discovered.hostID) }
        await waitUntil { await tracker.beginCount == 1 }
        let cancellation = Task { await product.cancelPairing(hostID: discovered.hostID) }
        await tracker.releaseBegin()
        await cancellation.value

        do {
            _ = try await begin.value
            XCTFail("A cancelled attempt must not return its PIN")
        } catch is CancellationError {}
        let cancellationCount = await tracker.cancellationCountValue()
        XCTAssertEqual(cancellationCount, 1)
    }

    func testAttemptExpiryCancelsAndReleasesAbandonedNativePairing() async throws {
        let fixture = try PairingProductFixture()
        defer { fixture.cleanup() }
        let tracker = PairingOperationTracker(suspendBegin: false, suspendVerification: false)
        let expiry = UInt64(max(0, Date().timeIntervalSince1970))
        let product = fixture.product(operations: operations(tracker: tracker, expiry: expiry))
        let discovered = candidate(host: "srv.local", port: 48_030, spkiByte: 0x66, token: 1)
        _ = await product.registerDiscoveredPairingHost(discovered)

        _ = try await product.beginPairing(hostID: discovered.hostID)
        await waitUntil { await tracker.cancellationCount == 1 }

        do {
            _ = try await product.completePairing(hostID: discovered.hostID)
            XCTFail("An expired attempt must not remain completable")
        } catch LSPTransportError.invalidState {}
    }

    func testVerifiedCompletionSurvivesRecoverablePersistenceFailure() async throws {
        let fixture = try PairingProductFixture()
        defer { fixture.cleanup() }
        let tracker = PairingOperationTracker(suspendBegin: false, suspendVerification: false)
        let failOnce = FailOnce()
        let product = fixture.product(
            operations: operations(tracker: tracker),
            afterTrustWrite: { try failOnce.call() }
        )
        let discovered = candidate(host: "srv.local", port: 48_030, spkiByte: 0x33, token: 1)
        _ = await product.registerDiscoveredPairingHost(discovered)
        _ = try await product.beginPairing(hostID: discovered.hostID)

        do {
            _ = try await product.completePairing(hostID: discovered.hostID)
            XCTFail("Injected persistence failure must be visible")
        } catch is FailOnce.InjectedFailure {}
        let failedVerificationCount = await tracker.verificationCount
        let rolledBackTrust = try await fixture.stores.trust.load()
        let unchangedHosts = try await fixture.stores.hosts.load()
        XCTAssertEqual(failedVerificationCount, 1)
        XCTAssertTrue(rolledBackTrust.records.isEmpty)
        XCTAssertTrue(unchangedHosts.records.isEmpty)

        let host = try await product.completePairing(hostID: discovered.hostID)
        XCTAssertEqual(host.address, discovered.host)
        let retriedVerificationCount = await tracker.verificationCount
        let committedTrust = try await fixture.stores.trust.load()
        let committedHosts = try await fixture.stores.hosts.load()
        XCTAssertEqual(retriedVerificationCount, 1)
        XCTAssertEqual(committedTrust.records.count, 1)
        XCTAssertEqual(committedHosts.records.first?.hostID, host.hostID)
        XCTAssertEqual(committedHosts.records.first?.address, host.address)
        XCTAssertEqual(committedHosts.records.first?.port, host.port)
    }

    private func operations(
        tracker: PairingOperationTracker,
        expiry: UInt64 = 4_000_000_000
    ) -> LSPProductPairingOperations {
        .init(
            begin: { host in
                await tracker.begin(host)
                let session = try LSPClientSession(identity: .generate())
                return .init(
                    session: session,
                    prompt: .init(host: host, pin: "004200", expiresAtUTCSeconds: expiry)
                )
            },
            verify: { start in
                await tracker.verify()
                return LSPTrustRecord(
                    hostID: start.prompt.host.hostID,
                    hostIdentityKey: Data(repeating: 0x44, count: 32),
                    dtlsSPKISHA256: start.prompt.host.serverSPKISHA256,
                    permissions: [.browseApplications, .startOrAttach, .input],
                    revocationGeneration: 1
                )
            },
            cancel: { _ in await tracker.cancel() }
        )
    }

    private func candidate(
        host: String,
        port: UInt16,
        spkiByte: UInt8,
        token: UInt64
    ) -> LSPDiscoveredPairingHost {
        .init(
            hostID: UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!,
            serverSPKISHA256: Data(repeating: spkiByte, count: 32),
            port: port,
            host: host,
            name: "Unverified Gaming PC",
            capabilities: "input,video",
            domain: "local.",
            interfaceName: "en0",
            discoveryChangeToken: token,
            discoveryServiceID: "Unverified Gaming PC|_lumen-stream._udp|local.|en0"
        )
    }

    private func waitUntil(
        _ condition: @escaping @Sendable () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<500 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Condition was not satisfied", file: file, line: line)
    }
}

private actor PairingOperationTracker {
    private(set) var beginCount = 0
    private(set) var verificationCount = 0
    private(set) var cancellationCount = 0
    private var suspendBegin: Bool
    private var suspendVerification: Bool
    private var beginWaiters: [CheckedContinuation<Void, Never>] = []
    private var verificationWaiters: [CheckedContinuation<Void, Never>] = []

    init(suspendBegin: Bool, suspendVerification: Bool) {
        self.suspendBegin = suspendBegin
        self.suspendVerification = suspendVerification
    }

    func begin(_ host: LSPDiscoveredPairingHost) async {
        _ = host
        beginCount += 1
        guard suspendBegin else { return }
        await withCheckedContinuation { beginWaiters.append($0) }
    }

    func verify() async {
        verificationCount += 1
        guard suspendVerification else { return }
        await withCheckedContinuation { verificationWaiters.append($0) }
    }

    func cancel() {
        cancellationCount += 1
    }

    func cancellationCountValue() -> Int {
        cancellationCount
    }

    func releaseBegin() {
        suspendBegin = false
        let waiters = beginWaiters
        beginWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func releaseVerification() {
        suspendVerification = false
        let waiters = verificationWaiters
        verificationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private final class PairingMutationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var mutations: [LSPPairingDiscoveryMutation] = []
    var values: [LSPPairingDiscoveryMutation] { lock.withLock { mutations } }
    func record(_ mutation: LSPPairingDiscoveryMutation) { lock.withLock { mutations.append(mutation) } }
}

private final class FailOnce: @unchecked Sendable {
    struct InjectedFailure: Error {}
    private let lock = NSLock()
    private var failed = false

    func call() throws {
        let shouldFail = lock.withLock { () -> Bool in
            guard !failed else { return false }
            failed = true
            return true
        }
        if shouldFail { throw InjectedFailure() }
    }
}

private struct PairingProductFixture {
    let directory: URL
    let stores: (
        trust: JSONFileStore<LSPTrustSnapshot>,
        hosts: JSONFileStore<LSPHostSnapshot>,
        identity: JSONFileStore<LSPClientIdentitySnapshot>
    )

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UmbraLSPProductPairing-\(UUID().uuidString)", isDirectory: true)
        stores = LSPPersistence.stores(in: directory)
    }

    func product(
        operations: LSPProductPairingOperations,
        afterTrustWrite: @escaping @Sendable () throws -> Void = {}
    ) -> LSPProductClient {
        LSPProductClient(
            trustStore: stores.trust,
            hostStore: stores.hosts,
            identityStore: stores.identity,
            pairingOperations: operations,
            afterPairingTrustWrite: afterTrustWrite
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

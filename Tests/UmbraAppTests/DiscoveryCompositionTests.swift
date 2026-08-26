import CryptoKit
import Foundation
import UmbraCore
@testable import UmbraApp
@testable import UmbraNetworking
import UmbraProtocolV3
import XCTest

@MainActor
final class DiscoveryCompositionTests: XCTestCase {
    func testLumenPublisherRecordsComposeThroughUmbraBrowsersWithoutDowngrade() async throws {
        let fixture = try loadFixture()
        XCTAssertEqual(fixture.schemaVersion, 1)
        XCTAssertEqual(fixture.producer.repository, "Lumen")
        XCTAssertEqual(fixture.producer.commit, "75aaf7e3")
        XCTAssertEqual(fixture.producer.serviceAssembly, "src/main.cpp:440-505")
        XCTAssertEqual(fixture.producer.modernFormatter, "src/protocol_v3/runtime.cpp:385-405")
        XCTAssertEqual(fixture.producer.publisherValidator, "src/platform/common.h:1300-1338")
        let legacy = try XCTUnwrap(fixture.services.first { $0.role == "legacy" })
        let modern = try XCTUnwrap(fixture.services.first { $0.role == "modern" })
        XCTAssertTrue(legacy.txt.isEmpty)
        XCTAssertEqual(modern.txt.count, 4)
        XCTAssertTrue(modern.txt.allSatisfy { $0.count == 2 })
        let hostPublicKey = try Data(hexadecimal: fixture.hostPublicKey)
        let hostID = Data(SHA256.hash(data: hostPublicKey).prefix(16))
        XCTAssertEqual(modern.txtDictionary["id"], hostID.hexadecimal)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UmbraDiscoveryComposition-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let trustStore = FileBackedProtocolV3TrustStore(url: root.appendingPathComponent("trust.json"))
        let hostCatalog = FileBackedModernLumenV3HostCatalog(url: root.appendingPathComponent("hosts.json"))
        let identity = try trustStore.identity()
        try trustStore.commit(
            identity: identity,
            trust: ProtocolV3TrustRecord(
                hostID: hostID,
                hostPublicKey: hostPublicKey,
                tlsSPKIHash: Data(repeating: 0xA5, count: 32),
                clientID: identity.clientID,
                grantedPermissions: 0x17,
                pairingGeneration: 1
            )
        )
        try hostCatalog.upsert(ModernLumenV3HostRecord(
            hostID: hostID,
            hostname: "stale-invitation.local",
            hostnameIsIPLiteral: false,
            port: UInt16(modern.port),
            displayName: "Pinned Lumen",
            applications: [],
            applicationRevision: nil,
            runningApplicationID: nil
        ))

        let browserFactory = CompositionBrowserFactory()
        let scheduler = CompositionRetryScheduler()
        let modernSource = NetworkBonjourDiscovery(
            queue: DispatchQueue(label: "test.umbra.composition.modern"),
            browserFactory: browserFactory,
            retryScheduler: scheduler,
            serviceKind: .modernLumenV3
        )
        let modernDiscovery = NetworkProtocolV3Discovery(
            source: modernSource,
            resolver: CompositionResolver(
                endpoint: ProtocolV3ResolvedEndpoint(
                    hostname: fixture.resolvedHost,
                    port: UInt16(modern.port)
                )
            )
        )
        let manager = ModernLumenV3Manager(
            trustStore: trustStore,
            hostCatalog: hostCatalog,
            discovery: modernDiscovery,
            log: nil
        )
        let legacyDiscovery = NetworkBonjourDiscovery(
            queue: DispatchQueue(label: "test.umbra.composition.legacy"),
            browserFactory: browserFactory,
            retryScheduler: scheduler,
            serviceKind: .legacyGameStream
        )
        let legacyRecorder = CompositionDiscoveryRecorder()

        manager.startDiscovery()
        legacyDiscovery.start { legacyRecorder.record($0) }
        let modernBrowser = try XCTUnwrap(browserFactory.browser(for: .modernLumenV3))
        let legacyBrowser = try XCTUnwrap(browserFactory.browser(for: .legacyGameStream))
        let legacyService = legacy.discoveredService(
            name: fixture.instanceName,
            domain: fixture.domain
        )
        let modernService = modern.discoveredService(
            name: fixture.instanceName,
            domain: fixture.domain
        )
        legacyBrowser.send(services: [legacyService])
        modernBrowser.send(services: [modernService])

        await eventually {
            (try? hostCatalog.host(hostID: hostID)?.hostname) == fixture.resolvedHost
        }
        XCTAssertEqual(legacyRecorder.events, [.added(legacyService)])
        let displayed = try XCTUnwrap(manager.displayHosts().first)
        XCTAssertTrue(displayed.id.rawValue.hasPrefix("v3:"))
        XCTAssertTrue(displayed.details.contains("downgrade disabled"))
        XCTAssertTrue(displayed.details.contains("\(fixture.resolvedHost):\(modern.port)"))

        modernBrowser.send(state: .failed("deterministic publisher withdrawal"))
        await Task.yield()
        XCTAssertEqual(try hostCatalog.host(hostID: hostID)?.hostname, fixture.resolvedHost)
        XCTAssertEqual(try manager.displayHosts().map(\.id), [displayed.id])
        XCTAssertEqual(legacyRecorder.events, [.added(legacyService)])

        manager.stopDiscovery()
        legacyDiscovery.stop()
    }

    private func loadFixture() throws -> DiscoveryCompositionFixture {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "lumen_v3_discovery_composition_75aaf7e3",
            withExtension: "json"
        ))
        return try JSONDecoder().decode(
            DiscoveryCompositionFixture.self,
            from: Data(contentsOf: url)
        )
    }

    private func eventually(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Condition was not satisfied", file: file, line: line)
    }
}

private struct DiscoveryCompositionFixture: Decodable {
    struct Producer: Decodable {
        let repository: String
        let commit: String
        let serviceAssembly: String
        let modernFormatter: String
        let publisherValidator: String
    }

    struct Service: Decodable {
        let role: String
        let type: String
        let port: Int
        let txt: [[String]]

        var txtDictionary: [String: String] {
            Dictionary(uniqueKeysWithValues: txt.compactMap { pair in
                guard pair.count == 2 else { return nil }
                return (pair[0], pair[1])
            })
        }

        func discoveredService(name: String, domain: String) -> DiscoveredHostService {
            DiscoveredHostService(
                name: name,
                type: type,
                domain: domain,
                interfaceName: "fixture0",
                txtRecord: txtDictionary
            )
        }
    }

    let schemaVersion: Int
    let producer: Producer
    let instanceName: String
    let domain: String
    let resolvedHost: String
    let hostPublicKey: String
    let services: [Service]
}

private final class CompositionBrowserFactory: BonjourBrowserCreating, @unchecked Sendable {
    private let lock = NSLock()
    private var browsers: [BonjourServiceKind: CompositionBrowser] = [:]

    func makeBrowser(for kind: BonjourServiceKind) -> any BonjourBrowsing {
        let browser = CompositionBrowser()
        lock.withLock { browsers[kind] = browser }
        return browser
    }

    func browser(for kind: BonjourServiceKind) -> CompositionBrowser? {
        lock.withLock { browsers[kind] }
    }
}

private final class CompositionBrowser: BonjourBrowsing, @unchecked Sendable {
    private let lock = NSLock()
    private var stateHandler: (@Sendable (BonjourBrowserState) -> Void)?
    private var resultsHandler: (@Sendable (Set<DiscoveredHostService>) -> Void)?

    func setStateUpdateHandler(_ handler: @escaping @Sendable (BonjourBrowserState) -> Void) {
        lock.withLock { stateHandler = handler }
    }

    func setResultsChangedHandler(
        _ handler: @escaping @Sendable (Set<DiscoveredHostService>) -> Void
    ) {
        lock.withLock { resultsHandler = handler }
    }

    func start(queue: DispatchQueue) {}
    func cancel() {}

    func send(state: BonjourBrowserState) {
        lock.withLock { stateHandler }?(state)
    }

    func send(services: Set<DiscoveredHostService>) {
        lock.withLock { resultsHandler }?(services)
    }
}

private struct CompositionResolver: ProtocolV3ServiceResolving, Sendable {
    let endpoint: ProtocolV3ResolvedEndpoint

    func resolve(_ service: DiscoveredHostService) async throws -> ProtocolV3ResolvedEndpoint {
        endpoint
    }
}

private struct CompositionRetryScheduler: BonjourRetryScheduling, Sendable {
    func schedule(
        after delay: TimeInterval,
        on queue: DispatchQueue,
        action: @escaping @Sendable () -> Void
    ) -> any BonjourRetryCancellable {
        CompositionRetryCancellation()
    }
}

private final class CompositionRetryCancellation: BonjourRetryCancellable, @unchecked Sendable {
    func cancel() {}
}

private final class CompositionDiscoveryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [DiscoveryEvent] = []

    var events: [DiscoveryEvent] {
        lock.withLock { recorded }
    }

    func record(_ event: DiscoveryEvent) {
        lock.withLock { recorded.append(event) }
    }
}

private extension Data {
    init(hexadecimal: String) throws {
        guard hexadecimal.count.isMultiple(of: 2) else {
            throw CocoaError(.coderInvalidValue)
        }
        self.init()
        reserveCapacity(hexadecimal.count / 2)
        var cursor = hexadecimal.startIndex
        while cursor < hexadecimal.endIndex {
            let next = hexadecimal.index(cursor, offsetBy: 2)
            guard let byte = UInt8(hexadecimal[cursor..<next], radix: 16) else {
                throw CocoaError(.coderInvalidValue)
            }
            append(byte)
            cursor = next
        }
    }

    var hexadecimal: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

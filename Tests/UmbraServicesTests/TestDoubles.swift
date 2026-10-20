import Foundation
import UmbraCore
import UmbraNetworking
@testable import UmbraServices

actor MemorySnapshotStore: SnapshotPersisting {
    private var snapshot: UmbraSnapshot
    private(set) var saveCount = 0

    init(_ snapshot: UmbraSnapshot = .defaultValue) {
        self.snapshot = snapshot
    }

    func load() async throws -> UmbraSnapshot { snapshot }

    func save(_ snapshot: UmbraSnapshot) async throws {
        self.snapshot = snapshot
        saveCount += 1
    }

    func update(
        _ transform: @Sendable (UmbraSnapshot) throws -> UmbraSnapshot
    ) async throws -> UmbraSnapshot {
        snapshot = try transform(snapshot)
        saveCount += 1
        return snapshot
    }

    func value() -> UmbraSnapshot { snapshot }
}

actor ReorderingSnapshotStore: SnapshotPersisting {
    private var snapshot: UmbraSnapshot
    private var updateCount = 0
    private var firstUpdateCommitted = false
    private var firstReturnContinuation: CheckedContinuation<Void, Never>?

    init(_ snapshot: UmbraSnapshot) {
        self.snapshot = snapshot
    }

    func load() async throws -> UmbraSnapshot { snapshot }

    func save(_ snapshot: UmbraSnapshot) async throws {
        self.snapshot = snapshot
    }

    func update(
        _ transform: @Sendable (UmbraSnapshot) throws -> UmbraSnapshot
    ) async throws -> UmbraSnapshot {
        updateCount += 1
        let invocation = updateCount
        snapshot = try transform(snapshot)
        let committed = snapshot
        if invocation == 1 {
            firstUpdateCommitted = true
            await withCheckedContinuation { firstReturnContinuation = $0 }
        }
        return committed
    }

    func waitUntilFirstUpdateCommitted() async {
        while !firstUpdateCommitted { await Task.yield() }
    }

    func releaseFirstReturn() {
        firstReturnContinuation?.resume()
        firstReturnContinuation = nil
    }
}

actor FakeGameStreamClient: GameStreamServing {
    struct ServerInfoCall: Sendable, Equatable {
        var address: HostAddress
        var secure: Bool
        var fastFail: Bool
    }

    struct StartCall: Sendable, Equatable {
        var kind: SessionStartKind
        var address: HostAddress
        var configuration: LaunchConfiguration
    }

    private var serverInfos: [HostAddress: ServerInfo] = [:]
    private var serverInfoQueues: [HostAddress: [ServerInfo]] = [:]
    private var applicationsValue: [GameStreamApp] = []
    private var assetValue = Data()
    private var sessionURL: URL?
    private var startResults: [Result<LaunchResponse, UmbraNetworkingError>] = []
    private var suspendedServerInfoResponseCount = 0
    private var serverInfoWaiters: [CheckedContinuation<Void, Never>] = []
    private var suspendedApplicationResponseCount = 0
    private var applicationWaiters: [CheckedContinuation<Void, Never>] = []
    private var suspendedStartResponseCount = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var forcedError: UmbraNetworkingError?
    private var forcedURLErrorCode: URLError.Code?
    private(set) var serverInfoCalls: [ServerInfoCall] = []
    private(set) var applicationAddresses: [HostAddress] = []
    private(set) var assetRequests: [(HostAddress, Int)] = []
    private(set) var startCalls: [StartCall] = []
    private(set) var cancellationAddresses: [HostAddress] = []

    func setServerInfo(_ info: ServerInfo, at address: HostAddress) {
        serverInfos[address] = info
    }

    func enqueueServerInfo(_ values: [ServerInfo], at address: HostAddress) {
        serverInfoQueues[address] = values
    }

    func removeAllServerInfo() { serverInfos.removeAll() }
    func setApplications(_ applications: [GameStreamApp]) { applicationsValue = applications }
    func setAsset(_ data: Data) { assetValue = data }
    func setSessionURL(_ url: URL?) { sessionURL = url }
    func enqueueStartResults(_ results: [Result<LaunchResponse, UmbraNetworkingError>]) {
        startResults.append(contentsOf: results)
    }
    func suspendNextServerInfoResponses(_ count: Int = 1) {
        suspendedServerInfoResponseCount += max(0, count)
    }

    func resumeSuspendedServerInfoResponses() {
        let waiters = serverInfoWaiters
        serverInfoWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
    func suspendNextApplicationResponses(_ count: Int = 1) {
        suspendedApplicationResponseCount += max(0, count)
    }
    func resumeSuspendedApplicationResponses() {
        let waiters = applicationWaiters
        applicationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
    func suspendNextStartResponses(_ count: Int = 1) {
        suspendedStartResponseCount += max(0, count)
    }
    func resumeSuspendedStartResponses() {
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
    func setError(_ error: UmbraNetworkingError?) { forcedError = error }
    func setURLError(_ code: URLError.Code?) { forcedURLErrorCode = code }

    func fetchServerInfo(address: HostAddress, secure: Bool, fastFail: Bool) async throws -> ServerInfo {
        serverInfoCalls.append(.init(address: address, secure: secure, fastFail: fastFail))
        let queuedValue: ServerInfo?
        if var queue = serverInfoQueues[address], !queue.isEmpty {
            queuedValue = queue.removeFirst()
            serverInfoQueues[address] = queue
        } else {
            queuedValue = nil
        }
        let shouldSuspend = suspendedServerInfoResponseCount > 0
        if shouldSuspend {
            suspendedServerInfoResponseCount -= 1
            await withCheckedContinuation { continuation in
                serverInfoWaiters.append(continuation)
            }
        }
        if let forcedError { throw forcedError }
        if let forcedURLErrorCode { throw URLError(forcedURLErrorCode) }
        if let queuedValue { return queuedValue }
        guard let value = serverInfos[address] else { throw URLError(.cannotConnectToHost) }
        return value
    }

    func fetchApplications(address: HostAddress) async throws -> [GameStreamApp] {
        applicationAddresses.append(address)
        let value = applicationsValue
        let shouldSuspend = suspendedApplicationResponseCount > 0
        if shouldSuspend {
            suspendedApplicationResponseCount -= 1
            await withCheckedContinuation { continuation in
                applicationWaiters.append(continuation)
            }
        }
        if let forcedError { throw forcedError }
        return value
    }

    func startSession(
        kind: SessionStartKind,
        address: HostAddress,
        configuration: LaunchConfiguration
    ) async throws -> LaunchResponse {
        startCalls.append(.init(kind: kind, address: address, configuration: configuration))
        let queuedResult = startResults.isEmpty ? nil : startResults.removeFirst()
        let shouldSuspend = suspendedStartResponseCount > 0
        if shouldSuspend {
            suspendedStartResponseCount -= 1
            await withCheckedContinuation { continuation in
                startWaiters.append(continuation)
            }
        }
        if let queuedResult { return try queuedResult.get() }
        if let forcedError { throw forcedError }
        return LaunchResponse(sessionURL: sessionURL)
    }

    func cancelSession(address: HostAddress) async throws {
        cancellationAddresses.append(address)
        if let forcedError { throw forcedError }
    }

    func fetchApplicationAsset(address: HostAddress, appID: Int) async throws -> Data {
        assetRequests.append((address, appID))
        if let forcedError { throw forcedError }
        return assetValue
    }

    func recordedServerInfoCalls() -> [ServerInfoCall] { serverInfoCalls }
    func recordedStartCalls() -> [StartCall] { startCalls }
    func recordedCancellationAddresses() -> [HostAddress] { cancellationAddresses }
    func recordedApplicationAddresses() -> [HostAddress] { applicationAddresses }
    func recordedAssetRequests() -> [(HostAddress, Int)] { assetRequests }
}

struct FakeClientProvider: GameStreamClientProviding, Sendable {
    let value: FakeGameStreamClient
    func client(for host: StreamHost?) -> any GameStreamServing { value }
}

final class FakeBonjourDiscovery: BonjourDiscovering, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (DiscoveryEvent) -> Void)?
    private var startCount = 0
    private var stopCount = 0

    func start(eventHandler: @escaping @Sendable (DiscoveryEvent) -> Void) {
        lock.withLock {
            startCount += 1
            handler = eventHandler
        }
    }

    func stop() {
        lock.withLock {
            stopCount += 1
            handler = nil
        }
    }

    func emit(_ event: DiscoveryEvent) {
        let callback = lock.withLock { handler }
        callback?(event)
    }

    func recordedLifecycleCounts() -> (starts: Int, stops: Int) {
        lock.withLock { (startCount, stopCount) }
    }
}

struct FakeDiscoveryResolver: DiscoveredServiceResolving, Sendable {
    let address: HostAddress
    func resolve(_ service: DiscoveredHostService) async throws -> HostAddress { address }
}

actor SuspendingDiscoveryResolver: DiscoveredServiceResolving {
    private let address: HostAddress
    private var continuation: CheckedContinuation<HostAddress, Never>?

    init(address: HostAddress) {
        self.address = address
    }

    func resolve(_ service: DiscoveredHostService) async throws -> HostAddress {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func hasPendingResolution() -> Bool {
        continuation != nil
    }

    func resume() {
        continuation?.resume(returning: address)
        continuation = nil
    }
}

actor FakeWakeSender: WakeOnLANSending {
    var shouldSucceed = true
    private(set) var sends: [(Data, [WakeOnLANTarget])] = []

    func setShouldSucceed(_ value: Bool) { shouldSucceed = value }

    func send(
        macAddress: Data,
        to targets: [WakeOnLANTarget]
    ) async -> [WakeOnLANTarget: Result<Void, Error>] {
        sends.append((macAddress, targets))
        return Dictionary(uniqueKeysWithValues: targets.map {
            ($0, shouldSucceed ? .success(()) : .failure(URLError(.cannotConnectToHost)))
        })
    }
}

actor ImmediateServiceClock: ServiceClock {
    private(set) var sleepCount = 0

    func sleep(for interval: Duration) async throws {
        try Task.checkCancellation()
        sleepCount += 1
    }

    func recordedSleepCount() -> Int { sleepCount }
}

actor FakePairingAdapter: HostPairingAdapting {
    let certificate: Data
    private(set) var receivedHost: HostAddress?
    private(set) var receivedPIN: String?
    private(set) var receivedVersion: String?
    private(set) var receivedNVIDIAServerSoftware: Bool?
    private(set) var cancelledHostID: String?

    init(certificate: Data) { self.certificate = certificate }

    func pair(
        host: HostAddress,
        pin: String,
        appVersion: String,
        isNVIDIAServerSoftware: Bool,
        progress: @escaping @Sendable (PairingProgress) -> Void
    ) async throws -> Data {
        receivedHost = host
        receivedPIN = pin
        receivedVersion = appVersion
        receivedNVIDIAServerSoftware = isNVIDIAServerSoftware
        progress(PairingProgress(stage: .complete, message: "paired"))
        return certificate
    }

    func cancel(hostID: String) async { cancelledHostID = hostID }

    func received() -> (HostAddress?, String?, String?, Bool?) {
        (receivedHost, receivedPIN, receivedVersion, receivedNVIDIAServerSoftware)
    }
}

actor BlockingStreamDriver: StreamSessionDriving {
    private(set) var preparedBootstrap: StreamBootstrap?
    private(set) var preparedBootstraps: [StreamBootstrap] = []
    private(set) var prepareCount = 0
    private(set) var bootstrap: StreamBootstrap?
    private(set) var cancelCount = 0
    private var shouldSuspendPreparation = false
    private var preparationContinuation: CheckedContinuation<Void, Never>?
    private var continuation: CheckedContinuation<SessionResult, Error>?
    private var eventHandler: (@Sendable (StreamDriverEvent) -> Void)?
    private var preparationBarrierFailure: UmbraServiceError?

    func prepare(_ bootstrap: StreamBootstrap) async throws -> StreamPreparationResult {
        prepareCount += 1
        preparedBootstrap = bootstrap
        preparedBootstraps.append(bootstrap)
        if shouldSuspendPreparation {
            shouldSuspendPreparation = false
            await withCheckedContinuation { preparationContinuation = $0 }
        }
        let hdr = bootstrap.preferences.enableHDR
            && bootstrap.application.hdrSupported
            && !bootstrap.host.codecSupport.intersection(.all10Bit).isEmpty
        let yuv444 = bootstrap.preferences.enableYUV444
            && !bootstrap.host.codecSupport.intersection(.allYUV444).isEmpty
        let format: Int32
        if hdr {
            format = 0x0200
        } else if yuv444 {
            format = 0x0004
        } else {
            format = 0x0001
        }
        return StreamPreparationResult(
            selectedVideoFormat: format,
            isHDR: hdr,
            isYUV444: yuv444
        )
    }

    func suspendNextPreparation() { shouldSuspendPreparation = true }
    func resumeSuspendedPreparation() {
        preparationContinuation?.resume()
        preparationContinuation = nil
    }

    func run(
        _ bootstrap: StreamBootstrap,
        events: @escaping @Sendable (StreamDriverEvent) -> Void
    ) async throws -> SessionResult {
        self.bootstrap = bootstrap
        eventHandler = events
        events(.connecting(.videoStreamInitialization))
        events(.streaming(Date(timeIntervalSince1970: 100)))
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func waitUntilPrepared(sessionID: UUID) async throws {
        if let failure = preparationBarrierFailure {
            preparationBarrierFailure = nil
            throw failure
        }
    }

    func failNextPreparationBarrier(with failure: UmbraServiceError) {
        preparationBarrierFailure = failure
    }

    func cancel() async {
        cancelCount += 1
        resumeSuspendedPreparation()
        continuation?.resume(returning: SessionResult())
        continuation = nil
    }

    func receivedBootstrap() -> StreamBootstrap? { bootstrap }
    func receivedPreparedBootstrap() -> StreamBootstrap? { preparedBootstrap }
    func receivedPreparedBootstraps() -> [StreamBootstrap] { preparedBootstraps }
    func recordedPrepareCount() -> Int { prepareCount }
    func recordedCancelCount() -> Int { cancelCount }
    func emit(_ event: StreamDriverEvent) { eventHandler?(event) }
}

actor FailingPreparationStreamDriver: StreamSessionDriving {
    let failure: SessionFailure
    private(set) var prepareCount = 0
    private(set) var runCount = 0
    private(set) var cancelCount = 0

    init(failure: SessionFailure) {
        self.failure = failure
    }

    func prepare(_ bootstrap: StreamBootstrap) async throws -> StreamPreparationResult {
        prepareCount += 1
        throw failure
    }

    func run(
        _ bootstrap: StreamBootstrap,
        events: @escaping @Sendable (StreamDriverEvent) -> Void
    ) async throws -> SessionResult {
        runCount += 1
        throw failure
    }

    func cancel() async { cancelCount += 1 }

    func recordedCounts() -> (prepare: Int, run: Int, cancel: Int) {
        (prepareCount, runCount, cancelCount)
    }
}

struct FixedCredentialProvider: RemoteInputCredentialProviding, Sendable {
    let credentials: RemoteInputCredentials
    func makeCredentials() throws -> RemoteInputCredentials { credentials }
}

struct FixedUUIDProvider: UUIDProviding, Sendable {
    let value: UUID
    func makeUUID() -> UUID { value }
}

func makeServerInfo(
    id: String = "host-1",
    name: String = "Studio Mac",
    pairState: UmbraNetworking.PairState = .paired,
    currentGameID: Int = 0,
    appVersion: String = "8.0.0",
    serverCodecModeSupport: Int = 0x301,
    maxLumaPixelsHEVC: Int = 8_294_400
) -> ServerInfo {
    ServerInfo(
        name: name,
        uniqueID: id,
        macAddress: Data([0, 1, 2, 3, 4, 5]),
        localAddress: "192.168.1.10",
        externalAddress: "203.0.113.5",
        httpsPort: 47_984,
        externalPort: 47_989,
        pairState: pairState,
        currentGameID: currentGameID,
        appVersion: appVersion,
        gfeVersion: "3.27",
        gpuModel: "Apple Silicon",
        serverCodecModeSupport: serverCodecModeSupport,
        maxLumaPixelsHEVC: maxLumaPixelsHEVC,
        displayModes: [.init(width: 1_920, height: 1_080, refreshRate: 60)]
    )
}

func makeHost(
    id: String = "host-1",
    name: String = "Studio Mac",
    status: HostStatus = .online,
    pairState: UmbraCore.PairState = .paired,
    currentGameID: Int? = nil,
    certificate: Data = Data([9, 8, 7]),
    applications: [StreamApplication] = [StreamApplication(id: 1, name: "Desktop", hdrSupported: true)]
) -> StreamHost {
    StreamHost(
        uuid: id,
        name: name,
        macAddress: Data([0, 1, 2, 3, 4, 5]),
        localAddress: NetworkEndpoint(hostname: "192.168.1.10"),
        serverCertificate: certificate,
        applications: applications,
        status: status,
        pairState: pairState,
        activeAddress: NetworkEndpoint(hostname: "192.168.1.10"),
        activeHTTPSPort: 47_984,
        currentGameID: currentGameID,
        appVersion: "8.0.0"
    )
}

func eventually(
    attempts: Int = 1_000,
    condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}

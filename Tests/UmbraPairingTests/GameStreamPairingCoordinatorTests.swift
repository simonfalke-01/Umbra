import Foundation
import Security
import XCTest
import UmbraNetworking
@testable import UmbraPairing

final class GameStreamPairingCoordinatorTests: XCTestCase {
    func testConcurrentPairingAttemptIsRejectedAsAlreadyInProgress() async throws {
        let identity = try makeEphemeralIdentity()
        let transcript = HoldingTranscript()
        let coordinator = GameStreamPairingCoordinator(
            transcript: transcript,
            identityProvider: StaticClientIdentityProvider(identity),
            appVersion: "7.1.0.0",
            randomSource: SequenceRandomSource([Data(0x00...0x0F)])
        )

        let activePairing = Task {
            try await coordinator.pair(
                host: HostAddress(host: "lumen.test"),
                pin: "1234",
                appVersion: "7.1.0.0"
            )
        }
        await transcript.waitUntilStarted()

        do {
            _ = try await coordinator.pair(
                host: HostAddress(host: "lumen.test"),
                pin: "5678",
                appVersion: "7.1.0.0"
            )
            XCTFail("Concurrent pairing unexpectedly started")
        } catch {
            XCTAssertEqual(error as? PairingError, .alreadyInProgress)
        }

        coordinator.cancel()
        do {
            _ = try await activePairing.value
            XCTFail("Active pairing unexpectedly completed after cancellation")
        } catch {
            XCTAssertEqual(error as? PairingError, .cancelled)
        }
    }

    func testSuccessfulCertificateResponseMissingPlaincertIsInvalidResponse() async throws {
        try await assertInvalidCertificateResponse(
            values: ["paired": "1"],
            reason: "plaincert is missing"
        )
    }

    func testSuccessfulCertificateResponseWithEmptyPlaincertIsInvalidResponse() async throws {
        try await assertInvalidCertificateResponse(
            values: ["paired": "1", "plaincert": ""],
            reason: "plaincert is empty"
        )
    }

    func testCancelInterruptsHeldServerCertificateRequest() async throws {
        let identity = try makeEphemeralIdentity()
        let transcript = HoldingTranscript()
        let coordinator = GameStreamPairingCoordinator(
            transcript: transcript,
            identityProvider: StaticClientIdentityProvider(identity),
            appVersion: "7.1.0.0",
            randomSource: SequenceRandomSource([Data(0x00...0x0F)])
        )

        let pairingTask = Task {
            try await coordinator.pair(
                host: HostAddress(host: "lumen.test"),
                pin: "1234",
                appVersion: "7.1.0.0"
            )
        }
        await transcript.waitUntilStarted()

        coordinator.cancel()

        do {
            _ = try await pairingTask.value
            XCTFail("Pairing unexpectedly completed after cancellation")
        } catch {
            XCTAssertEqual(error as? PairingError, .cancelled)
        }
        let wasCancelled = await transcript.wasCancelled
        XCTAssertTrue(wasCancelled)
    }

    func testPublicUnpairRejectsProtocolFailureStatus() async throws {
        let identity = try makeEphemeralIdentity()
        let coordinator = GameStreamPairingCoordinator(
            transcript: RejectedUnpairTranscript(),
            identityProvider: StaticClientIdentityProvider(identity),
            appVersion: "7.1.0.0"
        )

        do {
            try await coordinator.unpair(host: HostAddress(host: "lumen.test"))
            XCTFail("Rejected unpair unexpectedly succeeded")
        } catch {
            XCTAssertEqual(error as? PairingError, .unpairRejected(statusCode: 503))
        }
    }

    func testPairingFailurePreservesRejectedCleanupDetails() async throws {
        let clientIdentity = try makeEphemeralIdentity(serialNumber: Data([0x31]))
        let serverIdentity = try makeEphemeralIdentity(serialNumber: Data([0x32]))
        let coordinator = GameStreamPairingCoordinator(
            transcript: CleanupFailureTranscript(serverIdentity: serverIdentity),
            identityProvider: StaticClientIdentityProvider(clientIdentity),
            appVersion: "7.1.0.0",
            randomSource: SequenceRandomSource([
                Data(0x00...0x0F),
                Data(0x10...0x1F),
            ])
        )

        do {
            _ = try await coordinator.pair(
                host: HostAddress(host: "lumen.test"),
                pin: "1234",
                appVersion: "7.1.0.0"
            )
            XCTFail("Pairing unexpectedly succeeded")
        } catch let PairingError.cleanupFailed(pairing, cleanup) {
            XCTAssertTrue(pairing.contains(PairingStage.exchangingChallenges.rawValue))
            XCTAssertTrue(cleanup.contains("503"))
        }
    }

    func testFiveStageSHA256TranscriptPinsCertificateOnlyAfterMutualProof() async throws {
        let clientIdentity = try makeEphemeralIdentity(commonName: "Test GameStream Client", serialNumber: Data([1]))
        let serverIdentity = try makeEphemeralIdentity(commonName: "Test Lumen Host", serialNumber: Data([2]))
        let random = SequenceRandomSource([
            Data(0x00...0x0F),
            Data(0x10...0x1F),
            Data(0x20...0x2F),
        ])
        let transcript = try ProtocolTranscript(
            pin: "1234",
            digest: .sha256,
            serverIdentity: serverIdentity,
            expectedClientSecret: Data(0x20...0x2F)
        )
        let coordinator = GameStreamPairingCoordinator(
            transcript: transcript,
            identityProvider: StaticClientIdentityProvider(clientIdentity),
            appVersion: "7.1.0.0",
            randomSource: random
        )
        let host = HostAddress(host: "lumen.test")
        let progress = ProgressRecorder()

        let result = try await coordinator.pair(
            host: host,
            pin: "1234",
            appVersion: "7.1.0.0",
            onProgress: { progress.append($0.stage) }
        )

        XCTAssertEqual(result.serverCertificateDER, serverIdentity.certificateDER)
        XCTAssertEqual(progress.values, PairingStage.allCases)
        let requests = await transcript.requests
        XCTAssertEqual(requests.count, 5)
        XCTAssertEqual(requests.map(\.endpoint), [.pair, .pair, .pair, .pair, .pair])
        XCTAssertEqual(requests.map(\.scheme), [.http, .http, .http, .http, .https])
        XCTAssertEqual(requests.last?.pinnedServerCertificateDER, serverIdentity.certificateDER)
        let didValidateChallengeProof = await transcript.didValidateChallengeProof
        let didValidateClientSecret = await transcript.didValidateClientSecret
        XCTAssertTrue(didValidateChallengeProof)
        XCTAssertTrue(didValidateClientSecret)
    }

    func testIncorrectPINIsTypedAndTriggersUnpairCleanupWithoutPinning() async throws {
        let clientIdentity = try makeEphemeralIdentity(serialNumber: Data([3]))
        let serverIdentity = try makeEphemeralIdentity(serialNumber: Data([4]))
        let transcript = try ProtocolTranscript(
            pin: "9876",
            digest: .sha256,
            serverIdentity: serverIdentity,
            expectedClientSecret: Data(0x20...0x2F),
            validateChallengeProof: false
        )
        let coordinator = GameStreamPairingCoordinator(
            transcript: transcript,
            identityProvider: StaticClientIdentityProvider(clientIdentity),
            appVersion: "7.0.0.0",
            randomSource: SequenceRandomSource([
                Data(0x00...0x0F),
                Data(0x10...0x1F),
                Data(0x20...0x2F),
            ])
        )
        let host = HostAddress(host: "wrong-pin.test")

        do {
            _ = try await coordinator.pair(host: host, pin: "1234", appVersion: "7.0.0.0")
            XCTFail("Pairing unexpectedly succeeded")
        } catch {
            XCTAssertEqual(error as? PairingError, .incorrectPIN)
        }

        let requests = await transcript.requests
        XCTAssertEqual(requests.last?.endpoint, .unpair)
        XCTAssertEqual(requests.filter { $0.endpoint == .unpair }.count, 1)
    }

    func testSHA1TranscriptPadsClientChallengeProofToTwoAESBlocks() async throws {
        let clientIdentity = try makeEphemeralIdentity(serialNumber: Data([5]))
        let serverIdentity = try makeEphemeralIdentity(serialNumber: Data([6]))
        let transcript = try ProtocolTranscript(
            pin: "1234",
            digest: .sha1,
            serverIdentity: serverIdentity,
            expectedClientSecret: Data(0x20...0x2F)
        )
        let coordinator = GameStreamPairingCoordinator(
            transcript: transcript,
            identityProvider: StaticClientIdentityProvider(clientIdentity),
            appVersion: "6.0.0.0",
            randomSource: SequenceRandomSource([
                Data(0x00...0x0F),
                Data(0x10...0x1F),
                Data(0x20...0x2F),
            ])
        )

        _ = try await coordinator.pair(
            host: HostAddress(host: "legacy-gfe.test"),
            pin: "1234",
            appVersion: "6.0.0.0"
        )
        let didValidateChallengeProof = await transcript.didValidateChallengeProof
        XCTAssertTrue(didValidateChallengeProof)
    }

    func testRejectsNonFourDigitPINBeforeStartingTranscript() async throws {
        let identity = try makeEphemeralIdentity()
        let transcript = RejectingTranscript()
        let coordinator = GameStreamPairingCoordinator(
            transcript: transcript,
            identityProvider: StaticClientIdentityProvider(identity),
            appVersion: "7.0.0.0",
            randomSource: SequenceRandomSource([])
        )

        do {
            _ = try await coordinator.pair(
                host: HostAddress(host: "host.test"),
                pin: "12ab",
                appVersion: "7.0.0.0"
            )
            XCTFail("Pairing unexpectedly accepted an invalid PIN")
        } catch {
            XCTAssertEqual(error as? PairingError, .invalidPIN)
        }
        let exchangeCount = await transcript.exchangeCount
        XCTAssertEqual(exchangeCount, 0)
    }

    func testStageOneTimeoutExplainsLumenStaleSessionRecovery() async throws {
        let identity = try makeEphemeralIdentity()
        let coordinator = GameStreamPairingCoordinator(
            transcript: TimeoutTranscript(),
            identityProvider: StaticClientIdentityProvider(identity),
            appVersion: "7.0.0.0",
            randomSource: SequenceRandomSource([Data(0x00...0x0F)])
        )

        do {
            _ = try await coordinator.pair(
                host: HostAddress(host: "lumen.test"),
                pin: "5764",
                appVersion: "7.0.0.0"
            )
            XCTFail("Expected the held PIN request to time out")
        } catch let PairingError.transport(stage, message) {
            XCTAssertEqual(stage, .requestingServerCertificate)
            XCTAssertTrue(message.contains("restart Lumen"))
        }
    }

    func testExplicitCancellationAfterCertificateExchangeTriggersUnpair() async throws {
        let clientIdentity = try makeEphemeralIdentity(serialNumber: Data([7]))
        let serverIdentity = try makeEphemeralIdentity(serialNumber: Data([8]))
        let transcript = try ProtocolTranscript(
            pin: "1234",
            digest: .sha256,
            serverIdentity: serverIdentity,
            expectedClientSecret: Data(0x20...0x2F)
        )
        let coordinator = GameStreamPairingCoordinator(
            transcript: transcript,
            identityProvider: StaticClientIdentityProvider(clientIdentity),
            appVersion: "7.0.0.0",
            randomSource: SequenceRandomSource([
                Data(0x00...0x0F),
                Data(0x10...0x1F),
            ])
        )

        do {
            _ = try await coordinator.pair(
                host: HostAddress(host: "cancelled.test"),
                pin: "1234",
                appVersion: "7.0.0.0",
                onProgress: { progress in
                    if progress.stage == .exchangingChallenges { coordinator.cancel() }
                }
            )
            XCTFail("Cancelled pairing unexpectedly succeeded")
        } catch {
            XCTAssertEqual(error as? PairingError, .cancelled)
        }
        let requests = await transcript.requests
        XCTAssertEqual(requests.map(\.endpoint), [.pair, .unpair])
    }

    private func assertInvalidCertificateResponse(
        values: [String: String],
        reason: String
    ) async throws {
        let identity = try makeEphemeralIdentity()
        let transcript = CertificateResponseTranscript(values: values)
        let coordinator = GameStreamPairingCoordinator(
            transcript: transcript,
            identityProvider: StaticClientIdentityProvider(identity),
            appVersion: "7.1.0.0",
            randomSource: SequenceRandomSource([Data(0x00...0x0F)])
        )

        do {
            _ = try await coordinator.pair(
                host: HostAddress(host: "lumen.test"),
                pin: "1234",
                appVersion: "7.1.0.0"
            )
            XCTFail("Malformed certificate response unexpectedly succeeded")
        } catch {
            XCTAssertEqual(
                error as? PairingError,
                .invalidResponse(stage: .requestingServerCertificate, reason: reason)
            )
        }

        let endpoints = await transcript.endpoints
        XCTAssertEqual(endpoints, [.pair, .unpair])
    }
}

private actor ProtocolTranscript: PairingHTTPTranscript {
    private let pin: String
    private let digest: PairingDigest
    private let serverIdentity: ClientIdentity
    private let serverSecret = Data(0x40...0x4F)
    private let serverChallenge = Data(0x30...0x3F)
    private let expectedClientSecret: Data
    private let validateChallengeProof: Bool
    private var step = 0
    private var pinKey: Data?
    private var clientChallenge: Data?
    private var clientCertificate: Data?
    private(set) var requests: [PairingTranscriptRequest] = []
    private(set) var didValidateChallengeProof = false
    private(set) var didValidateClientSecret = false

    init(
        pin: String,
        digest: PairingDigest,
        serverIdentity: ClientIdentity,
        expectedClientSecret: Data,
        validateChallengeProof: Bool = true
    ) throws {
        self.pin = pin
        self.digest = digest
        self.serverIdentity = serverIdentity
        self.expectedClientSecret = expectedClientSecret
        self.validateChallengeProof = validateChallengeProof
    }

    func exchange(_ request: PairingTranscriptRequest) async throws -> PairingTranscriptResponse {
        requests.append(request)
        if request.endpoint == .unpair {
            return PairingTranscriptResponse(values: ["paired": "0"])
        }
        defer { step += 1 }
        switch step {
        case 0:
            guard request.parameters["phrase"] == "getservercert",
                  let saltHex = request.parameters["salt"],
                  let clientCertificateHex = request.parameters["clientcert"]
            else { throw TranscriptFailure.invalidStage(1) }
            let salt = try Data(pairingHex: saltHex)
            pinKey = PairingCryptography.pinKey(salt: salt, pin: pin, using: digest)
            clientCertificate = try Data(pairingHex: clientCertificateHex)
            return PairingTranscriptResponse(values: [
                "paired": "1",
                "plaincert": serverIdentity.certificatePEM.pairingHex,
            ])
        case 1:
            guard let pinKey,
                  let encryptedHex = request.parameters["clientchallenge"]
            else { throw TranscriptFailure.invalidStage(2) }
            clientChallenge = try PairingCryptography.decrypt(Data(pairingHex: encryptedHex), key: pinKey)
            guard let clientChallenge else { throw TranscriptFailure.invalidStage(2) }
            var responseInput = clientChallenge
            responseInput.append(try PairingCertificate.signature(from: serverIdentity.certificateDER))
            responseInput.append(serverSecret)
            var plaintext = PairingCryptography.digest(responseInput, using: digest)
            plaintext.append(serverChallenge)
            let padding = (16 - plaintext.count % 16) % 16
            plaintext.append(Data(repeating: 0, count: padding))
            return PairingTranscriptResponse(values: [
                "paired": "1",
                "challengeresponse": try PairingCryptography.encrypt(plaintext, key: pinKey).pairingHex,
            ])
        case 2:
            guard let pinKey,
                  let clientCertificate,
                  let proofHex = request.parameters["serverchallengeresp"]
            else { throw TranscriptFailure.invalidStage(3) }
            if validateChallengeProof {
                var expectedProofInput = serverChallenge
                expectedProofInput.append(try PairingCertificate.signature(from: clientCertificate))
                expectedProofInput.append(expectedClientSecret)
                var expectedProof = PairingCryptography.digest(expectedProofInput, using: digest)
                if expectedProof.count < 32 {
                    expectedProof.append(Data(repeating: 0, count: 32 - expectedProof.count))
                }
                let actualProof = try PairingCryptography.decrypt(Data(pairingHex: proofHex), key: pinKey)
                guard actualProof == expectedProof else { throw TranscriptFailure.proofMismatch }
                didValidateChallengeProof = true
            }
            var pairingSecret = serverSecret
            pairingSecret.append(try PairingCryptography.sign(serverSecret, with: serverIdentity.privateKey))
            return PairingTranscriptResponse(values: ["paired": "1", "pairingsecret": pairingSecret.pairingHex])
        case 3:
            guard let clientCertificate,
                  let secretHex = request.parameters["clientpairingsecret"]
            else { throw TranscriptFailure.invalidStage(4) }
            let signedSecret = try Data(pairingHex: secretHex)
            guard signedSecret.count > 16 else { throw TranscriptFailure.invalidStage(4) }
            let secret = Data(signedSecret.prefix(16))
            let signature = Data(signedSecret.dropFirst(16))
            let clientPublicKey = try PairingCertificate.publicKey(from: clientCertificate)
            guard secret == expectedClientSecret,
                  PairingCryptography.verify(signature, message: secret, publicKey: clientPublicKey)
            else { throw TranscriptFailure.proofMismatch }
            didValidateClientSecret = true
            return PairingTranscriptResponse(values: ["paired": "1"])
        case 4:
            guard request.scheme == .https,
                  request.parameters["phrase"] == "pairchallenge",
                  request.pinnedServerCertificateDER == serverIdentity.certificateDER
            else { throw TranscriptFailure.invalidStage(5) }
            return PairingTranscriptResponse(values: ["paired": "1"])
        default:
            throw TranscriptFailure.invalidStage(step + 1)
        }
    }
}

private actor RejectingTranscript: PairingHTTPTranscript {
    private(set) var exchangeCount = 0
    func exchange(_ request: PairingTranscriptRequest) async throws -> PairingTranscriptResponse {
        exchangeCount += 1
        throw TranscriptFailure.unexpectedExchange
    }
}

private actor CertificateResponseTranscript: PairingHTTPTranscript {
    private let values: [String: String]
    private(set) var endpoints: [PairingRequestEndpoint] = []

    init(values: [String: String]) {
        self.values = values
    }

    func exchange(_ request: PairingTranscriptRequest) async throws -> PairingTranscriptResponse {
        endpoints.append(request.endpoint)
        if request.endpoint == .unpair {
            return PairingTranscriptResponse(values: ["paired": "0"])
        }
        return PairingTranscriptResponse(values: values)
    }
}

private actor HoldingTranscript: PairingHTTPTranscript {
    private(set) var started = false
    private(set) var wasCancelled = false

    func exchange(_ request: PairingTranscriptRequest) async throws -> PairingTranscriptResponse {
        started = true
        do {
            try await Task.sleep(for: .seconds(60))
            throw TranscriptFailure.unexpectedExchange
        } catch is CancellationError {
            wasCancelled = true
            throw CancellationError()
        }
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }
}

private struct RejectedUnpairTranscript: PairingHTTPTranscript {
    func exchange(_ request: PairingTranscriptRequest) async throws -> PairingTranscriptResponse {
        PairingTranscriptResponse(statusCode: 503, values: [:])
    }
}

private actor CleanupFailureTranscript: PairingHTTPTranscript {
    private let serverIdentity: ClientIdentity
    private var pairExchangeCount = 0

    init(serverIdentity: ClientIdentity) {
        self.serverIdentity = serverIdentity
    }

    func exchange(_ request: PairingTranscriptRequest) async throws -> PairingTranscriptResponse {
        if request.endpoint == .unpair {
            return PairingTranscriptResponse(statusCode: 503, values: [:])
        }
        defer { pairExchangeCount += 1 }
        if pairExchangeCount == 0 {
            return PairingTranscriptResponse(values: [
                "paired": "1",
                "plaincert": serverIdentity.certificatePEM.pairingHex,
            ])
        }
        throw URLError(.networkConnectionLost)
    }
}

private struct TimeoutTranscript: PairingHTTPTranscript {
    func exchange(_ request: PairingTranscriptRequest) async throws -> PairingTranscriptResponse {
        throw URLError(.timedOut)
    }
}

private enum TranscriptFailure: Error {
    case invalidStage(Int)
    case proofMismatch
    case unexpectedExchange
}

private final class SequenceRandomSource: PairingRandomSource, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Data]

    init(_ values: [Data]) { self.values = values }

    func bytes(count: Int) throws -> Data {
        try lock.withLock {
            guard !values.isEmpty else { throw TranscriptFailure.unexpectedExchange }
            let next = values.removeFirst()
            guard next.count == count else { throw TranscriptFailure.unexpectedExchange }
            return next
        }
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PairingStage] = []
    var values: [PairingStage] { lock.withLock { storage } }
    func append(_ value: PairingStage) { lock.withLock { storage.append(value) } }
}

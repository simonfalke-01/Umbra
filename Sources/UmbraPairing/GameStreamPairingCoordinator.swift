import Foundation
import UmbraNetworking

public final class GameStreamPairingCoordinator: PairingCoordinating, @unchecked Sendable {
    public typealias ProgressHandler = @Sendable (PairingProgress) -> Void

    private let transcript: any PairingHTTPTranscript
    private let identityProvider: any ClientIdentityProviding
    private let randomSource: any PairingRandomSource
    private let defaultAppVersion: String
    private let operationLock = NSLock()
    private var operationActive = false
    private var cancellationRequested = false
    private var activeExchange: (id: UUID, task: Task<PairingTranscriptResponse, Error>)?

    public init(
        transcript: any PairingHTTPTranscript,
        identityProvider: any ClientIdentityProviding = FileBackedClientIdentityProvider(),
        appVersion: String
    ) {
        self.transcript = transcript
        self.identityProvider = identityProvider
        self.randomSource = SecurePairingRandomSource()
        self.defaultAppVersion = appVersion
    }

    init(
        transcript: any PairingHTTPTranscript,
        identityProvider: any ClientIdentityProviding,
        appVersion: String,
        randomSource: any PairingRandomSource
    ) {
        self.transcript = transcript
        self.identityProvider = identityProvider
        self.randomSource = randomSource
        self.defaultAppVersion = appVersion
    }

    /// Satisfies UmbraNetworking's progress-stream surface. The secure handshake completes before
    /// the stream is returned so protocol failures remain throwable rather than being lost inside
    /// a non-throwing `AsyncStream`.
    public func pair(host: HostAddress, pin: String) async throws -> AsyncStream<PairingProgress> {
        let progress = PairingProgressCollector()
        _ = try await pair(host: host, pin: pin, appVersion: defaultAppVersion) { progress.append($0) }
        let events = progress.values
        return AsyncStream(PairingProgress.self, bufferingPolicy: .unbounded) { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    @discardableResult
    public func pair(
        host: HostAddress,
        pin: String,
        appVersion: String,
        onProgress: ProgressHandler = { _ in }
    ) async throws -> PairedHostIdentity {
        guard pin.count == 4, pin.allSatisfy(\.isNumber), pin.utf8.count == 4 else {
            throw PairingError.invalidPIN
        }
        guard beginOperation() else { throw PairingError.alreadyInProgress }
        defer { endOperation() }

        let identity = try identityProvider.identity()
        let digestAlgorithm = try PairingDigest.forServerVersion(appVersion)
        var pairingStarted = false

        do {
            try checkCancellation()
            let salt = try randomSource.bytes(count: 16)
            let pinKey = PairingCryptography.pinKey(salt: salt, pin: pin, using: digestAlgorithm)

            onProgress(PairingProgress(
                stage: .requestingServerCertificate,
                message: "Requesting and pinning the host certificate"
            ))
            let certificateResponse = try await exchange(
                stage: .requestingServerCertificate,
                request: PairingTranscriptRequest(
                    host: host,
                    scheme: .http,
                    endpoint: .pair,
                    parameters: commonParameters.merging([
                        "phrase": "getservercert",
                        "salt": salt.pairingHex,
                        "clientcert": identity.certificatePEM.pairingHex,
                    ], uniquingKeysWith: { _, new in new }),
                    pinnedServerCertificateDER: nil,
                    clientIdentity: identity
                )
            )
            try requireAccepted(certificateResponse, stage: .requestingServerCertificate)
            pairingStarted = true
            guard let encodedCertificate = certificateResponse["plaincert"] else {
                throw PairingError.invalidResponse(
                    stage: .requestingServerCertificate,
                    reason: "plaincert is missing"
                )
            }
            guard !encodedCertificate.isEmpty else {
                throw PairingError.invalidResponse(
                    stage: .requestingServerCertificate,
                    reason: "plaincert is empty"
                )
            }
            let serverCertificatePEM: Data
            let serverCertificateDER: Data
            do {
                serverCertificatePEM = try Data(pairingHex: encodedCertificate)
                serverCertificateDER = try PairingCertificate.der(from: serverCertificatePEM)
            } catch {
                throw PairingError.invalidResponse(
                    stage: .requestingServerCertificate,
                    reason: "plaincert is not a valid hexadecimal X.509 certificate"
                )
            }
            let serverPublicKey = try PairingCertificate.publicKey(from: serverCertificateDER)
            try checkCancellation()

            onProgress(PairingProgress(
                stage: .exchangingChallenges,
                message: "Exchanging encrypted pairing challenges"
            ))
            let clientChallenge = try randomSource.bytes(count: 16)
            let encryptedChallenge = try PairingCryptography.encrypt(clientChallenge, key: pinKey)
            let challengeResponse = try await exchange(
                stage: .exchangingChallenges,
                request: PairingTranscriptRequest(
                    host: host,
                    scheme: .http,
                    endpoint: .pair,
                    parameters: commonParameters.merging([
                        "clientchallenge": encryptedChallenge.pairingHex,
                    ], uniquingKeysWith: { _, new in new }),
                    pinnedServerCertificateDER: serverCertificateDER,
                    clientIdentity: identity
                )
            )
            try requireAccepted(challengeResponse, stage: .exchangingChallenges)
            guard let encodedChallenge = challengeResponse["challengeresponse"] else {
                throw PairingError.invalidResponse(stage: .exchangingChallenges, reason: "challengeresponse is missing")
            }
            let encryptedChallengeResponse: Data
            do {
                encryptedChallengeResponse = try Data(pairingHex: encodedChallenge)
            } catch {
                throw PairingError.invalidResponse(stage: .exchangingChallenges, reason: "challengeresponse is not hexadecimal")
            }
            guard !encryptedChallengeResponse.isEmpty,
                  encryptedChallengeResponse.count.isMultiple(of: 16)
            else {
                throw PairingError.invalidResponse(stage: .exchangingChallenges, reason: "challengeresponse is not AES block aligned")
            }
            let decryptedChallengeResponse = try PairingCryptography.decrypt(encryptedChallengeResponse, key: pinKey)
            let hashLength = digestAlgorithm == .sha256 ? 32 : 20
            guard decryptedChallengeResponse.count >= hashLength + 16 else {
                throw PairingError.invalidResponse(stage: .exchangingChallenges, reason: "challengeresponse is truncated")
            }
            let serverResponse = Data(decryptedChallengeResponse.prefix(hashLength))
            let challengeStart = decryptedChallengeResponse.index(decryptedChallengeResponse.startIndex, offsetBy: hashLength)
            let challengeEnd = decryptedChallengeResponse.index(challengeStart, offsetBy: 16)
            let serverChallenge = Data(decryptedChallengeResponse[challengeStart..<challengeEnd])

            let clientSecret = try randomSource.bytes(count: 16)
            let clientCertificateSignature = try PairingCertificate.signature(from: identity.certificateDER)
            var challengeProof = serverChallenge
            challengeProof.append(clientCertificateSignature)
            challengeProof.append(clientSecret)
            var challengeProofHash = PairingCryptography.digest(challengeProof, using: digestAlgorithm)
            if challengeProofHash.count < 32 {
                challengeProofHash.append(Data(repeating: 0, count: 32 - challengeProofHash.count))
            }
            let encryptedChallengeProof = try PairingCryptography.encrypt(challengeProofHash, key: pinKey)
            try checkCancellation()

            onProgress(PairingProgress(
                stage: .verifyingServerSecret,
                message: "Verifying the host certificate and PIN proof"
            ))
            let secretResponse = try await exchange(
                stage: .verifyingServerSecret,
                request: PairingTranscriptRequest(
                    host: host,
                    scheme: .http,
                    endpoint: .pair,
                    parameters: commonParameters.merging([
                        "serverchallengeresp": encryptedChallengeProof.pairingHex,
                    ], uniquingKeysWith: { _, new in new }),
                    pinnedServerCertificateDER: serverCertificateDER,
                    clientIdentity: identity
                )
            )
            try requireAccepted(secretResponse, stage: .verifyingServerSecret)
            guard let encodedSecret = secretResponse["pairingsecret"] else {
                throw PairingError.invalidResponse(stage: .verifyingServerSecret, reason: "pairingsecret is missing")
            }
            let pairingSecret: Data
            do {
                pairingSecret = try Data(pairingHex: encodedSecret)
            } catch {
                throw PairingError.invalidResponse(stage: .verifyingServerSecret, reason: "pairingsecret is not hexadecimal")
            }
            guard pairingSecret.count > 16 else {
                throw PairingError.invalidResponse(stage: .verifyingServerSecret, reason: "pairingsecret is truncated")
            }
            let serverSecret = Data(pairingSecret.prefix(16))
            let serverSecretSignature = Data(pairingSecret.dropFirst(16))
            guard PairingCryptography.verify(serverSecretSignature, message: serverSecret, publicKey: serverPublicKey) else {
                throw PairingError.serverAuthenticationFailed
            }

            let serverCertificateSignature = try PairingCertificate.signature(from: serverCertificateDER)
            var expectedServerResponseInput = clientChallenge
            expectedServerResponseInput.append(serverCertificateSignature)
            expectedServerResponseInput.append(serverSecret)
            let expectedServerResponse = PairingCryptography.digest(expectedServerResponseInput, using: digestAlgorithm)
            guard PairingCryptography.constantTimeEqual(expectedServerResponse, serverResponse) else {
                throw PairingError.incorrectPIN
            }
            try checkCancellation()

            onProgress(PairingProgress(
                stage: .sendingClientSecret,
                message: "Sending the signed client pairing secret"
            ))
            var signedClientSecret = clientSecret
            signedClientSecret.append(try PairingCryptography.sign(clientSecret, with: identity.privateKey))
            let clientSecretResponse = try await exchange(
                stage: .sendingClientSecret,
                request: PairingTranscriptRequest(
                    host: host,
                    scheme: .http,
                    endpoint: .pair,
                    parameters: commonParameters.merging([
                        "clientpairingsecret": signedClientSecret.pairingHex,
                    ], uniquingKeysWith: { _, new in new }),
                    pinnedServerCertificateDER: serverCertificateDER,
                    clientIdentity: identity
                )
            )
            try requireAccepted(clientSecretResponse, stage: .sendingClientSecret)
            try checkCancellation()

            onProgress(PairingProgress(
                stage: .confirmingPairChallenge,
                message: "Confirming pairing over certificate-pinned HTTPS"
            ))
            let confirmationResponse = try await exchange(
                stage: .confirmingPairChallenge,
                request: PairingTranscriptRequest(
                    host: host,
                    scheme: .https,
                    endpoint: .pair,
                    parameters: commonParameters.merging([
                        "phrase": "pairchallenge",
                    ], uniquingKeysWith: { _, new in new }),
                    pinnedServerCertificateDER: serverCertificateDER,
                    clientIdentity: identity
                )
            )
            try requireAccepted(confirmationResponse, stage: .confirmingPairChallenge)
            try checkCancellation()
            onProgress(PairingProgress(stage: .complete, message: "Pairing complete"))
            return PairedHostIdentity(serverCertificateDER: serverCertificateDER)
        } catch {
            let primaryError: Error = if error is CancellationError || isCancellationRequested {
                PairingError.cancelled
            } else {
                error
            }
            if pairingStarted {
                if let cleanupError = await cleanupPairing(host: host, identity: identity) {
                    throw PairingError.cleanupFailed(
                        pairing: primaryError.localizedDescription,
                        cleanup: cleanupError.localizedDescription
                    )
                }
            }
            throw primaryError
        }
    }

    public func cancel() {
        let exchangeTask = operationLock.withLock {
            cancellationRequested = true
            return activeExchange?.task
        }
        exchangeTask?.cancel()
    }

    public func unpair(host: HostAddress) async throws {
        let identity = try identityProvider.identity()
        let response = try await transcript.exchange(unpairRequest(host: host, identity: identity))
        try requireUnpairAccepted(response)
    }

    private var commonParameters: [String: String] {
        ["devicename": "roth", "updateState": "1"]
    }

    private func exchange(
        stage: PairingStage,
        request: PairingTranscriptRequest
    ) async throws -> PairingTranscriptResponse {
        try checkCancellation()
        let exchangeID = UUID()
        let exchangeTask = Task { try await transcript.exchange(request) }
        let registered = operationLock.withLock {
            guard operationActive, !cancellationRequested else { return false }
            activeExchange = (exchangeID, exchangeTask)
            return true
        }
        guard registered else {
            exchangeTask.cancel()
            throw PairingError.cancelled
        }
        defer {
            operationLock.withLock {
                if activeExchange?.id == exchangeID { activeExchange = nil }
            }
        }
        do {
            let response = try await withTaskCancellationHandler {
                try await exchangeTask.value
            } onCancel: {
                exchangeTask.cancel()
            }
            try checkCancellation()
            return response
        } catch let error as PairingError {
            throw error
        } catch is CancellationError {
            throw PairingError.cancelled
        } catch {
            if stage == .requestingServerCertificate,
               (error as? URLError)?.code == .timedOut {
                throw PairingError.transport(
                    stage: stage,
                    message: "The host did not finish PIN confirmation. Sunshine may retain a stale pending pairing session after a timeout; restart Sunshine before retrying."
                )
            }
            throw PairingError.transport(stage: stage, message: error.localizedDescription)
        }
    }

    private func requireAccepted(_ response: PairingTranscriptResponse, stage: PairingStage) throws {
        guard response.statusCode == 200 else {
            throw PairingError.invalidResponse(stage: stage, reason: "status_code was \(response.statusCode)")
        }
        guard response["paired"] == "1" else {
            throw PairingError.serverRejected(stage: stage)
        }
    }

    private func unpairRequest(host: HostAddress, identity: ClientIdentity) -> PairingTranscriptRequest {
        PairingTranscriptRequest(
            host: host,
            scheme: .http,
            endpoint: .unpair,
            parameters: [:],
            pinnedServerCertificateDER: nil,
            clientIdentity: identity
        )
    }

    private func requireUnpairAccepted(_ response: PairingTranscriptResponse) throws {
        guard response.statusCode == 200 else {
            throw PairingError.unpairRejected(statusCode: response.statusCode)
        }
    }

    private func cleanupPairing(host: HostAddress, identity: ClientIdentity) async -> Error? {
        let request = unpairRequest(host: host, identity: identity)
        do {
            let response = try await Task.detached { [transcript] in
                try await transcript.exchange(request)
            }.value
            try requireUnpairAccepted(response)
            return nil
        } catch {
            return error
        }
    }

    private func checkCancellation() throws {
        if Task.isCancelled || isCancellationRequested { throw PairingError.cancelled }
    }

    private var isCancellationRequested: Bool {
        operationLock.withLock { cancellationRequested }
    }

    private func beginOperation() -> Bool {
        operationLock.withLock {
            guard !operationActive else { return false }
            operationActive = true
            cancellationRequested = false
            return true
        }
    }

    private func endOperation() {
        let exchangeTask = operationLock.withLock {
            operationActive = false
            cancellationRequested = false
            defer { activeExchange = nil }
            return activeExchange?.task
        }
        exchangeTask?.cancel()
    }
}

private final class PairingProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PairingProgress] = []

    var values: [PairingProgress] { lock.withLock { storage } }
    func append(_ value: PairingProgress) { lock.withLock { storage.append(value) } }
}

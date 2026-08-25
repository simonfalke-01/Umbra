import Combine
import Foundation
import UmbraProtocolV3
import UniformTypeIdentifiers
import Vision

enum SecurePairingInvitationImportError: LocalizedError, Equatable {
    case fileTooLarge
    case invalidText
    case noQRCode
    case multipleQRCodes
    case wrongQRCode
    case unreadable

    var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            "The selected file is too large. Choose a text invitation or QR code image under 32 MB."
        case .invalidText:
            "The selected text file does not contain a Lumen invitation."
        case .noQRCode:
            "No QR code was found in the selected image."
        case .multipleQRCodes:
            "The image contains more than one QR code. Crop it to the Lumen invitation and try again."
        case .wrongQRCode:
            "The QR code is not a Lumen invitation. Generate a new invitation in Lumen."
        case .unreadable:
            "Umbra couldn’t read the selected file. Choose a text invitation or QR code image and try again."
        }
    }
}

enum SecurePairingInvitationImporter {
    static func load(from url: URL) async throws -> String {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

            do {
                let values = try url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
                try Task.checkCancellation()
                guard (values.fileSize ?? 0) <= 32 * 1_024 * 1_024 else {
                    throw SecurePairingInvitationImportError.fileTooLarge
                }
                if values.contentType?.conforms(to: .image) == true {
                    return try scanQRCode(at: url)
                }
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                try Task.checkCancellation()
                guard data.count <= 2_048,
                      let value = String(data: data, encoding: .utf8)?.trimmingCharacters(
                          in: .whitespacesAndNewlines
                      ),
                      value.hasPrefix(ProtocolV3PairingInvitation.uriPrefix) else {
                    throw SecurePairingInvitationImportError.invalidText
                }
                return value
            } catch let error as SecurePairingInvitationImportError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw SecurePairingInvitationImportError.unreadable
            }
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func scanQRCode(at url: URL) throws -> String {
        try Task.checkCancellation()
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(url: url).perform([request])
        try Task.checkCancellation()
        let payloads = Set(request.results?.compactMap(\.payloadStringValue) ?? [])
        guard !payloads.isEmpty else { throw SecurePairingInvitationImportError.noQRCode }
        guard payloads.count == 1 else { throw SecurePairingInvitationImportError.multipleQRCodes }
        guard let payload = payloads.first,
              payload.hasPrefix(ProtocolV3PairingInvitation.uriPrefix) else {
            throw SecurePairingInvitationImportError.wrongQRCode
        }
        return payload
    }
}

@MainActor
final class SecurePairingInvitationImportCoordinator: ObservableObject {
    enum Outcome: Equatable {
        case success(String)
        case failure(String)
    }

    struct Completion: Equatable {
        let token: UInt64
        let outcome: Outcome
    }

    @Published private(set) var completion: Completion?

    private let loader: @Sendable (URL) async throws -> String
    private var task: Task<Void, Never>?
    private var nextToken: UInt64 = 0
    private var activeToken: UInt64?

    init(
        loader: @escaping @Sendable (URL) async throws -> String =
            SecurePairingInvitationImporter.load
    ) {
        self.loader = loader
    }

    func start(url: URL) {
        task?.cancel()
        guard let token = advanceToken() else {
            task = nil
            activeToken = nil
            completion = nil
            return
        }
        activeToken = token
        completion = nil
        let loader = self.loader

        task = Task { [weak self] in
            do {
                let invitation = try await loader(url)
                try Task.checkCancellation()
                guard let self, self.activeToken == token else { return }
                self.completion = Completion(token: token, outcome: .success(invitation))
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self, self.activeToken == token else { return }
                self.completion = Completion(
                    token: token,
                    outcome: .failure(error.localizedDescription)
                )
            }
        }
    }

    func invalidate() {
        task?.cancel()
        task = nil
        _ = advanceToken()
        activeToken = nil
        completion = nil
    }

    func owns(_ token: UInt64) -> Bool {
        activeToken == token
    }

    private func advanceToken() -> UInt64? {
        guard nextToken < UInt64.max else { return nil }
        nextToken += 1
        return nextToken
    }
}

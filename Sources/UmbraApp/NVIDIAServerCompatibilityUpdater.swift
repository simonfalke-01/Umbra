import Foundation
import UmbraServices

struct NVIDIAServerCompatibilityUpdater {
    private static let storageKey = "Umbra.maximumSupportedNVIDIAVersion"
    private static let endpoint = URL(string: "https://moonlight-stream.org/compatibility/v1")!

    private let defaults: UserDefaults
    private let session: URLSession

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session
    }

    var cachedMaximumVersion: String {
        guard let cached = defaults.string(forKey: Self.storageKey),
              NVIDIAServerCompatibilityPolicy(maximumSupportedVersion: cached) != nil
        else {
            return NVIDIAServerCompatibilityPolicy.bundledMaximumVersion
        }
        return cached
    }

    func refresh(_ service: UmbraApplicationService) async {
        var request = URLRequest(url: Self.endpoint)
        request.cachePolicy = .reloadRevalidatingCacheData
        request.timeoutInterval = 5
        guard let (data, response) = try? await session.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let version = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              NVIDIAServerCompatibilityPolicy(maximumSupportedVersion: version) != nil
        else {
            return
        }
        do {
            try await service.updateMaximumSupportedNVIDIAVersion(version)
            defaults.set(version, forKey: Self.storageKey)
        } catch {
            return
        }
    }
}

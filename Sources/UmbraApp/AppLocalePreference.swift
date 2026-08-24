import Foundation
import UmbraCore

struct AppLocalePreference: Codable, Hashable, Sendable {
    let languageTag: String?

    static let system = AppLocalePreference(languageTag: nil)

    init(languageTag: String?) {
        self.languageTag = languageTag
    }

    init(migrating legacyLanguage: AppLanguage) {
        languageTag = switch legacyLanguage {
        case .automatic: nil
        case .english: "en"
        case .french: "fr"
        case .simplifiedChinese: "zh-Hans"
        case .german: "de"
        case .norwegianBokmal: "nb"
        case .russian: "ru"
        case .spanish: "es"
        case .japanese: "ja"
        case .vietnamese: "vi"
        case .thai: "th"
        case .korean: "ko"
        case .hungarian: "hu"
        case .dutch: "nl"
        case .swedish: "sv"
        case .turkish: "tr"
        case .ukrainian: "uk"
        case .traditionalChinese: "zh-Hant"
        case .portuguese: "pt"
        case .brazilianPortuguese: "pt-BR"
        case .greek: "el"
        case .italian: "it"
        case .hindi: "hi"
        case .polish: "pl"
        case .czech: "cs"
        case .hebrew: "he"
        case .centralKurdish: "ckb"
        case .lithuanian: "lt"
        case .estonian: "et"
        case .bulgarian: "bg"
        case .esperanto: "eo"
        case .tamil: "ta"
        }
    }
}

enum AppLocalePreferencePersistence {
    static let storageKey = "Umbra.appLocalePreference"

    static func load(from defaults: UserDefaults) -> AppLocalePreference {
        storedPreference(in: defaults) ?? .system
    }

    static func save(_ preference: AppLocalePreference, to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(preference) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private static func storedPreference(in defaults: UserDefaults) -> AppLocalePreference? {
        guard let data = defaults.data(forKey: storageKey),
              let preference = try? JSONDecoder().decode(AppLocalePreference.self, from: data) else {
            return nil
        }
        return preference
    }

    @discardableResult
    static func migrateLegacyLanguage(
        in settings: inout StreamingPreferences,
        defaults: UserDefaults
    ) -> Bool {
        guard settings.language != .automatic else { return false }

        if storedPreference(in: defaults) == nil {
            save(AppLocalePreference(migrating: settings.language), to: defaults)
        }
        settings.language = .automatic
        return true
    }

    static func reset(in defaults: UserDefaults) {
        defaults.removeObject(forKey: storageKey)
    }
}

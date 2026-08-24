import Foundation
import XCTest
import UmbraCore
@testable import UmbraApp

final class LocalizationFoundationTests: XCTestCase {
    func testEnglishCatalogIsBundledAndProvidesSourceFallback() throws {
        let bundle = UmbraLocalization.resourceBundle
        XCTAssertEqual(bundle.localizations, ["en"])

        let englishBundle = try XCTUnwrap(
            bundle.url(forResource: "en", withExtension: "lproj").flatMap(Bundle.init(url:))
        )
        XCTAssertEqual(
            englishBundle.localizedString(
                forKey: "Automatic",
                value: nil,
                table: "Localizable"
            ),
            "Automatic"
        )
        XCTAssertEqual(UmbraLocalization.string("Add Host..."), "Add Host...")
    }

    func testStreamingModeAccessibilityCopyComesFromLocalizationCatalog() {
        XCTAssertEqual(UmbraLocalization.string("Streaming mode"), "Streaming mode")
        XCTAssertEqual(
            UmbraLocalization.string("Choose Lowest Latency or Best Quality."),
            "Choose Lowest Latency or Best Quality."
        )
    }

    func testEnglishInfoPlistLocalizationIsBundled() throws {
        let englishBundle = try XCTUnwrap(
            UmbraLocalization.resourceBundle
                .url(forResource: "en", withExtension: "lproj")
                .flatMap(Bundle.init(url:))
        )

        XCTAssertEqual(
            englishBundle.localizedString(
                forKey: "CFBundleDisplayName",
                value: nil,
                table: "InfoPlist"
            ),
            "Umbra"
        )
        XCTAssertEqual(
            englishBundle.localizedString(
                forKey: "NSLocalNetworkUsageDescription",
                value: nil,
                table: "InfoPlist"
            ),
            "Umbra discovers and connects to game-streaming hosts on your local network."
        )
        XCTAssertEqual(
            englishBundle.localizedString(
                forKey: "NSInputMonitoringUsageDescription",
                value: nil,
                table: "InfoPlist"
            ),
            "Umbra monitors keyboard input when system shortcut capture is enabled, so those shortcuts can be sent to the streaming host."
        )
        XCTAssertEqual(
            englishBundle.localizedString(
                forKey: "NSMicrophoneUsageDescription",
                value: nil,
                table: "InfoPlist"
            ),
            "Umbra forwards microphone audio to a compatible streaming host when you enable microphone forwarding."
        )
    }

    func testCompiledEnglishResourcesMatchTheSourceCatalogs() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let resourcesURL = repositoryRoot
            .appending(path: "Sources/UmbraApp/Resources", directoryHint: .isDirectory)
        let englishBundle = try XCTUnwrap(
            UmbraLocalization.resourceBundle
                .url(forResource: "en", withExtension: "lproj")
                .flatMap(Bundle.init(url:))
        )

        for tableName in ["Localizable", "InfoPlist"] {
            let data = try Data(contentsOf: resourcesURL.appending(path: "\(tableName).xcstrings"))
            let catalog = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            XCTAssertEqual(catalog["sourceLanguage"] as? String, "en")
            let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])

            for (key, rawEntry) in strings {
                let entry = try XCTUnwrap(rawEntry as? [String: Any])
                let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
                XCTAssertEqual(Set(localizations.keys), ["en"])
                let english = try XCTUnwrap(localizations["en"] as? [String: Any])
                let stringUnit = try XCTUnwrap(english["stringUnit"] as? [String: Any])
                let sourceValue = try XCTUnwrap(stringUnit["value"] as? String)
                XCTAssertEqual(
                    englishBundle.localizedString(forKey: key, value: nil, table: tableName),
                    sourceValue,
                    "\(tableName).strings is out of sync with \(tableName).xcstrings for \(key)"
                )
            }
        }
    }

    func testExplicitPreferenceResolvesExactRegionAndScriptMatches() throws {
        let fixture = try makeLocalizationBundle(
            complete: ["en", "fr", "fr-CA", "zh-Hans", "zh-Hant"]
        )
        defer { fixture.remove() }

        XCTAssertEqual(
            resolvedIdentifier("fr-CA", in: fixture.bundle),
            "fr-CA"
        )
        XCTAssertEqual(
            resolvedIdentifier("fr-BE", in: fixture.bundle),
            "fr"
        )
        XCTAssertEqual(
            resolvedIdentifier("zh-Hant-TW", in: fixture.bundle),
            "zh-Hant"
        )
        XCTAssertEqual(
            resolvedIdentifier("zh-CN", in: fixture.bundle),
            "zh-Hans"
        )
    }

    func testUnsupportedMalformedAndCorruptLocalizationsFallBackSafely() throws {
        let fixture = try makeLocalizationBundle(
            complete: ["en", "fr"],
            corrupt: ["ja"]
        )
        defer { fixture.remove() }

        XCTAssertEqual(
            UmbraLocalization.reviewedLocalizationIdentifiers(in: fixture.bundle),
            ["en", "fr"]
        )
        XCTAssertEqual(
            UmbraLocalization.resolvedLocalization(
                in: fixture.bundle,
                preference: AppLocalePreference(languageTag: "ja"),
                preferredLanguages: ["fr-FR"]
            ).identifier,
            "fr"
        )
        XCTAssertEqual(
            UmbraLocalization.resolvedLocalization(
                in: fixture.bundle,
                preference: AppLocalePreference(languageTag: "%%%%"),
                preferredLanguages: ["fr"]
            ).identifier,
            "fr"
        )
        XCTAssertEqual(
            UmbraLocalization.resolvedLocalization(
                in: fixture.bundle,
                preference: AppLocalePreference(languageTag: "es-MX"),
                preferredLanguages: ["es"]
            ).identifier,
            "en"
        )
    }

    func testSystemPreferenceUsesPreferredLanguageOrder() throws {
        let fixture = try makeLocalizationBundle(complete: ["en", "fr", "fr-CA"])
        defer { fixture.remove() }

        XCTAssertEqual(
            UmbraLocalization.resolvedLocalization(
                in: fixture.bundle,
                preference: .system,
                preferredLanguages: ["es-MX", "fr-CA", "en"]
            ).identifier,
            "fr-CA"
        )
        XCTAssertEqual(
            UmbraLocalization.resolvedLocalization(
                in: fixture.bundle,
                preference: .system,
                preferredLanguages: []
            ).identifier,
            "en"
        )
    }

    func testLanguageSettingRequiresTwoCompleteReviewedLocalizations() throws {
        XCTAssertFalse(
            UmbraLocalization.shouldShowLanguageSetting(
                in: UmbraLocalization.resourceBundle
            )
        )

        let incompleteFixture = try makeLocalizationBundle(
            complete: ["en"],
            incomplete: ["fr"]
        )
        defer { incompleteFixture.remove() }
        XCTAssertFalse(
            UmbraLocalization.shouldShowLanguageSetting(in: incompleteFixture.bundle)
        )

        let completeFixture = try makeLocalizationBundle(complete: ["en", "fr"])
        defer { completeFixture.remove() }
        XCTAssertTrue(
            UmbraLocalization.shouldShowLanguageSetting(in: completeFixture.bundle)
        )
        let options = UmbraLocalization.languageOptions(
            in: completeFixture.bundle,
            displayLocaleIdentifier: "en"
        )
        XCTAssertEqual(options.map(\.preference), [
            .system,
            AppLocalePreference(languageTag: "en"),
            AppLocalePreference(languageTag: "fr"),
        ])
        XCTAssertEqual(options.first?.label, "System Default")
        XCTAssertFalse(options.dropFirst().contains(where: { option in
            option.label == option.preference.languageTag
        }))
    }

    func testEveryLegacyLanguageMigratesToSystemOrAUniqueBCP47Tag() {
        let preferences = AppLanguage.allCases.map(AppLocalePreference.init(migrating:))
        XCTAssertNil(preferences[AppLanguage.automatic.rawValue].languageTag)

        let languageTags = preferences.compactMap(\.languageTag)
        XCTAssertEqual(languageTags.count, AppLanguage.allCases.count - 1)
        XCTAssertEqual(Set(languageTags).count, languageTags.count)
        XCTAssertFalse(languageTags.contains(where: { $0.contains("_") }))
        XCTAssertEqual(AppLocalePreference(migrating: .simplifiedChinese).languageTag, "zh-Hans")
        XCTAssertEqual(AppLocalePreference(migrating: .traditionalChinese).languageTag, "zh-Hant")
        XCTAssertEqual(AppLocalePreference(migrating: .brazilianPortuguese).languageTag, "pt-BR")
    }

    func testLegacyRightToLeftLanguagesRetainRightToLeftBCP47Semantics() throws {
        for legacyLanguage in [AppLanguage.hebrew, .centralKurdish] {
            let tag = try XCTUnwrap(AppLocalePreference(migrating: legacyLanguage).languageTag)
            XCTAssertEqual(Locale.Language(identifier: tag).characterDirection, .rightToLeft)
        }
    }

    @MainActor
    func testPreferencesStoreMigratesLegacyLanguageWithoutExposingItAsASetting() throws {
        let suiteName = "UmbraAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var stored = StreamingPreferences.default
        stored.language = .japanese
        defaults.set(try JSONEncoder().encode(stored), forKey: "Umbra.streamingPreferences")

        let preferences = PreferencesStore(defaults: defaults)

        XCTAssertEqual(preferences.settings.language, .automatic)
        XCTAssertEqual(
            AppLocalePreferencePersistence.load(from: defaults),
            AppLocalePreference(migrating: .japanese)
        )
        let normalizedData = try XCTUnwrap(defaults.data(forKey: "Umbra.streamingPreferences"))
        let normalized = try JSONDecoder().decode(StreamingPreferences.self, from: normalizedData)
        XCTAssertEqual(normalized.language, .automatic)
    }

    @MainActor
    func testExistingBCP47PreferenceWinsDuringLegacyMigrationAndResetClearsIt() throws {
        let suiteName = "UmbraAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let currentPreference = AppLocalePreference(migrating: .french)
        defaults.set(
            try JSONEncoder().encode(currentPreference),
            forKey: AppLocalePreferencePersistence.storageKey
        )
        var stored = StreamingPreferences.default
        stored.language = .german
        defaults.set(try JSONEncoder().encode(stored), forKey: "Umbra.streamingPreferences")

        let preferences = PreferencesStore(defaults: defaults)

        XCTAssertEqual(AppLocalePreferencePersistence.load(from: defaults), currentPreference)
        preferences.resetAll()
        XCTAssertEqual(AppLocalePreferencePersistence.load(from: defaults), .system)
    }

    @MainActor
    func testCorruptLocalePreferenceDoesNotBlockLegacyMigration() throws {
        let suiteName = "UmbraAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(Data("not-json".utf8), forKey: AppLocalePreferencePersistence.storageKey)
        var stored = StreamingPreferences.default
        stored.language = .traditionalChinese
        defaults.set(try JSONEncoder().encode(stored), forKey: "Umbra.streamingPreferences")

        _ = PreferencesStore(defaults: defaults)

        XCTAssertEqual(
            AppLocalePreferencePersistence.load(from: defaults),
            AppLocalePreference(migrating: .traditionalChinese)
        )
    }

    @MainActor
    func testPreferencesStorePersistsLocaleForNextLaunchWithoutChangingStreamingPreferences() throws {
        let suiteName = "UmbraAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = PreferencesStore(defaults: defaults)
        let selectedLocale = AppLocalePreference(languageTag: "fr-CA")

        preferences.updateAppLocalePreference(selectedLocale)

        XCTAssertEqual(preferences.appLocalePreference, selectedLocale)
        XCTAssertEqual(AppLocalePreferencePersistence.load(from: defaults), selectedLocale)
        XCTAssertEqual(preferences.settings.language, .automatic)
    }

    private func resolvedIdentifier(_ identifier: String, in bundle: Bundle) -> String {
        UmbraLocalization.resolvedLocalization(
            in: bundle,
            preference: AppLocalePreference(languageTag: identifier),
            preferredLanguages: ["en"]
        ).identifier
    }

    private func makeLocalizationBundle(
        complete: [String],
        incomplete: [String] = [],
        corrupt: [String] = []
    ) throws -> TemporaryLocalizationBundle {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "UmbraLocalizationTests-\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let localizations = complete + incomplete + corrupt
        let info: [String: Any] = [
            "CFBundleIdentifier": "app.umbra.localization-tests.\(UUID().uuidString)",
            "CFBundleDevelopmentRegion": "en",
            "CFBundleLocalizations": localizations,
        ]
        try writePropertyList(info, to: rootURL.appending(path: "Info.plist"))

        for identifier in complete {
            try writeLocalization(identifier, to: rootURL, complete: true)
        }
        for identifier in incomplete {
            try writeLocalization(identifier, to: rootURL, complete: false)
        }
        for identifier in corrupt {
            let localizationURL = rootURL.appending(
                path: "\(identifier).lproj",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(
                at: localizationURL,
                withIntermediateDirectories: true
            )
            try Data("not-a-strings-file".utf8).write(
                to: localizationURL.appending(path: "Localizable.strings")
            )
            try writePropertyList(
                ["CFBundleDisplayName": "Umbra"],
                to: localizationURL.appending(path: "InfoPlist.strings")
            )
        }

        return TemporaryLocalizationBundle(
            bundle: try XCTUnwrap(Bundle(url: rootURL)),
            url: rootURL
        )
    }

    private func writeLocalization(
        _ identifier: String,
        to rootURL: URL,
        complete: Bool
    ) throws {
        let localizationURL = rootURL.appending(
            path: "\(identifier).lproj",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: localizationURL,
            withIntermediateDirectories: true
        )
        var localizable = [
            "Greeting": "\(identifier) greeting",
            "System Default": "System Default",
        ]
        if !complete {
            localizable.removeValue(forKey: "Greeting")
        }
        try writePropertyList(
            localizable,
            to: localizationURL.appending(path: "Localizable.strings")
        )
        try writePropertyList(
            ["CFBundleDisplayName": "Umbra"],
            to: localizationURL.appending(path: "InfoPlist.strings")
        )
    }

    private func writePropertyList(_ propertyList: Any, to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .xml,
            options: 0
        )
        try data.write(to: url)
    }
}

private struct TemporaryLocalizationBundle {
    let bundle: Bundle
    let url: URL

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

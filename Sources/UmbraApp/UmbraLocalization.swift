import Foundation

struct AppLocaleOption: Hashable, Identifiable, Sendable {
    let preference: AppLocalePreference
    let label: String

    var id: String { preference.languageTag ?? "system" }
}

enum UmbraLocalization {
    struct Resolution {
        let identifier: String
        let bundle: Bundle
    }

    private struct ReviewedLocalization {
        let identifier: String
        let bundle: Bundle
    }

    private struct Runtime {
        let resourceBundle: Bundle
        let resolution: Resolution
        let languageOptions: [AppLocaleOption]
        let showsLanguageSetting: Bool
    }

    private static let requiredTables = ["Localizable", "InfoPlist"]

    private static let runtime: Runtime = {
        let resourceBundle = packagedResourceBundle()
        let reviewed = reviewedLocalizations(in: resourceBundle)
        let resolution = resolvedLocalization(
            from: reviewed,
            preference: AppLocalePreferencePersistence.load(from: .standard),
            preferredLanguages: Locale.preferredLanguages,
            fallbackBundle: resourceBundle
        )
        return Runtime(
            resourceBundle: resourceBundle,
            resolution: resolution,
            languageOptions: languageOptions(
                from: reviewed,
                displayLocaleIdentifier: resolution.identifier,
                displayBundle: resolution.bundle,
                fallbackBundle: resourceBundle
            ),
            showsLanguageSetting: reviewed.count > 1
        )
    }()

    /// The package resource root, retained for resource and release audits.
    static var resourceBundle: Bundle { runtime.resourceBundle }

    /// The locale is fixed for the process lifetime. A saved change applies on next launch.
    static var activeLocale: Locale { Locale(identifier: runtime.resolution.identifier) }

    static var languageOptions: [AppLocaleOption] { runtime.languageOptions }

    static var showsLanguageSetting: Bool { runtime.showsLanguageSetting }

    static func string(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: runtime.resolution.bundle)
    }

    static func resolvedLocalization(
        in resourceBundle: Bundle,
        preference: AppLocalePreference,
        preferredLanguages: [String]
    ) -> Resolution {
        resolvedLocalization(
            from: reviewedLocalizations(in: resourceBundle),
            preference: preference,
            preferredLanguages: preferredLanguages,
            fallbackBundle: resourceBundle
        )
    }

    private static func resolvedLocalization(
        from reviewed: [ReviewedLocalization],
        preference: AppLocalePreference,
        preferredLanguages: [String],
        fallbackBundle: Bundle
    ) -> Resolution {
        let available = reviewed.map(\.identifier)
        let selectedIdentifier = preference.languageTag.flatMap { requested in
            matchingLocalization(for: [requested], available: available)
        } ?? matchingLocalization(for: preferredLanguages, available: available)
            ?? available.first(where: { languageCode(in: $0) == "en" })
            ?? available.first

        guard let selectedIdentifier,
              let selection = reviewed.first(where: { $0.identifier == selectedIdentifier }) else {
            return Resolution(identifier: "en", bundle: fallbackBundle)
        }
        return Resolution(identifier: selection.identifier, bundle: selection.bundle)
    }

    static func reviewedLocalizationIdentifiers(in resourceBundle: Bundle) -> [String] {
        reviewedLocalizations(in: resourceBundle).map(\.identifier)
    }

    static func shouldShowLanguageSetting(in resourceBundle: Bundle) -> Bool {
        reviewedLocalizations(in: resourceBundle).count > 1
    }

    static func languageOptions(
        in resourceBundle: Bundle,
        displayLocaleIdentifier: String,
        displayBundle: Bundle? = nil
    ) -> [AppLocaleOption] {
        languageOptions(
            from: reviewedLocalizations(in: resourceBundle),
            displayLocaleIdentifier: displayLocaleIdentifier,
            displayBundle: displayBundle,
            fallbackBundle: resourceBundle
        )
    }

    private static func languageOptions(
        from reviewed: [ReviewedLocalization],
        displayLocaleIdentifier: String,
        displayBundle: Bundle?,
        fallbackBundle: Bundle
    ) -> [AppLocaleOption] {
        let displayLocale = Locale(identifier: displayLocaleIdentifier)
        let localizationBundle = displayBundle
            ?? reviewed.first(where: { $0.identifier == displayLocaleIdentifier })?.bundle
            ?? fallbackBundle
        let systemLabel = localizationBundle.localizedString(
            forKey: "System Default",
            value: "System Default",
            table: "Localizable"
        )
        let localizedOptions = reviewed.compactMap { localization -> AppLocaleOption? in
            guard let label = displayLocale.localizedString(forIdentifier: localization.identifier),
                  !label.isEmpty else {
                return nil
            }
            return AppLocaleOption(
                preference: AppLocalePreference(languageTag: localization.identifier),
                label: label
            )
        }
        .sorted { lhs, rhs in
            lhs.label.localizedStandardCompare(rhs.label) == .orderedAscending
        }
        return [AppLocaleOption(preference: .system, label: systemLabel)] + localizedOptions
    }

    private static func packagedResourceBundle() -> Bundle {
        if let packagedBundleURL = Bundle.main.url(
            forResource: "Umbra_UmbraApp",
            withExtension: "bundle"
        ), let packagedBundle = Bundle(url: packagedBundleURL) {
            return packagedBundle
        }
        return .module
    }

    private static func reviewedLocalizations(in resourceBundle: Bundle) -> [ReviewedLocalization] {
        let localizationDirectories = candidateLocalizationIdentifiers(in: resourceBundle)
        guard let englishDirectory = localizationDirectories.first(where: {
            normalizedLanguageIdentifier($0) == "en"
        }), let englishTables = localizedTables(
            in: resourceBundle,
            localizationDirectory: englishDirectory
        ) else {
            return []
        }

        var localizationsByIdentifier: [String: ReviewedLocalization] = [:]
        for directoryIdentifier in localizationDirectories {
            guard let identifier = normalizedLanguageIdentifier(directoryIdentifier),
                  let tables = localizedTables(
                    in: resourceBundle,
                    localizationDirectory: directoryIdentifier
                  ), tablesAreComplete(tables, matching: englishTables),
                  let bundle = localizationBundle(
                    in: resourceBundle,
                    localizationDirectory: directoryIdentifier
                  ) else {
                continue
            }
            // Shipping an .lproj is the review boundary; exact table parity prevents partial UI.
            localizationsByIdentifier[identifier] = ReviewedLocalization(
                identifier: identifier,
                bundle: bundle
            )
        }
        return localizationsByIdentifier.values.sorted { $0.identifier < $1.identifier }
    }

    private static func candidateLocalizationIdentifiers(in resourceBundle: Bundle) -> [String] {
        let directoryIdentifiers = (try? FileManager.default.contentsOfDirectory(
            at: resourceBundle.bundleURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?.compactMap { url in
            url.pathExtension == "lproj" ? url.deletingPathExtension().lastPathComponent : nil
        } ?? []
        return Array(Set(resourceBundle.localizations + directoryIdentifiers))
            .filter { $0.caseInsensitiveCompare("Base") != .orderedSame }
            .sorted()
    }

    private static func localizedTables(
        in resourceBundle: Bundle,
        localizationDirectory: String
    ) -> [String: [String: String]]? {
        let localizationURL = resourceBundle.bundleURL
            .appending(path: "\(localizationDirectory).lproj", directoryHint: .isDirectory)
        var tables: [String: [String: String]] = [:]
        for table in requiredTables {
            let tableURL = localizationURL.appending(path: "\(table).strings")
            guard let data = try? Data(contentsOf: tableURL),
                  let values = try? PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                  ) as? [String: String],
                  !values.isEmpty,
                  values.allSatisfy({ !$0.key.isEmpty && !$0.value.isEmpty }) else {
                return nil
            }
            tables[table] = values
        }
        return tables
    }

    private static func tablesAreComplete(
        _ candidate: [String: [String: String]],
        matching reference: [String: [String: String]]
    ) -> Bool {
        requiredTables.allSatisfy { table in
            guard let candidateValues = candidate[table],
                  let referenceValues = reference[table] else {
                return false
            }
            return Set(candidateValues.keys) == Set(referenceValues.keys)
        }
    }

    private static func localizationBundle(
        in resourceBundle: Bundle,
        localizationDirectory: String
    ) -> Bundle? {
        Bundle(url: resourceBundle.bundleURL.appending(
            path: "\(localizationDirectory).lproj",
            directoryHint: .isDirectory
        ))
    }

    private static func matchingLocalization(
        for preferences: [String],
        available: [String]
    ) -> String? {
        for preference in preferences {
            guard let normalizedPreference = normalizedLanguageIdentifier(preference),
                  let requestedLanguage = languageCode(in: normalizedPreference) else {
                continue
            }
            let matches = Bundle.preferredLocalizations(
                from: available,
                forPreferences: [normalizedPreference]
            )
            if let match = matches.first(where: {
                available.contains($0) && languageCode(in: $0) == requestedLanguage
            }) {
                return match
            }
        }
        return nil
    }

    private static func normalizedLanguageIdentifier(_ identifier: String) -> String? {
        guard !identifier.isEmpty, !identifier.contains("_") else { return nil }
        let subtags = identifier.split(separator: "-", omittingEmptySubsequences: false)
        guard let language = subtags.first,
              (2...8).contains(language.count),
              language.allSatisfy(\.isASCIIAlphabetic),
              subtags.dropFirst().allSatisfy({ subtag in
                  (1...8).contains(subtag.count) && subtag.allSatisfy(\.isASCIIAlphanumeric)
              }) else {
            return nil
        }
        let normalized = Locale.canonicalLanguageIdentifier(from: identifier)
        return normalized.isEmpty ? nil : normalized
    }

    private static func languageCode(in identifier: String) -> String? {
        normalizedLanguageIdentifier(identifier)?
            .split(separator: "-", maxSplits: 1)
            .first
            .map { String($0).lowercased() }
    }
}

private extension Character {
    var isASCIIAlphabetic: Bool {
        isASCII && isLetter
    }

    var isASCIIAlphanumeric: Bool {
        isASCII && (isLetter || isNumber)
    }
}

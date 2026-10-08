import Foundation

/// One-time import for the pre-release app identity change. Credentials and
/// account files retain their existing namespaces and are never read here.
@MainActor
enum LegacyPreferencesMigration {
    static let currentBundleIdentifier = "com.lumax.tsx"
    static let previousBundleIdentifier = "com.theoyuuu.LumaxTranslate"
    static let completionKey = "migration.legacyPreferencesImported"

    static var preferenceKeys: Set<String> {
        var keys: Set<String> = [
            AppPreferences.StorageKey.defaultTarget,
            AppPreferences.StorageKey.interfaceLanguage,
            AppPreferences.StorageKey.appearance,
            AppPreferences.StorageKey.material,
            AppPreferences.StorageKey.hoverCursor,
            AppPreferences.StorageKey.translationLayout,
            TranslationServiceStore.StorageKey.services,
            TranslationServiceStore.StorageKey.appleAutomaticTranslation,
            TranslationUsageStore.StorageKey.enabled,
            TranslationUsageStore.StorageKey.records
        ]
        for action in ShortcutAction.allCases {
            keys.insert(AppPreferences.StorageKey.shortcut(action))
        }
        for window in TranslationWindowKind.allCases {
            for layout in TranslationLayout.allCases {
                keys.insert(AppPreferences.StorageKey.windowSize(window, layout))
            }
        }
        return keys
    }

    static func migrateIfNeeded(
        defaults: UserDefaults = .standard,
        sourceDomain: String = previousBundleIdentifier,
        destinationDomain: String = currentBundleIdentifier
    ) {
        guard sourceDomain != destinationDomain else { return }
        var destination = defaults.persistentDomain(forName: destinationDomain) ?? [:]
        guard destination[completionKey] as? Bool != true else { return }

        // An already configured new app wins as a whole. Mixing old services
        // or usage with new settings could restore a deliberately removed item.
        if preferenceKeys.isDisjoint(with: destination.keys) {
            let source = defaults.persistentDomain(forName: sourceDomain) ?? [:]
            for key in preferenceKeys {
                if let value = source[key] { destination[key] = value }
            }
        }
        destination[completionKey] = true
        defaults.setPersistentDomain(destination, forName: destinationDomain)
        // Keep the old domain intact so the existing trial app still works.
    }
}

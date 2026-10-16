import Foundation

enum UpdatePreferences {
    static let includesPrereleasesKey = "updateChecker.includesPrereleases"
    static let automaticChecksKey = "updateChecker.automaticChecks"
    static let sparkleMigrationKey = "updates.sparkleMigrationCompleted"

    static func registerDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [automaticChecksKey: true])
    }

    #if os(macOS)
    @MainActor
    static func migrate(to backend: any UpdateBackend, defaults: UserDefaults) {
        guard !defaults.bool(forKey: sparkleMigrationKey) else { return }
        // Sparkle is the sole owner of these preferences after this one-time migration.
        if defaults.object(forKey: automaticChecksKey) != nil {
            backend.automaticallyChecksForUpdates = defaults.bool(forKey: automaticChecksKey)
        }
        for suffix in [
            "lastAttempt", "lastSuccessfulCheck", "lastSuccessfulChannel", "cachedRelease", "etag",
            "cacheSchema", "suppressedUpdate", "automaticChecks",
        ] {
            defaults.removeObject(forKey: "updateChecker.\(suffix)")
        }
        defaults.set(true, forKey: sparkleMigrationKey)
    }
    #endif
}

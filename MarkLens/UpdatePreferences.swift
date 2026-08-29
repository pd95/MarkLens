import Foundation

enum UpdatePreferences {
    static let includesPrereleasesKey = "updateChecker.includesPrereleases"
    static let automaticChecksKey = "updateChecker.automaticChecks"

    static func registerDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [automaticChecksKey: true])
    }
}

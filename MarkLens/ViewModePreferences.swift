import Foundation

#if os(macOS)
enum ViewModePreferences {
    static let defaultKey = "DefaultViewModeEnabled"
    private static let overridesKey = "ViewModeFileOverrides"

    static func registerDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [defaultKey: false])
    }

    static func isEnabled(for fileURL: URL?, in defaults: UserDefaults = .standard) -> Bool {
        guard let fileURL else { return defaults.bool(forKey: defaultKey) }
        let overrides = defaults.dictionary(forKey: overridesKey) as? [String: Bool] ?? [:]
        return overrides[fileURL.standardizedFileURL.resolvingSymlinksInPath().path]
            ?? defaults.bool(forKey: defaultKey)
    }

    static func setEnabled(_ enabled: Bool, for fileURL: URL?, in defaults: UserDefaults = .standard) {
        guard let fileURL else { return }
        var overrides = defaults.dictionary(forKey: overridesKey) as? [String: Bool] ?? [:]
        overrides[fileURL.standardizedFileURL.resolvingSymlinksInPath().path] = enabled
        defaults.set(overrides, forKey: overridesKey)
    }
}
#endif

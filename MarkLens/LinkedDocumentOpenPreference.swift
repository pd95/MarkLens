import Foundation

#if os(macOS)
enum LinkedDocumentOpenPreference: String, CaseIterable {
    case followSystem
    case newWindow
    case newTab

    static let key = "LinkedDocumentOpenPreference"

    static func registerDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [key: Self.followSystem.rawValue])
    }

    static func current(in defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: key) ?? "") ?? .followSystem
    }
}
#endif

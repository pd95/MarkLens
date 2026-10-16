import Foundation

nonisolated enum LinkedFileAction: String, CaseIterable, Sendable {
    case revealInFinder
    case quickLook
    case openInDefaultApp

    var title: String {
        switch self {
        case .revealInFinder: "Reveal in Finder"
        case .quickLook: "Quick Look"
        case .openInDefaultApp: "Open in Default App"
        }
    }
}

nonisolated struct LinkedFileOpenPreference: Equatable, Sendable {
    static let key = "LinkedFileOpenPreference"
    static let commandClickKey = "LinkedFileCommandClickPreference"

    var clickAction: LinkedFileAction = .revealInFinder
    var commandClickAction: LinkedFileAction = .quickLook

    static func registerDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            key: LinkedFileAction.revealInFinder.rawValue,
            commandClickKey: LinkedFileAction.quickLook.rawValue
        ])
    }

    static func current(in defaults: UserDefaults = .standard) -> Self {
        Self(
            clickAction: LinkedFileAction(rawValue: defaults.string(forKey: key) ?? "") ?? .revealInFinder,
            commandClickAction: LinkedFileAction(rawValue: defaults.string(forKey: commandClickKey) ?? "") ?? .quickLook
        )
    }

    func action(commandKey: Bool) -> LinkedFileAction {
        commandKey ? commandClickAction : clickAction
    }
}

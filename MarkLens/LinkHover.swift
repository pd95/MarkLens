import Foundation

nonisolated struct LinkHover: Equatable, Sendable {
    let url: URL
    var commandKey = false

#if os(macOS)
    func annotation(
        documentURL: URL?,
        navigatesInPlace: Bool,
        fileOpenPreference: LinkedFileOpenPreference = .init()
    ) -> String? {
        switch LocalLinkDestination(url: url) {
        case .markdown(let fileURL):
            let components = URLComponents(url: url, resolvingAgainstBaseURL: true)
            var destination = displayPath(for: fileURL, relativeTo: documentURL)
            if let query = components?.percentEncodedQuery { destination += "?" + query }
            if let fragment = components?.fragment {
                if fragment.hasPrefix("marklens-line="),
                   let line = Int(fragment.dropFirst("marklens-line=".count)), line > 0 {
                    destination += ":\(line)"
                } else {
                    destination += "#" + fragment
                }
            }
            if components?.fragment != nil,
               fileURL == documentURL.flatMap({ LocalLinkDestination(url: $0)?.fileURL }) {
                return "Navigate to " + destination
            }
            return openingAction(navigatesInPlace: navigatesInPlace) + destination
        case .wiki(let target):
            return openingAction(navigatesInPlace: navigatesInPlace) + "wiki page " + target
        case .file(let fileURL):
            let action = fileOpenPreference.action(commandKey: commandKey)
            return action.title + ": " + displayPath(for: fileURL, relativeTo: documentURL)
        case nil:
            switch url.scheme?.lowercased() {
            case "http", "https": return "Open in browser: " + url.absoluteString
            case "about" where url.absoluteString.hasPrefix("about:blank#"):
                return "Navigate to #" + (url.fragment ?? "")
            default: return nil
            }
        }
    }

    private func displayPath(for fileURL: URL, relativeTo documentURL: URL?) -> String {
        guard let documentURL = documentURL.flatMap({ LocalLinkDestination(url: $0)?.fileURL }) else {
            return fileURL.path
        }
        let directoryComponents = documentURL.deletingLastPathComponent().pathComponents
        let targetComponents = fileURL.pathComponents
        let sharedCount = zip(directoryComponents, targetComponents).prefix { $0.0 == $0.1 }.count
        let components = Array(repeating: "..", count: directoryComponents.count - sharedCount)
            + targetComponents.dropFirst(sharedCount)
        return components.isEmpty ? "." : components.joined(separator: "/")
    }

    private func openingAction(navigatesInPlace: Bool) -> String {
        if commandKey { return "Open in New Tab: " }
        return navigatesInPlace ? "Navigate to " : "Open "
    }
#endif
}

import Foundation
import MarkdownPipeline

#if os(macOS)
nonisolated enum WikiLinkAction: Equatable, Sendable {
    case open(inNewTab: Bool)
    case revealInFinder
    case quickLook
}

nonisolated struct ResolvedWikiLink: Sendable {
    let matches: [URL]
    let heading: String?
    let line: Int?

    static func resolve(
        _ target: String,
        in root: URL,
        action: WikiLinkAction,
        shouldCancel: @Sendable () -> Bool = { false }
    ) throws -> Self {
        let parts = target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let heading: String?
        switch action {
        case .open: heading = parts.count < 2 ? nil : String(parts[1])
        case .revealInFinder, .quickLook: heading = nil
        }
        let resolver = WikiLinkResolver()
        let matches = try resolver.matches(for: String(parts[0]), in: root, shouldCancel: shouldCancel)
        let line = try heading.flatMap { heading in
            try matches.count == 1
                ? resolver.sourceLine(forHeading: heading, in: matches[0], shouldCancel: shouldCancel)
                : nil
        }
        return Self(matches: matches, heading: heading, line: line)
    }
}
#endif

import Foundation
import Markdown

public enum WikiLinkResolverError: LocalizedError, Sendable {
    case invalidTarget
    case missingTarget(String)
    case missingHeading(String)

    public var errorDescription: String? {
        switch self {
        case .invalidTarget:
            return "This wikilink target is not valid."
        case .missingTarget(let target):
            return "No Markdown document named \(target) was found in the selected wiki folder."
        case .missingHeading(let heading):
            return "No heading named \(heading) was found in the linked document."
        }
    }
}

public struct WikiLinkResolver: Sendable {
    public static let defaultMarkdownExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "mkdn"
    ]

    private let markdownExtensions: Set<String>

    public init(markdownExtensions: Set<String> = defaultMarkdownExtensions) {
        self.markdownExtensions = Set(markdownExtensions.map { $0.lowercased() })
    }

    public func matches(
        for target: String,
        in root: URL,
        shouldCancel: @Sendable () -> Bool = { false }
    ) throws -> [URL] {
        if shouldCancel() { throw CancellationError() }
        guard let query = normalized(target) else {
            throw WikiLinkResolverError.invalidTarget
        }

        let isPathQualified = query.target.contains("/")
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw WikiLinkResolverError.missingTarget(target)
        }

        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        var matches: [URL] = []
        for case let candidate as URL in enumerator {
            if shouldCancel() { throw CancellationError() }
            let values = try? candidate.resourceValues(forKeys: resourceKeys)
            guard values?.isRegularFile == true,
                  values?.isSymbolicLink != true,
                  markdownExtensions.contains(candidate.pathExtension.lowercased()) else {
                continue
            }

            let canonicalCandidate = candidate.standardizedFileURL.resolvingSymlinksInPath()
            guard contains(canonicalCandidate, in: canonicalRoot) else { continue }

            var candidateValue = isPathQualified
                ? relativePath(of: canonicalCandidate, in: canonicalRoot)
                : canonicalCandidate.lastPathComponent
            if query.hasExplicitExtension == false {
                candidateValue = (candidateValue as NSString).deletingPathExtension
            }
            if candidateValue.compare(
                query.target,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame {
                matches.append(canonicalCandidate)
            }
        }

        guard matches.isEmpty == false else {
            throw WikiLinkResolverError.missingTarget(target)
        }
        if shouldCancel() { throw CancellationError() }
        return matches.sorted {
            relativePath(of: $0, in: canonicalRoot).localizedStandardCompare(
                relativePath(of: $1, in: canonicalRoot)
            ) == .orderedAscending
        }
    }

    public func relativePath(of url: URL, in root: URL) -> String {
        let rootComponents = root.standardizedFileURL.pathComponents
        let fileComponents = url.standardizedFileURL.pathComponents
        return fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    public func sourceLine(
        forHeading heading: String,
        in documentURL: URL,
        shouldCancel: @Sendable () -> Bool = { false }
    ) throws -> Int {
        let heading = heading.trimmingCharacters(in: .whitespacesAndNewlines)
        guard heading.isEmpty == false else { throw WikiLinkResolverError.invalidTarget }
        if shouldCancel() { throw CancellationError() }
        let markdown = try String(contentsOf: documentURL, encoding: .utf8)
        if shouldCancel() { throw CancellationError() }
        let extraction = FrontMatterExtractor().extract(from: markdown)
        let normalized = MarkdownFenceNormalizer().normalize(extraction.bodyMarkdown)
        let document = Document(parsing: normalized)
        if shouldCancel() { throw CancellationError() }
        var lookup = HeadingLineLookup(
            requestedID: WikiHeadingID.slug(from: heading),
            requestedText: heading,
            matchesByText: heading.unicodeScalars.contains(where: { $0.isASCII == false }),
            lineOffset: extraction.bodyLineOffset
        )
        guard let line = try lookup.find(in: document, shouldCancel: shouldCancel) else {
            throw WikiLinkResolverError.missingHeading(heading)
        }
        return line
    }

    private func normalized(_ target: String) -> (target: String, hasExplicitExtension: Bool)? {
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard target.isEmpty == false,
              target.hasPrefix("/") == false,
              target.hasPrefix("~") == false else {
            return nil
        }
        let components = target.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ $0.isEmpty == false && $0 != "." && $0 != ".." }) else {
            return nil
        }
        return (target, URL(fileURLWithPath: target).pathExtension.isEmpty == false)
    }

    private func contains(_ file: URL, in folder: URL) -> Bool {
        let fileComponents = file.standardizedFileURL.pathComponents
        let folderComponents = folder.standardizedFileURL.pathComponents
        return fileComponents.starts(with: folderComponents)
            && fileComponents.count > folderComponents.count
    }
}

private struct HeadingLineLookup {
    let requestedID: String
    let requestedText: String
    let matchesByText: Bool
    let lineOffset: Int
    var counts: [String: Int] = [:]
    var textCounts: [String: Int] = [:]

    mutating func find(in markup: Markup, shouldCancel: () -> Bool) throws -> Int? {
        if shouldCancel() { throw CancellationError() }
        if let heading = markup as? Heading {
            let base = WikiHeadingID.slug(from: heading.plainText)
            let count = counts[base, default: 0]
            let identifier = count == 0 ? base : "\(base)-\(count)"
            counts[base] = count + 1
            let headingText = heading.plainText
            let textKey = headingText.lowercased()
            let textCount = textCounts[textKey, default: 0]
            textCounts[textKey] = textCount + 1
            let textReference = textCount == 0 ? headingText : "\(headingText)-\(textCount)"
            let matches = matchesByText
                ? textReference.compare(requestedText, options: [.caseInsensitive]) == .orderedSame
                : identifier == requestedID
            if matches, let range = heading.range {
                return range.lowerBound.line + lineOffset
            }
        }
        for child in markup.children {
            if let line = try find(in: child, shouldCancel: shouldCancel) { return line }
        }
        return nil
    }
}

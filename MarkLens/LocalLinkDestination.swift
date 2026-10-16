import Foundation
import MarkdownPipeline

#if os(macOS)
nonisolated enum LocalLinkDestination: Equatable {
    case markdown(URL)
    case file(URL)
    case folder(URL)
    case wiki(String)

    init?(url: URL) {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        if components.scheme?.lowercased() == "marklens-wikilink" {
            guard components.host == "open",
                  let target = components.queryItems?.first(where: { $0.name == "target" })?.value,
                  !target.isEmpty else { return nil }
            self = .wiki(target)
            return
        }
        guard url.isFileURL,
              components.host?.isEmpty != false || components.host?.lowercased() == "localhost" else {
            return nil
        }
        components.query = nil
        components.fragment = nil
        guard let fileURL = components.url?.standardizedFileURL else { return nil }
        let fileExtension = fileURL.pathExtension.lowercased()
        // Check metadata for links without a trailing slash, resolving symlinks
        // only for the type check so Finder still receives the original URL.
        if fileURL.hasDirectoryPath
            || (try? fileURL.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            self = .folder(fileURL)
        } else if WikiLinkResolver.defaultMarkdownExtensions.contains(fileExtension) {
            self = .markdown(fileURL)
        } else {
            self = .file(fileURL)
        }
    }

    var fileURL: URL? {
        switch self {
        case .markdown(let url), .file(let url), .folder(let url): url
        case .wiki: nil
        }
    }
}
#endif

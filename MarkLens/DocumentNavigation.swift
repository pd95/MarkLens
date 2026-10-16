import Foundation

#if os(macOS)
import Combine
import MarkdownPipeline

struct DocumentNavigationRequest: Equatable {
    let id = UUID()
    let fileURL: URL
    let position: DocumentScrollPosition
}

@MainActor
final class DocumentNavigationCoordinator: ObservableObject {
    @Published private(set) var requests: [URL: DocumentNavigationRequest] = [:]

    func enqueue(fileURL: URL, line: Int) {
        guard line > 0 else { return }
        enqueue(fileURL: fileURL, position: DocumentScrollPosition(sourceLine: line, progress: 0))
    }

    func enqueue(fileURL: URL, position: DocumentScrollPosition) {
        let fileURL = Self.documentURL(fileURL)
        requests[fileURL] = DocumentNavigationRequest(fileURL: fileURL, position: position)
    }

    func takeRequest(for fileURL: URL, id: UUID) -> DocumentScrollPosition? {
        let fileURL = Self.documentURL(fileURL)
        guard let request = requests[fileURL], request.id == id else { return nil }
        requests.removeValue(forKey: fileURL)
        return request.position
    }

    func cancel(for fileURL: URL) {
        requests.removeValue(forKey: Self.documentURL(fileURL))
    }

    private static func documentURL(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        components?.fragment = nil
        components?.query = nil
        return components?.url?.standardizedFileURL ?? url.standardizedFileURL
    }

    static func incomingDestination(from url: URL) -> (fileURL: URL, line: Int)? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "marklens",
              components.host?.lowercased() == "open",
              components.path.isEmpty || components.path == "/",
              components.fragment == nil,
              let query = components.queryItems,
              query.count == 2,
              let fileValue = query.first(where: { $0.name == "file" })?.value,
              let lineValue = query.first(where: { $0.name == "line" })?.value,
              let fileURL = URL(string: fileValue), fileURL.isFileURL,
              let line = Int(lineValue), line > 0,
              WikiLinkResolver.defaultMarkdownExtensions.contains(fileURL.pathExtension.lowercased()) else {
            return nil
        }
        return (fileURL.standardizedFileURL, line)
    }
}
#endif

import Foundation

#if os(macOS)
import Combine
import MarkdownPipeline

struct LineNavigationRequest: Equatable {
    let id = UUID()
    let fileURL: URL
    let line: Int
}

@MainActor
final class LineNavigationCoordinator: ObservableObject {
    @Published private(set) var requests: [URL: LineNavigationRequest] = [:]

    func enqueue(fileURL: URL, line: Int) {
        guard line > 0 else { return }
        let fileURL = fileURL.standardizedFileURL
        requests[fileURL] = LineNavigationRequest(fileURL: fileURL, line: line)
    }

    func takeRequest(for fileURL: URL, id: UUID) -> Int? {
        let fileURL = fileURL.standardizedFileURL
        guard let request = requests[fileURL], request.id == id else { return nil }
        requests.removeValue(forKey: fileURL)
        return request.line
    }

    func cancel(for fileURL: URL) {
        requests.removeValue(forKey: fileURL.standardizedFileURL)
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

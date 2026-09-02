import Foundation

public struct HTMLDocument {
    public let html: String
    public let title: String?
    public let baseURL: URL?
    public let containsWikiLinks: Bool
    public let containsFrontMatter: Bool
    public let resources: [HTMLResource]
    public let filteredHTMLFragmentCount: Int

    public init(
        html: String,
        title: String?,
        baseURL: URL?,
        containsWikiLinks: Bool = false,
        containsFrontMatter: Bool = false,
        resources: [HTMLResource] = [],
        filteredHTMLFragmentCount: Int = 0
    ) {
        self.html = html
        self.title = title
        self.baseURL = baseURL
        self.containsWikiLinks = containsWikiLinks
        self.containsFrontMatter = containsFrontMatter
        self.resources = resources
        self.filteredHTMLFragmentCount = filteredHTMLFragmentCount
    }

    @discardableResult
    public func write(to url: URL) throws -> URL {
        try standaloneHTML.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    public var standaloneHTML: String {
        resources.reduce(html) { result, resource in
            let encoded = resource.data.base64EncodedString()
            let dataURL = "data:\(resource.contentType);base64,\(encoded)"
            return result.replacingOccurrences(of: resource.url.absoluteString, with: dataURL)
        }
    }

    public func writeToTemporaryFile() throws -> URL {
        let fileName = "markdown-preview-\(UUID().uuidString).html"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        return try write(to: url)
    }
}

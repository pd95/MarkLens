//
//  MarkdownDocument.swift
//  MarkLens
//
//  Created by Philipp on 02.01.2026.
//

import SwiftUI
import Combine
import MarkdownPipeline
import UniformTypeIdentifiers
#if canImport(os)
import os
#endif

final class MarkdownDocument: ReferenceFileDocument {
    typealias Snapshot = String

    private(set) var text: String
    @Published private(set) var renderedHTML: String
    @Published private(set) var renderedResources: [HTMLResource]
    @Published private(set) var containsWikiLinks: Bool
    @Published private(set) var renderRevision: Int
    let filename: String?

    private static let renderingPipeline = MarkdownPipeline(
        plugins: [.wikiLinks(), .syntaxHighlighting(), .math(), .mermaid(), .customCSS()]
    )

    static let starterText = """
        # Welcome to MarkLens

        This is a new Markdown document. Choose **Edit Source** in the toolbar or press `⌘E` in MarkLens to edit its source.

        ## Quick start

        Use **bold**, *italic*, `inline code`, and [links](https://commonmark.org/help/).

        - Create lists with hyphens
        - Add headings with `#`
        - Quote text with `>`

        ```swift
        let message = "Hello, Markdown!"
        ```

        ## Learn more

        - [CommonMark quick reference](https://commonmark.org/help/)
        - [GitHub Flavored Markdown specification](https://github.github.com/gfm/)
        """

    init(text: String = "") {
        self.text = text
        self.filename = nil
        let rendering = Self.renderHTML(from: text, title: nil)
        self.renderedHTML = rendering.html
        self.renderedResources = rendering.resources
        self.containsWikiLinks = rendering.containsWikiLinks
        self.renderRevision = 0
    }

    static let readableContentTypes = [
        UTType.appMarkdown
    ]
    static let writableContentTypes = [
        UTType.appMarkdown
    ]

    required init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard let text = DocumentPerformanceInstrumentation.measure("DocumentDecode", operation: {
            String(data: data, encoding: .utf8)
        }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
        self.filename = configuration.file.preferredFilename
        let rendering = Self.renderHTML(from: text, title: configuration.file.preferredFilename)
        self.renderedHTML = rendering.html
        self.renderedResources = rendering.resources
        self.containsWikiLinks = rendering.containsWikiLinks
        self.renderRevision = 0
    }

    func snapshot(contentType: UTType) throws -> String {
        text
    }

    func fileWrapper(snapshot: String, configuration: WriteConfiguration) throws -> FileWrapper {
        let data = snapshot.data(using: .utf8) ?? Data()
        return .init(regularFileWithContents: data)
    }

    func updateText(_ newText: String) {
        guard text != newText else {
            return
        }

        text = newText
        let rendering = Self.renderHTML(from: newText, title: filename)
        renderedHTML = rendering.html
        renderedResources = rendering.resources
        containsWikiLinks = rendering.containsWikiLinks
        renderRevision += 1
    }

    private static func renderHTML(
        from markdown: String,
        title: String?
    ) -> (html: String, containsWikiLinks: Bool, resources: [HTMLResource]) {
        DocumentPerformanceInstrumentation.measure("DocumentRender") {
            let context = PipelineContext(title: title)
            if let document = try? renderingPipeline.renderHTML(from: .string(markdown), context: context) {
                return (document.html, document.containsWikiLinks, document.resources)
            }
            return (renderFailureHTML, false, [])
        }
    }

    private static let renderFailureHTML = "<!doctype html><html><body><pre>Unable to render document.</pre></body></html>"
}

private enum DocumentPerformanceInstrumentation {
#if canImport(os)
    private static let log = OSLog(subsystem: "ch.doapp.MarkLens", category: "Document")
#endif

    static func measure<Result>(_ name: StaticString, operation: () -> Result) -> Result {
#if canImport(os)
        let signpostID = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: signpostID)
        defer {
            os_signpost(.end, log: log, name: name, signpostID: signpostID)
        }
#endif
        return operation()
    }
}

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
    @Published private(set) var containsFrontMatter: Bool
    @Published private(set) var filteredHTMLFragmentCount: Int
    @Published private(set) var htmlContentAdjustmentReason: HTMLContentAdjustmentReason?
    @Published private(set) var renderRevision: Int
    let filename: String?
    private var renderingPreferences: RenderingPreferences

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
        self.renderingPreferences = .secureDefaults
        let rendering = Self.renderHTML(from: text, title: nil, preferences: .secureDefaults)
        self.renderedHTML = rendering.html
        self.renderedResources = rendering.resources
        self.containsWikiLinks = rendering.containsWikiLinks
        self.containsFrontMatter = rendering.containsFrontMatter
        self.filteredHTMLFragmentCount = rendering.filteredHTMLFragmentCount
        self.htmlContentAdjustmentReason = rendering.htmlContentAdjustmentReason
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
        self.renderingPreferences = .secureDefaults
        let rendering = Self.renderHTML(
            from: text,
            title: configuration.file.preferredFilename,
            preferences: .secureDefaults
        )
        self.renderedHTML = rendering.html
        self.renderedResources = rendering.resources
        self.containsWikiLinks = rendering.containsWikiLinks
        self.containsFrontMatter = rendering.containsFrontMatter
        self.filteredHTMLFragmentCount = rendering.filteredHTMLFragmentCount
        self.htmlContentAdjustmentReason = rendering.htmlContentAdjustmentReason
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
        let rendering = Self.renderHTML(from: newText, title: filename, preferences: renderingPreferences)
        renderedHTML = rendering.html
        renderedResources = rendering.resources
        containsWikiLinks = rendering.containsWikiLinks
        containsFrontMatter = rendering.containsFrontMatter
        filteredHTMLFragmentCount = rendering.filteredHTMLFragmentCount
        htmlContentAdjustmentReason = rendering.htmlContentAdjustmentReason
        renderRevision += 1
    }

    func updateRenderingPreferences(_ preferences: RenderingPreferences) {
        guard renderingPreferences != preferences else { return }
        renderingPreferences = preferences
        let rendering = Self.renderHTML(from: text, title: filename, preferences: preferences)
        renderedHTML = rendering.html
        renderedResources = rendering.resources
        containsWikiLinks = rendering.containsWikiLinks
        containsFrontMatter = rendering.containsFrontMatter
        filteredHTMLFragmentCount = rendering.filteredHTMLFragmentCount
        htmlContentAdjustmentReason = rendering.htmlContentAdjustmentReason
        renderRevision += 1
    }

    private static func renderHTML(
        from markdown: String,
        title: String?,
        preferences: RenderingPreferences
    ) -> (
        html: String,
        containsWikiLinks: Bool,
        containsFrontMatter: Bool,
        resources: [HTMLResource],
        filteredHTMLFragmentCount: Int,
        htmlContentAdjustmentReason: HTMLContentAdjustmentReason?
    ) {
        DocumentPerformanceInstrumentation.measure("DocumentRender") {
            let context = preferences.pipelineContext(title: title)
            if let document = try? renderingPipeline.renderHTML(from: .string(markdown), context: context) {
                let adjustmentReason = document.filteredHTMLFragmentCount > 0
                    ? preferences.htmlContentAdjustmentReason
                    : nil
                return (
                    document.html,
                    document.containsWikiLinks,
                    document.containsFrontMatter,
                    document.resources,
                    document.filteredHTMLFragmentCount,
                    adjustmentReason
                )
            }
            return (renderFailureHTML, false, false, [], 0, nil)
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

import Foundation

public struct PipelineContext {
    public enum RawHTMLPolicy: Sendable, Equatable {
        case escaped
        case sanitized
    }

    public enum Theme: String, Sendable {
        case light
        case dark
        case auto
    }

    public enum MermaidRendering: Sendable, Equatable {
        case rendered
        case source
        case sourceWithAppHint
    }

    public var title: String?
    public var baseURL: URL?
    public var theme: Theme
    /// Legacy per-render override. Prefer configuring `.syntaxHighlighting(languageSubset:)`
    /// when constructing `MarkdownPipeline`.
    public var highlightLanguageSubset: [String]
    /// Legacy per-render switch retained for source compatibility.
    public var enableCodeHighlighting: Bool
    /// Legacy per-render override. A source fallback requested here or by the Mermaid feature wins.
    public var mermaidRendering: MermaidRendering
    public var rawHTMLPolicy: RawHTMLPolicy
    public var allowsRemoteResources: Bool
    public var allowsLocalResources: Bool

    public init(
        title: String? = nil,
        baseURL: URL? = nil,
        theme: Theme = .auto,
        highlightLanguageSubset: [String] = [],
        enableCodeHighlighting: Bool = true,
        mermaidRendering: MermaidRendering = .rendered,
        rawHTMLPolicy: RawHTMLPolicy = .sanitized,
        allowsRemoteResources: Bool = true,
        allowsLocalResources: Bool = true
    ) {
        self.title = title
        self.baseURL = baseURL
        self.theme = theme
        self.highlightLanguageSubset = highlightLanguageSubset
        self.enableCodeHighlighting = enableCodeHighlighting
        self.mermaidRendering = mermaidRendering
        self.rawHTMLPolicy = rawHTMLPolicy
        self.allowsRemoteResources = allowsRemoteResources
        self.allowsLocalResources = allowsLocalResources
    }
}

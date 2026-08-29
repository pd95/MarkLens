import Foundation
import Markdown

final class CustomCSSHTMLPlugin: HTMLRenderingPlugin {
    let identifier = "custom-css"
    private let css: String

    init(css: String) {
        self.css = css
    }

    func makeSession(context: PipelineContext) -> any HTMLRenderingPluginSession {
        CustomCSSHTMLPluginSession(css: css)
    }
}

private final class CustomCSSHTMLPluginSession: HTMLRenderingPluginSession {
    private let css: String

    init(css: String) {
        self.css = css
    }

    func contribution() throws -> HTMLPluginContribution {
        var contribution = HTMLPluginContribution()
        contribution.overrideStyles = css
        return contribution
    }
}

final class WikiLinkHTMLPlugin: HTMLRenderingPlugin {
    let identifier = "wiki-links"

    func makeSession(context: PipelineContext) -> any HTMLRenderingPluginSession {
        WikiLinkHTMLPluginSession()
    }
}

private final class WikiLinkHTMLPluginSession: HTMLRenderingPluginSession {
    private var placeholder: String?
    private var containsWikiLinks = false

    func preprocess(_ markdown: String) -> String {
        let protected = WikiLinkEscapes.protect(in: markdown)
        placeholder = protected.placeholder
        return protected.markdown
    }

    func restoreLiteral(_ text: String) -> String {
        WikiLinkEscapes.restoreText(text, placeholder: placeholder, includeBackslash: true)
    }

    func renderText(
        _ text: String,
        environment: HTMLTextEnvironment,
        next: (String) -> String
    ) -> String {
        guard environment.allowsWikiLinks else {
            return WikiLinkEscapes.restoreText(
                text,
                placeholder: placeholder,
                includeBackslash: false
            ).encodedHTMLEntities()
        }
        let rendered = WikiLinkRenderer.render(text, escapedWikiLinkPlaceholder: placeholder)
        containsWikiLinks = containsWikiLinks || rendered.containsWikiLinks
        return rendered.html
    }

    func contribution() throws -> HTMLPluginContribution {
        var contribution = HTMLPluginContribution()
        contribution.containsWikiLinks = containsWikiLinks
        return contribution
    }
}

final class MathHTMLPlugin: HTMLRenderingPlugin {
    let identifier = "math"
    private let engine = LockedKaTeXEngine()

    func makeSession(context: PipelineContext) -> any HTMLRenderingPluginSession {
        MathHTMLPluginSession(engine: engine)
    }
}

private final class LockedKaTeXEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var renderer: KaTeXRenderer?

    func render(_ source: String, displayMode: Bool) -> String? {
        lock.withLock {
            if renderer == nil {
                renderer = KaTeXRenderer()
            }
            return renderer?.render(source, displayMode: displayMode)
        }
    }
}

private final class MathHTMLPluginSession: HTMLRenderingPluginSession {
    private let engine: LockedKaTeXEngine
    private var expressions: [String: ProtectedMath.Expression] = [:]
    private var containsRenderedMath = false

    init(engine: LockedKaTeXEngine) {
        self.engine = engine
    }

    func preprocess(_ markdown: String) -> String {
        let protected = MathSyntaxProtector().protect(in: markdown)
        expressions = protected.expressions
        return protected.markdown
    }

    func restoreLiteral(_ text: String) -> String {
        expressions.values.reduce(text) { result, expression in
            result.replacingOccurrences(of: expression.token, with: expression.original)
        }
    }

    func renderStandaloneParagraph(_ text: String) -> String? {
        guard let expression = expressions[text], expression.displayMode else {
            return nil
        }
        return render(expression) + "\n"
    }

    func renderText(
        _ text: String,
        environment: HTMLTextEnvironment,
        next: (String) -> String
    ) -> String {
        var result = ""
        var remaining = text[...]
        while let match = expressions.values
            .compactMap({ expression -> (ProtectedMath.Expression, Range<String.Index>)? in
                guard let range = remaining.range(of: expression.token) else { return nil }
                return (expression, range)
            })
            .min(by: { $0.1.lowerBound < $1.1.lowerBound }) {
            result += next(String(remaining[..<match.1.lowerBound]))
            result += render(match.0)
            remaining = remaining[match.1.upperBound...]
        }
        result += next(String(remaining))
        return result
    }

    func contribution() throws -> HTMLPluginContribution {
        guard containsRenderedMath else { return HTMLPluginContribution() }
        let assets = try KaTeXAssets.load()
        var contribution = HTMLPluginContribution()
        contribution.styles = assets.stylesheet
        contribution.resources = assets.resources
        return contribution
    }

    private func render(_ expression: ProtectedMath.Expression) -> String {
        guard let html = engine.render(expression.source, displayMode: expression.displayMode) else {
            return expression.original.encodedHTMLEntities()
        }
        containsRenderedMath = true
        let tag = expression.displayMode ? "div" : "span"
        let mode = expression.displayMode ? "display" : "inline"
        return "<\(tag) class=\"math math-\(mode)\">\(html)</\(tag)>"
    }
}

final class MermaidHTMLPlugin: HTMLRenderingPlugin {
    let identifier = "mermaid"
    private let rendering: PipelineContext.MermaidRendering

    init(rendering: PipelineContext.MermaidRendering) {
        self.rendering = rendering
    }

    func makeSession(context: PipelineContext) -> any HTMLRenderingPluginSession {
        // Preserve the legacy context override. Source fallback is conservative: requesting it
        // from either configuration surface wins until the context option can be removed.
        let resolvedRendering: PipelineContext.MermaidRendering
        if rendering == .rendered {
            resolvedRendering = context.mermaidRendering
        } else {
            resolvedRendering = rendering
        }
        return MermaidHTMLPluginSession(rendering: resolvedRendering, theme: context.theme)
    }
}

private final class MermaidHTMLPluginSession: HTMLRenderingPluginSession {
    private let rendering: PipelineContext.MermaidRendering
    private let theme: PipelineContext.Theme
    private var containsBlocks = false
    private var containsRenderedDiagrams = false

    init(rendering: PipelineContext.MermaidRendering, theme: PipelineContext.Theme) {
        self.rendering = rendering
        self.theme = theme
    }

    func renderCodeBlock(_ codeBlock: CodeBlock, restoredSource: String) -> String? {
        guard codeBlock.language?
            .split(whereSeparator: { $0.isWhitespace })
            .first?
            .lowercased() == "mermaid" else {
            return nil
        }

        let source = restoredSource.trimmingCharacters(in: .newlines).encodedHTMLEntities()
        containsBlocks = true
        switch rendering {
        case .rendered:
            containsRenderedDiagrams = true
            return """
            <div class="mermaid-block" data-mermaid-diagram>
            <pre class="mermaid-source"><code class="language-mermaid">\(source)\n</code></pre>
            <p class="mermaid-error" role="status" hidden>Could not render Mermaid diagram. Showing source.</p>
            </div>
            """ + "\n"
        case .source:
            return """
            <div class="mermaid-block mermaid-source-fallback">
            <pre class="mermaid-source"><code class="lang-plaintext">\(source)\n</code></pre>
            </div>
            """ + "\n"
        case .sourceWithAppHint:
            return """
            <div class="mermaid-block mermaid-source-fallback">
            <p class="mermaid-hint"><strong>Quick Look source</strong> — open in MarkLens to render this Mermaid diagram</p>
            <pre class="mermaid-source"><code class="lang-plaintext">\(source)\n</code></pre>
            </div>
            """ + "\n"
        }
    }

    func contribution() throws -> HTMLPluginContribution {
        guard containsBlocks else { return HTMLPluginContribution() }
        var contribution = HTMLPluginContribution()
        contribution.styles = try MermaidAssets.stylesheet()
        if containsRenderedDiagrams {
            let assets = try MermaidAssets.load(theme: theme)
            contribution.scripts = assets.scripts
            contribution.resources = assets.resources
        }
        return contribution
    }
}

final class SyntaxHighlightingHTMLPlugin: HTMLRenderingPlugin {
    let identifier = "syntax-highlighting"
    private let languageSubset: [String]
    private let engine = LockedHighlightEngine()

    init(languageSubset: [String]) {
        self.languageSubset = languageSubset
    }

    func makeSession(context: PipelineContext) -> any HTMLRenderingPluginSession {
        // A nonempty legacy context subset overrides the plugin default. An empty context subset
        // means "use the plugin configuration" for backward compatibility.
        let subset = context.highlightLanguageSubset.isEmpty
            ? languageSubset
            : context.highlightLanguageSubset
        return SyntaxHighlightingHTMLPluginSession(
            engine: engine,
            languageSubset: subset,
            isEnabled: context.enableCodeHighlighting,
            theme: context.theme
        )
    }
}

private final class LockedHighlightEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var highlighter: HLJSHighlighter?

    func highlight(code: String, language: String?, languageSubset: [String]) -> CodeHighlightResult? {
        lock.withLock {
            if highlighter == nil {
                highlighter = HLJSHighlighter()
            }
            return highlighter?.highlight(
                code: code,
                language: language,
                languageSubset: languageSubset
            )
        }
    }
}

private final class SyntaxHighlightingHTMLPluginSession: HTMLRenderingPluginSession {
    private let engine: LockedHighlightEngine
    private let languageSubset: [String]
    private let isEnabled: Bool
    private let theme: PipelineContext.Theme
    private var allowsAutomaticHighlighting = true
    private var containsCodeBlocks = false

    init(
        engine: LockedHighlightEngine,
        languageSubset: [String],
        isEnabled: Bool,
        theme: PipelineContext.Theme
    ) {
        self.engine = engine
        self.languageSubset = languageSubset
        self.isEnabled = isEnabled
        self.theme = theme
    }

    func preprocess(_ markdown: String) -> String {
        allowsAutomaticHighlighting = CodeHighlightingInputPolicy
            .allowsAutomaticHighlighting(document: markdown)
        return markdown
    }

    func renderCodeBlock(_ codeBlock: CodeBlock, restoredSource: String) -> String? {
        guard isEnabled else { return nil }
        let declaredLanguage = HLJSHighlighter.normalizedLanguageIdentifier(from: codeBlock.language)
        guard declaredLanguage != nil || allowsAutomaticHighlighting else {
            return nil
        }
        containsCodeBlocks = true
        guard let highlight = engine.highlight(
                code: restoredSource,
                language: declaredLanguage,
                languageSubset: languageSubset
              ) else {
            return nil
        }
        let metadata = CodeLanguageMetadata(
            identifier: highlight.language ?? CodeLanguageMetadata.plainTextIdentifier,
            source: highlight.language == nil
                ? .fallback
                : (declaredLanguage == nil ? .automatic : .explicit)
        )
        let languageClass = highlight.language
            .map { " language-\($0.encodedHTMLAttribute())" } ?? ""
        return "<pre><code class=\"hljs\(languageClass)\"\(metadata.htmlAttributes)>"
            + "\(highlight.html)</code></pre>\n"
    }

    func contribution() throws -> HTMLPluginContribution {
        guard containsCodeBlocks else { return HTMLPluginContribution() }
        var contribution = HTMLPluginContribution()
        contribution.styles = try highlightingStylesheet(for: theme)
        return contribution
    }

    private func highlightingStylesheet(for theme: PipelineContext.Theme) throws -> String {
        switch theme {
        case .light:
            guard let stylesheet = Self.lightStylesheet else {
                throw MarkdownPipelineError.missingResource("stackoverflow-light.min.css")
            }
            return stylesheet
        case .dark:
            guard let stylesheet = Self.darkStylesheet else {
                throw MarkdownPipelineError.missingResource("stackoverflow-dark.min.css")
            }
            return stylesheet
        case .auto:
            guard let dark = Self.darkStylesheet, let light = Self.lightStylesheet else {
                throw MarkdownPipelineError.missingResource("Highlight.js stylesheets")
            }
            return "@media (prefers-color-scheme: dark) {\n\(dark)\n}\n" +
                "@media (prefers-color-scheme: light), (prefers-color-scheme: no-preference) {\n\(light)\n}"
        }
    }

    private static let lightStylesheet = try? ResourceLoader.stringResource(
        "stackoverflow-light.min.css"
    )
    private static let darkStylesheet = try? ResourceLoader.stringResource(
        "stackoverflow-dark.min.css"
    )
}

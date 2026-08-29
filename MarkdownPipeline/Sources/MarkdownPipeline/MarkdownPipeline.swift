import Foundation

public struct MarkdownPipeline: Sendable {
    private let defaultTheme: PipelineContext.Theme
    private let plugins: [any HTMLRenderingPlugin]

    /// Creates an HTML pipeline from built-in feature descriptors.
    ///
    /// Feature order does not affect execution order. When a feature appears more than once,
    /// its last configuration is used.
    public init(
        defaultTheme: PipelineContext.Theme = .auto,
        plugins: [HTMLFeature] = HTMLFeature.defaultHTML
    ) {
        self.defaultTheme = defaultTheme
        self.plugins = Self.makePlugins(from: plugins)
    }

    public static func defaultHTML(theme: PipelineContext.Theme = .auto) -> MarkdownPipeline {
        MarkdownPipeline(defaultTheme: theme)
    }

    public func renderHTML(from input: MarkdownInput, context: PipelineContext = PipelineContext()) throws -> HTMLDocument {
        try render(input: input, context: context)
    }

    public func render(input: MarkdownInput, context: PipelineContext) throws -> HTMLDocument {
        try PipelineInstrumentation.measure("PipelineRender") {
            let markdown = try PipelineInstrumentation.measure("DocumentRead") {
                try input.resolvedString()
            }
            let extraction = PipelineInstrumentation.measure("FrontMatter") {
                FrontMatterExtractor().extract(from: markdown)
            }
            let mergedContext = merge(context: context, frontMatter: extraction.frontMatter)

            let coordinator = PipelineInstrumentation.measure("PluginSetup") {
                HTMLPluginCoordinator(plugins: plugins, context: mergedContext)
            }
            let normalizedMarkdown = PipelineInstrumentation.measure("FenceNormalization") {
                MarkdownFenceNormalizer().normalize(extraction.bodyMarkdown)
            }
            let preparedMarkdown = PipelineInstrumentation.measure("PluginPreprocessing") {
                coordinator.preprocess(normalizedMarkdown)
            }
            let document = PipelineInstrumentation.measure("MarkdownParse") {
                SwiftMarkdownParser().parse(markdown: preparedMarkdown)
            }
            let renderedBody = PipelineInstrumentation.measure("HTMLRender") {
                HTMLVisitor.render(
                    document: document,
                    sourceLineOffset: extraction.bodyLineOffset,
                    plugins: coordinator,
                    context: mergedContext
                )
            }
            let contribution = try PipelineInstrumentation.measure("PluginAssets") {
                try coordinator.contribution()
            }
            let html = try PipelineInstrumentation.measure("HTMLDocumentAssembly") {
                try HTMLEmitter().render(
                    bodyHTML: renderedBody.html,
                    title: mergedContext.title,
                    theme: mergedContext.theme,
                    additionalStyles: contribution.styles,
                    additionalScripts: contribution.scripts,
                    overrideStyles: contribution.overrideStyles,
                    securityPolicy: mergedContext
                )
            }
            return HTMLDocument(
                html: html,
                title: mergedContext.title,
                baseURL: mergedContext.baseURL,
                containsWikiLinks: contribution.containsWikiLinks,
                resources: contribution.resources,
                filteredHTMLFragmentCount: renderedBody.filteredHTMLFragmentCount
            )
        }
    }

    private func merge(context: PipelineContext, frontMatter: FrontMatter?) -> PipelineContext {
        var merged = context
        if merged.title == nil {
            merged.title = frontMatter?.title
        }
        if let rawTheme = frontMatter?.theme?.lowercased(),
           let parsedTheme = PipelineContext.Theme(rawValue: rawTheme) {
            merged.theme = parsedTheme
        }
        if merged.theme == .auto {
            merged.theme = defaultTheme
        }
        return merged
    }

    private static func makePlugins(from features: [HTMLFeature]) -> [any HTMLRenderingPlugin] {
        var includesWikiLinks = false
        var includesMath = false
        var highlightingSubset: [String]?
        var mermaidRendering: PipelineContext.MermaidRendering?
        var customCSS: String?

        for feature in features {
            switch feature.configuration {
            case .wikiLinks:
                includesWikiLinks = true
            case .syntaxHighlighting(let languageSubset):
                highlightingSubset = languageSubset
            case .math:
                includesMath = true
            case .mermaid(let rendering):
                mermaidRendering = rendering
            case .customCSS(let css):
                customCSS = css
            }
        }

        var plugins: [any HTMLRenderingPlugin] = []
        if includesMath {
            plugins.append(MathHTMLPlugin())
        }
        if includesWikiLinks {
            plugins.append(WikiLinkHTMLPlugin())
        }
        if let mermaidRendering {
            plugins.append(MermaidHTMLPlugin(rendering: mermaidRendering))
        }
        if let highlightingSubset {
            plugins.append(SyntaxHighlightingHTMLPlugin(languageSubset: highlightingSubset))
        }
        if let customCSS {
            plugins.append(CustomCSSHTMLPlugin(css: customCSS))
        }
        return plugins
    }
}

enum MarkdownPipelineError: Error {
    case invalidStringEncoding
    case missingResource(String)
}

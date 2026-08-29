import Foundation
import MarkdownPipeline

enum SecurityPreferences {
    static let rendersRawHTMLKey = "security.rendersRawHTML"
    static let loadsRemoteResourcesKey = "security.loadsRemoteResources"
    static let rendersMermaidKey = "security.rendersMermaid"
    static let loadsLocalImagesKey = "security.loadsLocalImages"

    static func registerDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            rendersRawHTMLKey: false,
            loadsRemoteResourcesKey: false,
            rendersMermaidKey: true,
            loadsLocalImagesKey: true,
        ])
    }
}

nonisolated struct RenderingPreferences: Equatable, Sendable {
    var rendersRawHTML: Bool
    var loadsRemoteResources: Bool
    var rendersMermaid: Bool
    var loadsLocalImages: Bool

    init(
        rendersRawHTML: Bool,
        loadsRemoteResources: Bool,
        rendersMermaid: Bool = true,
        loadsLocalImages: Bool = true
    ) {
        self.rendersRawHTML = rendersRawHTML
        self.loadsRemoteResources = loadsRemoteResources
        self.rendersMermaid = rendersMermaid
        self.loadsLocalImages = loadsLocalImages
    }

    static let secureDefaults = RenderingPreferences(
        rendersRawHTML: false,
        loadsRemoteResources: false,
        rendersMermaid: true,
        loadsLocalImages: true
    )

    func pipelineContext(title: String?, mermaidRendering: PipelineContext.MermaidRendering = .rendered) -> PipelineContext {
        PipelineContext(
            title: title,
            mermaidRendering: rendersMermaid ? mermaidRendering : .source,
            rawHTMLPolicy: rendersRawHTML ? .sanitized : .escaped,
            allowsRemoteResources: loadsRemoteResources,
            allowsLocalResources: loadsLocalImages
        )
    }
}

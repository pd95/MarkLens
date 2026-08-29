import Foundation
import MarkdownPipeline

enum SecurityPreferences {
    static let rendersRawHTMLKey = "security.rendersRawHTML"
    static let loadsRemoteResourcesKey = "security.loadsRemoteResources"

    static func registerDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            rendersRawHTMLKey: false,
            loadsRemoteResourcesKey: false,
        ])
    }
}

nonisolated struct RenderingPreferences: Equatable, Sendable {
    var rendersRawHTML: Bool
    var loadsRemoteResources: Bool

    static let secureDefaults = RenderingPreferences(
        rendersRawHTML: false,
        loadsRemoteResources: false
    )

    func pipelineContext(title: String?, mermaidRendering: PipelineContext.MermaidRendering = .rendered) -> PipelineContext {
        PipelineContext(
            title: title,
            mermaidRendering: mermaidRendering,
            rawHTMLPolicy: rendersRawHTML ? .sanitized : .escaped,
            allowsRemoteResources: loadsRemoteResources,
            allowsLocalResources: true
        )
    }
}

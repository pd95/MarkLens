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

nonisolated enum HTMLContentAdjustmentReason: Equatable, Sendable {
    case unsafeContentBlocked
    case renderingDisabled

    var alertTitle: String {
        switch self {
        case .unsafeContentBlocked:
            "Unsafe HTML Blocked"
        case .renderingDisabled:
            "HTML Not Rendered"
        }
    }

    var toolbarIcon: String {
        switch self {
        case .unsafeContentBlocked:
            "exclamationmark.shield.fill"
        case .renderingDisabled:
            "doc.plaintext"
        }
    }

    var toolbarHelp: String {
        switch self {
        case .unsafeContentBlocked:
            "Unsafe HTML was blocked."
        case .renderingDisabled:
            "HTML is being displayed as text because HTML rendering is turned off."
        }
    }

    func accessibilityLabel(fragmentCount: Int) -> String {
        let fragments = fragmentCount == 1 ? "fragment" : "fragments"
        switch self {
        case .unsafeContentBlocked:
            return "Unsafe HTML blocked in \(fragmentCount) \(fragments)"
        case .renderingDisabled:
            return "HTML not rendered in \(fragmentCount) \(fragments)"
        }
    }

    func explanation(fragmentCount: Int) -> String {
        let fragments = fragmentCount == 1 ? "one HTML fragment" : "\(fragmentCount) HTML fragments"
        switch self {
        case .unsafeContentBlocked:
            return "MarkLens blocked unsafe HTML in \(fragments). Unsafe elements or attributes were removed or "
                + "displayed as text. The Markdown source was not changed."
        case .renderingDisabled:
            return "MarkLens displayed HTML from \(fragments) as text because HTML rendering is turned off. "
                + "The Markdown source was not changed."
        }
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

    var htmlContentAdjustmentReason: HTMLContentAdjustmentReason {
        rendersRawHTML ? .unsafeContentBlocked : .renderingDisabled
    }

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

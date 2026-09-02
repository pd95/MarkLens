#if os(macOS)
import MarkdownPipeline
import SwiftUI

struct ReleaseNotesContentView: View {
    let markdown: String
    let contentIdentity: String
    let accessibilityLabel: String

    private static let releaseNotesCSS = """
        html, body {
            background: transparent !important;
        }

        body {
            margin: 0 0.5rem 0.75rem 0;
            font-size: 0.875rem;
        }

        body > h2:first-child {
            margin-top: 0;
        }

        h2 {
            margin: 1.25rem 0 0.4rem;
            padding-bottom: 0.3rem;
            border-bottom: 1px solid var(--separator-light);
            font-size: 1.15rem;
        }

        p, li {
            line-height: 1.5;
        }

        ul, ol {
            margin-block: 0.4rem 0.75rem;
        }

        @media (prefers-color-scheme: dark) {
            h2 {
                border-bottom-color: var(--separator-dark);
            }
        }
        """
    private static let renderingPipeline = MarkdownPipeline(
        plugins: [.customCSS(releaseNotesCSS)]
    )

    var body: some View {
        MarkdownWebView(
            html: renderedReleaseNotes,
            contentIdentity: contentIdentity
        )
        .accessibilityIdentifier("releaseNotesContent")
        .accessibilityLabel(accessibilityLabel)
    }

    private var renderedReleaseNotes: String {
        let context = PipelineContext(
            title: "What’s New in MarkLens",
            rawHTMLPolicy: .escaped,
            allowsRemoteResources: false,
            allowsLocalResources: false
        )
        return (try? Self.renderingPipeline.renderHTML(
            from: .string(markdown),
            context: context
        ).html) ?? "<!doctype html><html><body><p>Release notes are unavailable.</p></body></html>"
    }
}
#endif

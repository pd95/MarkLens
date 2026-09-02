#if os(macOS)
import MarkdownPipeline
import SwiftUI

struct UpdateAvailablePopover: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let release: AvailableRelease
    let installedVersion: String

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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text("MarkLens \(release.displayVersion) is available")
                        .font(.title3.weight(.semibold))

                    Text("You’re currently using MarkLens \(displayInstalledVersion).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)

            Divider()

            Text("What’s New")
                .font(.headline)

            MarkdownWebView(
                html: renderedReleaseNotes,
                contentIdentity: release.releaseNotesContentIdentity(since: installedVersion)
            )
            .accessibilityIdentifier("updateReleaseNotes")
            .accessibilityLabel("Changes since MarkLens \(displayInstalledVersion)")
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                Spacer()

                Button("Not Now") {
                    dismiss()
                }

                Button(primaryActionTitle) {
                    dismiss()
                    openURL(primaryActionURL)
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier(
                    release.downloadURL == nil ? "viewReleaseButton" : "downloadUpdateButton"
                )
            }
        }
        .padding()
        .frame(width: 520, height: 560)
    }

    private var displayInstalledVersion: String {
        installedVersion.first?.lowercased() == "v"
            ? String(installedVersion.dropFirst())
            : installedVersion
    }

    private var primaryActionTitle: String {
        release.downloadURL == nil ? "View on GitHub" : "Download Update"
    }

    private var primaryActionURL: URL {
        release.downloadURL ?? release.htmlURL
    }

    private var renderedReleaseNotes: String {
        let context = PipelineContext(
            title: "What’s New in MarkLens",
            rawHTMLPolicy: .escaped,
            allowsRemoteResources: false,
            allowsLocalResources: false
        )
        return (try? Self.renderingPipeline.renderHTML(
            from: .string(release.releaseNotes(since: installedVersion)),
            context: context
        ).html) ?? "<!doctype html><html><body><p>Release notes are unavailable.</p></body></html>"
    }
}

#Preview("Missed Release Notes") {
    UpdateAvailablePopover(
        release: AvailableRelease(
            tagName: "v1.9.0",
            name: "MarkLens v1.9.0",
            body: "Latest release notes.",
            htmlURL: URL(string: "https://github.com/pd95/MarkLens/releases/tag/v1.9.0")!,
            prerelease: false,
            changelog: """
                # Changelog

                ## 1.9.0

                - Added a polished release-notes view with direct update downloads.
                - Improved rendering performance for large Markdown documents.

                ## 1.8.1

                - Fixed local image refreshes after files are replaced externally.

                ## 1.8.0

                - Added new document navigation controls.
                - Improved keyboard and VoiceOver support throughout the preview.

                ## 1.7.0

                - Changes already installed and intentionally hidden.
                """,
            downloadURL: URL(
                string: "https://github.com/pd95/MarkLens/releases/download/v1.9.0/MarkLens-v1.9.0.zip"
            )!
        ),
        installedVersion: "1.7.0"
    )
}
#endif

#if os(macOS)
import SwiftUI

struct UpdateAvailablePopover: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let release: AvailableRelease
    let installedVersion: String
    let onCheckLater: () -> Void
    let onSkipVersion: () -> Void

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

            ReleaseNotesContentView(
                markdown: release.releaseNotes(since: installedVersion),
                contentIdentity: release.releaseNotesContentIdentity(since: installedVersion),
                accessibilityLabel: "Changes since MarkLens \(displayInstalledVersion)"
            )
            .accessibilityIdentifier("updateReleaseNotes")
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            Text(deferralExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Skip This Version") {
                    onSkipVersion()
                    dismiss()
                }
                .accessibilityIdentifier("skipUpdateVersionButton")
                .accessibilityHint(skipVersionExplanation)
                .help(skipVersionExplanation)

                Spacer()

                Button("Remind Me Later") {
                    onCheckLater()
                    dismiss()
                }
                .accessibilityIdentifier("checkUpdateLaterButton")
                .accessibilityHint(remindLaterExplanation)
                .help(remindLaterExplanation)

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
        .frame(width: 520, height: 590)
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

    private var deferralExplanation: String {
        "“Remind Me Later” shows this release after the next update check. "
            + "Skipping hides it until you check manually or a newer version is found."
    }

    private var remindLaterExplanation: String {
        "Hide this notice until the next successful automatic or manual update check."
    }

    private var skipVersionExplanation: String {
        "Hide MarkLens \(release.displayVersion) during automatic checks until a newer version "
            + "is found. A manual check will show it again."
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
        installedVersion: "1.7.0",
        onCheckLater: {},
        onSkipVersion: {}
    )
}
#endif

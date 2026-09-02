#if os(macOS)
import Combine
import Foundation
import SwiftUI

struct InstalledReleaseNotes: Equatable {
    let releaseTag: String
    let previousReleaseTag: String?
    let markdown: String

    var displayVersion: String {
        Self.displayVersion(for: releaseTag)
    }

    var previousDisplayVersion: String? {
        previousReleaseTag.map(Self.displayVersion)
    }

    var contentIdentity: String {
        "\(releaseTag)\n\(previousReleaseTag ?? "")\n\(markdown)"
    }

    private static func displayVersion(for tag: String) -> String {
        tag.first?.lowercased() == "v" ? String(tag.dropFirst()) : tag
    }
}

@MainActor
final class ReleaseNotesCoordinator: ObservableObject {
    typealias ChangelogLoader = () -> String?

    static let windowID = "installed-release-notes"
    static let lastAcknowledgedReleaseKey = "releaseNotes.lastAcknowledgedRelease"
    static let notesReleaseKey = "releaseNotes.currentRelease"
    static let notesBaselineKey = "releaseNotes.previousRelease"

    @Published private(set) var notes: InstalledReleaseNotes?
    @Published private(set) var shouldPresentAutomatically = false

    private let currentReleaseTag: String?
    private let defaults: UserDefaults
    private var automaticPresentationClaimed = false

    init(
        currentReleaseTag: String = BuildInfo.tagVersion,
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        changelogLoader: @escaping ChangelogLoader = ReleaseNotesCoordinator.loadBundledChangelog
    ) {
        #if DEBUG
        let requestedReleaseTag = environment["MARKLENS_MOCK_INSTALLED_RELEASE_VERSION"]
            ?? currentReleaseTag
        let mockedPreviousReleaseTag = environment["MARKLENS_MOCK_PREVIOUS_INSTALLED_VERSION"]
        let forcesAutomaticPresentation = environment["MARKLENS_FORCE_WHATS_NEW"] == "1"
        #else
        let requestedReleaseTag = currentReleaseTag
        let mockedPreviousReleaseTag: String? = nil
        let forcesAutomaticPresentation = false
        #endif

        self.defaults = defaults
        guard ReleaseVersion(requestedReleaseTag) != nil else {
            self.currentReleaseTag = nil
            notes = nil
            return
        }
        self.currentReleaseTag = requestedReleaseTag

        let changelog = changelogLoader()
        let acknowledgedTag = mockedPreviousReleaseTag
            ?? (forcesAutomaticPresentation
                ? nil
                : defaults.string(forKey: Self.lastAcknowledgedReleaseKey))
        let acknowledgedVersion = acknowledgedTag.flatMap(ReleaseVersion.init)
        let currentVersion = ReleaseVersion(requestedReleaseTag)!

        if let acknowledgedTag,
           let acknowledgedVersion,
           acknowledgedVersion > currentVersion {
            defaults.set(requestedReleaseTag, forKey: Self.lastAcknowledgedReleaseKey)
            defaults.set(requestedReleaseTag, forKey: Self.notesReleaseKey)
            defaults.removeObject(forKey: Self.notesBaselineKey)
            notes = Self.makeNotes(
                changelog: changelog,
                releaseTag: requestedReleaseTag,
                previousReleaseTag: nil
            )
            return
        }

        if let acknowledgedTag,
           let acknowledgedVersion,
           acknowledgedVersion == currentVersion {
            let storedNotesRelease = defaults.string(forKey: Self.notesReleaseKey)
            let storedBaseline = defaults.string(forKey: Self.notesBaselineKey)
            let baseline = storedNotesRelease == requestedReleaseTag ? storedBaseline : nil
            notes = Self.makeNotes(
                changelog: changelog,
                releaseTag: requestedReleaseTag,
                previousReleaseTag: baseline
            )
            return
        }

        let previousReleaseTag: String?
        if let acknowledgedTag, acknowledgedVersion != nil {
            previousReleaseTag = acknowledgedTag
        } else {
            previousReleaseTag = nil
        }
        defaults.set(requestedReleaseTag, forKey: Self.notesReleaseKey)
        if let previousReleaseTag {
            defaults.set(previousReleaseTag, forKey: Self.notesBaselineKey)
        } else {
            defaults.removeObject(forKey: Self.notesBaselineKey)
        }
        notes = Self.makeNotes(
            changelog: changelog,
            releaseTag: requestedReleaseTag,
            previousReleaseTag: previousReleaseTag
        )
        shouldPresentAutomatically = true
    }

    func claimAutomaticPresentation() -> Bool {
        guard shouldPresentAutomatically,
              automaticPresentationClaimed == false,
              notes != nil else {
            return false
        }
        acknowledgeCurrentRelease()
        automaticPresentationClaimed = true
        shouldPresentAutomatically = false
        return true
    }

    func acknowledgeCurrentRelease() {
        guard let currentReleaseTag else {
            return
        }
        defaults.set(currentReleaseTag, forKey: Self.lastAcknowledgedReleaseKey)
        shouldPresentAutomatically = false
    }

    nonisolated static func loadBundledChangelog() -> String? {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static func makeNotes(
        changelog: String?,
        releaseTag: String,
        previousReleaseTag: String?
    ) -> InstalledReleaseNotes {
        let selectedMarkdown: String?
        if let changelog, let previousReleaseTag {
            selectedMarkdown = ReleaseChangelog.missedChanges(
                in: changelog,
                installedVersion: previousReleaseTag,
                releaseTag: releaseTag
            ) ?? ReleaseChangelog.changes(in: changelog, for: releaseTag)
        } else if let changelog {
            selectedMarkdown = ReleaseChangelog.changes(in: changelog, for: releaseTag)
        } else {
            selectedMarkdown = nil
        }

        return InstalledReleaseNotes(
            releaseTag: releaseTag,
            previousReleaseTag: previousReleaseTag,
            markdown: selectedMarkdown ?? "Release notes are unavailable."
        )
    }

}

struct InstalledReleaseNotesView: View {
    @Environment(\.dismissWindow) private var dismissWindow

    let notes: InstalledReleaseNotes

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text("What’s New in MarkLens \(notes.displayVersion)")
                        .font(.title2.weight(.semibold))

                    if let previousVersion = notes.previousDisplayVersion {
                        Text("Updated from MarkLens \(previousVersion)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            ReleaseNotesContentView(
                markdown: notes.markdown,
                contentIdentity: notes.contentIdentity,
                accessibilityLabel: "Changes in MarkLens \(notes.displayVersion)"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                Spacer()
                Button("Done") {
                    dismissWindow(id: ReleaseNotesCoordinator.windowID)
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("releaseNotesDoneButton")
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 520)
    }
}

#Preview("Installed Release Notes") {
    InstalledReleaseNotesView(
        notes: InstalledReleaseNotes(
            releaseTag: "v1.7.0",
            previousReleaseTag: "v1.5.0",
            markdown: """
                ## 1.7.0

                - Added an offline What’s New window for installed releases.
                - Added persistent update reminder and skip choices.

                ## 1.6.0

                - Improved performance for very large Markdown documents.
                """
        )
    )
}
#endif

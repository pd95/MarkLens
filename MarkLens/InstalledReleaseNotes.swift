#if os(macOS)
import AppKit
import Combine
import Foundation
import SwiftUI

nonisolated struct InstalledReleaseNotes: Equatable {
    let releaseTag: String
    let previousReleaseTag: String?
    let markdown: String
    let showsFullChangelog: Bool

    init(
        releaseTag: String,
        previousReleaseTag: String?,
        markdown: String,
        showsFullChangelog: Bool = false
    ) {
        self.releaseTag = releaseTag
        self.previousReleaseTag = previousReleaseTag
        self.markdown = markdown
        self.showsFullChangelog = showsFullChangelog
    }

    var displayVersion: String {
        Self.displayVersion(for: releaseTag)
    }

    var previousDisplayVersion: String? {
        previousReleaseTag.map(Self.displayVersion)
    }

    var contentIdentity: String {
        "\(releaseTag)\n\(previousReleaseTag ?? "")\n\(showsFullChangelog)\n\(markdown)"
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
    private let automaticNotes: InstalledReleaseNotes?
    private let releaseNotes: InstalledReleaseNotes
    private let fullChangelogNotes: InstalledReleaseNotes
    private var automaticPresentationClaimed = false
    private var presentedNotesAcknowledgeCurrentRelease = false

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

        let changelog = changelogLoader()
        let fullChangelogNotes = InstalledReleaseNotes(
            releaseTag: requestedReleaseTag,
            previousReleaseTag: nil,
            markdown: Self.displayedChangelog(changelog),
            showsFullChangelog: true
        )
        let currentMarkdown = changelog.flatMap { changelog in
            if ReleaseVersion(requestedReleaseTag) != nil {
                return ReleaseChangelog.changes(in: changelog, for: requestedReleaseTag)
            }
            return ReleaseChangelog.latestChanges(in: changelog)
        }
        let releaseNotes = InstalledReleaseNotes(
            releaseTag: requestedReleaseTag,
            previousReleaseTag: nil,
            markdown: currentMarkdown ?? "Release notes are unavailable."
        )

        self.defaults = defaults
        self.releaseNotes = releaseNotes
        self.fullChangelogNotes = fullChangelogNotes
        #if DEBUG
        if requestedReleaseTag == "local" {
            self.currentReleaseTag = nil
            automaticNotes = nil
            notes = releaseNotes
            return
        }
        #endif
        guard ReleaseVersion(requestedReleaseTag) != nil else {
            self.currentReleaseTag = nil
            automaticNotes = nil
            notes = releaseNotes
            return
        }
        self.currentReleaseTag = requestedReleaseTag

        let acknowledgedTag = mockedPreviousReleaseTag
            ?? (forcesAutomaticPresentation
                ? nil
                : defaults.string(forKey: Self.lastAcknowledgedReleaseKey))
        let acknowledgedVersion = acknowledgedTag.flatMap(ReleaseVersion.init)
        let currentVersion = ReleaseVersion(requestedReleaseTag)!

        if let acknowledgedVersion,
           acknowledgedVersion > currentVersion {
            defaults.set(requestedReleaseTag, forKey: Self.lastAcknowledgedReleaseKey)
            defaults.set(requestedReleaseTag, forKey: Self.notesReleaseKey)
            defaults.removeObject(forKey: Self.notesBaselineKey)
            let installedNotes = Self.makeNotes(
                changelog: changelog,
                releaseTag: requestedReleaseTag,
                previousReleaseTag: nil
            )
            automaticNotes = installedNotes
            notes = installedNotes
            return
        }

        if let acknowledgedVersion,
           acknowledgedVersion == currentVersion {
            let storedNotesRelease = defaults.string(forKey: Self.notesReleaseKey)
            let storedBaseline = defaults.string(forKey: Self.notesBaselineKey)
            let baseline = storedNotesRelease == requestedReleaseTag ? storedBaseline : nil
            let installedNotes = Self.makeNotes(
                changelog: changelog,
                releaseTag: requestedReleaseTag,
                previousReleaseTag: baseline
            )
            automaticNotes = installedNotes
            notes = installedNotes
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
        let installedNotes = Self.makeNotes(
            changelog: changelog,
            releaseTag: requestedReleaseTag,
            previousReleaseTag: previousReleaseTag
        )
        automaticNotes = installedNotes
        notes = installedNotes
        shouldPresentAutomatically = true
    }

    func claimAutomaticPresentation() -> Bool {
        guard shouldPresentAutomatically,
              automaticPresentationClaimed == false,
              let automaticNotes else {
            return false
        }
        automaticPresentationClaimed = true
        shouldPresentAutomatically = false
        notes = automaticNotes
        presentedNotesAcknowledgeCurrentRelease = true
        return true
    }

    func presentFullChangelog() {
        notes = fullChangelogNotes
        presentedNotesAcknowledgeCurrentRelease = false
    }

    func presentReleaseNotes() {
        notes = releaseNotes
        presentedNotesAcknowledgeCurrentRelease = false
    }

    func acknowledgeCurrentRelease() {
        guard presentedNotesAcknowledgeCurrentRelease,
              let currentReleaseTag else {
            return
        }
        presentedNotesAcknowledgeCurrentRelease = false
        defaults.set(currentReleaseTag, forKey: Self.lastAcknowledgedReleaseKey)
        shouldPresentAutomatically = false
    }

    nonisolated static func loadBundledChangelog() -> String? {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static func displayedChangelog(_ changelog: String?) -> String {
        guard let changelog else { return "Release notes are unavailable." }
        var lines = changelog.components(separatedBy: .newlines)
        if lines.first == "# Changelog" {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
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
    let notes: InstalledReleaseNotes
    let showFullChangelog: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ReleaseNotesContentView(
                markdown: notes.markdown,
                contentIdentity: notes.contentIdentity,
                accessibilityLabel: releaseNotesAccessibilityLabel
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if notes.showsFullChangelog == false {
                HStack {
                    Button("View Full Changelog", action: showFullChangelog)
                        .buttonStyle(.link)
                        .accessibilityIdentifier("viewFullChangelogButton")
                    Spacer()
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 16)
            }
        }
        .background(ReleaseNotesWindowAppearance().frame(width: 0, height: 0))
        .frame(minWidth: 520, minHeight: 520)
    }

    private var releaseNotesAccessibilityLabel: String {
        if notes.showsFullChangelog {
            return "Complete MarkLens development changelog"
        }
        if let previousVersion = notes.previousDisplayVersion {
            return "Changes since MarkLens \(previousVersion)"
        }
        return "Changes in MarkLens \(notes.displayVersion)"
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
        ),
        showFullChangelog: {}
    )
}

private struct ReleaseNotesWindowAppearance: NSViewRepresentable {
    func makeNSView(context: Context) -> ReleaseNotesWindowAppearanceView {
        ReleaseNotesWindowAppearanceView(frame: .zero)
    }

    func updateNSView(_ view: ReleaseNotesWindowAppearanceView, context: Context) {
        view.configureWindow()
    }
}

private final class ReleaseNotesWindowAppearanceView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindow()
    }

    func configureWindow() {
        guard let window else { return }
        if window.styleMask.contains(.fullSizeContentView) == false {
            window.styleMask.insert(.fullSizeContentView)
        }
        if window.titlebarAppearsTransparent == false {
            window.titlebarAppearsTransparent = true
        }
        if window.titlebarSeparatorStyle != .none {
            window.titlebarSeparatorStyle = .none
        }
    }
}
#endif

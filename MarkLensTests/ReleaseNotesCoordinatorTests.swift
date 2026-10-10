#if os(macOS)
import XCTest
@testable import MarkLens

@MainActor
final class ReleaseNotesCoordinatorTests: XCTestCase {
    func testMissingMarkerShowsOnlyCurrentReleaseOnce() throws {
        let defaults = makeDefaults()
        let coordinator = makeCoordinator(current: "v1.3.0", defaults: defaults)

        XCTAssertTrue(coordinator.shouldPresentAutomatically)
        XCTAssertNil(coordinator.notes?.previousReleaseTag)
        let markdown = try XCTUnwrap(coordinator.notes?.markdown)
        XCTAssertTrue(markdown.contains("Current changes"))
        XCTAssertFalse(markdown.contains("Intermediate changes"))
        XCTAssertFalse(markdown.contains("Old changes"))

        XCTAssertTrue(coordinator.claimAutomaticPresentation())
        XCTAssertFalse(coordinator.claimAutomaticPresentation())
        XCTAssertNil(
            defaults.string(forKey: ReleaseNotesCoordinator.lastAcknowledgedReleaseKey),
            "Claiming presentation must not acknowledge a window that has not appeared."
        )

        let beforeWindowAppears = makeCoordinator(current: "v1.3.0", defaults: defaults)
        XCTAssertTrue(beforeWindowAppears.shouldPresentAutomatically)

        coordinator.acknowledgeCurrentRelease()
        XCTAssertEqual(
            defaults.string(forKey: ReleaseNotesCoordinator.lastAcknowledgedReleaseKey),
            "v1.3.0"
        )

        let restored = makeCoordinator(current: "v1.3.0", defaults: defaults)
        XCTAssertFalse(restored.shouldPresentAutomatically)
    }

    func testUpgradeShowsEveryChangeAfterPreviousRelease() throws {
        let defaults = makeDefaults()
        defaults.set("v1.1.0", forKey: ReleaseNotesCoordinator.lastAcknowledgedReleaseKey)

        let coordinator = makeCoordinator(current: "v1.3.0", defaults: defaults)

        XCTAssertTrue(coordinator.shouldPresentAutomatically)
        XCTAssertEqual(coordinator.notes?.previousReleaseTag, "v1.1.0")
        let markdown = try XCTUnwrap(coordinator.notes?.markdown)
        XCTAssertTrue(markdown.contains("Current changes"))
        XCTAssertTrue(markdown.contains("Intermediate changes"))
        XCTAssertFalse(markdown.contains("Old changes"))
    }

    func testHelpPresentationUsesCurrentReleaseWithoutAcknowledgingUpgrade() throws {
        let defaults = makeDefaults()
        defaults.set("v1.1.0", forKey: ReleaseNotesCoordinator.lastAcknowledgedReleaseKey)
        let coordinator = makeCoordinator(current: "v1.3.0", defaults: defaults)

        coordinator.presentReleaseNotes()

        XCTAssertFalse(coordinator.notes?.showsFullChangelog == true)
        XCTAssertNil(coordinator.notes?.previousReleaseTag)
        let releaseNotes = try XCTUnwrap(coordinator.notes?.markdown)
        XCTAssertTrue(releaseNotes.contains("Current changes"))
        XCTAssertFalse(releaseNotes.contains("Intermediate changes"))
        XCTAssertFalse(releaseNotes.contains("Old changes"))
        coordinator.acknowledgeCurrentRelease()
        XCTAssertEqual(
            defaults.string(forKey: ReleaseNotesCoordinator.lastAcknowledgedReleaseKey),
            "v1.1.0",
            "Opening release notes from Help must not acknowledge pending upgrade notes."
        )

        coordinator.presentFullChangelog()
        XCTAssertTrue(coordinator.notes?.showsFullChangelog == true)
        let fullChangelog = try XCTUnwrap(coordinator.notes?.markdown)
        XCTAssertTrue(fullChangelog.contains("Current changes"))
        XCTAssertTrue(fullChangelog.contains("Intermediate changes"))
        XCTAssertTrue(fullChangelog.contains("Old changes"))

        XCTAssertTrue(coordinator.claimAutomaticPresentation())
        XCTAssertFalse(coordinator.notes?.showsFullChangelog == true)
        XCTAssertEqual(coordinator.notes?.previousReleaseTag, "v1.1.0")
        let markdown = try XCTUnwrap(coordinator.notes?.markdown)
        XCTAssertTrue(markdown.contains("Current changes"))
        XCTAssertTrue(markdown.contains("Intermediate changes"))
        XCTAssertFalse(markdown.contains("Old changes"))
    }

    func testPrereleaseTagChangeCountsAsUpgradeButBuildNumberDoesNot() {
        let defaults = makeDefaults()
        defaults.set("v1.3.0-rc1", forKey: ReleaseNotesCoordinator.lastAcknowledgedReleaseKey)

        let releaseCandidate = makeCoordinator(current: "v1.3.0-rc2", defaults: defaults)
        XCTAssertTrue(releaseCandidate.shouldPresentAutomatically)
        XCTAssertEqual(releaseCandidate.notes?.previousReleaseTag, "v1.3.0-rc1")
        XCTAssertTrue(releaseCandidate.claimAutomaticPresentation())
        releaseCandidate.acknowledgeCurrentRelease()

        let sameTagRebuild = makeCoordinator(current: "v1.3.0-rc2", defaults: defaults)
        XCTAssertFalse(sameTagRebuild.shouldPresentAutomatically)
    }

    func testDowngradeResetsBaselineWithoutAutomaticPresentation() {
        let defaults = makeDefaults()
        defaults.set("v1.3.0", forKey: ReleaseNotesCoordinator.lastAcknowledgedReleaseKey)

        let coordinator = makeCoordinator(current: "v1.2.0", defaults: defaults)

        XCTAssertFalse(coordinator.shouldPresentAutomatically)
        XCTAssertNil(coordinator.notes?.previousReleaseTag)
        XCTAssertEqual(
            defaults.string(forKey: ReleaseNotesCoordinator.lastAcknowledgedReleaseKey),
            "v1.2.0"
        )
    }

    func testMalformedMarkerIsRepairedAfterCurrentNotesAreShown() {
        let defaults = makeDefaults()
        defaults.set("not-a-version", forKey: ReleaseNotesCoordinator.lastAcknowledgedReleaseKey)
        let coordinator = makeCoordinator(current: "v1.3.0", defaults: defaults)

        XCTAssertTrue(coordinator.shouldPresentAutomatically)
        XCTAssertNil(coordinator.notes?.previousReleaseTag)
        XCTAssertTrue(coordinator.claimAutomaticPresentation())
        XCTAssertEqual(
            defaults.string(forKey: ReleaseNotesCoordinator.lastAcknowledgedReleaseKey),
            "not-a-version"
        )
        coordinator.acknowledgeCurrentRelease()
        XCTAssertEqual(
            defaults.string(forKey: ReleaseNotesCoordinator.lastAcknowledgedReleaseKey),
            "v1.3.0"
        )
    }

    func testMissingChangelogUsesOfflineFallback() {
        let coordinator = ReleaseNotesCoordinator(
            currentReleaseTag: "v1.3.0",
            defaults: makeDefaults(),
            environment: [:],
            changelogLoader: { nil }
        )

        XCTAssertEqual(coordinator.notes?.markdown, "Release notes are unavailable.")
        XCTAssertTrue(coordinator.shouldPresentAutomatically)
    }

    func testBundledChangelogCanBeLoadedFromAppBundle() throws {
        let changelog = try XCTUnwrap(ReleaseNotesCoordinator.loadBundledChangelog())

        XCTAssertTrue(changelog.contains("# Changelog"))
        XCTAssertTrue(changelog.contains("## 1.8.1"))
    }

    func testLocalDevelopmentBuildShowsLatestReleaseNotesWithoutPresentingAutomatically() {
        let coordinator = ReleaseNotesCoordinator(
            currentReleaseTag: "local",
            defaults: makeDefaults(),
            environment: [:],
            changelogLoader: { Self.changelog }
        )

        XCTAssertTrue(coordinator.notes?.markdown.contains("Current changes") == true)
        XCTAssertFalse(coordinator.notes?.markdown.contains("Intermediate changes") == true)
        XCTAssertFalse(coordinator.notes?.showsFullChangelog == true)
        XCTAssertNil(coordinator.notes?.previousReleaseTag)
        XCTAssertFalse(coordinator.shouldPresentAutomatically)
        XCTAssertFalse(coordinator.claimAutomaticPresentation())

        coordinator.presentFullChangelog()
        XCTAssertTrue(coordinator.notes?.showsFullChangelog == true)
        XCTAssertTrue(coordinator.notes?.markdown.contains("Old changes") == true)
    }

    func testPatchReleaseNotesIncludeMinorReleaseAndEarlierPatches() throws {
        let changelog = """
            ## 1.10.0
            - Future minor.
            ## 1.9.3
            - Future patch.
            ## 1.9.2
            - Current patch.
            ## 1.9.1
            - Earlier patch.
            ## 1.9.0
            - Minor release features.
            ## 1.8.9
            - Previous minor.
            ## 0.9.0
            - Previous major.
            """
        for tag in ["v1.9.2", "v1.9.2-rc1"] {
            let defaults = makeDefaults()
            defaults.set("v1.9.1", forKey: ReleaseNotesCoordinator.lastAcknowledgedReleaseKey)
            let coordinator = ReleaseNotesCoordinator(
                currentReleaseTag: tag,
                defaults: defaults,
                environment: [:],
                changelogLoader: { changelog }
            )
            for presentsHelp in [false, true] {
                if presentsHelp { coordinator.presentReleaseNotes() }
                let markdown = try XCTUnwrap(coordinator.notes?.markdown)
                XCTAssertTrue(markdown.contains("Current patch"))
                XCTAssertTrue(markdown.contains("Earlier patch"))
                XCTAssertTrue(markdown.contains("Minor release features"))
                XCTAssertFalse(markdown.contains("Future"))
                XCTAssertFalse(markdown.contains("Previous"))
            }
        }
    }

    func testLocalDevelopmentNotesIncludeLatestMinorReleaseSeries() throws {
        let coordinator = ReleaseNotesCoordinator(
            currentReleaseTag: "local",
            defaults: makeDefaults(),
            environment: [:],
            changelogLoader: { """
                ## 1.9.1
                - Patch changes.
                ## 1.9.0
                - Minor features.
                ## 1.8.1
                - Older changes.
                """ }
        )
        let markdown = try XCTUnwrap(coordinator.notes?.markdown)
        XCTAssertTrue(markdown.contains("Patch changes"))
        XCTAssertTrue(markdown.contains("Minor features"))
        XCTAssertFalse(markdown.contains("Older changes"))
    }

    func testUpgradeToPatchIncludesMissedPreviousMinorChangesWhileHelpShowsCurrentMinor() throws {
        let defaults = makeDefaults()
        defaults.set("v1.8.0", forKey: ReleaseNotesCoordinator.lastAcknowledgedReleaseKey)
        let coordinator = ReleaseNotesCoordinator(
            currentReleaseTag: "v1.9.1",
            defaults: defaults,
            environment: [:],
            changelogLoader: { """
                ## 1.9.1
                - Current patch.
                ## 1.9.0
                - Current minor features.
                ## 1.8.1
                - Missed previous minor patch.
                ## 1.8.0
                - Already installed.
                """ }
        )

        XCTAssertTrue(coordinator.claimAutomaticPresentation())
        XCTAssertEqual(coordinator.notes?.previousReleaseTag, "v1.8.0")
        let automaticNotes = try XCTUnwrap(coordinator.notes?.markdown)
        XCTAssertTrue(automaticNotes.contains("## 1.9.1"))
        XCTAssertTrue(automaticNotes.contains("## 1.9.0"))
        XCTAssertTrue(automaticNotes.contains("## 1.8.1"))
        XCTAssertFalse(automaticNotes.contains("## 1.8.0"))

        coordinator.acknowledgeCurrentRelease()
        coordinator.presentReleaseNotes()
        XCTAssertNil(coordinator.notes?.previousReleaseTag)
        let helpNotes = try XCTUnwrap(coordinator.notes?.markdown)
        XCTAssertTrue(helpNotes.contains("## 1.9.1"))
        XCTAssertTrue(helpNotes.contains("## 1.9.0"))
        XCTAssertFalse(helpNotes.contains("## 1.8.1"))
        XCTAssertFalse(helpNotes.contains("## 1.8.0"))
    }

    private func makeCoordinator(
        current: String,
        defaults: UserDefaults
    ) -> ReleaseNotesCoordinator {
        ReleaseNotesCoordinator(
            currentReleaseTag: current,
            defaults: defaults,
            environment: [:],
            changelogLoader: { Self.changelog }
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "ReleaseNotesCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private static let changelog = """
        # Changelog

        ## 1.3.0

        - Current changes.

        ## 1.2.0

        - Intermediate changes.

        ## 1.1.0

        - Old changes.
        """
}
#endif

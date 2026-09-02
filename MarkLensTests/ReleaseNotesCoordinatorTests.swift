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

    func testHelpReopenRetainsTheOriginalUpgradeRange() throws {
        let defaults = makeDefaults()
        defaults.set("v1.1.0", forKey: ReleaseNotesCoordinator.lastAcknowledgedReleaseKey)
        let first = makeCoordinator(current: "v1.3.0", defaults: defaults)
        XCTAssertTrue(first.claimAutomaticPresentation())
        first.acknowledgeCurrentRelease()

        let restored = makeCoordinator(current: "v1.3.0", defaults: defaults)

        XCTAssertFalse(restored.shouldPresentAutomatically)
        XCTAssertEqual(restored.notes?.previousReleaseTag, "v1.1.0")
        let markdown = try XCTUnwrap(restored.notes?.markdown)
        XCTAssertTrue(markdown.contains("Current changes"))
        XCTAssertTrue(markdown.contains("Intermediate changes"))
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
        XCTAssertTrue(changelog.contains("## 1.8.0"))
    }

    func testLocalDevelopmentBuildDoesNotPresentAutomatically() {
        let coordinator = ReleaseNotesCoordinator(
            currentReleaseTag: "local",
            defaults: makeDefaults(),
            environment: [:],
            changelogLoader: { Self.changelog }
        )

        XCTAssertNil(coordinator.notes)
        XCTAssertFalse(coordinator.shouldPresentAutomatically)
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

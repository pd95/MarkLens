#if os(macOS)
import XCTest
@testable import MarkLens

@MainActor
final class ReleaseChangelogTests: XCTestCase {
    func testVersionComparisonUsesNumericComponentsAndPrereleaseOrdering() throws {
        XCTAssertLessThan(try version("v1.9.0"), try version("1.10.0"))
        XCTAssertEqual(try version("1.2"), try version("1.2.0"))
        XCTAssertLessThan(try version("1.2.0-rc1"), try version("1.2.0"))
        XCTAssertLessThan(try version("1.2.0-rc2"), try version("1.2.0-rc10"))
        XCTAssertLessThan(try version("1.2.0-rc.2"), try version("1.2.0-rc.10"))
        XCTAssertNil(ReleaseVersion("local"))
        XCTAssertNil(ReleaseVersion("1.two.0"))
    }

    func testMissedChangesIncludeOnlyVersionsAfterInstalledThroughTarget() throws {
        let changelog = """
            # Changelog

            ## 2.0.0

            - Not part of the detected release.

            ## 1.3.0

            - Newest available change.

            ## 1.2.1

            - Intermediate patch.

            ## 1.2.0

            - Already installed.

            ## Notes

            This unversioned section must not leak into another release.
            """

        let notes = try XCTUnwrap(
            ReleaseChangelog.missedChanges(
                in: changelog,
                installedVersion: "1.2.0",
                releaseTag: "v1.3.0"
            ))

        XCTAssertTrue(notes.contains("## 1.3.0"))
        XCTAssertTrue(notes.contains("## 1.2.1"))
        XCTAssertFalse(notes.contains("## 2.0.0"))
        XCTAssertFalse(notes.contains("## 1.2.0"))
        XCTAssertFalse(notes.contains("unversioned"))
    }

    func testMissedChangesUseBaseVersionForPrereleaseAndAcceptBracketedHeadings() throws {
        let changelog = """
            ## [1.5.0]

            - Preview changes.

            ## 1.4.0

            - Installed changes.
            """

        let notes = try XCTUnwrap(
            ReleaseChangelog.missedChanges(
                in: changelog,
                installedVersion: "1.4.0",
                releaseTag: "v1.5.0-rc1"
            ))

        XCTAssertTrue(notes.contains("Preview changes"))
        XCTAssertFalse(notes.contains("Installed changes"))
    }

    func testChangesForReleaseReturnsOnlyExactBaseVersion() throws {
        let changelog = """
            ## 1.3.0

            - Current changes.

            ## 1.2.0

            - Older changes.
            """

        let notes = try XCTUnwrap(
            ReleaseChangelog.changes(in: changelog, for: "v1.3.0-rc1")
        )

        XCTAssertTrue(notes.contains("Current changes"))
        XCTAssertFalse(notes.contains("Older changes"))
    }

    func testChangesForReleaseRecognizesUnreleasedHeading() throws {
        let changelog = """
            ## 1.8.0 (Unreleased)

            - Upcoming changes.

            ## 1.7.0

            - Published changes.
            """

        let notes = try XCTUnwrap(ReleaseChangelog.changes(in: changelog, for: "v1.8.0"))

        XCTAssertTrue(notes.contains("Upcoming changes"))
        XCTAssertFalse(notes.contains("Published changes"))
    }

    private func version(_ value: String) throws -> ReleaseVersion {
        try XCTUnwrap(ReleaseVersion(value))
    }
}
#endif

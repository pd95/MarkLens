#if os(macOS)
import XCTest
@testable import MarkLens

@MainActor
final class UpdateCheckerTests: XCTestCase {
    func testAutomaticChecksCanBeDisabledWithoutDisablingManualChecks() async {
        let defaults = makeDefaults()
        defaults.set(false, forKey: UpdatePreferences.automaticChecksKey)
        var requestCount = 0
        let checker = UpdateChecker(
            currentVersion: "1.0.0",
            releaseTag: "v1.0.0",
            defaults: defaults,
            request: { request in
                if Self.isChangelogRequest(request) {
                    return Self.changelogResponse()
                }
                requestCount += 1
                return UpdateHTTPResponse(
                    data: Self.releaseJSON(tag: "v2.0.0"),
                    statusCode: 200,
                    etag: nil
                )
            }
        )

        await checker.checkIfDue()
        XCTAssertEqual(requestCount, 0)

        let manualCheckSucceeded = await checker.checkNow()
        XCTAssertTrue(manualCheckSucceeded)
        XCTAssertEqual(requestCount, 1)
    }

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

        let notes = try XCTUnwrap(ReleaseChangelog.missedChanges(
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

        let notes = try XCTUnwrap(ReleaseChangelog.missedChanges(
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

    func testNewerStableReleaseBecomesAvailableAndIsCached() async throws {
        let defaults = makeDefaults()
        let checker = UpdateChecker(
            currentVersion: "1.2.0",
            releaseTag: "v1.2.0",
            defaults: defaults,
            request: { request in
                if Self.isChangelogRequest(request) {
                    XCTAssertEqual(
                        request.value(forHTTPHeaderField: "Accept"),
                        "application/vnd.github.raw+json"
                    )
                    XCTAssertEqual(request.url?.query, "ref=v1.3.0")
                    return Self.changelogResponse()
                }
                XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
                return UpdateHTTPResponse(
                    data: Self.releaseJSON(tag: "v1.3.0", body: "Useful improvements."),
                    statusCode: 200,
                    etag: "release-etag"
                )
            }
        )

        await checker.checkIfDue()

        XCTAssertEqual(checker.availableRelease?.displayVersion, "1.3.0")
        XCTAssertEqual(checker.availableRelease?.body, "Useful improvements.")

        let restored = UpdateChecker(
            currentVersion: "1.2.0",
            releaseTag: "v1.2.0",
            defaults: defaults,
            request: { _ in
                XCTFail("Restoring cached state must not make a request")
                throw URLError(.unknown)
            }
        )
        XCTAssertEqual(restored.availableRelease, checker.availableRelease)
    }

    func testUpdateLoadsTaggedChangelogAndTrustedZipAsset() async throws {
        let expectedDownloadURL =
            "https://github.com/pd95/MarkLens/releases/download/v1.3.0/MarkLens-v1.3.0.zip"
        let checker = UpdateChecker(
            currentVersion: "1.1.0",
            releaseTag: "v1.1.0",
            defaults: makeDefaults(),
            request: { request in
                if Self.isChangelogRequest(request) {
                    XCTAssertEqual(request.url?.query, "ref=v1.3.0")
                    return Self.changelogResponse()
                }
                return UpdateHTTPResponse(
                    data: Self.releaseJSON(
                        tag: "v1.3.0",
                        assetName: "MarkLens-v1.3.0.zip",
                        assetURL: expectedDownloadURL
                    ),
                    statusCode: 200,
                    etag: nil
                )
            }
        )

        await checker.checkIfDue()

        let release = try XCTUnwrap(checker.availableRelease)
        XCTAssertEqual(release.downloadURL?.absoluteString, expectedDownloadURL)
        let notes = release.releaseNotes(since: checker.currentVersion)
        XCTAssertTrue(notes.contains("## 1.3.0"))
        XCTAssertTrue(notes.contains("## 1.2.0"))
        XCTAssertFalse(notes.contains("## 1.1.0"))
    }

    func testSupplementalChangelogFailureFallsBackToReleaseBody() async throws {
        let checker = UpdateChecker(
            currentVersion: "1.0.0",
            releaseTag: "v1.0.0",
            defaults: makeDefaults(),
            request: { request in
                if Self.isChangelogRequest(request) {
                    return UpdateHTTPResponse(data: Data(), statusCode: 503, etag: nil)
                }
                return UpdateHTTPResponse(
                    data: Self.releaseJSON(tag: "v1.1.0", body: "Latest release only."),
                    statusCode: 200,
                    etag: nil
                )
            }
        )

        let succeeded = await checker.checkNow()

        XCTAssertTrue(succeeded)
        let release = try XCTUnwrap(checker.availableRelease)
        XCTAssertNil(release.changelog)
        XCTAssertEqual(release.releaseNotes(since: checker.currentVersion), "Latest release only.")
    }

    func testReleaseNotesIdentityChangesWhenCachedReleaseIsEnriched() {
        let bodyOnlyRelease = AvailableRelease(
            tagName: "v1.1.0",
            name: "MarkLens 1.1.0",
            body: "Latest release only.",
            htmlURL: URL(string: "https://github.com/pd95/MarkLens/releases/tag/v1.1.0")!,
            prerelease: false
        )
        let enrichedRelease = bodyOnlyRelease.adding(changelog: """
            ## 1.1.0

            - Complete changes.
            """)

        XCTAssertNotEqual(
            bodyOnlyRelease.releaseNotesContentIdentity(since: "1.0.0"),
            enrichedRelease.releaseNotesContentIdentity(since: "1.0.0")
        )
    }

    func testUntrustedOrUnexpectedZipAssetsAreIgnored() async {
        for (name, url) in [
            (
                "MarkLens-v1.1.0.zip",
                "https://example.com/pd95/MarkLens/releases/download/v1.1.0/MarkLens-v1.1.0.zip"
            ),
            (
                "another-file.zip",
                "https://github.com/pd95/MarkLens/releases/download/v1.1.0/another-file.zip"
            ),
            (
                "MarkLens-v1.1.0.zip",
                "http://github.com/pd95/MarkLens/releases/download/v1.1.0/MarkLens-v1.1.0.zip"
            ),
            (
                "MarkLens-v1.1.0.zip",
                "https://user@github.com/pd95/MarkLens/releases/download/v1.1.0/MarkLens-v1.1.0.zip"
            ),
            (
                "MarkLens-v1.1.0.zip",
                "https://github.com:443/pd95/MarkLens/releases/download/v1.1.0/MarkLens-v1.1.0.zip"
            ),
            (
                "MarkLens-v1.1.0.zip",
                "https://github.com/pd95/MarkLens/releases/download/v1.1.0/MarkLens-v1.1.0.zip?download=1"
            ),
            (
                "MarkLens-v1.1.0.zip",
                "https://github.com/pd95/MarkLens/releases/download/v1.1.0/MarkLens-v1.1.0.zip#fragment"
            ),
            (
                "MarkLens-v1.1.0.zip",
                "https://github.com/pd95/MarkLens/releases/download/v2.0.0/MarkLens-v1.1.0.zip"
            ),
        ] {
            let checker = UpdateChecker(
                currentVersion: "1.0.0",
                releaseTag: "v1.0.0",
                defaults: makeDefaults(),
                request: { request in
                    if Self.isChangelogRequest(request) {
                        return Self.changelogResponse()
                    }
                    return UpdateHTTPResponse(
                        data: Self.releaseJSON(tag: "v1.1.0", assetName: name, assetURL: url),
                        statusCode: 200,
                        etag: nil
                    )
                }
            )

            await checker.checkIfDue()
            XCTAssertNil(checker.availableRelease?.downloadURL)
        }
    }

    func testDownloadSkipsInvalidAssetsBeforeTrustedUploadedZip() async throws {
        let expectedURL =
            "https://github.com/pd95/MarkLens/releases/download/v1.1.0/MarkLens-v1.1.0.zip"
        var release = Self.releaseObject(tag: "v1.1.0")
        release["assets"] = [
            [
                "name": "MarkLens-v1.1.0.zip",
                "browser_download_url": expectedURL,
                "state": "failed",
            ],
            [
                "name": "MarkLens-v1.1.0.zip",
                "browser_download_url": expectedURL,
                "state": "uploaded",
            ],
        ]
        let checker = UpdateChecker(
            currentVersion: "1.0.0",
            releaseTag: "v1.0.0",
            defaults: makeDefaults(),
            request: { request in
                if Self.isChangelogRequest(request) {
                    return Self.changelogResponse()
                }
                return UpdateHTTPResponse(
                    data: try! JSONSerialization.data(withJSONObject: release),
                    statusCode: 200,
                    etag: nil
                )
            }
        )

        let checkSucceeded = await checker.checkNow()

        XCTAssertTrue(checkSucceeded)
        XCTAssertEqual(try XCTUnwrap(checker.availableRelease?.downloadURL).absoluteString, expectedURL)
    }

    func testCheckLaterPersistsAndSameReleaseReturnsAtNextScheduledCheck() async throws {
        let defaults = makeDefaults()
        var currentDate = Date(timeIntervalSince1970: 1_000_000)
        let firstChecker = UpdateChecker(
            currentVersion: "1.0.0",
            releaseTag: "v1.0.0",
            defaults: defaults,
            now: { currentDate },
            request: { request in
                if Self.isChangelogRequest(request) {
                    return Self.changelogResponse()
                }
                return UpdateHTTPResponse(
                    data: Self.releaseJSON(tag: "v1.1.0"),
                    statusCode: 200,
                    etag: "deferred-etag"
                )
            }
        )
        let firstCheckSucceeded = await firstChecker.checkNow()
        XCTAssertTrue(firstCheckSucceeded)

        firstChecker.checkLater()

        XCTAssertNil(firstChecker.availableRelease)
        XCTAssertEqual(firstChecker.activeSuppression?.disposition, .checkLater)

        let restoredChecker = UpdateChecker(
            currentVersion: "1.0.0",
            releaseTag: "v1.0.0",
            defaults: defaults,
            now: { currentDate },
            request: { request in
                XCTAssertFalse(Self.isChangelogRequest(request))
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "If-None-Match"),
                    "deferred-etag"
                )
                return UpdateHTTPResponse(data: Data(), statusCode: 304, etag: nil)
            }
        )
        XCTAssertNil(restoredChecker.availableRelease)

        currentDate.addTimeInterval(8 * 24 * 60 * 60)
        await restoredChecker.checkIfDue()

        XCTAssertEqual(restoredChecker.availableRelease?.tagName, "v1.1.0")
        XCTAssertNil(restoredChecker.suppressedUpdate)
    }

    func testSkippedReleaseWaitsForNewerScheduledRelease() async {
        let defaults = makeDefaults()
        var currentDate = Date(timeIntervalSince1970: 1_000_000)
        var returnedTag = "v1.1.0"
        let checker = UpdateChecker(
            currentVersion: "1.0.0",
            releaseTag: "v1.0.0",
            defaults: defaults,
            now: { currentDate },
            request: { request in
                if Self.isChangelogRequest(request) {
                    return Self.changelogResponse()
                }
                return UpdateHTTPResponse(
                    data: Self.releaseJSON(tag: returnedTag),
                    statusCode: 200,
                    etag: nil
                )
            }
        )
        let firstCheckSucceeded = await checker.checkNow()
        XCTAssertTrue(firstCheckSucceeded)
        checker.skipAvailableVersion()

        currentDate.addTimeInterval(8 * 24 * 60 * 60)
        await checker.checkIfDue()
        XCTAssertNil(checker.availableRelease)
        XCTAssertEqual(checker.activeSuppression?.disposition, .skipVersion)

        returnedTag = "v1.2.0"
        currentDate.addTimeInterval(8 * 24 * 60 * 60)
        await checker.checkIfDue()

        XCTAssertEqual(checker.availableRelease?.tagName, "v1.2.0")
        XCTAssertNil(checker.suppressedUpdate)
    }

    func testManualCheckRevealsSkippedRelease() async {
        var releaseRequestCount = 0
        let checker = UpdateChecker(
            currentVersion: "1.0.0",
            releaseTag: "v1.0.0",
            defaults: makeDefaults(),
            request: { request in
                if Self.isChangelogRequest(request) {
                    return Self.changelogResponse()
                }
                releaseRequestCount += 1
                if releaseRequestCount == 1 {
                    return UpdateHTTPResponse(
                        data: Self.releaseJSON(tag: "v1.1.0"),
                        statusCode: 200,
                        etag: "skipped-etag"
                    )
                }
                return UpdateHTTPResponse(data: Data(), statusCode: 304, etag: nil)
            }
        )
        let firstCheckSucceeded = await checker.checkNow()
        XCTAssertTrue(firstCheckSucceeded)
        checker.skipAvailableVersion()

        let succeeded = await checker.checkNow()

        XCTAssertTrue(succeeded)
        XCTAssertEqual(checker.availableRelease?.tagName, "v1.1.0")
        XCTAssertNil(checker.suppressedUpdate)
    }

    func testFailedCheckRetainsSkippedReleaseSuppression() async {
        var shouldFail = false
        let checker = UpdateChecker(
            currentVersion: "1.0.0",
            releaseTag: "v1.0.0",
            defaults: makeDefaults(),
            request: { request in
                if Self.isChangelogRequest(request) {
                    return Self.changelogResponse()
                }
                if shouldFail {
                    throw URLError(.notConnectedToInternet)
                }
                return UpdateHTTPResponse(
                    data: Self.releaseJSON(tag: "v1.1.0"),
                    statusCode: 200,
                    etag: nil
                )
            }
        )
        let firstCheckSucceeded = await checker.checkNow()
        XCTAssertTrue(firstCheckSucceeded)
        checker.skipAvailableVersion()
        shouldFail = true

        let failedCheckSucceeded = await checker.checkNow()
        XCTAssertFalse(failedCheckSucceeded)
        XCTAssertNil(checker.availableRelease)
        XCTAssertEqual(checker.activeSuppression?.tagName, "v1.1.0")
    }

    func testSuppressionSelectedDuringCheckCannotBeOverwrittenByCompletion() async {
        let defaults = makeDefaults()
        let cachedRelease = AvailableRelease(
            tagName: "v1.1.0",
            name: "MarkLens 1.1.0",
            body: "Release notes",
            htmlURL: URL(string: "https://github.com/pd95/MarkLens/releases/tag/v1.1.0")!,
            prerelease: false
        )
        defaults.set(
            try! JSONEncoder().encode(cachedRelease),
            forKey: "updateChecker.cachedRelease"
        )
        defaults.set(2, forKey: "updateChecker.cacheSchema")
        let requestStarted = TestGate()
        let allowResponse = TestGate()
        let checker = UpdateChecker(
            currentVersion: "1.0.0",
            releaseTag: "v1.0.0",
            defaults: defaults,
            request: { request in
                if Self.isChangelogRequest(request) {
                    return Self.changelogResponse()
                }
                await requestStarted.open()
                await allowResponse.wait()
                return UpdateHTTPResponse(
                    data: Self.releaseJSON(tag: "v1.1.0"),
                    statusCode: 200,
                    etag: nil
                )
            }
        )

        let check = Task { await checker.checkNow() }
        await requestStarted.wait()
        checker.skipAvailableVersion()
        await allowResponse.open()
        let succeeded = await check.value

        XCTAssertTrue(succeeded)
        XCTAssertNil(checker.availableRelease)
        XCTAssertEqual(checker.activeSuppression?.disposition, .skipVersion)
    }

    func testCurrentOrOlderReleaseDoesNotBecomeAvailable() async {
        for tag in ["v1.2.0", "v1.1.9"] {
            let checker = UpdateChecker(
                currentVersion: "1.2.0",
                releaseTag: "v1.2.0",
                defaults: makeDefaults(),
                request: { _ in
                    UpdateHTTPResponse(
                        data: Self.releaseJSON(tag: tag),
                        statusCode: 200,
                        etag: nil
                    )
                }
            )

            await checker.checkIfDue()
            XCTAssertNil(checker.availableRelease)
        }
    }

    func testPrereleaseChannelChoosesNewestEligibleRelease() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: UpdatePreferences.includesPrereleasesKey)
        let checker = UpdateChecker(
            currentVersion: "1.4.0",
            releaseTag: "v1.4.0",
            defaults: defaults,
            request: { request in
                if Self.isChangelogRequest(request) {
                    return Self.changelogResponse()
                }
                XCTAssertEqual(request.url?.path, "/repos/pd95/MarkLens/releases")
                XCTAssertEqual(request.url?.query, "per_page=20")
                return UpdateHTTPResponse(
                    data: Self.releasesJSON([
                        Self.releaseObject(tag: "v1.4.1"),
                        Self.releaseObject(tag: "v1.5.0-rc1", prerelease: true),
                        Self.releaseObject(tag: "v2.0.0-beta1", draft: true, prerelease: true),
                    ]),
                    statusCode: 200,
                    etag: nil
                )
            }
        )

        await checker.checkIfDue()

        XCTAssertEqual(checker.availableRelease?.tagName, "v1.5.0-rc1")
    }

    func testChangingReleaseChannelImmediatelyChecksAgain() async {
        let defaults = makeDefaults()
        var requestedURLs: [URL] = []
        let checker = UpdateChecker(
            currentVersion: "1.4.0",
            releaseTag: "v1.4.0",
            defaults: defaults,
            request: { request in
                if Self.isChangelogRequest(request) {
                    return Self.changelogResponse()
                }
                requestedURLs.append(request.url!)
                if defaults.bool(forKey: UpdatePreferences.includesPrereleasesKey) {
                    return UpdateHTTPResponse(
                        data: Self.releasesJSON([
                            Self.releaseObject(tag: "v1.5.0-rc1", prerelease: true)
                        ]),
                        statusCode: 200,
                        etag: nil
                    )
                }
                return UpdateHTTPResponse(
                    data: Self.releaseJSON(tag: "v1.4.1"),
                    statusCode: 200,
                    etag: "stable-etag"
                )
            }
        )

        await checker.checkIfDue()
        defaults.set(true, forKey: UpdatePreferences.includesPrereleasesKey)
        _ = await checker.releaseChannelDidChange()

        XCTAssertEqual(requestedURLs.count, 2)
        XCTAssertEqual(requestedURLs.last?.path, "/repos/pd95/MarkLens/releases")
        XCTAssertEqual(checker.availableRelease?.tagName, "v1.5.0-rc1")
    }

    func testChannelRefreshFailureRetainsAnEligibleKnownRelease() async {
        let defaults = makeDefaults()
        var requestCount = 0
        let checker = UpdateChecker(
            currentVersion: "1.0.0",
            releaseTag: "v1.0.0",
            defaults: defaults,
            request: { _ in
                requestCount += 1
                if requestCount == 2 {
                    throw URLError(.notConnectedToInternet)
                }
                return UpdateHTTPResponse(
                    data: Self.releaseJSON(tag: "v1.1.0"),
                    statusCode: 200,
                    etag: nil
                )
            }
        )

        await checker.checkIfDue()
        defaults.set(true, forKey: UpdatePreferences.includesPrereleasesKey)
        let succeeded = await checker.releaseChannelDidChange()

        XCTAssertFalse(succeeded)
        XCTAssertTrue(checker.lastCheckFailed)
        XCTAssertEqual(checker.availableRelease?.tagName, "v1.1.0")
        XCTAssertNil(checker.lastSuccessfulCheck)
    }

    func testStableChannelUsesGitHubPrereleaseFlagInsteadOfTagShape() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: UpdatePreferences.includesPrereleasesKey)
        let checker = UpdateChecker(
            currentVersion: "1.0.0",
            releaseTag: "v1.0.0",
            defaults: defaults,
            request: { _ in
                UpdateHTTPResponse(
                    data: Self.releasesJSON([
                        Self.releaseObject(tag: "v2.0.0", prerelease: true)
                    ]),
                    statusCode: 200,
                    etag: nil
                )
            }
        )

        await checker.checkIfDue()
        XCTAssertEqual(checker.availableRelease?.tagName, "v2.0.0")

        defaults.set(false, forKey: UpdatePreferences.includesPrereleasesKey)
        _ = await checker.releaseChannelDidChange()

        XCTAssertNil(checker.availableRelease)
    }

    func testLegacyCachedReleaseInfersPrereleaseFromTag() throws {
        let legacyJSON = Data(
            #"{"tagName":"v1.5.0-rc1","name":null,"body":"","htmlURL":"https:\/\/github.com\/pd95\/MarkLens\/releases\/tag\/v1.5.0-rc1"}"#.utf8
        )

        let release = try JSONDecoder().decode(AvailableRelease.self, from: legacyJSON)

        XCTAssertTrue(release.prerelease)
    }

    func testCacheMigrationInvalidatesTheReleaseETagOnlyOnce() {
        let defaults = makeDefaults()
        defaults.set("legacy-etag", forKey: "updateChecker.etag")

        _ = UpdateChecker(
            currentVersion: "1.0.0",
            releaseTag: "v1.0.0",
            defaults: defaults
        )
        XCTAssertNil(defaults.string(forKey: "updateChecker.etag"))

        defaults.set("current-etag", forKey: "updateChecker.etag")
        _ = UpdateChecker(
            currentVersion: "1.0.0",
            releaseTag: "v1.0.0",
            defaults: defaults
        )
        XCTAssertEqual(defaults.string(forKey: "updateChecker.etag"), "current-etag")
    }

    func testCachedChangelogIsRefilteredForTheInstalledVersion() throws {
        let release = AvailableRelease(
            tagName: "v1.3.0",
            name: "MarkLens v1.3.0",
            body: "Latest release only.",
            htmlURL: URL(string: "https://github.com/pd95/MarkLens/releases/tag/v1.3.0")!,
            prerelease: false,
            changelog: String(data: Self.changelogResponse().data, encoding: .utf8)
        )

        let notesFromVersionOne = release.releaseNotes(since: "1.1.0")
        let notesFromVersionTwo = release.releaseNotes(since: "1.2.0")

        XCTAssertTrue(notesFromVersionOne.contains("## 1.2.0"))
        XCTAssertFalse(notesFromVersionTwo.contains("## 1.2.0"))
        XCTAssertTrue(notesFromVersionTwo.contains("## 1.3.0"))
    }

    func testChecksAreThrottledForSevenDays() async {
        let defaults = makeDefaults()
        var currentDate = Date(timeIntervalSince1970: 1_000_000)
        var requestCount = 0
        let checker = UpdateChecker(
            currentVersion: "1.0.0",
            releaseTag: "v1.0.0",
            defaults: defaults,
            now: { currentDate },
            request: { request in
                if Self.isChangelogRequest(request) {
                    return Self.changelogResponse()
                }
                requestCount += 1
                return UpdateHTTPResponse(
                    data: Self.releaseJSON(tag: "v1.1.0"),
                    statusCode: 200,
                    etag: nil
                )
            }
        )

        await checker.checkIfDue()
        currentDate.addTimeInterval(6 * 24 * 60 * 60)
        await checker.checkIfDue()
        XCTAssertEqual(requestCount, 1)

        currentDate.addTimeInterval(2 * 24 * 60 * 60)
        await checker.checkIfDue()
        XCTAssertEqual(requestCount, 2)
    }

    func testManualCheckBypassesThrottleAndReportsFailure() async {
        var requestCount = 0
        var currentDate = Date(timeIntervalSince1970: 1_000_000)
        let defaults = makeDefaults()
        let checker = UpdateChecker(
            currentVersion: "1.0.0",
            releaseTag: "v1.0.0",
            defaults: defaults,
            now: { currentDate },
            request: { request in
                if Self.isChangelogRequest(request) {
                    return Self.changelogResponse()
                }
                requestCount += 1
                if requestCount == 2 {
                    throw URLError(.notConnectedToInternet)
                }
                return UpdateHTTPResponse(
                    data: Self.releaseJSON(tag: "v1.1.0"),
                    statusCode: 200,
                    etag: nil
                )
            }
        )

        await checker.checkIfDue()
        let successfulCheckDate = checker.lastSuccessfulCheck
        XCTAssertEqual(successfulCheckDate, currentDate)
        currentDate.addTimeInterval(60)
        let succeeded = await checker.checkNow()

        XCTAssertEqual(requestCount, 2)
        XCTAssertFalse(succeeded)
        XCTAssertEqual(checker.lastSuccessfulCheck, successfulCheckDate)
        XCTAssertTrue(checker.lastCheckFailed)
        XCTAssertEqual(checker.availableRelease?.tagName, "v1.1.0")

        let restored = UpdateChecker(
            currentVersion: "1.0.0",
            releaseTag: "v1.0.0",
            defaults: defaults
        )
        XCTAssertEqual(restored.lastSuccessfulCheck, successfulCheckDate)
    }

    func testETagIsSentAndNotModifiedKeepsCachedRelease() async {
        let defaults = makeDefaults()
        var requestCount = 0
        var currentDate = Date(timeIntervalSince1970: 1_000_000)
        let checker = UpdateChecker(
            currentVersion: "1.0.0",
            releaseTag: "v1.0.0",
            defaults: defaults,
            now: { currentDate },
            request: { request in
                if Self.isChangelogRequest(request) {
                    return Self.changelogResponse()
                }
                requestCount += 1
                if requestCount == 1 {
                    return UpdateHTTPResponse(
                        data: Self.releaseJSON(tag: "v1.1.0"),
                        statusCode: 200,
                        etag: "cached-etag"
                    )
                }
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "If-None-Match"),
                    "cached-etag"
                )
                return UpdateHTTPResponse(
                    data: Data(),
                    statusCode: 304,
                    etag: nil
                )
            }
        )

        await checker.checkIfDue()
        currentDate.addTimeInterval(8 * 24 * 60 * 60)
        await checker.checkIfDue()

        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(checker.availableRelease?.tagName, "v1.1.0")
    }

    func testNotModifiedResponseEnrichesLegacyCachedRelease() async throws {
        let defaults = makeDefaults()
        defaults.set(2, forKey: "updateChecker.cacheSchema")
        defaults.set("cached-etag", forKey: "updateChecker.etag")
        let cachedRelease = AvailableRelease(
            tagName: "v1.1.0",
            name: "MarkLens 1.1.0",
            body: "Latest release only.",
            htmlURL: URL(string: "https://github.com/pd95/MarkLens/releases/tag/v1.1.0")!,
            prerelease: false
        )
        defaults.set(
            try JSONEncoder().encode(cachedRelease),
            forKey: "updateChecker.cachedRelease"
        )
        let checker = UpdateChecker(
            currentVersion: "1.0.0",
            releaseTag: "v1.0.0",
            defaults: defaults,
            request: { request in
                if Self.isChangelogRequest(request) {
                    return Self.changelogResponse()
                }
                XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "cached-etag")
                return UpdateHTTPResponse(data: Data(), statusCode: 304, etag: nil)
            }
        )

        let checkSucceeded = await checker.checkNow()

        XCTAssertTrue(checkSucceeded)
        XCTAssertNotNil(checker.availableRelease?.changelog)
        let cachedData = try XCTUnwrap(defaults.data(forKey: "updateChecker.cachedRelease"))
        XCTAssertNotNil(try JSONDecoder().decode(AvailableRelease.self, from: cachedData).changelog)
    }

    func testChannelChangeDuringNotModifiedEnrichmentCannotPublishStaleRelease() async throws {
        let defaults = makeDefaults()
        defaults.set(true, forKey: UpdatePreferences.includesPrereleasesKey)
        defaults.set(2, forKey: "updateChecker.cacheSchema")
        defaults.set("cached-etag", forKey: "updateChecker.etag")
        let cachedRelease = AvailableRelease(
            tagName: "v1.1.0-rc1",
            name: "MarkLens 1.1.0 RC 1",
            body: "Preview release.",
            htmlURL: URL(string: "https://github.com/pd95/MarkLens/releases/tag/v1.1.0-rc1")!,
            prerelease: true
        )
        defaults.set(
            try JSONEncoder().encode(cachedRelease),
            forKey: "updateChecker.cachedRelease"
        )
        let changelogStarted = TestGate()
        let allowChangelogResponse = TestGate()
        var releaseRequestCount = 0
        let checker = UpdateChecker(
            currentVersion: "1.0.0",
            releaseTag: "v1.0.0",
            defaults: defaults,
            request: { request in
                if Self.isChangelogRequest(request) {
                    await changelogStarted.open()
                    await allowChangelogResponse.wait()
                    return Self.changelogResponse()
                }
                releaseRequestCount += 1
                if releaseRequestCount == 1 {
                    return UpdateHTTPResponse(data: Data(), statusCode: 304, etag: nil)
                }
                throw URLError(.notConnectedToInternet)
            }
        )

        let initialCheck = Task { await checker.checkNow() }
        await changelogStarted.wait()
        defaults.set(false, forKey: UpdatePreferences.includesPrereleasesKey)
        let channelRefresh = Task { await checker.releaseChannelDidChange() }
        await allowChangelogResponse.open()

        let initialCheckSucceeded = await initialCheck.value
        let channelRefreshSucceeded = await channelRefresh.value

        XCTAssertFalse(initialCheckSucceeded)
        XCTAssertFalse(channelRefreshSucceeded)
        XCTAssertNil(checker.availableRelease)
        XCTAssertNil(checker.lastSuccessfulCheck)
        XCTAssertNil(defaults.string(forKey: "updateChecker.lastSuccessfulChannel"))
    }

    func testConcurrentChecksShareOneRequest() async {
        var requestCount = 0
        let checker = UpdateChecker(
            currentVersion: "1.0.0",
            releaseTag: "v1.0.0",
            defaults: makeDefaults(),
            request: { request in
                if Self.isChangelogRequest(request) {
                    return Self.changelogResponse()
                }
                requestCount += 1
                try? await Task.sleep(for: .milliseconds(25))
                return UpdateHTTPResponse(
                    data: Self.releaseJSON(tag: "v1.1.0"),
                    statusCode: 200,
                    etag: nil
                )
            }
        )

        async let first: Void = checker.checkIfDue()
        async let second: Void = checker.checkIfDue()
        await first
        await second

        XCTAssertEqual(requestCount, 1)
    }

    func testLocalBuildDoesNotCheckAutomatically() async {
        var requested = false
        let checker = UpdateChecker(
            currentVersion: "local",
            releaseTag: "local",
            defaults: makeDefaults(),
            request: { _ in
                requested = true
                return UpdateHTTPResponse(data: Data(), statusCode: 500, etag: nil)
            }
        )

        await checker.checkIfDue()

        XCTAssertFalse(requested)
        XCTAssertNil(checker.availableRelease)
    }

    func testLocalBuildCanCheckManually() async {
        var requested = false
        let defaults = makeDefaults()
        let checker = UpdateChecker(
            currentVersion: "local",
            releaseTag: "local",
            defaults: defaults,
            request: { _ in
                requested = true
                return UpdateHTTPResponse(
                    data: Self.releaseJSON(tag: "v99.0.0"),
                    statusCode: 200,
                    etag: nil
                )
            }
        )

        let succeeded = await checker.checkNow()

        XCTAssertTrue(succeeded)
        XCTAssertTrue(requested)
        XCTAssertEqual(checker.availableRelease?.tagName, "v99.0.0")

        let restored = UpdateChecker(
            currentVersion: "local",
            releaseTag: "local",
            defaults: defaults
        )
        XCTAssertEqual(restored.availableRelease?.tagName, "v99.0.0")
    }

    #if DEBUG
    func testDebugMockReleaseAppearsWithoutRequestingGitHub() async {
        var requested = false
        let checker = UpdateChecker(
            currentVersion: "local",
            releaseTag: "local",
            defaults: makeDefaults(),
            environment: ["MARKLENS_MOCK_UPDATE_VERSION": "99.0.0"],
            request: { _ in
                requested = true
                return UpdateHTTPResponse(data: Data(), statusCode: 500, etag: nil)
            }
        )

        await checker.checkIfDue()

        XCTAssertFalse(requested)
        XCTAssertEqual(checker.availableRelease?.tagName, "v99.0.0")
        XCTAssertEqual(checker.availableRelease?.displayVersion, "99.0.0")
        XCTAssertEqual(
            checker.availableRelease?.htmlURL,
            URL(string: "https://github.com/pd95/MarkLens/releases/tag/v99.0.0")
        )

    }
    #endif

    func testFailuresUntrustedURLsAndNonStableReleasesAreIgnored() async {
        let failureChecker = UpdateChecker(
            currentVersion: "1.0.0",
            releaseTag: "v1.0.0",
            defaults: makeDefaults(),
            request: { _ in
                throw URLError(.notConnectedToInternet)
            }
        )
        await failureChecker.checkIfDue()
        XCTAssertNil(failureChecker.availableRelease)

        let untrustedChecker = UpdateChecker(
            currentVersion: "1.0.0",
            releaseTag: "v1.0.0",
            defaults: makeDefaults(),
            request: { _ in
                UpdateHTTPResponse(
                    data: Self.releaseJSON(tag: "v2.0.0", url: "https://example.com/release"),
                    statusCode: 200,
                    etag: nil
                )
            }
        )
        await untrustedChecker.checkIfDue()
        XCTAssertNil(untrustedChecker.availableRelease)

        for response in [
            Self.releaseJSON(tag: "v2.0.0", draft: true),
            Self.releaseJSON(tag: "v2.0.0-rc1", prerelease: true),
        ] {
            let checker = UpdateChecker(
                currentVersion: "1.0.0",
                releaseTag: "v1.0.0",
                defaults: makeDefaults(),
                request: { _ in
                    UpdateHTTPResponse(data: response, statusCode: 200, etag: nil)
                }
            )
            await checker.checkIfDue()
            XCTAssertNil(checker.availableRelease)
        }
    }

    private func version(_ value: String) throws -> ReleaseVersion {
        try XCTUnwrap(ReleaseVersion(value))
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "UpdateCheckerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    nonisolated private static func releaseJSON(
        tag: String,
        body: String = "Release notes",
        url: String = "https://github.com/pd95/MarkLens/releases/tag/v1.1.0",
        draft: Bool = false,
        prerelease: Bool = false,
        assetName: String? = nil,
        assetURL: String? = nil,
        assetState: String = "uploaded"
    ) -> Data {
        try! JSONSerialization.data(withJSONObject: releaseObject(
            tag: tag,
            body: body,
            url: url,
            draft: draft,
            prerelease: prerelease,
            assetName: assetName,
            assetURL: assetURL,
            assetState: assetState
        ))
    }

    nonisolated private static func releasesJSON(_ releases: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: releases)
    }

    nonisolated private static func releaseObject(
        tag: String,
        body: String = "Release notes",
        url: String = "https://github.com/pd95/MarkLens/releases/tag/v1.1.0",
        draft: Bool = false,
        prerelease: Bool = false,
        assetName: String? = nil,
        assetURL: String? = nil,
        assetState: String = "uploaded"
    ) -> [String: Any] {
        var release: [String: Any] = [
            "tag_name": tag,
            "name": "MarkLens \(tag)",
            "body": body,
            "html_url": url,
            "draft": draft,
            "prerelease": prerelease,
        ]
        if let assetName, let assetURL {
            release["assets"] = [[
                "name": assetName,
                "browser_download_url": assetURL,
                "state": assetState,
            ]]
        }
        return release
    }

    nonisolated private static func isChangelogRequest(_ request: URLRequest) -> Bool {
        request.url?.path == "/repos/pd95/MarkLens/contents/CHANGELOG.md"
    }

    nonisolated private static func changelogResponse() -> UpdateHTTPResponse {
        let changelog = """
            # Changelog

            ## 1.3.0

            - Latest changes.

            ## 1.2.0

            - Earlier missed changes.

            ## 1.1.0

            - Old changes.

            ## 99.0.0

            - Debug changes.
            """
        return UpdateHTTPResponse(data: Data(changelog.utf8), statusCode: 200, etag: nil)
    }
}

private actor TestGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard isOpen == false else {
            return
        }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pendingContinuations = continuations
        continuations.removeAll()
        for continuation in pendingContinuations {
            continuation.resume()
        }
    }
}
#endif

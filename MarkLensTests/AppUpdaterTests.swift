#if os(macOS)
import AppKit
import XCTest
@testable import MarkLens

@MainActor
final class AppUpdaterTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let domain = "MarkLens.AppUpdaterTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: domain) }
        return UserDefaults(suiteName: domain)!
    }

    func testMigratesDisabledChecksBeforeStartingAndManualCheckStillWorks() {
        let settings = defaults()
        settings.set(false, forKey: UpdatePreferences.automaticChecksKey)
        settings.set(true, forKey: UpdatePreferences.includesPrereleasesKey)
        settings.set(Data([1]), forKey: "updateChecker.cachedRelease")
        let backend = FakeUpdateBackend()
        let updater = AppUpdater(backend: backend, defaults: settings)
        XCTAssertEqual(backend.checksWhenStarted, false)
        XCTAssertTrue(updater.includesPrereleases)
        XCTAssertNil(settings.object(forKey: "updateChecker.cachedRelease"))
        XCTAssertFalse(updater.automaticallyDownloadsUpdates)
        updater.checkForUpdates()
        XCTAssertEqual(backend.checkCount, 1)
        XCTAssertNotNil(updater.lastUpdateCheckDate)
    }

    func testMigrationDoesNotOverwriteSubsequentSparkleChoices() {
        let settings = defaults()
        settings.set(false, forKey: UpdatePreferences.automaticChecksKey)
        let backend = FakeUpdateBackend()
        _ = AppUpdater(backend: backend, defaults: settings)
        backend.automaticallyChecksForUpdates = true
        settings.set(false, forKey: UpdatePreferences.automaticChecksKey)
        let updater = AppUpdater(backend: backend, defaults: settings)
        XCTAssertTrue(updater.automaticallyChecksForUpdates)
    }

    func testRegisteredSparkleDefaultDoesNotOverrideLegacyChoice() {
        let settings = defaults()
        settings.set(false, forKey: UpdatePreferences.automaticChecksKey)
        settings.register(defaults: ["SUEnableAutomaticChecks": true])
        let updater = AppUpdater(backend: FakeUpdateBackend(), defaults: settings)
        XCTAssertFalse(updater.automaticallyChecksForUpdates)
    }

    func testChannelChangeReschedulesOnceAndPersists() {
        let settings = defaults()
        let backend = FakeUpdateBackend()
        let updater = AppUpdater(backend: backend, defaults: settings)
        updater.setIncludesPrereleases(true)
        updater.setIncludesPrereleases(true)
        XCTAssertTrue(backend.includesPrereleases)
        XCTAssertTrue(settings.bool(forKey: UpdatePreferences.includesPrereleasesKey))
        XCTAssertEqual(backend.resetCount, 1)
        updater.setIncludesPrereleases(false)
        XCTAssertFalse(backend.includesPrereleases)
        XCTAssertEqual(backend.resetCount, 2)
    }

    func testBackendChangesRefreshSettingsAndBlockConcurrentManualChecks() {
        let backend = FakeUpdateBackend()
        let updater = AppUpdater(backend: backend, defaults: defaults())
        backend.canCheckForUpdates = false
        backend.automaticallyDownloadsUpdates = true
        backend.onChange?()
        XCTAssertTrue(updater.automaticallyDownloadsUpdates)
        updater.checkForUpdates()
        XCTAssertEqual(backend.checkCount, 0)
    }

    func testLocalAndXCTestBuildsNeverStartLiveUpdater() {
        let local = AppUpdater(defaults: defaults(), releaseTag: "local", environment: [:])
        XCTAssertFalse(local.canCheckForUpdates)
        XCTAssertNotNil(local.unavailableReason)
        let test = AppUpdater(
            defaults: defaults(), releaseTag: "v1.10.0",
            environment: ["XCTestConfigurationFilePath": "tests.xctestconfiguration"])
        XCTAssertFalse(test.canCheckForUpdates)
    }

    func testReleaseWithoutSigningKeyCannotStartUpdater() {
        let updater = AppUpdater(
            defaults: defaults(), releaseTag: "v1.10.0", environment: [:], publicKey: "")
        XCTAssertFalse(updater.canCheckForUpdates)
        XCTAssertNotNil(updater.unavailableReason)
    }

    func testCumulativeNotesRetainOnlyMissedVersionsAndFormatting() {
        let notes = NSAttributedString(
            string:
                "Version 2.0.0\nFuture\nVersion 1.3.0\nNew 😀\nVersion 1.2.1\nPatch\nVersion 1.2.0\nOld\n",
            attributes: [.foregroundColor: NSColor.red])
        let filtered = UpdateReleaseNotes.filter(
            notes, installedVersion: "1.2.0", targetVersion: "1.3.0-rc1")
        XCTAssertEqual(filtered.string, "Version 1.3.0\nNew 😀\nVersion 1.2.1\nPatch\n")
        XCTAssertNotNil(filtered.attribute(.foregroundColor, at: 0, effectiveRange: nil))
    }

    func testCumulativeNotesFilterNativeMarkdownRendering() throws {
        let markdown = """
            ## Version 1.10.0

            - New **formatting**.

            ## Version 1.9.1

            - Already installed.
            """
        let rendered = try NSAttributedString(markdown: Data(markdown.utf8))
        let filtered = UpdateReleaseNotes.filter(rendered, installedVersion: "1.9.1", targetVersion: "1.10.0")
        XCTAssertTrue(filtered.string.contains("New formatting."))
        XCTAssertFalse(filtered.string.contains("Already installed."))
    }

    func testNotesForUpdatesWithinSamePrereleaseRemainVisible() {
        let notes = NSAttributedString(string: "Version 1.10.0\nChanges\nVersion 1.9.1\nOld\n")
        let filtered = UpdateReleaseNotes.filter(
            notes, installedVersion: "1.10.0-rc1", targetVersion: "1.10.0-rc2")
        XCTAssertEqual(filtered.string, "Version 1.10.0\nChanges\n")
    }

    func testUnrecognizedNotesAreShownInsteadOfBeingDiscarded() {
        let notes = NSAttributedString(string: "Release notes unavailable.")
        XCTAssertEqual(
            UpdateReleaseNotes.filter(notes, installedVersion: "1.0.0", targetVersion: "1.1.0"), notes)
    }
}

@MainActor
private final class FakeUpdateBackend: UpdateBackend {
    var automaticallyChecksForUpdates = true
    var automaticallyDownloadsUpdates = false
    var includesPrereleases = false
    var canCheckForUpdates = true
    var lastUpdateCheckDate: Date?
    var onChange: (() -> Void)?
    var checksWhenStarted: Bool?
    var checkCount = 0
    var resetCount = 0
    func start() { checksWhenStarted = automaticallyChecksForUpdates }
    func checkForUpdates() {
        checkCount += 1
        lastUpdateCheckDate = Date()
        onChange?()
    }
    func resetUpdateCycle() { resetCount += 1 }
}
#endif

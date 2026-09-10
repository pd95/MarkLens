#if os(macOS)
import Dispatch
import Foundation
import XCTest
@testable import MarkLens

@MainActor
final class ExternalFileMonitorTests: XCTestCase {
    func testSignalsAtomicFileReplacement() throws {
        let fixture = try MonitorFixture(initialText: "Before")
        defer { fixture.remove() }

        let changed = expectation(description: "file change signal")
        let monitor = makeMonitor(fileURL: fixture.fileURL) {
            changed.fulfill()
        }

        try Data("After".utf8).write(to: fixture.fileURL, options: .atomic)

        wait(for: [changed], timeout: 2)
        monitor.stop()
    }

    func testSignalsContentReplacementThatPreservesModificationDate() throws {
        let fixture = try MonitorFixture(initialText: "Before")
        defer { fixture.remove() }
        let originalAttributes = try FileManager.default.attributesOfItem(
            atPath: fixture.fileURL.path
        )

        let changed = expectation(description: "timestamp-preserving change signal")
        let monitor = makeMonitor(fileURL: fixture.fileURL) {
            changed.fulfill()
        }

        try Data("After".utf8).write(to: fixture.fileURL)
        if let modificationDate = originalAttributes[.modificationDate] {
            try FileManager.default.setAttributes(
                [.modificationDate: modificationDate],
                ofItemAtPath: fixture.fileURL.path
            )
        }

        wait(for: [changed], timeout: 2)
        monitor.stop()
    }

    func testCoalescesSuccessiveFileEvents() throws {
        let fixture = try MonitorFixture(initialText: "Before")
        defer { fixture.remove() }

        let changed = expectation(description: "coalesced file change signal")
        var signalCount = 0
        let monitor = makeMonitor(fileURL: fixture.fileURL) {
            signalCount += 1
            changed.fulfill()
        }

        try Data("One".utf8).write(to: fixture.fileURL, options: .atomic)
        try Data("Two".utf8).write(to: fixture.fileURL, options: .atomic)
        try Data("Three".utf8).write(to: fixture.fileURL, options: .atomic)

        wait(for: [changed], timeout: 2)
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        XCTAssertEqual(signalCount, 1)
        monitor.stop()
    }

    func testSignalsWhenDeletedFileReappears() throws {
        let fixture = try MonitorFixture(initialText: "Before")
        defer { fixture.remove() }

        let changed = expectation(description: "recreated file signal")
        let monitor = makeMonitor(fileURL: fixture.fileURL) {
            changed.fulfill()
        }

        try FileManager.default.removeItem(at: fixture.fileURL)
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(150)) {
            try? Data("After".utf8).write(to: fixture.fileURL)
        }

        wait(for: [changed], timeout: 2)
        monitor.stop()
    }

    func testStopSuppressesQueuedSignal() throws {
        let fixture = try MonitorFixture(initialText: "Before")
        defer { fixture.remove() }

        let changed = expectation(description: "stale file change signal")
        changed.isInverted = true
        let monitor = makeMonitor(fileURL: fixture.fileURL) {
            changed.fulfill()
        }

        try Data("After".utf8).write(to: fixture.fileURL, options: .atomic)
        monitor.stop()

        wait(for: [changed], timeout: 0.5)
    }

    private func makeMonitor(
        fileURL: URL,
        changeHandler: @escaping ExternalFileMonitor.ChangeHandler
    ) -> ExternalFileMonitor {
        ExternalFileMonitor(
            fileURL: fileURL,
            timing: ExternalFileMonitor.Timing(
                quietPeriod: .milliseconds(100),
                maximumDelay: .milliseconds(350),
                reconnectDelay: .milliseconds(50)
            ),
            changeHandler: changeHandler
        )
    }
}

@MainActor
final class WikiPageFileMonitorIntegrationTests: XCTestCase {
    func testFileSignalReloadsCurrentWikiPageThroughLoader() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let pageURL = directoryURL.appendingPathComponent("page.md")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try "# Before".write(to: pageURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let navigation = WikiNavigationModel()
        navigation.navigate(to: pageURL, wikiRoot: directoryURL)
        await waitForLoad(navigation)

        let reloaded = expectation(description: "wiki page reloaded")
        let monitor = ExternalFileMonitor(
            fileURL: pageURL,
            timing: ExternalFileMonitor.Timing(
                quietPeriod: .milliseconds(100),
                maximumDelay: .milliseconds(350),
                reconnectDelay: .milliseconds(50)
            )
        ) {
            navigation.refreshCurrent(renderingPreferences: .secureDefaults) { _ in
                reloaded.fulfill()
            }
        }

        try "# After".write(to: pageURL, atomically: true, encoding: .utf8)

        await fulfillment(of: [reloaded], timeout: 2)
        XCTAssertTrue(navigation.currentPage?.html.contains("After") == true)
        monitor.stop()
    }

    private func waitForLoad(_ model: WikiNavigationModel) async {
        for _ in 0..<100 where model.isLoading {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(model.isLoading)
    }
}

@MainActor
final class ExternalDocumentReloadCoordinatorTests: XCTestCase {
    func testReloadsEverySignalForCleanDocument() {
        let document = ManagedDocumentStub()
        let coordinator = makeCoordinator(document: document)

        let result = coordinator.handleChange(isEditing: false)

        assertReloaded(result)
        XCTAssertEqual(document.reloadCount, 1)
    }

    func testReloadsSignalEvenWhenExternalReplacementPreservesModificationDate() {
        let document = ManagedDocumentStub()
        let coordinator = makeCoordinator(document: document)

        let result = coordinator.handleChange(isEditing: false)

        assertReloaded(result)
        XCTAssertEqual(document.reloadCount, 1)
    }

    func testRetriesChangeAfterDocumentBecomesAvailable() {
        let document = ManagedDocumentStub()
        var resolvedDocument: ManagedDocumentStub?
        let coordinator = ExternalDocumentReloadCoordinator(
            fileURL: URL(fileURLWithPath: "/tmp/document.md"),
            resolver: { _ in resolvedDocument }
        )

        guard case .unavailable = coordinator.handleChange(isEditing: false) else {
            return XCTFail("Expected the unresolved document to be unavailable.")
        }
        XCTAssertTrue(coordinator.hasDeferredChange)

        resolvedDocument = document
        let result = coordinator.resumeDeferredChange(isEditing: false)

        guard let result else {
            return XCTFail("Expected the unavailable change to remain pending.")
        }
        assertReloaded(result)
        XCTAssertFalse(coordinator.hasDeferredChange)
    }

    func testDefersReloadWhileEditing() {
        let document = ManagedDocumentStub()
        let coordinator = makeCoordinator(document: document)

        let result = coordinator.handleChange(isEditing: true)

        assertDeferred(result)
        XCTAssertTrue(coordinator.hasDeferredChange)
        XCTAssertEqual(document.reloadCount, 0)
    }

    func testDefersReloadWhileDocumentHasLocalChanges() {
        let document = ManagedDocumentStub()
        document.hasLocalChanges = true
        let coordinator = makeCoordinator(document: document)

        let result = coordinator.handleChange(isEditing: false)

        assertDeferred(result)
        XCTAssertEqual(document.reloadCount, 0)
    }

    func testResumesDeferredReloadAfterDocumentBecomesClean() {
        let document = ManagedDocumentStub()
        document.hasLocalChanges = true
        let coordinator = makeCoordinator(document: document)
        _ = coordinator.handleChange(isEditing: false)
        document.hasLocalChanges = false

        let result = coordinator.resumeDeferredChange(isEditing: false)

        guard let result else {
            return XCTFail("Expected a deferred change to be reconsidered.")
        }
        assertReloaded(result)
        XCTAssertFalse(coordinator.hasDeferredChange)
        XCTAssertEqual(document.reloadCount, 1)
    }

    func testReportsReloadFailureWithoutClearingDeferredState() {
        let document = ManagedDocumentStub()
        document.reloadError = CocoaError(.fileReadUnknown)
        let coordinator = makeCoordinator(document: document)

        let result = coordinator.handleChange(isEditing: false)

        guard case .failed = result else {
            return XCTFail("Expected the reload error to be reported.")
        }
        XCTAssertTrue(coordinator.hasDeferredChange)
        XCTAssertEqual(document.reloadCount, 1)
    }

    func testRetrySucceedsAfterTransientReloadFailure() {
        let document = ManagedDocumentStub()
        document.reloadError = CocoaError(.fileReadUnknown)
        let coordinator = makeCoordinator(document: document)
        _ = coordinator.handleChange(isEditing: false)
        document.reloadError = nil

        let result = coordinator.resumeDeferredChange(isEditing: false)

        guard let result else {
            return XCTFail("Expected the failed reload to remain pending.")
        }
        assertReloaded(result)
        XCTAssertFalse(coordinator.hasDeferredChange)
        XCTAssertEqual(document.reloadCount, 2)
    }

    func testUpdateKeepsAutosavedDraftUntilLocalSaveCompletes() throws {
        let sourceDocument = MarkdownDocument(text: "# Baseline")
        sourceDocument.beginSourceEditing()
        sourceDocument.updateSourceDraft("# Draft")
        let managedDocument = ManagedDocumentStub()
        let coordinator = makeCoordinator(document: managedDocument)
        _ = coordinator.handleChange(isEditing: true)

        XCTAssertTrue(sourceDocument.commitSourceEditing())
        coordinator.preserveLocalVersionForSaving()

        assertDeferred(try XCTUnwrap(coordinator.resumeDeferredChange(isEditing: false)))
        XCTAssertEqual(try sourceDocument.snapshot(contentType: .appMarkdown), "# Draft")
        XCTAssertEqual(managedDocument.reloadCount, 0)

        managedDocument.hasLocalChanges = false
        assertReloaded(try XCTUnwrap(coordinator.resumeDeferredChange(isEditing: false)))
        XCTAssertEqual(managedDocument.reloadCount, 1)
    }

    func testCancelKeepsRestoredBaselineUntilLocalSaveCompletes() throws {
        let sourceDocument = MarkdownDocument(text: "# Baseline")
        sourceDocument.beginSourceEditing()
        sourceDocument.updateSourceDraft("# Draft")
        let managedDocument = ManagedDocumentStub()
        let coordinator = makeCoordinator(document: managedDocument)
        _ = coordinator.handleChange(isEditing: true)

        XCTAssertTrue(sourceDocument.cancelSourceEditing())
        coordinator.preserveLocalVersionForSaving()

        assertDeferred(try XCTUnwrap(coordinator.resumeDeferredChange(isEditing: false)))
        XCTAssertEqual(try sourceDocument.snapshot(contentType: .appMarkdown), "# Baseline")
        XCTAssertEqual(managedDocument.reloadCount, 0)

        managedDocument.hasLocalChanges = false
        assertReloaded(try XCTUnwrap(coordinator.resumeDeferredChange(isEditing: false)))
        XCTAssertEqual(managedDocument.reloadCount, 1)
    }

    private func makeCoordinator(document: ManagedDocumentStub) -> ExternalDocumentReloadCoordinator {
        ExternalDocumentReloadCoordinator(
            fileURL: URL(fileURLWithPath: "/tmp/document.md"),
            resolver: { _ in document }
        )
    }

    private func assertReloaded(
        _ result: ExternalDocumentReloadCoordinator.Result,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .reloaded = result else {
            return XCTFail("Expected a reload result.", file: file, line: line)
        }
    }

    private func assertDeferred(
        _ result: ExternalDocumentReloadCoordinator.Result,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .deferred = result else {
            return XCTFail("Expected a deferred result.", file: file, line: line)
        }
    }

}

@MainActor
private final class ManagedDocumentStub: ManagedDocumentReloading {
    var hasLocalChanges = false
    var reloadError: Error?
    private(set) var markLocalVersionCount = 0
    private(set) var reloadCount = 0

    func markLocalVersionForSaving() {
        markLocalVersionCount += 1
        hasLocalChanges = true
    }

    func reloadFromDisk() throws {
        reloadCount += 1
        if let reloadError {
            throw reloadError
        }
    }
}

private struct MonitorFixture {
    let directoryURL: URL
    let fileURL: URL

    init(initialText: String) throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        fileURL = directoryURL.appendingPathComponent("document.md")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try Data(initialText.utf8).write(to: fileURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
#endif

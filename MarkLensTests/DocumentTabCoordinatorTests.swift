import XCTest
@testable import MarkLens

#if os(macOS)
import AppKit
import Combine

@MainActor
final class DocumentTabCoordinatorTests: XCTestCase {
    func testHandoffNotificationFollowsStoredState() {
        let tabs = DocumentTabCoordinator()
        let url = URL(fileURLWithPath: "/tmp/handoff.md")
        let handoff = DocumentViewHandoff(
            scrollPosition: .top,
            findText: "search",
            findPresented: true,
            frontMatterExpanded: false
        )
        var received: DocumentViewHandoff?
        let subscription = tabs.handoffRequests.sink { notifiedURL in
            received = tabs.takeHandoff(for: notifiedURL, id: handoff.id)
        }
        defer { subscription.cancel() }

        tabs.enqueue(handoff, for: url)
        XCTAssertEqual(received, handoff)
        XCTAssertNil(tabs.handoffs[url])
    }

    func testExplicitOpenGroupsNewDocumentAndReusesExistingWindow() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkLensTabs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.md")
        let targetURL = directory.appendingPathComponent("target.md")
        try "# Source".write(to: sourceURL, atomically: true, encoding: .utf8)
        try "# Target".write(to: targetURL, atomically: true, encoding: .utf8)

        let sourceDocument = try await openDocument(sourceURL)
        defer { sourceDocument.close() }
        let sourceWindow = try XCTUnwrap(sourceDocument.windowControllers.first?.window)
        let tabs = DocumentTabCoordinator()

        try await tabs.openInTab(targetURL, beside: sourceWindow)
        let targetDocument = try XCTUnwrap(NSDocumentController.shared.document(for: targetURL))
        defer { targetDocument.close() }
        let targetWindow = try XCTUnwrap(targetDocument.windowControllers.first?.window)
        XCTAssertTrue(sourceWindow.tabGroup === targetWindow.tabGroup)
        XCTAssertTrue(sourceWindow.tabGroup?.selectedWindow === targetWindow)

        try await tabs.openInTab(targetURL, beside: sourceWindow)
        XCTAssertEqual(targetDocument.windowControllers.count, 1)
        XCTAssertTrue(sourceWindow.tabGroup?.selectedWindow === targetWindow)
    }

    private func openDocument(_ url: URL) async throws -> NSDocument {
        try await withCheckedThrowingContinuation { continuation in
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) {
                document, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let document {
                    continuation.resume(returning: document)
                } else {
                    continuation.resume(throwing: CocoaError(.fileReadUnknown))
                }
            }
        }
    }
}
#endif

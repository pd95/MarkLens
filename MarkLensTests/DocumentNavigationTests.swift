#if os(macOS)
import XCTest
@testable import MarkLens

@MainActor
final class DocumentNavigationTests: XCTestCase {
    func testIncomingURLParsesFileAndLine() throws {
        var components = URLComponents()
        components.scheme = "marklens"
        components.host = "open"
        components.queryItems = [
            URLQueryItem(name: "file", value: "file:///tmp/notes%20with%20spaces.md"),
            URLQueryItem(name: "line", value: "12")
        ]

        let destination = try XCTUnwrap(DocumentNavigationCoordinator.incomingDestination(
            from: XCTUnwrap(components.url)
        ))
        XCTAssertEqual(destination.fileURL.lastPathComponent, "notes with spaces.md")
        XCTAssertEqual(destination.line, 12)
    }

    func testIncomingURLRejectsRemoteAndInvalidLine() throws {
        let remote = try XCTUnwrap(URL(string: "marklens://open?file=https%3A%2F%2Fexample.com%2Fnotes.md&line=12"))
        let zero = try XCTUnwrap(URL(string: "marklens://open?file=file%3A%2F%2F%2Ftmp%2Fnotes.md&line=0"))

        XCTAssertNil(DocumentNavigationCoordinator.incomingDestination(from: remote))
        XCTAssertNil(DocumentNavigationCoordinator.incomingDestination(from: zero))
    }

    func testPendingRequestIsTakenOnlyByMatchingDocument() {
        let coordinator = DocumentNavigationCoordinator()
        let target = URL(fileURLWithPath: "/tmp/notes.md")
        coordinator.enqueue(fileURL: target, line: 12)
        let requestID = coordinator.requests[target]?.id

        XCTAssertNil(coordinator.takeRequest(
            for: URL(fileURLWithPath: "/tmp/other.md"), id: requestID ?? UUID()
        ))
        XCTAssertEqual(coordinator.takeRequest(for: target, id: requestID ?? UUID())?.sourceLine, 12)
        XCTAssertTrue(coordinator.requests.isEmpty)
    }

    func testPendingRequestsForDifferentFilesRemainIndependent() throws {
        let coordinator = DocumentNavigationCoordinator()
        let first = URL(fileURLWithPath: "/tmp/first.md")
        let second = URL(fileURLWithPath: "/tmp/second.md")
        coordinator.enqueue(fileURL: first, line: 12)
        coordinator.enqueue(fileURL: second, line: 27)

        let firstID = try XCTUnwrap(coordinator.requests[first]?.id)
        let secondID = try XCTUnwrap(coordinator.requests[second]?.id)
        XCTAssertEqual(coordinator.takeRequest(for: first, id: firstID)?.sourceLine, 12)
        XCTAssertEqual(coordinator.takeRequest(for: second, id: secondID)?.sourceLine, 27)
    }

    func testFragmentRequestsSurviveOpeningAndMatchTheUnfragmentedDocument() throws {
        let coordinator = DocumentNavigationCoordinator()
        let link = try XCTUnwrap(URL(string: "file:///tmp/notes.md#ABC%20%25"))
        let file = URL(fileURLWithPath: "/tmp/notes.md")
        let position = try XCTUnwrap(DocumentScrollPosition.linkTarget(url: link, line: nil))
        XCTAssertEqual(position.fragment, "ABC %")
        coordinator.enqueue(fileURL: link, position: position)
        let id = try XCTUnwrap(coordinator.requests[file]?.id)
        XCTAssertEqual(coordinator.takeRequest(for: file, id: id), position)
        coordinator.enqueue(fileURL: file, position: position)
        coordinator.cancel(for: link)
        XCTAssertTrue(coordinator.requests.isEmpty)
    }

    func testLineTargetsTakePriorityAndEmptyFragmentsMeanTop() throws {
        let link = try XCTUnwrap(URL(string: "file:///tmp/notes.md#marklens-line=12"))
        XCTAssertEqual(DocumentScrollPosition.linkTarget(url: link, line: 12), DocumentScrollPosition(sourceLine: 12, progress: 0))
        let bare = try XCTUnwrap(URL(string: "file:///tmp/notes.md#"))
        XCTAssertEqual(DocumentScrollPosition.linkTarget(url: bare, line: nil)?.fragment, "")
        XCTAssertNil(DocumentScrollPosition.linkTarget(url: URL(fileURLWithPath: "/tmp/notes.md"), line: nil))
    }
}
#endif

#if os(macOS)
import XCTest
@testable import MarkLens

@MainActor
final class LineNavigationTests: XCTestCase {
    func testIncomingURLParsesFileAndLine() throws {
        var components = URLComponents()
        components.scheme = "marklens"
        components.host = "open"
        components.queryItems = [
            URLQueryItem(name: "file", value: "file:///tmp/notes%20with%20spaces.md"),
            URLQueryItem(name: "line", value: "12")
        ]

        let destination = try XCTUnwrap(LineNavigationCoordinator.incomingDestination(
            from: XCTUnwrap(components.url)
        ))
        XCTAssertEqual(destination.fileURL.lastPathComponent, "notes with spaces.md")
        XCTAssertEqual(destination.line, 12)
    }

    func testIncomingURLRejectsRemoteAndInvalidLine() throws {
        let remote = try XCTUnwrap(URL(string: "marklens://open?file=https%3A%2F%2Fexample.com%2Fnotes.md&line=12"))
        let zero = try XCTUnwrap(URL(string: "marklens://open?file=file%3A%2F%2F%2Ftmp%2Fnotes.md&line=0"))

        XCTAssertNil(LineNavigationCoordinator.incomingDestination(from: remote))
        XCTAssertNil(LineNavigationCoordinator.incomingDestination(from: zero))
    }

    func testPendingRequestIsTakenOnlyByMatchingDocument() {
        let coordinator = LineNavigationCoordinator()
        let target = URL(fileURLWithPath: "/tmp/notes.md")
        coordinator.enqueue(fileURL: target, line: 12)
        let requestID = coordinator.requests[target]?.id

        XCTAssertNil(coordinator.takeRequest(
            for: URL(fileURLWithPath: "/tmp/other.md"), id: requestID ?? UUID()
        ))
        XCTAssertEqual(coordinator.takeRequest(for: target, id: requestID ?? UUID()), 12)
        XCTAssertTrue(coordinator.requests.isEmpty)
    }

    func testPendingRequestsForDifferentFilesRemainIndependent() throws {
        let coordinator = LineNavigationCoordinator()
        let first = URL(fileURLWithPath: "/tmp/first.md")
        let second = URL(fileURLWithPath: "/tmp/second.md")
        coordinator.enqueue(fileURL: first, line: 12)
        coordinator.enqueue(fileURL: second, line: 27)

        let firstID = try XCTUnwrap(coordinator.requests[first]?.id)
        let secondID = try XCTUnwrap(coordinator.requests[second]?.id)
        XCTAssertEqual(coordinator.takeRequest(for: first, id: firstID), 12)
        XCTAssertEqual(coordinator.takeRequest(for: second, id: secondID), 27)
    }
}
#endif

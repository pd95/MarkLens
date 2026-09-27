import XCTest
@testable import MarkLens

#if os(macOS)
import AppKit

@MainActor
final class WindowPlacementCoordinatorTests: XCTestCase {
    func testRestoresPerFileFrameAndUsesLastDocumentForUnseenFile() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let coordinator = makeCoordinator()
        let firstURL = URL(fileURLWithPath: "/tmp/placement-first.md")
        let secondURL = URL(fileURLWithPath: "/tmp/placement-second.md")
        defer { clearFrames(coordinator, urls: [firstURL, secondURL]) }

        let first = makeWindow()
        coordinator.track(first, fileURL: firstURL, isUntitled: false)
        let firstFrame = frame(in: screen.visibleFrame, inset: 35)
        first.setFrame(firstFrame, display: false)
        coordinator.saveNow(first)
        first.close()

        let second = makeWindow()
        coordinator.track(second, fileURL: secondURL, isUntitled: false)
        XCTAssertEqual(second.frame, firstFrame)
        let secondFrame = frame(in: screen.visibleFrame, inset: 70)
        second.setFrame(secondFrame, display: false)
        coordinator.saveNow(second)
        second.close()

        let reopenedFirst = makeWindow()
        coordinator.track(reopenedFirst, fileURL: firstURL, isUntitled: false)
        XCTAssertEqual(reopenedFirst.frame, firstFrame)
        reopenedFirst.close()
    }

    func testSaveAsAdoptsCurrentFrameWithoutMovingWindow() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let coordinator = makeCoordinator()
        let firstURL = URL(fileURLWithPath: "/tmp/placement-original.md")
        let savedURL = URL(fileURLWithPath: "/tmp/placement-saved.md")
        defer { clearFrames(coordinator, urls: [firstURL, savedURL]) }

        let window = makeWindow()
        coordinator.track(window, fileURL: firstURL, isUntitled: false)
        let expected = frame(in: screen.visibleFrame, inset: 50)
        window.setFrame(expected, display: false)
        coordinator.track(window, fileURL: savedURL, isUntitled: false)
        XCTAssertEqual(window.frame, expected)
        window.close()

        let reopened = makeWindow()
        coordinator.track(reopened, fileURL: savedURL, isUntitled: false)
        XCTAssertEqual(reopened.frame, expected)
        reopened.close()
    }

    func testSavingUntitledDocumentKeepsItsPlacement() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let coordinator = makeCoordinator()
        let savedURL = URL(fileURLWithPath: "/tmp/placement-new-document.md")
        defer { clearFrames(coordinator, urls: [savedURL]) }

        let window = makeWindow()
        coordinator.track(window, fileURL: nil, isUntitled: true)
        let expected = frame(in: screen.visibleFrame, inset: 45)
        window.setFrame(expected, display: false)
        coordinator.track(window, fileURL: savedURL, isUntitled: true)
        XCTAssertEqual(window.frame, expected)
        window.close()

        let reopened = makeWindow()
        coordinator.track(reopened, fileURL: savedURL, isUntitled: false)
        XCTAssertEqual(reopened.frame, expected)
        reopened.close()
    }

    func testTabGroupFrameIsSavedForEveryFile() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let coordinator = makeCoordinator()
        let firstURL = URL(fileURLWithPath: "/tmp/placement-tab-first.md")
        let secondURL = URL(fileURLWithPath: "/tmp/placement-tab-second.md")
        defer { clearFrames(coordinator, urls: [firstURL, secondURL]) }

        let first = makeWindow()
        let second = makeWindow()
        coordinator.track(first, fileURL: firstURL, isUntitled: false)
        coordinator.track(second, fileURL: secondURL, isUntitled: false)
        first.addTabbedWindow(second, ordered: .above)
        let expected = frame(in: screen.visibleFrame, inset: 60)
        first.setFrame(expected, display: false)
        coordinator.saveNow(first)
        first.close()
        second.close()

        let reopenedSecond = makeWindow()
        coordinator.track(reopenedSecond, fileURL: secondURL, isUntitled: false)
        XCTAssertEqual(reopenedSecond.frame, expected)
        reopenedSecond.close()
    }

    func testConstrainedFrameFitsUnavailableAndSmallerDisplays() {
        let visible = NSRect(x: 0, y: 0, width: 900, height: 700)
        let offscreen = NSRect(x: 1800, y: 1200, width: 1200, height: 900)
        XCTAssertEqual(
            WindowPlacementCoordinator.constrainedFrame(offscreen, to: [visible]),
            visible
        )

        let partlyOutside = NSRect(x: 800, y: 600, width: 400, height: 300)
        XCTAssertEqual(
            WindowPlacementCoordinator.constrainedFrame(partlyOutside, to: [visible]),
            NSRect(x: 500, y: 400, width: 400, height: 300)
        )
    }

    func testReachableFrameSpanningDisplaysKeepsItsSizeAndPosition() {
        let left = NSRect(x: 0, y: 0, width: 900, height: 700)
        let right = NSRect(x: 900, y: 0, width: 900, height: 700)
        let spanning = NSRect(x: 700, y: 100, width: 500, height: 400)
        XCTAssertEqual(
            WindowPlacementCoordinator.constrainedFrame(spanning, to: [left, right]),
            spanning
        )

        let partlyOutside = NSRect(x: -100, y: 100, width: 500, height: 400)
        XCTAssertEqual(
            WindowPlacementCoordinator.constrainedFrame(partlyOutside, to: [left]),
            partlyOutside
        )
    }

    private func makeCoordinator() -> WindowPlacementCoordinator {
        WindowPlacementCoordinator(namespace: "MarkLens.WindowPlacementTests.\(UUID().uuidString)")
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private func frame(in visible: NSRect, inset: CGFloat) -> NSRect {
        NSRect(
            x: visible.minX + inset,
            y: visible.minY + inset,
            width: min(500, visible.width - inset * 2),
            height: min(400, visible.height - inset * 2)
        )
    }

    private func clearFrames(_ coordinator: WindowPlacementCoordinator, urls: [URL]) {
        for url in urls {
            NSWindow.removeFrame(usingName: coordinator.frameName(for: url))
        }
        NSWindow.removeFrame(usingName: coordinator.fallbackFrameName)
    }
}
#endif

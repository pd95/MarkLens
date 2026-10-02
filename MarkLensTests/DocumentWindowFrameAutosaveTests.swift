import XCTest
@testable import MarkLens

#if os(macOS)
import AppKit

@MainActor
final class DocumentWindowFrameAutosaveTests: XCTestCase {
    func testSaveAsKeepsOpenWindowFrame() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let autosave = makeAutosave()
        let originalURL = URL(fileURLWithPath: "/tmp/placement-original.md")
        let savedURL = URL(fileURLWithPath: "/tmp/placement-saved.md")
        defer { clearFrames(autosave, urls: [originalURL, savedURL]) }

        let window = makeWindow()
        autosave.update(window: window, fileURL: originalURL)
        let expected = NSRect(
            x: screen.visibleFrame.minX + 50,
            y: screen.visibleFrame.minY + 50,
            width: 500,
            height: 400
        )
        window.setFrame(expected, display: false)

        autosave.update(window: window, fileURL: savedURL)

        XCTAssertEqual(window.frame, expected)
        XCTAssertEqual(window.frameAutosaveName, autosave.frameName(for: savedURL))
        window.close()
    }

    func testFittedFrameKeepsWindowsFullyVisibleOnSmallerScreen() {
        let visible = NSRect(x: 0, y: 0, width: 900, height: 700)
        let oversized = NSRect(x: 0, y: 0, width: 1200, height: 900)
        XCTAssertEqual(
            DocumentWindowFrameAutosave.fittedFrame(oversized, to: [visible]),
            visible
        )

        let disconnectedDisplay = NSRect(x: 1800, y: 1200, width: 1200, height: 900)
        XCTAssertEqual(
            DocumentWindowFrameAutosave.fittedFrame(disconnectedDisplay, to: [visible]),
            visible
        )

        let partlyOutside = NSRect(x: 800, y: 600, width: 400, height: 300)
        XCTAssertEqual(
            DocumentWindowFrameAutosave.fittedFrame(partlyOutside, to: [visible]),
            NSRect(x: 500, y: 400, width: 400, height: 300)
        )

        let alreadyVisible = NSRect(x: 50, y: 50, width: 500, height: 400)
        XCTAssertEqual(
            DocumentWindowFrameAutosave.fittedFrame(alreadyVisible, to: [visible]),
            alreadyVisible
        )
    }

    func testFittedFrameUsesAvailableScreenWithLargestOverlap() {
        let left = NSRect(x: 0, y: 0, width: 900, height: 700)
        let right = NSRect(x: 900, y: 0, width: 900, height: 700)
        let spanning = NSRect(x: 700, y: 100, width: 500, height: 400)
        XCTAssertEqual(
            DocumentWindowFrameAutosave.fittedFrame(spanning, to: [left, right]),
            spanning
        )

        let partlyOutside = NSRect(x: 1600, y: 100, width: 500, height: 400)
        XCTAssertEqual(
            DocumentWindowFrameAutosave.fittedFrame(partlyOutside, to: [left, right]),
            NSRect(x: 1300, y: 100, width: 500, height: 400)
        )

        let disconnectedDisplay = NSRect(x: 2500, y: 100, width: 500, height: 400)
        XCTAssertEqual(
            DocumentWindowFrameAutosave.fittedFrame(disconnectedDisplay, to: [left, right]),
            NSRect(x: 400, y: 100, width: 500, height: 400)
        )
    }

    private func makeAutosave() -> DocumentWindowFrameAutosave {
        DocumentWindowFrameAutosave(namespace: "MarkLens.WindowFrameAutosaveTests.\(UUID().uuidString)")
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

    private func clearFrames(_ autosave: DocumentWindowFrameAutosave, urls: [URL]) {
        for url in urls {
            NSWindow.removeFrame(usingName: autosave.frameName(for: url))
        }
    }
}
#endif

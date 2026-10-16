import XCTest
@testable import MarkLens

#if os(macOS)
@MainActor
final class LinkedFilePreviewTests: XCTestCase {
    func testQuickLookSupportsMarkdownJSONAndFolders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let markdown = root.appendingPathComponent("notes.md")
        let json = root.appendingPathComponent("settings.json")
        try Data("# Notes".utf8).write(to: markdown)
        try Data("{}".utf8).write(to: json)
        let fileLink = root.appendingPathComponent("linked-settings.json")
        let folderLink = root.appendingPathComponent("linked-folder")
        try FileManager.default.createSymbolicLink(at: fileLink, withDestinationURL: json)
        try FileManager.default.createSymbolicLink(at: folderLink, withDestinationURL: root)
        let preview = LinkedFilePreview()
        for url in [markdown, json, root, fileLink, folderLink] {
            preview.preview(url)
            await waitUntil { preview.previewURL == url }
            XCTAssertNil(preview.errorDescription)
            XCTAssertNil(preview.accessRequest)
        }
        preview.close()
    }

    func testReadableImagePreviewsWithoutRequestingAccess() async {
        let preview = LinkedFilePreview(checkAccess: { _ in .readable })
        let url = URL(fileURLWithPath: "/wiki/image.png")
        preview.preview(url)
        await waitUntil { preview.previewURL != nil }
        XCTAssertEqual(preview.previewURL, url)
        XCTAssertNil(preview.accessRequest)
        preview.previewURL = nil
        XCTAssertNil(preview.previewURL)
    }

    func testIndividualFileGrantSurvivesDismissalAndIsReleasedOnce() async {
        let probe = AccessProbe()
        var released: [URL] = []
        let preview = LinkedFilePreview(checkAccess: { probe.check($0) }, releaseAccess: { released.append($0) })
        let url = URL(fileURLWithPath: "/wiki/image.png")
        preview.preview(url)
        await waitUntil { preview.accessRequest != nil }
        XCTAssertNil(preview.previewURL)
        preview.authorize(url, for: url)
        await waitUntil { preview.previewURL != nil }
        XCTAssertEqual(preview.previewURL, url)
        XCTAssertNil(preview.accessRequest)
        preview.previewURL = nil
        XCTAssertTrue(released.isEmpty)
        preview.preview(url)
        await waitUntil { preview.previewURL != nil }
        XCTAssertTrue(released.isEmpty)
        preview.close()
        preview.close()
        XCTAssertEqual(released, [url])
        XCTAssertNil(preview.previewURL)
    }

    func testCancellingAccessDoesNotPresentPreview() async {
        let preview = LinkedFilePreview(checkAccess: { _ in .permissionDenied })
        preview.preview(URL(fileURLWithPath: "/wiki/image.jpg"))
        await waitUntil { preview.accessRequest != nil }
        preview.cancelAccessRequest()
        XCTAssertNil(preview.previewURL)
        XCTAssertNil(preview.accessRequest)
        XCTAssertNil(preview.errorDescription)
    }

    func testFileSelectionAcceptsTheSameImageThroughASymlink() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let selected = directory.appendingPathComponent("target.png")
        try Data().write(to: selected)
        let requested = directory.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: requested, withDestinationURL: selected)
        let probe = AccessProbe()
        var released: [URL] = []
        let preview = LinkedFilePreview(checkAccess: { probe.check($0) }, releaseAccess: { released.append($0) })
        preview.preview(requested)
        await waitUntil { preview.accessRequest != nil }
        preview.authorize(selected, for: requested)
        await waitUntil { preview.previewURL != nil }
        XCTAssertEqual(preview.previewURL, selected)
        preview.close()
        XCTAssertEqual(released, [selected])
    }

    func testPersistentPermissionFailureDoesNotRepeatTheAccessPanel() async {
        let preview = LinkedFilePreview(checkAccess: { _ in .permissionDenied }, releaseAccess: { _ in })
        let url = URL(fileURLWithPath: "/wiki/image.png")
        preview.preview(url)
        await waitUntil { preview.accessRequest != nil }
        preview.authorize(url, for: url)
        await waitUntil { preview.errorDescription != nil }
        XCTAssertNil(preview.accessRequest)
        XCTAssertNil(preview.previewURL)
        preview.close()
    }

    func testWrongFileAndStaleSelectionReleaseTheirGrants() async {
        var released: [URL] = []
        let preview = LinkedFilePreview(
            checkAccess: { _ in .permissionDenied },
            releaseAccess: { released.append($0) }
        )
        let expected = URL(fileURLWithPath: "/wiki/image.jpg")
        let wrong = URL(fileURLWithPath: "/wiki/other.jpg")
        preview.preview(expected)
        await waitUntil { preview.accessRequest != nil }
        preview.authorize(wrong, for: expected)
        XCTAssertEqual(released, [wrong])
        XCTAssertNotNil(preview.errorDescription)
        XCTAssertNil(preview.previewURL)
        preview.close()
        preview.authorize(expected, for: expected)
        XCTAssertEqual(released, [wrong, expected])
        XCTAssertNil(preview.previewURL)
    }

    func testMissingFileReportsFailureWithoutAskingForPermission() async {
        let preview = LinkedFilePreview()
        preview.preview(FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png"))
        await waitUntil { preview.errorDescription != nil }
        XCTAssertNil(preview.accessRequest)
        XCTAssertNil(preview.previewURL)
    }

    func testNewRequestAndClosingIgnoreStaleCompletions() async {
        let old = URL(fileURLWithPath: "/wiki/old.png")
        let current = URL(fileURLWithPath: "/wiki/current.png")
        let preview = LinkedFilePreview(checkAccess: { url in
            if url == old { Thread.sleep(forTimeInterval: 0.1) }
            return .readable
        })
        preview.preview(old)
        preview.preview(current)
        await waitUntil { preview.previewURL == current }
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(preview.previewURL, current)
        preview.preview(old)
        preview.close()
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(preview.previewURL)
        XCTAssertNil(preview.accessRequest)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("File preview did not finish its access check.")
    }
}

private final class AccessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0

    func check(_ url: URL) -> LinkedFileAccessResult {
        lock.withLock {
            attempts += 1
            return attempts == 1 ? .permissionDenied : .readable
        }
    }
}
#endif

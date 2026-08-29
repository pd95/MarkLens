import Foundation
import XCTest
@testable import MarkLens

final class LocalDocumentAccessTests: XCTestCase {
    func testDisplayPathAbbreviatesOnlyHomeDirectoryDescendants() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

        XCTAssertEqual(LocalDocumentAccess.displayPath(for: home, homeDirectory: home), "~")
        XCTAssertEqual(
            LocalDocumentAccess.displayPath(
                for: URL(fileURLWithPath: "/Users/example/Documents/wiki", isDirectory: true),
                homeDirectory: home
            ),
            "~/Documents/wiki"
        )
        XCTAssertEqual(
            LocalDocumentAccess.displayPath(
                for: URL(fileURLWithPath: "/Users/example-other/wiki", isDirectory: true),
                homeDirectory: home
            ),
            "/Users/example-other/wiki"
        )
    }

    func testFolderAvailabilityRequiresAnExistingDirectory() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }

        XCTAssertTrue(LocalDocumentAccess.isFolderAvailable(folder))
        XCTAssertFalse(LocalDocumentAccess.isFolderAvailable(folder.appendingPathComponent("missing")))

        let file = folder.appendingPathComponent("file.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data()))
        XCTAssertFalse(LocalDocumentAccess.isFolderAvailable(file))
    }
}

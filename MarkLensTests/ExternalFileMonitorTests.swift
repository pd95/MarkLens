#if os(macOS)
import Dispatch
import Foundation
import XCTest
@testable import MarkLens

@MainActor
final class ExternalFileMonitorTests: XCTestCase {
    func testDetectsAtomicFileReplacement() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let fileURL = directoryURL.appendingPathComponent("document.md")
        try Data("# Before".utf8).write(to: fileURL)

        let changed = expectation(description: "external file change")
        let monitor = makeMonitor(fileURL: fileURL, initialText: "# Before") { text in
            XCTAssertEqual(text, "# After")
            changed.fulfill()
        }

        try Data("# After".utf8).write(to: fileURL, options: .atomic)
        wait(for: [changed], timeout: 3)
        monitor.stop()
        withExtendedLifetime(monitor) {}
    }

    func testDetectsSuccessiveAtomicReplacements() throws {
        let fixture = try MonitorFixture(initialText: "One")
        defer { fixture.remove() }

        let changed = expectation(description: "successive changes")
        changed.expectedFulfillmentCount = 2
        var received: [String] = []
        let monitor = makeMonitor(fileURL: fixture.fileURL, initialText: "One") { text in
            received.append(text)
            changed.fulfill()
        }

        try Data("Two".utf8).write(to: fixture.fileURL, options: .atomic)
        XCTAssertTrue(waitUntil { received == ["Two"] })
        try Data("Three".utf8).write(to: fixture.fileURL, options: .atomic)

        wait(for: [changed], timeout: 3)
        XCTAssertEqual(received, ["Two", "Three"])
        monitor.stop()
    }

    func testDetectsFileRecreatedAfterDeletion() throws {
        let fixture = try MonitorFixture(initialText: "Before")
        defer { fixture.remove() }

        let changed = expectation(description: "recreated file")
        let monitor = makeMonitor(fileURL: fixture.fileURL, initialText: "Before") { text in
            XCTAssertEqual(text, "After")
            changed.fulfill()
        }

        try FileManager.default.removeItem(at: fixture.fileURL)
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(300)) {
            try? Data("After".utf8).write(to: fixture.fileURL)
        }

        wait(for: [changed], timeout: 3)
        monitor.stop()
    }

    func testStopSuppressesQueuedDelivery() throws {
        let fixture = try MonitorFixture(initialText: "Before")
        defer { fixture.remove() }

        let changed = expectation(description: "stale change")
        changed.isInverted = true
        let monitor = makeMonitor(fileURL: fixture.fileURL, initialText: "Before") { _ in
            changed.fulfill()
        }

        try Data("After".utf8).write(to: fixture.fileURL, options: .atomic)
        monitor.stop()

        wait(for: [changed], timeout: 0.5)
    }

    func testReplacingFileDoesNotReportItsOwnWrite() async throws {
        let fixture = try MonitorFixture(initialText: "Before")
        defer { fixture.remove() }

        let changed = expectation(description: "stale external change")
        changed.isInverted = true
        let monitor = makeMonitor(fileURL: fixture.fileURL, initialText: "Before") { _ in
            changed.fulfill()
        }

        try await monitor.replaceFile(with: "Draft")

        await fulfillment(of: [changed], timeout: 0.5)
        XCTAssertEqual(try String(contentsOf: fixture.fileURL, encoding: .utf8), "Draft")
        monitor.stop()
    }

    func testReplacingFileRejectsAChangedBaseline() async throws {
        let fixture = try MonitorFixture(initialText: "Before")
        defer { fixture.remove() }
        let monitor = makeMonitor(fileURL: fixture.fileURL, initialText: "Before") { _ in }

        try Data("External".utf8).write(to: fixture.fileURL, options: .atomic)

        do {
            try await monitor.replaceFile(with: "Draft")
            XCTFail("Expected the changed file to prevent replacement")
        } catch ExternalFileMonitor.ReplacementError.fileChanged(let text) {
            XCTAssertEqual(text, "External")
        }
        XCTAssertEqual(try String(contentsOf: fixture.fileURL, encoding: .utf8), "External")
        monitor.stop()
    }

    func testStartsMonitoringWhenInitiallyMissingFileAppears() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let fileURL = directoryURL.appendingPathComponent("document.md")

        let changed = expectation(description: "created file")
        let monitor = makeMonitor(fileURL: fileURL, initialText: "Before") { text in
            XCTAssertEqual(text, "After")
            changed.fulfill()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(300)) {
            try? Data("After".utf8).write(to: fileURL)
        }

        wait(for: [changed], timeout: 3)
        monitor.stop()
    }

    func testRecreatedFileStartsANewRewriteWindow() throws {
        let fixture = try MonitorFixture(initialText: "Before")
        defer { fixture.remove() }

        let timing = ExternalFileMonitor.ReloadTiming(
            appendDelay: .milliseconds(50),
            rewriteQuietPeriod: .milliseconds(180),
            maximumRewriteDelay: .milliseconds(220),
            stabilityInterval: .milliseconds(10),
            reconnectDelay: .milliseconds(30)
        )
        var received: [String] = []
        let monitor = ExternalFileMonitor(
            fileURL: fixture.fileURL,
            initialText: "Before",
            timing: timing
        ) { text in
            received.append(text)
        }

        try FileManager.default.removeItem(at: fixture.fileURL)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        try Data("After".utf8).write(to: fixture.fileURL)

        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(received.isEmpty)
        XCTAssertTrue(waitUntil(timeout: 1) { received == ["After"] })
        monitor.stop()
    }

    func testFrequentAppendsAreCoalesced() throws {
        let fixture = try MonitorFixture(initialText: "Start\n")
        defer { fixture.remove() }

        let changed = expectation(description: "coalesced append")
        var received: [String] = []
        let monitor = makeMonitor(fileURL: fixture.fileURL, initialText: "Start\n") { text in
            received.append(text)
            changed.fulfill()
        }

        try Data("Start\nOne\n".utf8).write(to: fixture.fileURL, options: .atomic)
        try Data("Start\nOne\nTwo\n".utf8).write(to: fixture.fileURL, options: .atomic)
        try Data("Start\nOne\nTwo\nThree\n".utf8).write(to: fixture.fileURL, options: .atomic)

        wait(for: [changed], timeout: 1)
        XCTAssertEqual(received, ["Start\nOne\nTwo\nThree\n"])
        monitor.stop()
    }

    func testInPlaceAppendsRefreshAcrossMultipleWindows() throws {
        let fixture = try MonitorFixture(initialText: "Start\n")
        defer { fixture.remove() }

        let changed = expectation(description: "periodic append refreshes")
        changed.expectedFulfillmentCount = 2
        var received: [String] = []
        let monitor = makeMonitor(fileURL: fixture.fileURL, initialText: "Start\n") { text in
            received.append(text)
            changed.fulfill()
            if received.count == 1 {
                try? self.append("Two\n", to: fixture.fileURL)
            }
        }

        try append("One\n", to: fixture.fileURL)

        wait(for: [changed], timeout: 1)
        XCTAssertEqual(received, ["Start\nOne\n", "Start\nOne\nTwo\n"])
        monitor.stop()
    }

    func testLargerChangedPrefixUsesRewriteQuietPeriod() throws {
        let fixture = try MonitorFixture(initialText: "Original")
        defer { fixture.remove() }

        let changed = expectation(description: "completed rewrite")
        let startedAt = Date()
        var received: [String] = []
        let monitor = makeMonitor(fileURL: fixture.fileURL, initialText: "Original") { text in
            received.append(text)
            changed.fulfill()
        }

        try Data("Intermediate content longer than before".utf8)
            .write(to: fixture.fileURL, options: .atomic)
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) {
            try? Data("Final rewritten content longer than before".utf8)
                .write(to: fixture.fileURL, options: .atomic)
        }

        wait(for: [changed], timeout: 1)
        XCTAssertEqual(received, ["Final rewritten content longer than before"])
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(startedAt), 0.22)
        monitor.stop()
    }

    func testContinuousRewriteUsesMaximumDelay() throws {
        let fixture = try MonitorFixture(initialText: "Original")
        defer { fixture.remove() }

        let timing = ExternalFileMonitor.ReloadTiming(
            appendDelay: .milliseconds(50),
            rewriteQuietPeriod: .milliseconds(250),
            maximumRewriteDelay: .milliseconds(350),
            stabilityInterval: .milliseconds(10),
            reconnectDelay: .milliseconds(50)
        )
        let changed = expectation(description: "bounded rewrite")
        let startedAt = Date()
        var received: [String] = []
        let monitor = ExternalFileMonitor(
            fileURL: fixture.fileURL,
            initialText: "Original",
            timing: timing
        ) { text in
            received.append(text)
            changed.fulfill()
        }

        try Data("Rewrite zero".utf8).write(to: fixture.fileURL, options: .atomic)
        for (delay, version) in [(100, 1), (200, 2), (300, 3)] {
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(delay)) {
                try? Data("Rewrite \(version)".utf8).write(to: fixture.fileURL, options: .atomic)
            }
        }

        wait(for: [changed], timeout: 1)
        XCTAssertEqual(received, ["Rewrite 3"])
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(startedAt), 0.3)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.7)
        monitor.stop()
    }

    func testInvalidUTF8DoesNotReplaceAppendBaseline() throws {
        let fixture = try MonitorFixture(initialText: "Start")
        defer { fixture.remove() }

        var received: [String] = []
        let monitor = makeMonitor(fileURL: fixture.fileURL, initialText: "Start") { text in
            received.append(text)
        }

        try Data(Array("Start".utf8) + [0xC3]).write(to: fixture.fileURL, options: .atomic)
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        try Data("Start".utf8).write(to: fixture.fileURL, options: .atomic)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(received.isEmpty)

        try Data(Array("Start".utf8) + [0xC3, 0xA9])
            .write(to: fixture.fileURL, options: .atomic)
        XCTAssertTrue(waitUntil(timeout: 1) { received == ["Starté"] })
        monitor.stop()
    }

    private func append(_ text: String, to fileURL: URL) throws {
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func makeMonitor(
        fileURL: URL,
        initialText: String,
        changeHandler: @escaping ExternalFileMonitor.ChangeHandler
    ) -> ExternalFileMonitor {
        ExternalFileMonitor(
            fileURL: fileURL,
            initialText: initialText,
            timing: ExternalFileMonitor.ReloadTiming(
                appendDelay: .milliseconds(100),
                rewriteQuietPeriod: .milliseconds(160),
                maximumRewriteDelay: .milliseconds(450),
                stabilityInterval: .milliseconds(10),
                reconnectDelay: .milliseconds(50)
            ),
            changeHandler: changeHandler
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        condition: @escaping () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while condition() == false && RunLoop.current.run(mode: .default, before: deadline) && Date() < deadline {}
        return condition()
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

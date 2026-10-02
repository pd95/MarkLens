import Foundation
import Testing
@testable import MarkdownPipeline

@Suite("Wiki Link Resolution")
struct WikiLinkResolverTests {
    @Test func resolvesNamesAcrossSupportedExtensionsRecursively() throws {
        try withWiki { root in
            let nested = root.appendingPathComponent("Guides", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let target = nested.appendingPathComponent("Overview.markdown")
            try "# Overview".write(to: target, atomically: true, encoding: .utf8)

            let matches = try WikiLinkResolver().matches(for: "overview", in: root)
            #expect(matches == [target.standardizedFileURL.resolvingSymlinksInPath()])
        }
    }

    @Test func pathQualifiedTargetsAreRootRelative() throws {
        try withWiki { root in
            let nested = root.appendingPathComponent("Guides", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let target = nested.appendingPathComponent("Start.md")
            try "# Start".write(to: target, atomically: true, encoding: .utf8)

            let matches = try WikiLinkResolver().matches(for: "guides/start", in: root)
            #expect(matches.count == 1)
            #expect(WikiLinkResolver().relativePath(of: matches[0], in: root) == "Guides/Start.md")
        }
    }

    @Test func returnsDuplicateNamesInStablePathOrder() throws {
        try withWiki { root in
            for folder in ["Zeta", "Alpha"] {
                let directory = root.appendingPathComponent(folder, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try "# Note".write(
                    to: directory.appendingPathComponent("Note.md"),
                    atomically: true,
                    encoding: .utf8
                )
            }

            let matches = try WikiLinkResolver().matches(for: "Note", in: root)
            let paths = matches.map { WikiLinkResolver().relativePath(of: $0, in: root) }
            #expect(paths == ["Alpha/Note.md", "Zeta/Note.md"])
        }
    }

    @Test func rejectsTraversalAndIgnoresSymlinksOutsideRoot() throws {
        try withWiki { root in
            #expect(throws: WikiLinkResolverError.self) {
                try WikiLinkResolver().matches(for: "../Secret", in: root)
            }

            let outside = root.deletingLastPathComponent().appendingPathComponent("Outside.md")
            defer { try? FileManager.default.removeItem(at: outside) }
            try "# Outside".write(to: outside, atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("Outside.md"),
                withDestinationURL: outside
            )

            #expect(throws: WikiLinkResolverError.self) {
                try WikiLinkResolver().matches(for: "Outside", in: root)
            }
        }
    }

    @Test func cooperativelyCancelsRecursiveSearch() throws {
        try withWiki { root in
            try "# Note".write(
                to: root.appendingPathComponent("Note.md"),
                atomically: true,
                encoding: .utf8
            )

            #expect(throws: CancellationError.self) {
                try WikiLinkResolver().matches(
                    for: "Note",
                    in: root,
                    shouldCancel: { true }
                )
            }
        }
    }

    @Test func findsHeadingLinesWithFrontMatterAndDuplicateHeadings() throws {
        try withWiki { root in
            let target = root.appendingPathComponent("Transaction.md")
            try """
            ---
            title: Transaction
            ---
            # Overview
            ## Client Money Transfer Baseline
            ## Client Money Transfer Baseline
            """.write(to: target, atomically: true, encoding: .utf8)

            let resolver = WikiLinkResolver()
            #expect(try resolver.sourceLine(forHeading: "client-money-transfer-baseline", in: target) == 5)
            #expect(try resolver.sourceLine(forHeading: "client-money-transfer-baseline-1", in: target) == 6)
            #expect(throws: WikiLinkResolverError.self) {
                try resolver.sourceLine(forHeading: "missing-heading", in: target)
            }
        }
    }

    @Test func distinguishesNonLatinHeadings() throws {
        try withWiki { root in
            let target = root.appendingPathComponent("Notes.md")
            try "# 第一\n\n# 第二\n\n# Cafe\n\n# Café\n\n# 第一\n".write(
                to: target, atomically: true, encoding: .utf8
            )

            let resolver = WikiLinkResolver()
            #expect(try resolver.sourceLine(forHeading: "第一", in: target) == 1)
            #expect(try resolver.sourceLine(forHeading: "第二", in: target) == 3)
            #expect(try resolver.sourceLine(forHeading: "Café", in: target) == 7)
            #expect(try resolver.sourceLine(forHeading: "第一-1", in: target) == 9)
        }
    }

    private func withWiki(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikilink-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
}

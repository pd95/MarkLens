#if os(macOS)
import Foundation

enum ReleaseChangelog {
    private struct Section {
        let version: ReleaseVersion
        let markdown: String
    }

    static func missedChanges(
        in markdown: String,
        installedVersion: String,
        releaseTag: String
    ) -> String? {
        guard let installed = ReleaseVersion(installedVersion),
              let target = ReleaseVersion(baseVersion(from: releaseTag)) else {
            return nil
        }

        return joinedMarkdown(
            from: sections(in: markdown).filter {
                $0.version > installed && $0.version <= target
            }
        )
    }

    static func changes(in markdown: String, for releaseTag: String) -> String? {
        guard let target = ReleaseVersion(baseVersion(from: releaseTag)) else {
            return nil
        }
        return joinedMarkdown(
            from: sections(in: markdown).filter { $0.version == target }
        )
    }

    private static func sections(in markdown: String) -> [Section] {
        let lines = markdown.components(separatedBy: .newlines)
        var sections: [Section] = []
        var sectionStart: Int?
        var sectionVersion: ReleaseVersion?

        for index in lines.indices where isLevelTwoHeading(lines[index]) {
            appendSection(
                from: sectionStart,
                through: index,
                version: sectionVersion,
                lines: lines,
                to: &sections
            )
            sectionStart = index
            if let heading = headingVersion(lines[index]) {
                sectionVersion = ReleaseVersion(heading)
            } else {
                sectionVersion = nil
            }
        }

        appendSection(
            from: sectionStart,
            through: lines.endIndex,
            version: sectionVersion,
            lines: lines,
            to: &sections
        )

        return sections
    }

    private static func joinedMarkdown(from sections: [Section]) -> String? {
        guard sections.isEmpty == false else {
            return nil
        }
        return sections.map(\.markdown).joined(separator: "\n\n")
    }

    private static func appendSection(
        from start: Int?,
        through end: Int,
        version: ReleaseVersion?,
        lines: [String],
        to sections: inout [Section]
    ) {
        guard let start, let version else {
            return
        }
        let markdown = lines[start..<end]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard markdown.isEmpty == false else {
            return
        }
        sections.append(Section(version: version, markdown: markdown))
    }

    private static func isLevelTwoHeading(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("## ") || trimmed == "##"
    }

    private static func headingVersion(_ line: String) -> String? {
        var heading = line.trimmingCharacters(in: .whitespaces)
        guard heading.hasPrefix("##") else {
            return nil
        }
        heading.removeFirst(2)
        heading = heading.trimmingCharacters(in: .whitespaces)
        if heading.first == "[", heading.last == "]" {
            heading.removeFirst()
            heading.removeLast()
        }
        return heading.isEmpty ? nil : heading
    }

    private static func baseVersion(from tag: String) -> String {
        String(tag.split(separator: "-", maxSplits: 1).first ?? Substring(tag))
    }
}
#endif

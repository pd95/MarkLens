#if os(macOS)
import Foundation

/// Filters the canonical "Version <tag>" headings published by the release pipeline.
/// Work with attributed ranges so Sparkle's native Markdown formatting survives.
enum UpdateReleaseNotes {
    static func filter(
        _ text: NSAttributedString, installedVersion: String, targetVersion: String
    ) -> NSAttributedString {
        guard let installed = ReleaseVersion(installedVersion),
            let target = ReleaseVersion(String(targetVersion.split(separator: "-", maxSplits: 1).first ?? ""))
        else { return text }
        let string = text.string as NSString
        let fullRange = NSRange(location: 0, length: string.length)
        var headings: [(location: Int, version: ReleaseVersion)] = []
        // Foundation's native Markdown parser has no literal paragraph separators.
        // NSPresentationIntent bridges to Swift's PresentationIntent; the legacy
        // NSAttributedString key itself has no Swift static accessor.
        text.enumerateAttribute(NSAttributedString.Key("NSPresentationIntent"), in: fullRange) { value, range, _ in
            guard let intent = value as? PresentationIntent,
                intent.components.contains(where: {
                    if case .header(level: 2) = $0.kind { return true }
                    return false
                })
            else { return }
            let heading = string.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            guard heading.hasPrefix("Version "),
                let version = ReleaseVersion(String(heading.dropFirst("Version ".count)))
            else { return }
            headings.append((range.location, version))
        }
        if headings.isEmpty {
            // Also support Sparkle's already laid-out text and plain-text notes.
            let expression = try! NSRegularExpression(pattern: "(?m)^Version ([0-9][0-9A-Za-z.\\-]*)[ \\t]*\\r?$")
            headings = expression.matches(in: text.string, range: fullRange).compactMap { match in
                guard let version = ReleaseVersion(string.substring(with: match.range(at: 1))) else { return nil }
                return (match.range.location, version)
            }
        }
        guard !headings.isEmpty else { return text }
        let result = NSMutableAttributedString(string: "")
        var targetSection: NSAttributedString?
        for (index, heading) in headings.enumerated() {
            let end = index + 1 < headings.count ? headings[index + 1].location : string.length
            let section = text.attributedSubstring(
                from: NSRange(location: heading.location, length: end - heading.location))
            if heading.version == target { targetSection = section }
            if heading.version > installed && heading.version <= target { result.append(section) }
        }
        // RC-to-RC updates can share a changelog section; still show that release's notes.
        return result.length > 0 ? result : targetSection ?? text
    }
}
#endif

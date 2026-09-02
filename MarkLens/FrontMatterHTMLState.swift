import Foundation

enum FrontMatterHTMLState {
    private static let startMarker = "<!-- marklens-frontmatter:start -->"
    private static let endMarker = "<!-- marklens-frontmatter:end -->"
    private static let openingTag = "<details id=\"marklens-frontmatter\""

    static func applying(expanded: Bool, to html: String) -> String {
        guard let start = html.range(of: startMarker),
              let end = html.range(of: endMarker, range: start.upperBound..<html.endIndex) else {
            return html
        }
        let blockRange = start.lowerBound..<end.upperBound
        var block = String(html[blockRange])
        guard let tag = block.range(of: openingTag),
              let tagEnd = block[tag.upperBound...].firstIndex(of: ">") else {
            return html
        }
        var opening = String(block[tag.lowerBound...tagEnd])
        opening = opening.replacingOccurrences(of: " open>", with: ">")
        if expanded { opening.insert(contentsOf: " open", at: opening.index(before: opening.endIndex)) }
        block.replaceSubrange(tag.lowerBound...tagEnd, with: opening)
        var result = html
        result.replaceSubrange(blockRange, with: block)
        return result
    }

    static func removingFrontMatter(from html: String) -> String {
        guard let start = html.range(of: startMarker),
              let end = html.range(of: endMarker, range: start.upperBound..<html.endIndex) else {
            return html
        }
        var result = html
        result.removeSubrange(start.lowerBound..<end.upperBound)
        return result
    }
}

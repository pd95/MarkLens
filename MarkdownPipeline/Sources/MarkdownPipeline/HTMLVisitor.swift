import Foundation
import Markdown

extension String {
    func encodedHTMLEntities() -> String {
        self
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    func encodedHTMLAttribute() -> String {
        self
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

struct HTMLVisitor: MarkupVisitor {
    struct RenderResult {
        let html: String
        let filteredHTMLFragmentCount: Int
    }

    var skipParagraphTags = false
    var currentTable: Table?
    var currentColumnIndex = 0
    var headingIDCounts: [String: Int] = [:]
    var linkDepth = 0
    var filteredHTMLFragmentCount = 0
    let sourceLineOffset: Int
    let plugins: HTMLPluginCoordinator
    let context: PipelineContext

    init(
        sourceLineOffset: Int = 0,
        plugins: HTMLPluginCoordinator,
        context: PipelineContext
    ) {
        self.sourceLineOffset = sourceLineOffset
        self.plugins = plugins
        self.context = context
    }

    static func render(
        document: Document,
        sourceLineOffset: Int = 0,
        plugins: HTMLPluginCoordinator,
        context: PipelineContext
    ) -> RenderResult {
        var visitor = HTMLVisitor(
            sourceLineOffset: sourceLineOffset,
            plugins: plugins,
            context: context
        )
        let html = visitor.visit(document)
        return RenderResult(
            html: html,
            filteredHTMLFragmentCount: visitor.filteredHTMLFragmentCount
        )
    }

    mutating func defaultVisit(_ markup: any Markup) -> String {
        var result = ""
        for child in markup.children {
            result += visit(child)
        }
        return result
    }

    mutating func visitText(_ text: Text) -> String {
        plugins.renderText(text.plainText, allowsWikiLinks: linkDepth == 0)
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> String {
        if paragraph.childCount == 1,
           let text = paragraph.child(at: 0) as? Text,
           let rendered = plugins.renderStandaloneParagraph(text.plainText) {
            return addingSourceLine(to: rendered, for: paragraph)
        }
        var result: String
        let shouldSkipParagraph = skipParagraphTags
        if shouldSkipParagraph {
            skipParagraphTags = false
            result = ""
        } else {
            result = "<p\(sourceLineAttribute(for: paragraph))>"
        }

        for child in paragraph.children {
            result += visit(child)
        }

        if shouldSkipParagraph {
            result += "\n"
        } else {
            result += "</p>\n"
        }
        return result
    }

    mutating func visitStrong(_ strong: Strong) -> String {
        var result = "<strong>"
        for child in strong.children {
            result += visit(child)
        }
        result += "</strong>"
        return result
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) -> String {
        var result = "<em>"
        for child in emphasis.children {
            result += visit(child)
        }
        result += "</em>"
        return result
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> String {
        var result = "<del>"
        for child in strikethrough.children {
            result += visit(child)
        }
        result += "</del>"
        return result
    }

    mutating func visitLink(_ link: Link) -> String {
        let destination = sanitizedURL(plugins.restoreLiteral(link.destination ?? ""), fallback: "#")
            .encodedHTMLAttribute()
        var result = "<a href=\"\(destination)\">"
        linkDepth += 1
        for child in link.children {
            result += visit(child)
        }
        linkDepth -= 1
        result += "</a>"
        return result
    }

    mutating func visitImage(_ image: Image) -> String {
        let sanitizedSource = sanitizedImageURL(plugins.restoreLiteral(image.source ?? ""), fallback: "")
        let source = sanitizedSource.encodedHTMLAttribute()
        var result = "<img src=\"\(source)\""
        if isLocalImageURL(sanitizedSource),
           let capability = sanitizedSource.data(using: .utf8)?.base64EncodedString() {
            result += " data-marklens-local-image=\"\(capability)\""
        }

        if image.isEmpty == false {
            result += " alt=\""
            for child in image.children {
                if let plainTextMarkup = child as? PlainTextConvertibleMarkup {
                    result += plugins.restoreLiteral(plainTextMarkup.plainText).encodedHTMLAttribute()
                }
            }
            result += "\""
        }
        result += image.title.map { " title=\"\(plugins.restoreLiteral($0).encodedHTMLAttribute())\"" } ?? ""
        result += ">"
        return result
    }

    private func isLocalImageURL(_ raw: String) -> Bool {
        guard raw.isEmpty == false, raw.lowercased().hasPrefix("data:") == false else {
            return false
        }
        guard let scheme = urlScheme(from: raw) else {
            return true
        }
        return scheme.caseInsensitiveCompare("file") == .orderedSame
    }

    func visitInlineCode(_ inlineCode: InlineCode) -> String {
        let code = plugins.restoreLiteral(inlineCode.code)
        return "<code>\(code.encodedHTMLEntities())</code>"
    }

    func visitLineBreak(_ lineBreak: LineBreak) -> String {
        "<br>"
    }

    func visitSoftBreak(_ softBreak: SoftBreak) -> String {
        "\n"
    }

    func visitSymbolLink(_ symbolLink: SymbolLink) -> String {
        "<code>\(symbolLink.destination ?? "")</code>"
    }

    mutating func visitHeading(_ heading: Heading) -> String {
        let identifier = uniqueHeadingID(for: heading)
        var result = "<h\(heading.level) id=\"\(identifier.encodedHTMLAttribute())\"\(sourceLineAttribute(for: heading))>"
        for child in heading.children {
            result += visit(child)
        }
        result += "</h\(heading.level)>\n"
        return result
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
        if let rendered = plugins.renderCodeBlock(codeBlock) {
            return addingSourceLine(
                to: rendered,
                for: codeBlock,
                selectionLine: codeContentStartLine(for: codeBlock)
            )
        }

        let declaredLanguage = HLJSHighlighter.normalizedLanguageIdentifier(from: codeBlock.language)
        let metadata = CodeLanguageMetadata(
            identifier: declaredLanguage ?? CodeLanguageMetadata.plainTextIdentifier,
            source: declaredLanguage == nil ? .fallback : .explicit
        )
        let languageClass = "lang-\(metadata.identifier)".encodedHTMLAttribute()
        let sourceAttribute = sourceLineAttribute(
            for: codeBlock,
            selectionLine: codeContentStartLine(for: codeBlock)
        )
        var result = "<pre\(sourceAttribute)>"
            + "<code class=\"\(languageClass)\"\(metadata.htmlAttributes)>"
        result += plugins.restoreLiteral(codeBlock.code)
            .trimmingCharacters(in: .newlines)
            .encodedHTMLEntities()
        result += "\n</code></pre>\n"
        return result
    }

    func visitThematicBreak(_ thematicBreak: ThematicBreak) -> String {
        "<hr\(sourceLineAttribute(for: thematicBreak))>"
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> String {
        var result = "<blockquote\(sourceLineAttribute(for: blockQuote))>\n"
        for child in blockQuote.children {
            result += visit(child)
        }
        result += "</blockquote>\n"
        return result
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) -> String {
        var result = "<ol\(sourceLineAttribute(for: orderedList))>\n"
        for child in orderedList.listItems {
            result += visit(child)
        }
        result += "</ol>\n"
        return result
    }

    mutating func visitUnorderedList(_ orderedList: UnorderedList) -> String {
        var result = "<ul\(sourceLineAttribute(for: orderedList))>\n"
        for child in orderedList.listItems {
            result += visit(child)
        }
        result += "</ul>\n"
        return result
    }

    mutating func visitListItem(_ listItem: ListItem) -> String {
        var result = "<li\(sourceLineAttribute(for: listItem))>"

        if let checkbox = listItem.checkbox {
            result += "<input type=\"checkbox\" disabled\(checkbox == .checked ? " checked" : "")>"
        }
        skipParagraphTags = true
        for child in listItem.children {
            result += visit(child)
        }

        result += "</li>\n"
        return result
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) -> String {
        let rawHTML = plugins.restoreLiteral(html.rawHTML)
        var result = sanitizeRawHTML(rawHTML)
        result += "\n"
        return result
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> String {
        let rawHTML = plugins.restoreLiteral(inlineHTML.rawHTML)
        return sanitizeRawHTML(rawHTML)
    }

    private mutating func sanitizeRawHTML(_ rawHTML: String) -> String {
        let result = RawHTMLSanitizer(
            policy: context.rawHTMLPolicy,
            allowsRemoteResources: context.allowsRemoteResources
        ).sanitizeWithReport(rawHTML)
        if result.didFilter {
            filteredHTMLFragmentCount += 1
        }
        return result.html
    }

    mutating func visitTable(_ table: Table) -> String {
        let previousState = (table: currentTable, index: currentColumnIndex)
        currentTable = table

        var result = "<table\(sourceLineAttribute(for: table))>"
        for child in table.children {
            result += visit(child)
        }
        result += "</table>\n"

        currentTable = previousState.table
        currentColumnIndex = previousState.index
        return result
    }

    mutating func visitTableHead(_ head: Table.Head) -> String {
        var result = "<thead>"
        currentColumnIndex = 0
        for child in head.children {
            result += visit(child)
        }

        result += "</thead>\n"
        return result
    }

    mutating func visitTableBody(_ body: Table.Body) -> String {
        var result = "<tbody>"
        for child in body.children {
            result += visit(child)
        }

        result += "</tbody>\n"
        return result
    }

    mutating func visitTableRow(_ row: Table.Row) -> String {
        var result = "<tr\(sourceLineAttribute(for: row))>"

        currentColumnIndex = 0
        for child in row.children {
            result += visit(child)
        }

        result += "</tr>\n"
        return result
    }

    mutating func visitTableCell(_ cell: Table.Cell) -> String {
        var attributes = ""
        if cell.colspan > 1 {
            attributes += " colspan=\"\(cell.colspan)\""
        }
        if cell.rowspan > 1 {
            attributes += " rowspan=\"\(cell.rowspan)\""
        }
        if let alignment = currentTable?.columnAlignments[currentColumnIndex] {
            attributes += "  style=\"text-align:\(String(describing: alignment))\""
        }

        var result = "<td\(attributes)\(sourceLineAttribute(for: cell))>"
        for child in cell.children {
            result += visit(child)
        }

        currentColumnIndex += Int(cell.colspan)

        result += "</td>\n"
        return result
    }

    private func sourceLineAttribute(
        for markup: any Markup,
        selectionLine: Int? = nil
    ) -> String {
        guard let range = markup.range else { return "" }
        let line = range.lowerBound.line + sourceLineOffset
        let endLine = range.upperBound.line + sourceLineOffset
        var result = " data-marklens-source-line=\"\(line)\""
        if let selectionLine, selectionLine != line {
            result += " data-marklens-selection-line=\"\(selectionLine)\""
        }
        if endLine > line {
            result += " data-marklens-source-end-line=\"\(endLine)\""
        }
        return result
    }

    private func codeContentStartLine(for codeBlock: CodeBlock) -> Int? {
        guard let range = codeBlock.range else { return nil }
        let sourceLineCount = range.upperBound.line - range.lowerBound.line + 1
        let codeLineCount = max(1, codeBlock.code.components(separatedBy: "\n").count)
        let firstLine = range.lowerBound.line + sourceLineOffset
        return sourceLineCount > codeLineCount ? firstLine + 1 : firstLine
    }

    private func addingSourceLine(
        to html: String,
        for markup: any Markup,
        selectionLine: Int? = nil
    ) -> String {
        let attribute = sourceLineAttribute(for: markup, selectionLine: selectionLine)
        guard attribute.isEmpty == false,
              let tagEnd = html.firstIndex(of: ">") else {
            return html
        }

        var result = html
        result.insert(contentsOf: attribute, at: tagEnd)
        return result
    }

    private func sanitizedURL(_ raw: String?, fallback: String) -> String {
        guard let raw,
              let normalized = normalizedURL(raw),
              normalized.isEmpty == false else {
            return fallback
        }

        if let scheme = urlScheme(from: normalized),
           ["http", "https", "file"].contains(scheme.lowercased()) == false {
            return fallback
        }

        return normalized
    }

    private func sanitizedImageURL(_ raw: String?, fallback: String) -> String {
        guard let raw,
              let normalized = normalizedURL(raw),
              normalized.isEmpty == false else {
            return fallback
        }

        if normalized.lowercased().hasPrefix("data:") {
            return isAllowedImageDataURI(normalized) ? normalized : fallback
        }

        if normalized.hasPrefix("//") {
            guard context.allowsRemoteResources else { return fallback }
        } else if let scheme = urlScheme(from: normalized) {
            switch scheme.lowercased() {
            case "http", "https":
                guard context.allowsRemoteResources else { return fallback }
            case "file":
                guard context.allowsLocalResources else { return fallback }
            default:
                break
            }
        } else if context.allowsLocalResources == false {
            return fallback
        }

        return sanitizedURL(normalized, fallback: fallback)
    }

    private func normalizedURL(_ raw: String) -> String? {
        var scalars = raw.unicodeScalars.filter { ![9, 10, 13].contains($0.value) }
        while scalars.first?.value ?? 33 <= 32 { scalars.removeFirst() }
        while scalars.last?.value ?? 33 <= 32 { scalars.removeLast() }
        let normalized = String(String.UnicodeScalarView(scalars))
        guard let colon = normalized.firstIndex(of: ":") else { return normalized }
        if let terminator = normalized.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }),
           terminator < colon {
            return normalized
        }
        let prefix = normalized[..<colon]
        guard prefix.isEmpty == false,
              prefix.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }) else {
            return nil
        }
        return normalized
    }

    private func isAllowedImageDataURI(_ raw: String) -> Bool {
        let lowercased = raw.lowercased()
        guard lowercased.hasPrefix("data:image/") else {
            return false
        }

        let allowedTypes = [
            "image/png",
            "image/jpeg",
            "image/gif",
            "image/webp"
        ]

        let headerEnd = lowercased.firstIndex(of: ",")
        guard let headerEnd else {
            return false
        }

        let header = String(lowercased[..<headerEnd])
        guard header.contains(";base64") else {
            return false
        }

        return allowedTypes.contains { header.hasPrefix("data:\($0)") }
    }

    private func urlScheme(from raw: String) -> String? {
        if let range = raw.range(of: "://") {
            return String(raw[..<range.lowerBound])
        }

        if let colonRange = raw.range(of: ":") {
            let prefix = raw[..<colonRange.lowerBound]
            if let terminatorIndex = raw.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }),
               terminatorIndex < colonRange.lowerBound {
                return nil
            }
            return String(prefix)
        }

        return nil
    }

    private mutating func uniqueHeadingID(for heading: Heading) -> String {
        let headingText = plugins.restoreLiteral(heading.plainText)
        let base = slugifiedHeadingID(from: headingText)
        let count = headingIDCounts[base, default: 0]
        let identifier = count == 0 ? base : "\(base)-\(count)"
        headingIDCounts[base] = count + 1
        return identifier
    }

    private func slugifiedHeadingID(from text: String) -> String {
        let lowercase = text.lowercased()
        var slug = ""
        var needsDash = false

        for scalar in lowercase.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                if needsDash && slug.isEmpty == false {
                    slug.append("-")
                }
                needsDash = false
                slug.append(Character(scalar))
            } else {
                needsDash = true
            }
        }

        if slug.isEmpty {
            return "section"
        }

        return slug
    }
}

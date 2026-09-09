import Foundation

enum FrontMatterRenderer {
    static let startMarker = "<!-- marklens-frontmatter:start -->"
    static let endMarker = "<!-- marklens-frontmatter:end -->"

    static func render(_ frontMatter: FrontMatter, plugins: HTMLPluginCoordinator) -> String {
        let summaryTitle = frontMatter.title.map {
            let source = frontMatter.titleLine.map(sourceAttribute) ?? ""
            return "<span class=\"frontmatter-summary-title\"\(source)>\($0.encodedHTMLEntities())</span>"
        } ?? ""
        let count = entryCount(frontMatter.root)
        let countLabel = count == 1 ? "1 entry" : "\(count) entries"
        var result = "\(startMarker)\n"
        result += "<details id=\"marklens-frontmatter\" class=\"frontmatter-card"
        if frontMatter.parseError != nil { result += " frontmatter-invalid" }
        result += "\">\n"
        result += "<summary data-marklens-source-line=\"1\">"
        result += "<span class=\"frontmatter-disclosure\" aria-hidden=\"true\"></span>"
        result += "<span class=\"frontmatter-summary-label\">Document details</span>"
        result += summaryTitle
        result += "<span class=\"frontmatter-summary-count\">\(countLabel)</span>"
        result += "</summary>\n<div class=\"frontmatter-content\">\n"

        if let error = frontMatter.parseError {
            result += "<p class=\"frontmatter-error\">Unable to parse: \(error.encodedHTMLEntities())</p>\n"
            let rawEndLine = max(2, frontMatter.raw.components(separatedBy: "\n").count + 1)
            result += "<pre class=\"frontmatter-raw\"\(sourceRangeAttribute(line: 2, endLine: rawEndLine))><code>"
            result += frontMatter.raw.encodedHTMLEntities()
            result += "</code></pre>\n"
        } else if let root = frontMatter.root {
            result += renderRoot(root, plugins: plugins)
        } else {
            result += "<p class=\"frontmatter-empty\">No values</p>\n"
        }

        result += "</div>\n</details>\n\(endMarker)\n"
        return result
    }

    private static func entryCount(_ value: FrontMatterValue?) -> Int {
        switch value {
        case .mapping(let pairs, _): pairs.count
        case .sequence(let values, _): values.count
        case .scalar, .blockString: 1
        case nil: 0
        }
    }

    private static func renderRoot(
        _ root: FrontMatterValue,
        plugins: HTMLPluginCoordinator
    ) -> String {
        switch root {
        case .mapping(let pairs, _):
            return pairs.map { renderPair($0, plugins: plugins) }.joined()
        default:
            return "<div class=\"frontmatter-generic-root\">\(renderValue(root, plugins: plugins))</div>\n"
        }
    }

    private static func renderPair(
        _ pair: FrontMatterPair,
        plugins: HTMLPluginCoordinator
    ) -> String {
        let kind = recognizedKind(for: pair.key, value: pair.value)
        let source = sourceAttribute(pair.keyLine)
        switch kind {
        case .title:
            return "<div class=\"frontmatter-print-title\">\(renderInlineValue(pair.value, plugins: plugins))</div>\n"
        case .prose:
            return "<div class=\"frontmatter-prose\"\(source)><div class=\"frontmatter-label\">\(displayLabel(pair.key))</div>\(renderInlineValue(pair.value, plugins: plugins))</div>\n"
        case .chips:
            return "<div class=\"frontmatter-field frontmatter-chip-field\"\(source)><div class=\"frontmatter-label\">\(displayLabel(pair.key))</div>\(renderChips(pair.value, plugins: plugins))</div>\n"
        case .questions:
            return "<div class=\"frontmatter-field frontmatter-questions\"\(source)><div class=\"frontmatter-label\">\(displayLabel(pair.key))</div>\(renderSequenceAsList(pair.value, plugins: plugins))</div>\n"
        case .status:
            return "<div class=\"frontmatter-field frontmatter-compact-field\"\(source)><span class=\"frontmatter-label\">\(displayLabel(pair.key))</span><span class=\"frontmatter-status\">\(renderInlineValue(pair.value, plugins: plugins))</span></div>\n"
        case .date, .authors:
            return "<div class=\"frontmatter-field frontmatter-compact-field\"\(source)><span class=\"frontmatter-label\">\(displayLabel(pair.key))</span>\(renderInlineValue(pair.value, plugins: plugins))</div>\n"
        case .generic:
            return "<div class=\"frontmatter-field\"\(source)><div class=\"frontmatter-label\">\(displayLabel(pair.key))</div>\(renderValue(pair.value, plugins: plugins))</div>\n"
        }
    }

    private static func renderValue(
        _ value: FrontMatterValue,
        plugins: HTMLPluginCoordinator
    ) -> String {
        switch value {
        case .scalar(let scalar, _):
            return renderScalar(scalar, plugins: plugins)
        case .blockString(_, let sourceLines, let style, let chomping, let line, let endLine):
            return renderBlockString(
                sourceLines,
                style: style,
                chomping: chomping,
                line: line,
                endLine: endLine,
                plugins: plugins
            )
        case .sequence:
            return renderSequenceAsList(value, plugins: plugins)
        case .mapping(let pairs, _):
            var result = "<dl class=\"frontmatter-map\">\n"
            for pair in pairs {
                result += "<div class=\"frontmatter-map-entry\"\(sourceAttribute(pair.keyLine))>"
                result += "<dt>\(displayLabel(pair.key))</dt><dd>\(renderValue(pair.value, plugins: plugins))</dd></div>\n"
            }
            return result + "</dl>\n"
        }
    }

    private static func renderInlineValue(
        _ value: FrontMatterValue,
        plugins: HTMLPluginCoordinator
    ) -> String {
        switch value {
        case .scalar(let scalar, _): renderScalar(scalar, plugins: plugins)
        case .blockString: renderValue(value, plugins: plugins)
        default: renderValue(value, plugins: plugins)
        }
    }

    private static func renderScalar(
        _ scalar: FrontMatterScalar,
        plugins: HTMLPluginCoordinator
    ) -> String {
        let className: String
        switch scalar {
        case .string: className = "frontmatter-string"
        case .boolean: className = "frontmatter-boolean"
        case .integer, .number: className = "frontmatter-number"
        case .null: className = "frontmatter-null"
        }
        let content: String
        if case .string(let value) = scalar {
            content = plugins.renderText(value, allowsWikiLinks: true)
        } else {
            content = scalar.displayText.encodedHTMLEntities()
        }
        return "<span class=\"\(className)\">\(content)</span>"
    }

    private static func renderBlockString(
        _ sourceLines: [FrontMatterBlockLine],
        style: Character,
        chomping: Character?,
        line: Int,
        endLine: Int,
        plugins: HTMLPluginCoordinator
    ) -> String {
        var displayedLines = sourceLines
        if chomping != "+" {
            while displayedLines.last?.text.isEmpty == true { displayedLines.removeLast() }
        }
        var content = ""
        for (offset, sourceLine) in displayedLines.enumerated() {
            if offset > 0 {
                let previous = displayedLines[offset - 1].text
                content += style == ">" && previous.isEmpty == false && sourceLine.text.isEmpty == false
                    ? " " : "\n"
            }
            content += "<span data-marklens-source-line=\"\(sourceLine.sourceLine)\">"
            content += plugins.renderText(sourceLine.text, allowsWikiLinks: true)
            content += "</span>"
        }
        if displayedLines.isEmpty == false, chomping != "-" { content += "\n" }
        return "<span class=\"frontmatter-string\"\(sourceRangeAttribute(line: line, endLine: endLine))>\(content)</span>"
    }

    private static func renderSequenceAsList(
        _ value: FrontMatterValue,
        plugins: HTMLPluginCoordinator
    ) -> String {
        guard case .sequence(let values, _) = value else {
            return renderInlineValue(value, plugins: plugins)
        }
        var result = "<ul class=\"frontmatter-list\">\n"
        for item in values {
            result += "<li\(sourceAttribute(item.line))>\(renderValue(item, plugins: plugins))</li>\n"
        }
        return result + "</ul>\n"
    }

    private static func renderChips(
        _ value: FrontMatterValue,
        plugins: HTMLPluginCoordinator
    ) -> String {
        let values: [FrontMatterValue]
        if case .sequence(let sequence, _) = value { values = sequence } else { values = [value] }
        var result = "<ul class=\"frontmatter-chips\">\n"
        for item in values {
            result += "<li\(sourceAttribute(item.line))>\(renderInlineValue(item, plugins: plugins))</li>\n"
        }
        return result + "</ul>\n"
    }

    private enum Kind { case title, prose, chips, questions, status, date, authors, generic }

    private static func recognizedKind(for key: String, value: FrontMatterValue) -> Kind {
        switch normalizedKey(key) {
        case "title": .title
        case "summary", "description": .prose
        case "tags", "categories", "keywords": .chips
        case "questions": .questions
        case "status", "draft", "published": .status
        case "author", "authors": .authors
        case "date", "created", "createdat", "updated", "updatedat", "lastmod", "reviewedat", "publishedat": .date
        default: .generic
        }
    }

    private static func normalizedKey(_ key: String) -> String {
        key.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func displayLabel(_ key: String) -> String {
        switch normalizedKey(key) {
        case "reviewedat": return "Reviewed"
        case "createdat": return "Created"
        case "updatedat", "lastmod": return "Updated"
        case "publishedat": return "Published"
        default: break
        }
        var result = ""
        var previousWasLowercase = false
        for character in key {
            if character == "_" || character == "-" {
                if result.last != " " { result.append(" ") }
                previousWasLowercase = false
            } else {
                if character.isUppercase, previousWasLowercase { result.append(" ") }
                result.append(character)
                previousWasLowercase = character.isLowercase || character.isNumber
            }
        }
        let cleaned = result.trimmingCharacters(in: .whitespaces)
        return (cleaned.prefix(1).uppercased() + cleaned.dropFirst()).encodedHTMLEntities()
    }

    private static func sourceAttribute(_ line: Int) -> String {
        " data-marklens-source-line=\"\(line)\""
    }

    private static func sourceRangeAttribute(line: Int, endLine: Int) -> String {
        var result = sourceAttribute(line)
        if endLine > line { result += " data-marklens-source-end-line=\"\(endLine)\"" }
        return result
    }
}

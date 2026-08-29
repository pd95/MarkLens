import Foundation

struct RawHTMLSanitizer {
    struct SanitizationResult {
        let html: String
        let didModify: Bool
    }

    private static let allowedTags: Set<String> = [
        "a", "abbr", "b", "blockquote", "br", "caption", "cite", "code", "col", "colgroup",
        "dd", "del", "details", "div", "dl", "dt", "em", "figcaption", "figure", "h1", "h2",
        "h3", "h4", "h5", "h6", "hr", "i", "img", "kbd", "li", "mark", "ol", "p", "pre",
        "q", "s", "samp", "small", "span", "strong", "sub", "summary", "sup", "table", "tbody",
        "td", "tfoot", "th", "thead", "tr", "ul", "var",
    ]
    private static let globalAttributes: Set<String> = [
        "aria-label", "aria-describedby", "aria-hidden", "class", "dir", "id", "lang", "role", "title",
    ]
    private static let reservedClasses: Set<String> = [
        "code-block", "code-block-controls", "code-block-header", "code-collapse-btn",
        "code-expand-btn", "code-language-badge", "code-reveal-btn", "copy-btn", "hljs",
        "katex", "math", "mermaid-block", "mermaid-error", "mermaid-source",
    ]
    private static let attributeRegex = try! NSRegularExpression(
        pattern: #"(?i)([a-z_:][a-z0-9_.:-]*)(?:\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+)))?"#
    )

    let policy: PipelineContext.RawHTMLPolicy
    let allowsRemoteResources: Bool

    func sanitize(_ html: String) -> String {
        sanitizeWithReport(html).html
    }

    func sanitizeWithReport(_ html: String) -> SanitizationResult {
        guard policy == .sanitized else {
            let sanitized = html.encodedHTMLEntities()
            return SanitizationResult(html: sanitized, didModify: sanitized != html)
        }
        var output = ""
        var cursor = html.startIndex
        while cursor < html.endIndex {
            guard html[cursor] == "<" else {
                output.append(html[cursor])
                cursor = html.index(after: cursor)
                continue
            }
            guard let end = tagEnd(in: html, from: cursor) else {
                output += String(html[cursor...]).encodedHTMLEntities()
                break
            }
            let token = String(html[cursor...end])
            output += sanitizedTag(token) ?? escapedTagWithoutAttributes(token)
            cursor = html.index(after: end)
        }
        return SanitizationResult(html: output, didModify: output != html)
    }

    private func escapedTagWithoutAttributes(_ token: String) -> String {
        var body = token.dropFirst().dropLast()[...]
        body = body.drop(while: { $0.isWhitespace })
        let isClosing = body.first == "/"
        if isClosing { body = body.dropFirst().drop(while: { $0.isWhitespace }) }
        let nameEnd = body.firstIndex(where: { !$0.isLetter && !$0.isNumber }) ?? body.endIndex
        guard nameEnd != body.startIndex else { return token.encodedHTMLEntities() }
        let name = body[..<nameEnd].lowercased()
        return (isClosing ? "</\(name)>" : "<\(name)>").encodedHTMLEntities()
    }

    private func tagEnd(in html: String, from start: String.Index) -> String.Index? {
        var quote: Character?
        var index = html.index(after: start)
        while index < html.endIndex {
            let character = html[index]
            if let activeQuote = quote {
                if character == activeQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return index
            }
            index = html.index(after: index)
        }
        return nil
    }

    private func sanitizedTag(_ token: String) -> String? {
        var body = token.dropFirst().dropLast()[...]
        body = body.drop(while: { $0.isWhitespace })
        let isClosing = body.first == "/"
        if isClosing { body = body.dropFirst().drop(while: { $0.isWhitespace }) }
        let nameEnd = body.firstIndex(where: { !$0.isLetter && !$0.isNumber }) ?? body.endIndex
        guard nameEnd != body.startIndex else { return nil }
        let name = body[..<nameEnd].lowercased()
        guard Self.allowedTags.contains(name) else { return nil }
        if isClosing { return "</\(name)>" }

        let selfClosing = body.drop(while: { $0.isWhitespace }).last == "/"
        return "<\(name)\(parseAttributes(body[nameEnd...], tag: name))\(selfClosing ? " /" : "")>"
    }

    private func parseAttributes(_ source: Substring, tag: String) -> String {
        let text = String(source)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return Self.attributeRegex.matches(in: text, range: range).compactMap { match -> String? in
            guard let nameRange = Range(match.range(at: 1), in: text) else { return nil }
            let name = text[nameRange].lowercased()
            guard allowedAttribute(name, on: tag) else { return nil }
            let value = (2...4).compactMap { index -> String? in
                guard match.range(at: index).location != NSNotFound,
                      let valueRange = Range(match.range(at: index), in: text) else { return nil }
                return String(text[valueRange])
            }.first ?? ""
            guard let sanitized = sanitizedAttributeValue(value, name: name, tag: tag) else { return nil }
            return " \(name)=\"\(sanitized.encodedHTMLAttribute())\""
        }.joined()
    }

    private func allowedAttribute(_ name: String, on tag: String) -> Bool {
        if Self.globalAttributes.contains(name) { return true }
        if name.hasPrefix("data-") { return name.hasPrefix("data-marklens-") == false }
        switch tag {
        case "a": return name == "href"
        case "img": return ["src", "alt", "width", "height", "loading"].contains(name)
        case "ol": return ["start", "reversed"].contains(name)
        case "li": return name == "value"
        case "td", "th": return ["colspan", "rowspan", "scope", "headers"].contains(name)
        case "col", "colgroup": return name == "span"
        default: return false
        }
    }

    private func sanitizedAttributeValue(_ value: String, name: String, tag: String) -> String? {
        if name == "id" { return value.lowercased().hasPrefix("marklens") ? nil : value }
        if name == "class" {
            let classes = value.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard classes.allSatisfy({ !Self.reservedClasses.contains($0.lowercased()) && !$0.lowercased().hasPrefix("marklens") }) else {
                return nil
            }
            return classes.joined(separator: " ")
        }
        guard name == "href" || name == "src" else { return value }
        let normalized = normalizedURL(value)
        guard normalized.isEmpty == false else { return nil }
        if normalized.hasPrefix("//") {
            return name == "href" || allowsRemoteResources ? normalized : nil
        }
        guard let scheme = scheme(in: normalized) else {
            if hasSchemeDelimiter(in: normalized) { return nil }
            return name == "href" ? normalized : nil
        }
        switch scheme {
        case "http", "https": return name == "href" || allowsRemoteResources ? normalized : nil
        case "file": return name == "href" ? normalized : nil
        case "data": return tag == "img" && allowedImageDataURL(normalized) ? normalized : nil
        default: return nil
        }
    }

    private func normalizedURL(_ value: String) -> String {
        var scalars = value.unicodeScalars.filter { ![9, 10, 13].contains($0.value) }
        while scalars.first?.value ?? 33 <= 32 { scalars.removeFirst() }
        while scalars.last?.value ?? 33 <= 32 { scalars.removeLast() }
        return String(String.UnicodeScalarView(scalars))
    }

    private func scheme(in value: String) -> String? {
        guard let colon = value.firstIndex(of: ":") else { return nil }
        if let terminator = value.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }),
           terminator < colon {
            return nil
        }
        let prefix = value[..<colon]
        guard prefix.isEmpty == false,
              prefix.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }) else { return nil }
        return prefix.lowercased()
    }

    private func hasSchemeDelimiter(in value: String) -> Bool {
        guard let colon = value.firstIndex(of: ":") else { return false }
        guard let terminator = value.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) else {
            return true
        }
        return colon < terminator
    }

    private func allowedImageDataURL(_ value: String) -> Bool {
        let lower = value.lowercased()
        return ["png", "jpeg", "gif", "webp"].contains { lower.hasPrefix("data:image/\($0);base64,") }
    }
}

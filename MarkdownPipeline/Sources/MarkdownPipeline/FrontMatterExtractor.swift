import Foundation

indirect enum FrontMatterValue: Equatable {
    case mapping([FrontMatterPair], line: Int)
    case sequence([FrontMatterValue], line: Int)
    case scalar(FrontMatterScalar, line: Int)
    case blockString(
        String,
        sourceLines: [FrontMatterBlockLine],
        style: Character,
        chomping: Character?,
        line: Int,
        endLine: Int
    )

    var line: Int {
        switch self {
        case .mapping(_, let line), .sequence(_, let line), .scalar(_, let line),
             .blockString(_, _, _, _, let line, _): line
        }
    }

    var stringValue: String? {
        switch self {
        case .scalar(.string(let value), _), .blockString(let value, _, _, _, _, _): value
        default: nil
        }
    }
}

struct FrontMatterBlockLine: Equatable {
    let text: String
    let sourceLine: Int
}

struct FrontMatterPair: Equatable {
    let key: String
    let keyLine: Int
    let value: FrontMatterValue
}

enum FrontMatterScalar: Equatable {
    case string(String)
    case boolean(Bool)
    case integer(String)
    case number(String)
    case null

    var displayText: String {
        switch self {
        case .string(let value), .integer(let value), .number(let value): value
        case .boolean(let value): value ? "true" : "false"
        case .null: "null"
        }
    }
}

struct FrontMatter {
    let raw: String
    let root: FrontMatterValue?
    let parseError: String?
    let fallbackTitle: String?
    let fallbackTitleLine: Int?
    let fallbackTheme: String?

    var title: String? { topLevelString(for: "title") ?? fallbackTitle }
    var titleLine: Int? { topLevelPair(for: "title")?.keyLine ?? fallbackTitleLine }
    var theme: String? { topLevelString(for: "theme") ?? fallbackTheme }

    private func topLevelString(for requestedKey: String) -> String? {
        topLevelPair(for: requestedKey)?.value.stringValue
    }

    private func topLevelPair(for requestedKey: String) -> FrontMatterPair? {
        guard case .mapping(let pairs, _) = root else { return nil }
        return pairs.reversed().first {
            $0.key.caseInsensitiveCompare(requestedKey) == .orderedSame
        }
    }
}

struct FrontMatterExtractor {
    func extract(from markdown: String) -> (
        frontMatter: FrontMatter?,
        bodyMarkdown: String,
        bodyLineOffset: Int
    ) {
        let normalizedMarkdown = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalizedMarkdown.components(separatedBy: "\n")
        guard lines.first == "---" else { return (nil, markdown, 0) }
        guard let closingIndex = lines.dropFirst().firstIndex(of: "---") else {
            return (nil, markdown, 0)
        }

        let frontMatterLines = Array(lines[1..<closingIndex])
        let raw = frontMatterLines.joined(separator: "\n")
        let fallbackTitle = Self.fallbackString(for: "title", in: frontMatterLines)
        let fallbackTheme = Self.fallbackString(for: "theme", in: frontMatterLines)
        let frontMatter: FrontMatter
        do {
            var parser = FrontMatterParser(lines: frontMatterLines)
            frontMatter = FrontMatter(
                raw: raw,
                root: try parser.parse(),
                parseError: nil,
                fallbackTitle: fallbackTitle?.value,
                fallbackTitleLine: fallbackTitle?.line,
                fallbackTheme: fallbackTheme?.value
            )
        } catch let error as FrontMatterParseError {
            frontMatter = FrontMatter(
                raw: raw,
                root: nil,
                parseError: error.description,
                fallbackTitle: fallbackTitle?.value,
                fallbackTitleLine: fallbackTitle?.line,
                fallbackTheme: fallbackTheme?.value
            )
        } catch {
            frontMatter = FrontMatter(
                raw: raw,
                root: nil,
                parseError: "Unable to parse frontmatter.",
                fallbackTitle: fallbackTitle?.value,
                fallbackTitleLine: fallbackTitle?.line,
                fallbackTheme: fallbackTheme?.value
            )
        }
        return (
            frontMatter,
            Array(lines[(closingIndex + 1)...]).joined(separator: "\n"),
            closingIndex + 1
        )
    }

    private static func fallbackString(
        for requestedKey: String,
        in lines: [String]
    ) -> (value: String, line: Int)? {
        for (offset, line) in lines.enumerated().reversed() {
            guard line.first?.isWhitespace != true,
                  let colon = line.firstIndex(of: ":"),
                  line[..<colon].trimmingCharacters(in: .whitespaces)
                    .caseInsensitiveCompare(requestedKey) == .orderedSame else { continue }
            let rawValue = fallbackValueText(
                String(line[line.index(after: colon)...])
            ).trimmingCharacters(in: .whitespaces)
            guard rawValue.isEmpty == false else { continue }
            var parser = FlowValueParser(text: rawValue, line: offset + 2)
            guard let value = try? parser.parse(), let string = value.stringValue else { continue }
            return (string, offset + 2)
        }
        return nil
    }

    private static func fallbackValueText(_ text: String) -> String {
        var quote: Character?
        var escaped = false
        var previous: Character?
        for position in text.indices {
            let character = text[position]
            if quote == "\"", escaped { escaped = false; previous = character; continue }
            if quote == "\"", character == "\\" { escaped = true; previous = character; continue }
            if let activeQuote = quote {
                if character == activeQuote { quote = nil }
                previous = character
                continue
            }
            if character == "\"" || character == "'" { quote = character; previous = character; continue }
            if character == "#", previous?.isWhitespace != false { return String(text[..<position]) }
            previous = character
        }
        return text
    }
}

private struct FrontMatterParseError: Error, CustomStringConvertible {
    let line: Int?
    let message: String
    var description: String { line.map { "Line \($0): \(message)" } ?? message }
}

private struct FrontMatterParser {
    private let lines: [String]
    private var index = 0
    private var nodeCount = 0
    private static let maximumDepth = 64
    private static let maximumNodes = 100_000

    init(lines: [String]) { self.lines = lines }

    mutating func parse() throws -> FrontMatterValue? {
        try rejectUnsupportedDocumentSyntax()
        skipTrivia()
        guard index < lines.count else { return nil }
        guard try indentation(at: index) == 0 else {
            throw failure("The first value must not be indented.", at: index)
        }
        let value = try parseBlock(indent: 0, depth: 0)
        skipTrivia()
        guard index == lines.count else {
            throw failure("Unexpected content after the frontmatter value.", at: index)
        }
        return value
    }

    private mutating func parseBlock(indent: Int, depth: Int) throws -> FrontMatterValue {
        guard depth <= Self.maximumDepth else {
            throw failure("Frontmatter nesting exceeds \(Self.maximumDepth) levels.", at: index)
        }
        skipTrivia()
        guard index < lines.count, try indentation(at: index) == indent else {
            throw failure("Unexpected indentation.", at: index)
        }
        let content = String(lines[index].dropFirst(indent))
        return try isSequenceIndicator(content)
            ? parseSequence(indent: indent, depth: depth)
            : parseMapping(indent: indent, depth: depth)
    }

    private mutating func parseMapping(indent: Int, depth: Int) throws -> FrontMatterValue {
        let firstLine = index + 2
        var pairs: [FrontMatterPair] = []
        while true {
            skipTrivia()
            guard index < lines.count else { break }
            let lineIndent = try indentation(at: index)
            if lineIndent < indent { break }
            guard lineIndent == indent else {
                throw failure("Unexpected indentation after a mapping value.", at: index)
            }
            let content = String(lines[index].dropFirst(indent))
            if isSequenceIndicator(content) { break }
            pairs.append(try parseMappingEntry(content, indent: indent, depth: depth))
        }
        guard pairs.isEmpty == false else { throw failure("Expected a key and value.", at: index) }
        return try register(.mapping(pairs, line: firstLine))
    }

    private mutating func parseMappingEntry(
        _ content: String,
        indent: Int,
        depth: Int
    ) throws -> FrontMatterPair {
        let entryIndex = index
        let sourceLine = entryIndex + 2
        guard let colon = structuralColon(in: content) else {
            throw failure("Expected ':' after a mapping key.", at: entryIndex)
        }
        let rawKey = String(content[..<colon]).trimmingCharacters(in: .whitespaces)
        guard rawKey.isEmpty == false else { throw failure("Mapping keys cannot be empty.", at: entryIndex) }
        let key = try parseKey(rawKey, line: sourceLine)
        let rawValue = String(content[content.index(after: colon)...])
        let valueText = stripComment(rawValue).trimmingCharacters(in: .whitespaces)
        index += 1

        let value: FrontMatterValue
        if let first = valueText.first, first == "|" || first == ">",
           isBlockScalarHeader(valueText) == false {
            throw FrontMatterParseError(
                line: sourceLine,
                message: "Explicit block-scalar indentation indicators are not supported."
            )
        }
        if isBlockScalarHeader(valueText) {
            value = try parseBlockScalar(header: valueText, parentIndent: indent, line: sourceLine)
        } else if valueText.isEmpty {
            value = try parseNestedValue(parentIndent: indent, depth: depth + 1, fallbackLine: sourceLine)
        } else {
            value = try parseFlow(valueText, line: sourceLine)
        }
        return FrontMatterPair(key: key, keyLine: sourceLine, value: value)
    }

    private mutating func parseSequence(indent: Int, depth: Int) throws -> FrontMatterValue {
        let firstLine = index + 2
        var values: [FrontMatterValue] = []
        while true {
            skipTrivia()
            guard index < lines.count else { break }
            let lineIndent = try indentation(at: index)
            if lineIndent < indent { break }
            guard lineIndent == indent else {
                throw failure("Unexpected indentation after a sequence item.", at: index)
            }
            let content = String(lines[index].dropFirst(indent))
            guard isSequenceIndicator(content) else { break }
            let sourceLine = index + 2
            let remainder = stripComment(String(content.dropFirst()).trimmingCharacters(in: .whitespaces))
                .trimmingCharacters(in: .whitespaces)
            index += 1

            if remainder.isEmpty {
                values.append(try parseNestedValue(
                    parentIndent: indent,
                    depth: depth + 1,
                    fallbackLine: sourceLine
                ))
            } else if let first = remainder.first, first == "|" || first == ">",
                      isBlockScalarHeader(remainder) == false {
                throw FrontMatterParseError(
                    line: sourceLine,
                    message: "Explicit block-scalar indentation indicators are not supported."
                )
            } else if isBlockScalarHeader(remainder) {
                values.append(try parseBlockScalar(
                    header: remainder,
                    parentIndent: indent,
                    line: sourceLine
                ))
            } else if let colon = sequenceMappingColon(in: remainder) {
                values.append(try parseSequenceMapping(
                    firstContent: remainder,
                    colon: colon,
                    sequenceIndent: indent,
                    depth: depth + 1,
                    line: sourceLine
                ))
            } else {
                values.append(try parseFlow(remainder, line: sourceLine).withLine(sourceLine))
            }
        }
        return try register(.sequence(values, line: firstLine))
    }

    private mutating func parseSequenceMapping(
        firstContent: String,
        colon: String.Index,
        sequenceIndent: Int,
        depth: Int,
        line: Int
    ) throws -> FrontMatterValue {
        let key = try parseKey(
            String(firstContent[..<colon]).trimmingCharacters(in: .whitespaces),
            line: line
        )
        let remainder = stripComment(String(firstContent[firstContent.index(after: colon)...]))
            .trimmingCharacters(in: .whitespaces)
        let mappingIndent = sequenceIndent + 2
        let firstValue: FrontMatterValue
        if remainder.isEmpty {
            firstValue = try parseNestedValue(
                parentIndent: mappingIndent,
                depth: depth + 1,
                fallbackLine: line
            )
        } else if let first = remainder.first, first == "|" || first == ">",
                  isBlockScalarHeader(remainder) == false {
            throw FrontMatterParseError(
                line: line,
                message: "Explicit block-scalar indentation indicators are not supported."
            )
        } else if isBlockScalarHeader(remainder) {
            firstValue = try parseBlockScalar(
                header: remainder,
                parentIndent: mappingIndent,
                line: line
            )
        } else {
            firstValue = try parseFlow(remainder, line: line)
        }
        var pairs = [FrontMatterPair(key: key, keyLine: line, value: firstValue)]

        let afterFirstValue = index
        skipTrivia()
        if index < lines.count {
            let childIndent = try indentation(at: index)
            if childIndent > sequenceIndent {
                let childContent = String(lines[index].dropFirst(childIndent))
                if isSequenceIndicator(childContent) == false,
                   case .mapping(let additional, _) = try parseMapping(indent: childIndent, depth: depth) {
                    pairs.append(contentsOf: additional)
                }
            } else {
                index = afterFirstValue
            }
        }
        return try register(.mapping(pairs, line: line))
    }

    private mutating func parseNestedValue(
        parentIndent: Int,
        depth: Int,
        fallbackLine: Int
    ) throws -> FrontMatterValue {
        let beforeTrivia = index
        skipTrivia()
        guard index < lines.count else { return try register(.scalar(.null, line: fallbackLine)) }
        let childIndent = try indentation(at: index)
        guard childIndent > parentIndent else {
            index = beforeTrivia
            return try register(.scalar(.null, line: fallbackLine))
        }
        return try parseBlock(indent: childIndent, depth: depth)
    }

    private mutating func parseBlockScalar(
        header: String,
        parentIndent: Int,
        line: Int
    ) throws -> FrontMatterValue {
        let style = header.first!
        let chomping = header.dropFirst().first
        var collected: [(indent: Int, text: String, sourceLine: Int)] = []
        while index < lines.count {
            let raw = lines[index]
            if raw.isEmpty {
                collected.append((parentIndent + 1, "", index + 2))
                index += 1
                continue
            }
            let indent = try indentation(at: index)
            guard indent > parentIndent else { break }
            collected.append((indent, raw, index + 2))
            index += 1
        }
        let contentIndent = collected.filter { $0.text.isEmpty == false }.map(\.indent).min()
            ?? parentIndent + 1
        let contentLines = collected.map { entry in
            entry.text.isEmpty ? "" : String(entry.text.dropFirst(contentIndent))
        }
        var value = style == "|" ? contentLines.joined(separator: "\n") : fold(contentLines)
        if chomping == "+" {
            if collected.isEmpty == false { value += "\n" }
        } else if chomping == "-" {
            value = value.trimmingCharacters(in: .newlines)
        } else if collected.isEmpty == false {
            value = value.trimmingCharacters(in: .newlines) + "\n"
        }
        return try register(.blockString(
            value,
            sourceLines: zip(contentLines, collected).map {
                FrontMatterBlockLine(text: $0.0, sourceLine: $0.1.sourceLine)
            },
            style: style,
            chomping: chomping,
            line: collected.first?.sourceLine ?? line,
            endLine: collected.last?.sourceLine ?? line
        ))
    }

    private func fold(_ lines: [String]) -> String {
        var result = ""
        for (offset, line) in lines.enumerated() {
            if offset > 0 { result += lines[offset - 1].isEmpty || line.isEmpty ? "\n" : " " }
            result += line
        }
        return result
    }

    private mutating func parseFlow(_ text: String, line: Int) throws -> FrontMatterValue {
        var parser = FlowValueParser(text: text, line: line)
        let value = try parser.parse()
        try registerTree(value)
        return value
    }

    private mutating func registerTree(_ value: FrontMatterValue) throws {
        func total(_ value: FrontMatterValue) -> Int {
            switch value {
            case .scalar, .blockString: 1
            case .sequence(let values, _): 1 + values.reduce(0) { $0 + total($1) }
            case .mapping(let pairs, _): 1 + pairs.reduce(0) { $0 + total($1.value) }
            }
        }
        nodeCount += total(value)
        try enforceNodeLimit(line: value.line)
    }

    private mutating func register(_ value: FrontMatterValue) throws -> FrontMatterValue {
        nodeCount += 1
        try enforceNodeLimit(line: value.line)
        return value
    }

    private func enforceNodeLimit(line: Int) throws {
        guard nodeCount <= Self.maximumNodes else {
            throw FrontMatterParseError(line: line, message: "Frontmatter contains too many values.")
        }
    }

    private mutating func skipTrivia() {
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.isEmpty || trimmed.hasPrefix("#") else { break }
            index += 1
        }
    }

    private func indentation(at index: Int) throws -> Int {
        var count = 0
        for character in lines[index] {
            if character == " " { count += 1; continue }
            if character == "\t" {
                throw FrontMatterParseError(line: index + 2, message: "Tabs cannot be used for indentation.")
            }
            break
        }
        return count
    }

    private func structuralColon(in text: String) -> String.Index? {
        var quote: Character?
        var escaped = false
        var squareDepth = 0
        var braceDepth = 0
        for position in text.indices {
            let character = text[position]
            if quote == "\"", escaped { escaped = false; continue }
            if quote == "\"", character == "\\" { escaped = true; continue }
            if let activeQuote = quote {
                if character == activeQuote { quote = nil }
                continue
            }
            if character == "\"" || character == "'" { quote = character; continue }
            if character == "[" { squareDepth += 1; continue }
            if character == "]" { squareDepth -= 1; continue }
            if character == "{" { braceDepth += 1; continue }
            if character == "}" { braceDepth -= 1; continue }
            if character == ":", squareDepth == 0, braceDepth == 0 { return position }
        }
        return nil
    }

    private func sequenceMappingColon(in text: String) -> String.Index? {
        guard let colon = structuralColon(in: text) else { return nil }
        let next = text.index(after: colon)
        return next == text.endIndex || text[next].isWhitespace ? colon : nil
    }

    private func stripComment(_ text: String) -> String {
        var quote: Character?
        var escaped = false
        var previous: Character?
        for position in text.indices {
            let character = text[position]
            if quote == "\"", escaped { escaped = false; previous = character; continue }
            if quote == "\"", character == "\\" { escaped = true; previous = character; continue }
            if let activeQuote = quote {
                if character == activeQuote { quote = nil }
                previous = character
                continue
            }
            if character == "\"" || character == "'" { quote = character; previous = character; continue }
            if character == "#", previous?.isWhitespace != false { return String(text[..<position]) }
            previous = character
        }
        return text
    }

    private func parseKey(_ text: String, line: Int) throws -> String {
        var parser = FlowValueParser(text: text, line: line)
        let value = try parser.parse()
        guard case .scalar(.string(let key), _) = value, key.isEmpty == false else {
            throw FrontMatterParseError(line: line, message: "Only string mapping keys are supported.")
        }
        return key
    }

    private func isSequenceIndicator(_ content: String) -> Bool {
        content == "-" || content.hasPrefix("- ") || content.hasPrefix("-\t")
    }

    private func isBlockScalarHeader(_ text: String) -> Bool {
        ["|", "|-", "|+", ">", ">-", ">+"].contains(text)
    }

    private func rejectUnsupportedDocumentSyntax() throws {
        for (offset, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("%") || trimmed == "..." {
                throw FrontMatterParseError(
                    line: offset + 2,
                    message: "YAML directives and multiple documents are not supported."
                )
            }
            if trimmed.hasPrefix("?") {
                throw FrontMatterParseError(line: offset + 2, message: "Complex mapping keys are not supported.")
            }
        }
    }

    private func failure(_ message: String, at index: Int) -> FrontMatterParseError {
        FrontMatterParseError(line: min(index + 2, lines.count + 1), message: message)
    }
}

private struct FlowValueParser {
    let text: String
    let line: Int
    private var index: String.Index

    init(text: String, line: Int) {
        self.text = text
        self.line = line
        self.index = text.startIndex
    }

    mutating func parse() throws -> FrontMatterValue {
        skipSpaces()
        let value = try parseValue(depth: 0)
        skipSpaces()
        guard index == text.endIndex else { throw failure("Unexpected characters after the value.") }
        return value
    }

    private mutating func parseValue(depth: Int) throws -> FrontMatterValue {
        guard depth <= 64 else { throw failure("Flow collection nesting exceeds 64 levels.") }
        guard index < text.endIndex else { return .scalar(.null, line: line) }
        guard [",", "]", "}"].contains(text[index]) == false else {
            throw failure("Expected a value.")
        }
        switch text[index] {
        case "[": return try parseSequence(depth: depth + 1)
        case "{": return try parseMapping(depth: depth + 1)
        case "\"": return .scalar(.string(try parseDoubleQuoted()), line: line)
        case "'": return .scalar(.string(try parseSingleQuoted()), line: line)
        case "&", "*", "!": throw failure("Anchors, aliases, and custom tags are not supported.")
        default: return .scalar(parsePlain(), line: line)
        }
    }

    private mutating func parseSequence(depth: Int) throws -> FrontMatterValue {
        advance()
        skipSpaces()
        var values: [FrontMatterValue] = []
        if consume("]") { return .sequence(values, line: line) }
        while true {
            values.append(try parseValue(depth: depth))
            skipSpaces()
            if consume("]") { break }
            guard consume(",") else { throw failure("Expected ',' or ']' in the sequence.") }
            skipSpaces()
            if consume("]") { break }
        }
        return .sequence(values, line: line)
    }

    private mutating func parseMapping(depth: Int) throws -> FrontMatterValue {
        advance()
        skipSpaces()
        var pairs: [FrontMatterPair] = []
        if consume("}") { return .mapping(pairs, line: line) }
        while true {
            let key = try parseFlowKey()
            skipSpaces()
            guard consume(":") else { throw failure("Expected ':' in the mapping.") }
            skipSpaces()
            pairs.append(FrontMatterPair(key: key, keyLine: line, value: try parseValue(depth: depth)))
            skipSpaces()
            if consume("}") { break }
            guard consume(",") else { throw failure("Expected ',' or '}' in the mapping.") }
            skipSpaces()
            if consume("}") { break }
        }
        return .mapping(pairs, line: line)
    }

    private mutating func parseFlowKey() throws -> String {
        if index < text.endIndex, text[index] == "\"" { return try parseDoubleQuoted() }
        if index < text.endIndex, text[index] == "'" { return try parseSingleQuoted() }
        let start = index
        while index < text.endIndex, text[index] != ":" { advance() }
        let key = text[start..<index].trimmingCharacters(in: .whitespaces)
        guard key.isEmpty == false else {
            throw failure("Only string keys are supported in flow mappings.")
        }
        return key
    }

    private mutating func parseDoubleQuoted() throws -> String {
        advance()
        var result = ""
        while index < text.endIndex {
            let character = text[index]
            advance()
            if character == "\"" { return result }
            guard character == "\\" else { result.append(character); continue }
            guard index < text.endIndex else { throw failure("Unterminated escape sequence.") }
            let escaped = text[index]
            advance()
            switch escaped {
            case "\\": result.append("\\")
            case "\"": result.append("\"")
            case "n": result.append("\n")
            case "r": result.append("\r")
            case "t": result.append("\t")
            case "u":
                let digits = try takeHexDigits(4)
                guard let scalarValue = UInt32(digits, radix: 16), let scalar = UnicodeScalar(scalarValue) else {
                    throw failure("Invalid Unicode escape sequence.")
                }
                result.unicodeScalars.append(scalar)
            default: throw failure("Unsupported escape sequence '\\\(escaped)'.")
            }
        }
        throw failure("Unterminated double-quoted string.")
    }

    private mutating func parseSingleQuoted() throws -> String {
        advance()
        var result = ""
        while index < text.endIndex {
            let character = text[index]
            advance()
            if character == "'" {
                if consume("'") { result.append("'"); continue }
                return result
            }
            result.append(character)
        }
        throw failure("Unterminated single-quoted string.")
    }

    private mutating func parsePlain() -> FrontMatterScalar {
        let start = index
        while index < text.endIndex, [",", "]", "}"].contains(text[index]) == false { advance() }
        let raw = String(text[start..<index]).trimmingCharacters(in: .whitespaces)
        if raw == "null" || raw == "~" { return .null }
        if raw == "true" { return .boolean(true) }
        if raw == "false" { return .boolean(false) }
        if raw.range(of: #"^[+-]?[0-9]+$"#, options: .regularExpression) != nil { return .integer(raw) }
        if raw.range(of: #"^[+-]?(?:[0-9]+\.[0-9]*|[0-9]*\.[0-9]+|[0-9]+[eE][+-]?[0-9]+)(?:[eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil {
            return .number(raw)
        }
        return .string(raw)
    }

    private mutating func takeHexDigits(_ count: Int) throws -> String {
        var result = ""
        for _ in 0..<count {
            guard index < text.endIndex, text[index].isHexDigit else {
                throw failure("Invalid Unicode escape sequence.")
            }
            result.append(text[index])
            advance()
        }
        return result
    }

    private mutating func skipSpaces() {
        while index < text.endIndex, text[index].isWhitespace { advance() }
    }

    private mutating func consume(_ character: Character) -> Bool {
        guard index < text.endIndex, text[index] == character else { return false }
        advance()
        return true
    }

    private mutating func advance() { index = text.index(after: index) }
    private func failure(_ message: String) -> FrontMatterParseError {
        FrontMatterParseError(line: line, message: message)
    }
}

private extension FrontMatterValue {
    func withLine(_ line: Int) -> FrontMatterValue {
        switch self {
        case .mapping(let pairs, _): .mapping(pairs, line: line)
        case .sequence(let values, _): .sequence(values, line: line)
        case .scalar(let scalar, _): .scalar(scalar, line: line)
        case .blockString(let value, let sourceLines, let style, let chomping, _, let endLine):
            .blockString(
                value,
                sourceLines: sourceLines,
                style: style,
                chomping: chomping,
                line: line,
                endLine: endLine
            )
        }
    }
}

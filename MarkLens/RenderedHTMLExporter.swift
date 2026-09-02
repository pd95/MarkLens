import Foundation
import MarkdownPipeline

nonisolated struct RenderedHTMLExporter {
    static func export(
        html: String,
        resources: [HTMLResource],
        customCSS: String,
        sourceURL: URL?,
        frontMatterExpanded: Bool,
        to destinationURL: URL
    ) throws {
        var result = preparingFrontMatter(in: html, expanded: frontMatterExpanded)
        result = applying(customCSS: customCSS, to: result)
        result = inline(resources: resources, in: result)
        result = try embeddingLocalImages(in: result, relativeTo: sourceURL)
        try result.write(to: destinationURL, atomically: true, encoding: .utf8)
    }

    static func standaloneHTML(
        html: String,
        resources: [HTMLResource],
        customCSS: String,
        sourceURL: URL?,
        frontMatterExpanded: Bool = false
    ) throws -> String {
        var result = preparingFrontMatter(in: html, expanded: frontMatterExpanded)
        result = applying(customCSS: customCSS, to: result)
        result = inline(resources: resources, in: result)
        return try embeddingLocalImages(in: result, relativeTo: sourceURL)
    }

    private static func preparingFrontMatter(in html: String, expanded: Bool) -> String {
        expanded
            ? FrontMatterHTMLState.applying(expanded: true, to: html)
            : FrontMatterHTMLState.removingFrontMatter(from: html)
    }

    private static func applying(customCSS: String, to html: String) -> String {
        let escapedCSS = customCSS.replacingOccurrences(of: "<", with: "\\3C ")
        let identifier = NSRegularExpression.escapedPattern(
            for: HTMLFeature.customCSSStyleElementID
        )
        let pattern = "(?s)(<style\\s+id=\"\(identifier)\"[^>]*>).*?(</style>)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return html }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)

        if let match = regex.firstMatch(in: html, range: range),
           let matchRange = Range(match.range, in: html),
           let openingRange = Range(match.range(at: 1), in: html),
           let closingRange = Range(match.range(at: 2), in: html) {
            let replacement = String(html[openingRange]) + "\n" + escapedCSS + "\n"
                + String(html[closingRange])
            return html.replacingCharacters(in: matchRange, with: replacement)
        }

        let style = "<style id=\"\(HTMLFeature.customCSSStyleElementID)\">\n\(escapedCSS)\n</style>\n"
        if let headEnd = html.range(of: "</head>", options: .caseInsensitive) {
            var result = html
            result.insert(contentsOf: style, at: headEnd.lowerBound)
            return result
        }
        return style + html
    }

    private static func inline(resources: [HTMLResource], in html: String) -> String {
        resources.reduce(html) { result, resource in
            if resource.contentType == "application/javascript",
               let script = String(data: resource.data, encoding: .utf8) {
                return inline(script: script, from: resource.url, in: result)
            }

            let encoded = resource.data.base64EncodedString()
            let dataURL = "data:\(resource.contentType);base64,\(encoded)"
            let sourceURL = resource.url.absoluteString
            return [
                ("src=\"\(sourceURL)\"", "src=\"\(dataURL)\""),
                ("href=\"\(sourceURL)\"", "href=\"\(dataURL)\""),
                ("url(\(sourceURL))", "url(\(dataURL))"),
                ("url('\(sourceURL)')", "url('\(dataURL)')"),
                ("url(\"\(sourceURL)\")", "url(\"\(dataURL)\")"),
            ].reduce(result) { partialResult, replacement in
                partialResult.replacingOccurrences(of: replacement.0, with: replacement.1)
            }
        }
    }

    private static func inline(script: String, from sourceURL: URL, in html: String) -> String {
        let escapedScript = script.replacingOccurrences(
            of: "</script",
            with: "<\\/script",
            options: .caseInsensitive
        )
        let escapedURL = NSRegularExpression.escapedPattern(for: sourceURL.absoluteString)
        let pattern = "<script\\b([^>]*)\\bsrc=\"\(escapedURL)\"([^>]*)>\\s*</script>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return html
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var result = html
        for match in regex.matches(in: html, range: range).reversed() {
            guard let matchRange = Range(match.range, in: result),
                  let leadingRange = Range(match.range(at: 1), in: result),
                  let trailingRange = Range(match.range(at: 2), in: result) else { continue }
            let attributeText = (String(result[leadingRange]) + String(result[trailingRange]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let attributes = attributeText.isEmpty ? "" : " \(attributeText)"
            result.replaceSubrange(
                matchRange,
                with: "<script\(attributes)>\(escapedScript)</script>"
            )
        }
        return result
    }

    private static func embeddingLocalImages(in html: String, relativeTo sourceURL: URL?) throws -> String {
        let pattern = "(?is)<img\\b[^>]*\\bdata-marklens-local-image=\"([^\"]+)\"[^>]*>"
        let regex = try NSRegularExpression(pattern: pattern)
        let fullRange = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, range: fullRange)
        guard matches.isEmpty == false else { return html }
        guard let sourceURL else { throw ExportError.unsavedDocumentWithLocalImages }

        let documentFolder = sourceURL.deletingLastPathComponent()
        var result = html
        for match in matches.reversed() {
            guard let tagRange = Range(match.range, in: result),
                  let capabilityRange = Range(match.range(at: 1), in: result),
                  let capabilityData = Data(base64Encoded: String(result[capabilityRange])),
                  let imageReference = String(data: capabilityData, encoding: .utf8),
                  let imageURL = URL(string: imageReference, relativeTo: sourceURL)?.absoluteURL else {
                throw ExportError.invalidLocalImageReference
            }

            let canonicalURL = imageURL.standardizedFileURL.resolvingSymlinksInPath()
            guard canonicalURL.isFileURL,
                  contains(canonicalURL, in: documentFolder) else {
                throw ExportError.localImageOutsideDocumentFolder(canonicalURL)
            }

            let data: Data
            do {
                data = try Data(contentsOf: canonicalURL)
            } catch {
                throw ExportError.unreadableLocalImage(canonicalURL, error)
            }
            guard let mimeType = LocalImageData.validatedMIMEType(for: data) else {
                throw ExportError.unsupportedLocalImage(canonicalURL)
            }

            let dataURL = "data:\(mimeType);base64,\(data.base64EncodedString())"
            var tag = String(result[tagRange])
            tag = replacingSource(in: tag, with: dataURL)
            tag = tag.replacingOccurrences(
                of: "\\s+data-marklens-local-image=\"[^\"]*\"",
                with: "",
                options: .regularExpression
            )
            result.replaceSubrange(tagRange, with: tag)
        }
        return result
    }

    private static func replacingSource(in imageTag: String, with dataURL: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "(?i)\\bsrc=\"[^\"]*\"") else {
            return imageTag
        }
        let range = NSRange(imageTag.startIndex..<imageTag.endIndex, in: imageTag)
        return regex.stringByReplacingMatches(
            in: imageTag,
            range: range,
            withTemplate: "src=\"\(dataURL)\""
        )
    }

    private static func contains(_ file: URL, in folder: URL) -> Bool {
        let fileComponents = canonical(file).pathComponents
        let folderComponents = canonical(folder).pathComponents
        return fileComponents.starts(with: folderComponents)
            && fileComponents.count > folderComponents.count
    }

    private static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}

extension RenderedHTMLExporter {
    enum ExportError: LocalizedError {
        case unsavedDocumentWithLocalImages
        case invalidLocalImageReference
        case localImageOutsideDocumentFolder(URL)
        case unreadableLocalImage(URL, Error)
        case unsupportedLocalImage(URL)

        var errorDescription: String? {
            switch self {
            case .unsavedDocumentWithLocalImages:
                "Save the Markdown document before exporting HTML with local images."
            case .invalidLocalImageReference:
                "A local image reference in the rendered document is invalid."
            case .localImageOutsideDocumentFolder(let url):
                "The local image \(url.lastPathComponent) is outside the document folder and cannot be embedded."
            case .unreadableLocalImage(let url, let error):
                "The local image \(url.lastPathComponent) could not be read. Grant folder access in MarkLens and try again. \(error.localizedDescription)"
            case .unsupportedLocalImage(let url):
                "The local image \(url.lastPathComponent) is not a supported PNG, JPEG, GIF, or WebP file."
            }
        }
    }
}

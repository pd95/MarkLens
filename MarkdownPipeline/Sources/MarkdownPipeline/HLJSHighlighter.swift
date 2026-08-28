import Foundation
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

struct CodeHighlightResult {
    let html: String
    let language: String?
}

enum CodeHighlightingInputPolicy {
    static let maximumAutomaticDocumentByteCount = 1024 * 1024
    static let maximumAutomaticByteCount = 32 * 1024
    static let maximumExplicitByteCount = 256 * 1024

    static func allowsAutomaticHighlighting(document: String) -> Bool {
        document.utf8.count <= maximumAutomaticDocumentByteCount
    }

    static func allowsHighlighting(code: String, language: String?) -> Bool {
        let maximumByteCount = language == nil
            ? maximumAutomaticByteCount
            : maximumExplicitByteCount
        return code.utf8.count <= maximumByteCount
    }
}

final class HLJSHighlighter {
    private let cache = NSCache<NSString, CodeHighlightBox>()
    private let aliasMap: [String: String] = [
        "js": "javascript",
        "ts": "typescript",
        "yml": "yaml",
        "sh": "bash",
        "zsh": "bash",
        "py": "python",
        "rb": "ruby",
        "kt": "kotlin",
        "md": "markdown",
        "objc": "objectivec"
    ]

    #if canImport(JavaScriptCore)
    private let context: JSContext
    private let isReady: Bool
    #else
    private let isReady = false
    #endif

    init() {
        #if canImport(JavaScriptCore)
        let context = JSContext()!
        var ready = false
        context.exceptionHandler = { _, exception in
            if let message = exception?.toString() {
                NSLog("HLJS exception: \(message)")
            }
        }
        if let script = try? ResourceLoader.stringResource("highlight.min.js") {
            context.evaluateScript(script)
            if context.objectForKeyedSubscript("hljs") != nil {
                ready = true
            }
        }
        self.context = context
        self.isReady = ready
        #endif
    }

    func highlight(code: String, language: String?, languageSubset: [String]) -> CodeHighlightResult? {
        guard isReady else {
            return nil
        }
        let normalizedLanguage = language.flatMap { normalize(language: $0) }
        guard CodeHighlightingInputPolicy.allowsHighlighting(
            code: code,
            language: normalizedLanguage
        ) else {
            return nil
        }
        let cacheKey = cacheKey(for: code, language: normalizedLanguage, subset: languageSubset)
        if let cached = cache.object(forKey: cacheKey) {
            return cached.result
        }

        let result: CodeHighlightResult?
        if let normalizedLanguage {
            result = highlightExplicit(code: code, language: normalizedLanguage)
        } else {
            result = highlightAuto(code: code, subset: languageSubset)
        }

        if let result {
            cache.setObject(CodeHighlightBox(result: result), forKey: cacheKey)
        }
        return result
    }

    private func normalize(language: String) -> String {
        let lowercased = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return aliasMap[lowercased] ?? lowercased
    }

    private func cacheKey(for code: String, language: String?, subset: [String]) -> NSString {
        let subsetKey = subset.joined(separator: ",")
        let key = "\(language ?? "auto")::\(subsetKey)::\(code)"
        return NSString(string: key)
    }

    private func highlightExplicit(code: String, language: String) -> CodeHighlightResult? {
        #if canImport(JavaScriptCore)
        guard let hljs = context.objectForKeyedSubscript("hljs") else {
            return nil
        }
        guard invoke(hljs, method: "getLanguage", arguments: [language]) != nil else {
            return nil
        }
        let options: [String: Any] = ["language": language, "ignoreIllegals": true]
        guard let result = invoke(hljs, method: "highlight", arguments: [code, options]) else {
            return nil
        }
        guard let value = result.objectForKeyedSubscript("value"),
              value.isUndefined == false,
              value.isNull == false,
              let html = value.toString() else {
            return nil
        }
        return CodeHighlightResult(html: html, language: language)
        #else
        return nil
        #endif
    }

    private func highlightAuto(code: String, subset: [String]) -> CodeHighlightResult? {
        #if canImport(JavaScriptCore)
        guard let hljs = context.objectForKeyedSubscript("hljs") else {
            return nil
        }
        let args: [Any] = subset.isEmpty ? [code] : [code, subset]
        guard let result = invoke(hljs, method: "highlightAuto", arguments: args) else {
            return nil
        }
        guard let value = result.objectForKeyedSubscript("value"),
              value.isUndefined == false,
              value.isNull == false,
              let html = value.toString() else {
            return nil
        }
        let languageValue = result.objectForKeyedSubscript("language")
        let language = languageValue?.isUndefined == false && languageValue?.isNull == false
            ? languageValue?.toString()
            : nil
        return CodeHighlightResult(html: html, language: language)
        #else
        return nil
        #endif
    }

    #if canImport(JavaScriptCore)
    private func invoke(_ object: JSValue, method: String, arguments: [Any]) -> JSValue? {
        context.exception = nil
        let result = object.invokeMethod(method, withArguments: arguments)
        guard context.exception == nil,
              let result,
              result.isUndefined == false,
              result.isNull == false else {
            context.exception = nil
            return nil
        }
        return result
    }
    #endif
}

private final class CodeHighlightBox: NSObject {
    let result: CodeHighlightResult

    init(result: CodeHighlightResult) {
        self.result = result
    }
}

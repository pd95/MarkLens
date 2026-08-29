import Testing
@testable import MarkdownPipeline

@Suite("Front Matter")
struct FrontMatterTests {
    @Test func noFrontMatterReturnsOriginal() {
        let input = "# Title\nBody text"
        let result = FrontMatterExtractor().extract(from: input)
        #expect(result.frontMatter == nil)
        #expect(result.bodyMarkdown == input)
        #expect(result.bodyLineOffset == 0)
    }

    @Test func validFrontMatterExtractsValues() {
        let input = """
        ---
        title: Something
        theme: dark
        ---
        # Content
        """
        let result = FrontMatterExtractor().extract(from: input)
        #expect(result.frontMatter?.title == "Something")
        #expect(result.frontMatter?.theme == "dark")
        #expect(result.bodyMarkdown == "# Content")
        #expect(result.bodyLineOffset == 4)
    }

    @Test func malformedFrontMatterIsIgnored() {
        let input = """
        ---
        title: Something
        # Content
        """
        let result = FrontMatterExtractor().extract(from: input)
        #expect(result.frontMatter == nil)
        #expect(result.bodyMarkdown == input)
        #expect(result.bodyLineOffset == 0)
    }

    @Test func windowsLineEndingsKeepLogicalSourceLines() {
        let input = "---\r\ntitle: Windows\r\n---\r\n# Content"
        let result = FrontMatterExtractor().extract(from: input)

        #expect(result.frontMatter?.title == "Windows")
        #expect(result.bodyMarkdown == "# Content")
        #expect(result.bodyLineOffset == 3)
    }
}

@Test func sanitizesDisallowedRawHTML() throws {
    let input = "<script>alert('xss')</script>"
    let pipeline = MarkdownPipeline()
    let document = try pipeline.render(input: .string(input), context: PipelineContext())
    #expect(document.html.contains("&lt;script"))
}

@Test func sanitizesUnsafeLinks() throws {
    let input = "[link](javascript:alert(1))"
    let pipeline = MarkdownPipeline()
    let document = try pipeline.render(input: .string(input), context: PipelineContext())
    #expect(document.html.contains("href=\"#\""))
}

@Test func sanitizesExecutableRawHTMLAttributesAndActiveTags() throws {
    let input = """
    <img src="missing" onerror="alert(1)">
    <button onclick="alert(2)">Run</button>
    <form action="https://example.com"><input name="secret"></form>
    """
    let document = try MarkdownPipeline().renderHTML(from: .string(input))

    #expect(document.html.contains("onerror") == false)
    #expect(document.html.contains("onclick") == false)
    #expect(document.html.contains("&lt;button"))
    #expect(document.html.contains("&lt;form"))
    #expect(document.html.contains("&lt;input"))
}

@Test func canEscapeAllRawHTML() throws {
    let context = PipelineContext(rawHTMLPolicy: .escaped)
    let document = try MarkdownPipeline().render(input: .string("<span>Text</span>"), context: context)

    #expect(document.html.contains("&lt;span&gt;Text&lt;/span&gt;"))
    #expect(document.html.contains("<span>Text</span>") == false)
}

@Test func resourcePolicyBlocksRemoteAndLocalImagesButKeepsLinks() throws {
    let context = PipelineContext(allowsRemoteResources: false, allowsLocalResources: false)
    let input = """
    [Remote link](https://example.com)
    ![Remote](https://example.com/image.png)
    ![Local](images/image.png)
    <img src="https://example.com/raw.png">
    """
    let document = try MarkdownPipeline().render(input: .string(input), context: context)

    #expect(document.html.contains("href=\"https://example.com\""))
    #expect(document.html.contains("https://example.com/image.png") == false)
    #expect(document.html.contains("images/image.png") == false)
    #expect(document.html.contains("https://example.com/raw.png") == false)
    #expect(document.html.contains("img-src data: marklens-resource:"))
    #expect(document.html.contains("img-src data: marklens-resource: file:") == false)
}

@Test func rawHTMLCannotBypassLocalImageCapabilities() throws {
    let context = PipelineContext(
        rawHTMLPolicy: .sanitized,
        allowsRemoteResources: false,
        allowsLocalResources: true
    )
    let input = """
    ![Markdown](images/allowed.png)
    <img src="../outside.png">
    <img src="file:///tmp/outside.png">
    """
    let document = try MarkdownPipeline().render(input: .string(input), context: context)

    #expect(document.html.contains("data-marklens-local-image"))
    #expect(document.html.contains("../outside.png") == false)
    #expect(document.html.contains("file:///tmp/outside.png") == false)
    #expect(document.html.contains("img-src data: marklens-resource: marklens-local-image:"))
    #expect(document.html.contains("img-src data: marklens-resource: file:") == false)
}

@Test func contentIDPolicyAllowsOnlyQuickLookFontAttachments() throws {
    let context = PipelineContext(
        rawHTMLPolicy: .escaped,
        allowsRemoteResources: false,
        allowsLocalResources: false,
        allowsContentIDResources: true
    )
    let document = try MarkdownPipeline().render(
        input: .string(#"Math $x$"#),
        context: context
    )

    #expect(document.html.contains("font-src data: marklens-resource: cid:"))
    #expect(document.html.contains("img-src data: marklens-resource: cid:") == false)
    #expect(document.html.components(separatedBy: "cid:").count - 1 == 1)
}

@Test func localImagePolicyDoesNotRemoveRawHTMLLinks() throws {
    let context = PipelineContext(
        rawHTMLPolicy: .sanitized,
        allowsRemoteResources: false,
        allowsLocalResources: false
    )
    let input = #"<a href="other.md">Relative</a> <a href="file:///tmp/other.md">File</a>"#
    let document = try MarkdownPipeline().render(input: .string(input), context: context)

    #expect(document.html.contains("href=\"other.md\""))
    #expect(document.html.contains("href=\"file:///tmp/other.md\""))
}

@Test func normalizesRawHTMLURLsBeforeSchemeValidation() throws {
    let sanitizer = RawHTMLSanitizer(policy: .sanitized, allowsRemoteResources: false)
    let html = """
    <a href=" \tjava\nscript:alert(1)">Unsafe</a>
    <a href="JaVaScRiPt:alert(2)">Unsafe</a>
    <a href="java%73cript:alert(3)">Unsafe</a>
    <a href=" other.md ">Safe</a>
    <img src="//example.com/tracker.png">
    """
    let result = sanitizer.sanitize(html)

    #expect(result.contains("javascript") == false)
    #expect(result.contains("JaVaScRiPt") == false)
    #expect(result.contains("java%73cript") == false)
    #expect(result.contains("href=\"other.md\""))
    #expect(result.contains("tracker.png") == false)
}

@Test func malformedRawHTMLIsHandledInOneForwardPass() {
    let sanitizer = RawHTMLSanitizer(policy: .sanitized, allowsRemoteResources: false)
    let input = "<div>" + String(repeating: "<", count: 100_000)

    let result = sanitizer.sanitize(input)

    #expect(result.hasPrefix("<div>"))
    #expect(result.components(separatedBy: "&lt;").count - 1 == 100_000)
}

@Test func includesLargeDocumentCodeBlockControlsAndVirtualization() throws {
    let document = try MarkdownPipeline().render(
        input: .string("```\ncode\n```"),
        context: PipelineContext()
    )

    #expect(document.html.contains("code-block-virtualized"))
    #expect(document.html.contains("content-visibility: auto"))
    #expect(document.html.contains("contain-intrinsic-block-size: auto"))
    #expect(document.html.contains("content-visibility: visible"))
    #expect(document.html.contains("code-block-collapsed"))
    #expect(document.html.contains("code-block-controls"))
    #expect(document.html.contains("code-block-header"))
    #expect(document.html.contains("code-language-badge"))
    #expect(document.html.contains("Automatically detected language"))
    #expect(document.html.contains("Plain text"))
    #expect(document.html.contains("codeLanguageColors"))
    #expect(document.html.contains("--code-language-color"))
    #expect(document.html.contains("['pgsql', 'PostgreSQL']"))
    #expect(document.html.contains("role', 'group"))
    #expect(document.html.contains("code-expand-btn"))
    #expect(document.html.contains("code-reveal-btn"))
    #expect(document.html.contains("code-collapse-btn"))
    #expect(document.html.contains("code-block-transitioning"))
    #expect(document.html.contains("more lines"))
    #expect(document.html.contains("aria-expanded"))
    #expect(document.html.contains("max-height: 32rem"))
    #expect(document.html.contains("position: sticky"))
    #expect(document.html.contains("pointer: fine"))
    #expect(document.html.contains("code-block-collapsed:hover"))
    #expect(document.html.contains("padding-top: 2.75rem"))
    #expect(document.html.contains("code:only-child"))
    #expect(document.html.contains("code-control-hover-light"))
    #expect(document.html.contains("copy-icon-tight"))
    #expect(document.html.contains("success-icon-tight"))
    #expect(document.html.contains("chevron-icon"))
    #expect(document.html.contains("copy-success-surface-light"))
    #expect(document.html.contains(".copy-btn::after"))
    #expect(document.html.contains("transition-duration: 140ms"))
    #expect(document.html.contains("opacity 120ms ease-out"))
    #expect(document.html.contains("opacity 180ms ease-out"))
    #expect(document.html.contains("transition-delay: 120ms"))
    #expect(document.html.contains("code-expand-btn:not(.is-exiting):hover"))
    #expect(document.html.contains("code-collapse-btn.is-active + .copy-btn"))
    #expect(document.html.contains("focus({ preventScroll: true })"))
    #expect(document.html.contains("codeControlTransitionDuration"))
    #expect(document.html.contains("copyResetTimers"))
    #expect(document.html.contains("}, 1200);"))
}

@Suite("Code Highlighting Input Policy")
struct CodeHighlightingInputPolicyTests {
    @Test func largeDocumentsDisableAutomaticHighlighting() {
        let limit = CodeHighlightingInputPolicy.maximumAutomaticDocumentByteCount

        #expect(CodeHighlightingInputPolicy.allowsAutomaticHighlighting(
            document: String(repeating: "a", count: limit)
        ))
        #expect(CodeHighlightingInputPolicy.allowsAutomaticHighlighting(
            document: String(repeating: "a", count: limit + 1)
        ) == false)
    }

    @Test func automaticHighlightingUsesSmallerLimit() {
        let limit = CodeHighlightingInputPolicy.maximumAutomaticByteCount

        #expect(CodeHighlightingInputPolicy.allowsHighlighting(
            code: String(repeating: "a", count: limit),
            language: nil
        ))
        #expect(CodeHighlightingInputPolicy.allowsHighlighting(
            code: String(repeating: "a", count: limit + 1),
            language: nil
        ) == false)
    }

    @Test func explicitHighlightingUsesLargerLimit() {
        let limit = CodeHighlightingInputPolicy.maximumExplicitByteCount

        #expect(CodeHighlightingInputPolicy.allowsHighlighting(
            code: String(repeating: "a", count: limit),
            language: "swift"
        ))
        #expect(CodeHighlightingInputPolicy.allowsHighlighting(
            code: String(repeating: "a", count: limit + 1),
            language: "swift"
        ) == false)
    }

    @Test func limitsAreMeasuredAsUTF8Bytes() {
        let code = String(
            repeating: "é",
            count: CodeHighlightingInputPolicy.maximumAutomaticByteCount / 2 + 1
        )

        #expect(CodeHighlightingInputPolicy.allowsHighlighting(
            code: code,
            language: nil
        ) == false)
    }

    @Test func shortSingleLineBlocksSkipAutomaticDetection() {
        #expect(CodeHighlightingInputPolicy.allowsAutomaticDetection(
            code: "no language here"
        ) == false)
        #expect(CodeHighlightingInputPolicy.allowsAutomaticDetection(
            code: "function greet(name) { return name; }"
        ))
        #expect(CodeHighlightingInputPolicy.allowsAutomaticDetection(
            code: """
            curl example.com \\
                -H 'Accept: application/json'
            """
        ))
    }
}

#if canImport(JavaScriptCore)
@Suite("Highlighting")
struct HighlightingTests {
    @Test func highlightsExplicitLanguageBlocks() throws {
        let input = """
        ```swift
        let value = 1
        ```
        """
        let pipeline = MarkdownPipeline()
        let document = try pipeline.render(input: .string(input), context: PipelineContext())
        #expect(document.html.contains("class=\"hljs"))
        #expect(document.html.contains("language-swift"))
        #expect(document.html.contains("data-code-language=\"swift\""))
        #expect(document.html.contains("data-code-language-source=\"explicit\""))
    }

    @Test func highlightsAutoLanguageBlocksWithSubset() throws {
        let input = """
        ```
        function greet(name) {
          return "Hello " + name;
        }
        ```
        """
        let pipeline = MarkdownPipeline()
        let context = PipelineContext(highlightLanguageSubset: ["swift", "javascript"])
        let document = try pipeline.render(input: .string(input), context: context)
        #expect(document.html.contains("class=\"hljs"))
        #expect(document.html.contains("language-swift") || document.html.contains("language-javascript"))
        #expect(document.html.contains("data-code-language-source=\"automatic\""))
    }

    @Test func oversizedAutomaticBlockFallsBackToPlainCode() throws {
        let code = String(
            repeating: "let value = 1\n",
            count: CodeHighlightingInputPolicy.maximumAutomaticByteCount / 14 + 1
        )
        let input = "```\n\(code)```"
        let document = try MarkdownPipeline().render(
            input: .string(input),
            context: PipelineContext()
        )

        #expect(document.html.contains("class=\"hljs") == false)
        #expect(document.html.contains("class=\"lang-plaintext\""))
        #expect(document.html.contains("data-code-language=\"plaintext\""))
        #expect(document.html.contains("data-code-language-source=\"fallback\""))
    }

    @Test func shortAutomaticBlockFallsBackToPlainCode() throws {
        let document = try MarkdownPipeline().render(
            input: .string("```\nno language here\n```"),
            context: PipelineContext()
        )

        #expect(document.html.contains("class=\"hljs") == false)
        #expect(document.html.contains("class=\"lang-plaintext\""))
        #expect(document.html.contains("data-code-language-source=\"fallback\""))
    }

    @Test func oversizedExplicitBlockFallsBackToPlainCode() throws {
        let code = String(
            repeating: "let value = 1\n",
            count: CodeHighlightingInputPolicy.maximumExplicitByteCount / 14 + 1
        )
        let input = "```swift\n\(code)```"
        let document = try MarkdownPipeline().render(
            input: .string(input),
            context: PipelineContext()
        )

        #expect(document.html.contains("class=\"hljs") == false)
        #expect(document.html.contains("class=\"lang-swift\""))
    }

    @Test func largeDocumentSkipsAutomaticButKeepsExplicitHighlighting() throws {
        let padding = String(
            repeating: "ordinary prose ",
            count: CodeHighlightingInputPolicy.maximumAutomaticDocumentByteCount / 14 + 1
        )
        let input = """
        ```
        let automatic = true
        ```

        ```swift
        let explicit = true
        ```

        \(padding)
        """
        let document = try MarkdownPipeline().render(
            input: .string(input),
            context: PipelineContext()
        )

        #expect(document.html.contains("class=\"lang-plaintext\""))
        #expect(document.html.contains("class=\"hljs language-swift\""))
    }
}
#endif

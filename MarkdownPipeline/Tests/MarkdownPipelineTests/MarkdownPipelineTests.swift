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

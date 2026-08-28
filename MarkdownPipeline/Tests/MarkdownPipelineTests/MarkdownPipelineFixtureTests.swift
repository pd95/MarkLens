import Foundation
import Testing
@testable import MarkdownPipeline

@Suite("Fixtures")
struct MarkdownPipelineFixtureTests {
    @Test func rendersSampleFixture() throws {
        let url = try fixtureURL(named: "sample.md")
        let data = try Data(contentsOf: url)
        let pipeline = MarkdownPipeline()
        let context = PipelineContext(enableCodeHighlighting: false)
        let document = try pipeline.render(input: .data(data), context: context)
        let html = document.html

        #expect(html.contains("id=\"sample-heading\" data-marklens-source-line=\"5\">Sample Heading</h1>"))
        #expect(html.contains("<strong>bold</strong>"))
        #expect(html.contains("<em>italic</em>"))
        #expect(html.contains("<del>strikethrough</del>"))
        #expect(html.contains("<br>"))
        #expect(html.contains("<ol data-marklens-source-line="))
        #expect(html.contains("<table data-marklens-source-line="))
        #expect(html.contains("text-align:left"))
        #expect(html.contains("text-align:center"))
        #expect(html.contains("text-align:right"))
        #expect(html.contains("class=\"lang-swift\""))
        #expect(html.contains("class=\"lang-plaintext\""))
        #expect(html.contains("<code>print(\"hi\")</code>"))
        #expect(html.contains("href=\"https://example.com\""))
        #expect(html.contains("href=\"#\""))
        #expect(html.contains("<img src=\"https://example.com/image.png\""))
        #expect(html.contains("<blockquote data-marklens-source-line="))
        #expect(html.contains("<span class=\"note\">Inline</span>"))
        #expect(html.contains("colspan=\"2\""))
        #expect(html.contains("rowspan=\"2\""))
        #expect(html.contains("&lt;script"))
    }

    @Test func rendersFixtureFromFileInput() throws {
        let url = try fixtureURL(named: "sample.md")
        let pipeline = MarkdownPipeline()
        let context = PipelineContext(enableCodeHighlighting: false)
        let document = try pipeline.render(input: .file(url), context: context)
        #expect(document.html.contains("id=\"sample-heading\" data-marklens-source-line=\"5\">Sample Heading</h1>"))
    }

    private func fixtureURL(named name: String) throws -> URL {
        let bundle = Bundle.module
        guard let url = bundle.url(forResource: name, withExtension: nil) else {
            throw FixtureError.missingFixture(name)
        }
        return url
    }
}

enum FixtureError: Error {
    case missingFixture(String)
}

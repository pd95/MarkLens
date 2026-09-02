#if os(macOS)
import Foundation
import MarkdownPipeline
import UniformTypeIdentifiers
import WebKit
import XCTest
@testable import MarkLens

final class RenderedHTMLExporterTests: XCTestCase {
    func testExportFormatNormalizesExtensionUsingSelectedContentType() {
        let originalURL = URL(fileURLWithPath: "/tmp/report.wrong")

        XCTAssertEqual(
            RenderedDocumentExportFormat(contentType: .pdf).normalizedURL(originalURL).path,
            "/tmp/report.pdf"
        )
        XCTAssertEqual(
            RenderedDocumentExportFormat(contentType: .html).normalizedURL(originalURL).path,
            "/tmp/report.html"
        )
    }

    func testExportFormatRestoresStoredSelectionWithPDFFallback() {
        XCTAssertEqual(RenderedDocumentExportFormat(storedValue: "html"), .html)
        XCTAssertEqual(RenderedDocumentExportFormat(storedValue: "pdf"), .pdf)
        XCTAssertEqual(RenderedDocumentExportFormat(storedValue: "unsupported"), .pdf)
        XCTAssertEqual(RenderedDocumentExportFormat(storedValue: nil), .pdf)
    }

    func testExportPreferencesRememberLastSuccessfulFormat() throws {
        let suiteName = "RenderedHTMLExporterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(ExportPreferences.rememberedFormat(in: defaults), .pdf)
        ExportPreferences.remember(.html, in: defaults)
        XCTAssertEqual(ExportPreferences.rememberedFormat(in: defaults), .html)
        ExportPreferences.remember(.pdf, in: defaults)
        XCTAssertEqual(ExportPreferences.rememberedFormat(in: defaults), .pdf)
    }

    func testStandaloneHTMLInlinesResourcesCSSAndLocalImages() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let documentURL = folder.appendingPathComponent("document.md")
        let imageURL = folder.appendingPathComponent("image.png")
        let imageData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        try imageData.write(to: imageURL)

        let imageReference = "image.png"
        let capability = try XCTUnwrap(imageReference.data(using: .utf8)?.base64EncodedString())
        let resource = HTMLResource(
            identifier: "font.woff2",
            contentType: "font/woff2",
            data: Data([1, 2, 3])
        )
        let html = """
        <html><head>
        <style id="marklens-custom-css"></style>
        <style>src: url(\(resource.url.absoluteString))</style>
        </head><body>
        <img src="image.png" data-marklens-local-image="\(capability)">
        <img src="https://example.com/remote.png">
        <code>\(resource.url.absoluteString)</code>
        </body></html>
        """

        let exported = try RenderedHTMLExporter.standaloneHTML(
            html: html,
            resources: [resource],
            customCSS: "body::before { content: \"</style>\"; }",
            sourceURL: documentURL
        )

        XCTAssertTrue(exported.contains("data:font/woff2;base64,AQID"))
        XCTAssertTrue(exported.contains("data:image/png;base64,\(imageData.base64EncodedString())"))
        XCTAssertTrue(exported.contains("body::before { content: \"\\3C /style>\"; }"))
        XCTAssertTrue(exported.contains("https://example.com/remote.png"))
        XCTAssertTrue(exported.contains("<code>\(resource.url.absoluteString)</code>"))
        XCTAssertFalse(exported.contains("data-marklens-local-image"))
    }

    func testStandaloneHTMLInlinesJavaScriptWithoutDataURL() throws {
        let script = "window.rendered = '</script>';"
        let resource = HTMLResource(
            identifier: "renderer.js",
            contentType: "application/javascript",
            data: Data(script.utf8)
        )
        let html = "<script src=\"\(resource.url.absoluteString)\"></script>"

        let exported = try RenderedHTMLExporter.standaloneHTML(
            html: html,
            resources: [resource],
            customCSS: "",
            sourceURL: nil
        )

        XCTAssertTrue(exported.contains("<script>window.rendered = '<\\/script>';</script>"))
        XCTAssertFalse(exported.contains("data:application/javascript"))
        XCTAssertFalse(exported.contains(resource.url.absoluteString))
    }

    func testStandaloneHTMLOmitsCollapsedFrontMatter() throws {
        let document = try MarkdownPipeline.defaultHTML().renderHTML(from: .string("""
        ---
        title: Metadata title
        tags: [one, two]
        ---
        # Body title
        """))

        let exported = try RenderedHTMLExporter.standaloneHTML(
            html: document.html,
            resources: document.resources,
            customCSS: "",
            sourceURL: nil,
            frontMatterExpanded: false
        )

        XCTAssertFalse(exported.contains("marklens-frontmatter:start"))
        XCTAssertFalse(exported.contains("id=\"marklens-frontmatter\""))
        XCTAssertTrue(exported.contains("Body title"))
    }

    func testStandaloneHTMLIncludesExpandedInteractiveFrontMatter() throws {
        let document = try MarkdownPipeline.defaultHTML().renderHTML(from: .string("""
        ---
        title: Metadata title
        ---
        Body
        """))

        let exported = try RenderedHTMLExporter.standaloneHTML(
            html: document.html,
            resources: document.resources,
            customCSS: "",
            sourceURL: nil,
            frontMatterExpanded: true
        )

        XCTAssertTrue(exported.contains("<details id=\"marklens-frontmatter\" class=\"frontmatter-card\" open>"))
        XCTAssertTrue(exported.contains("Metadata title"))
        XCTAssertTrue(exported.contains("<summary data-marklens-source-line=\"1\">"))
        XCTAssertTrue(exported.contains("class=\"frontmatter-print-title\""))
        XCTAssertTrue(exported.contains(".frontmatter-card[open] .frontmatter-print-title"))
    }

    @MainActor
    func testStandaloneHTMLRendersMermaidInWebView() async throws {
        let pipeline = MarkdownPipeline(plugins: [.mermaid()])
        let document = try pipeline.renderHTML(
            from: .string("""
            ```mermaid
            graph TD
                A --> B
            ```
            """),
            context: PipelineContext()
        )
        let exported = try RenderedHTMLExporter.standaloneHTML(
            html: document.html,
            resources: document.resources,
            customCSS: "",
            sourceURL: nil
        )

        let webView = WKWebView()
        webView.loadHTMLString(exported, baseURL: nil)

        for _ in 0..<100 {
            let rendered = try? await webView.evaluateJavaScript(
                "document.querySelector('[data-mermaid-diagram] svg') !== null"
            ) as? Bool
            if rendered == true {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        XCTFail("Expected exported Mermaid markup to render as SVG.")
    }

    func testStandaloneHTMLRejectsUnreadableLocalImage() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let reference = "missing.png"
        let capability = try XCTUnwrap(reference.data(using: .utf8)?.base64EncodedString())
        let html = "<img src=\"missing.png\" data-marklens-local-image=\"\(capability)\">"

        XCTAssertThrowsError(try RenderedHTMLExporter.standaloneHTML(
            html: html,
            resources: [],
            customCSS: "",
            sourceURL: folder.appendingPathComponent("document.md")
        )) { error in
            guard let exportError = error as? RenderedHTMLExporter.ExportError,
                  case .unreadableLocalImage = exportError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testStandaloneHTMLEmbedsEverySupportedLocalImageFormat() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let fixtures: [(name: String, data: Data, mimeType: String)] = [
            ("photo.jpg", Data([0xFF, 0xD8, 0xFF]), "image/jpeg"),
            ("animation.gif", Data("GIF89a".utf8), "image/gif"),
            (
                "graphic.webp",
                Data("RIFF".utf8) + Data([0, 0, 0, 0]) + Data("WEBP".utf8),
                "image/webp"
            ),
        ]

        var imageTags = ""
        for fixture in fixtures {
            try fixture.data.write(to: folder.appendingPathComponent(fixture.name))
            let capability = try XCTUnwrap(
                fixture.name.data(using: .utf8)?.base64EncodedString()
            )
            imageTags += "<img src=\"\(fixture.name)\" data-marklens-local-image=\"\(capability)\">"
        }

        let exported = try RenderedHTMLExporter.standaloneHTML(
            html: imageTags,
            resources: [],
            customCSS: "",
            sourceURL: folder.appendingPathComponent("document.md")
        )

        for fixture in fixtures {
            XCTAssertTrue(exported.contains(
                "data:\(fixture.mimeType);base64,\(fixture.data.base64EncodedString())"
            ))
        }
    }

    func testStandaloneHTMLRejectsUnsupportedLocalImageData() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let imageName = "not-an-image.png"
        try Data("not an image".utf8).write(to: folder.appendingPathComponent(imageName))
        let capability = try XCTUnwrap(imageName.data(using: .utf8)?.base64EncodedString())
        let html = "<img src=\"\(imageName)\" data-marklens-local-image=\"\(capability)\">"

        XCTAssertThrowsError(try RenderedHTMLExporter.standaloneHTML(
            html: html,
            resources: [],
            customCSS: "",
            sourceURL: folder.appendingPathComponent("document.md")
        )) { error in
            guard let exportError = error as? RenderedHTMLExporter.ExportError,
                  case .unsupportedLocalImage = exportError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testStandaloneHTMLRejectsImagesOutsideDocumentFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let documentFolder = root.appendingPathComponent("document", isDirectory: true)
        try FileManager.default.createDirectory(at: documentFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let outsideImage = root.appendingPathComponent("outside.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: outsideImage)
        let reference = "../outside.png"
        let capability = try XCTUnwrap(reference.data(using: .utf8)?.base64EncodedString())
        let html = "<img src=\"\(reference)\" data-marklens-local-image=\"\(capability)\">"

        XCTAssertThrowsError(try RenderedHTMLExporter.standaloneHTML(
            html: html,
            resources: [],
            customCSS: "",
            sourceURL: documentFolder.appendingPathComponent("document.md")
        )) { error in
            guard let exportError = error as? RenderedHTMLExporter.ExportError,
                  case .localImageOutsideDocumentFolder = exportError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testStandaloneHTMLRequiresSavedDocumentForLocalImages() throws {
        let reference = "image.png"
        let capability = try XCTUnwrap(reference.data(using: .utf8)?.base64EncodedString())
        let html = "<img src=\"image.png\" data-marklens-local-image=\"\(capability)\">"

        XCTAssertThrowsError(try RenderedHTMLExporter.standaloneHTML(
            html: html,
            resources: [],
            customCSS: "",
            sourceURL: nil
        )) { error in
            guard let exportError = error as? RenderedHTMLExporter.ExportError,
                  case .unsavedDocumentWithLocalImages = exportError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }
}
#endif

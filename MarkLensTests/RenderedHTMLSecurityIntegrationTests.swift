import MarkdownPipeline
import WebKit
import XCTest
@testable import MarkLens

@MainActor
final class RenderedHTMLSecurityIntegrationTests: XCTestCase {
    func testTrustedTemplateRunsButRawEventHandlersDoNot() async throws {
        let document = try MarkdownPipeline.defaultHTML().render(
            input: .string("""
            <img id="security-probe" src="missing" onerror="window.rawHandlerRan = true">

            ```swift
            let trusted = true
            ```
            """),
            context: PipelineContext(
                rawHTMLPolicy: .sanitized,
                allowsRemoteResources: false,
                allowsLocalResources: false
            )
        )
        let webView = WKWebView(frame: .zero, configuration: MarkdownWebView.makeSecureConfiguration())
        webView.loadHTMLString(document.html, baseURL: nil)
        try await waitUntilReady(webView)

        let result = try await webView.evaluateJavaScript("""
            ({
                handler: document.querySelector('#security-probe')?.getAttribute('onerror') ?? null,
                ran: window.rawHandlerRan === true,
                trustedTemplateScript: typeof codeLanguageDisplayName === 'function',
                nonce: document.scripts[0]?.nonce ?? null,
                policy: document.querySelector('meta[http-equiv="Content-Security-Policy"]')?.content ?? null
            })
            """) as? [String: Any]

        XCTAssertTrue(result?["handler"] is NSNull)
        XCTAssertEqual(result?["ran"] as? Bool, false)
        XCTAssertEqual(result?["trustedTemplateScript"] as? Bool, true, "\(String(describing: result))")
        let nonce = try XCTUnwrap(result?["nonce"] as? String)
        let policy = try XCTUnwrap(result?["policy"] as? String)
        XCTAssertFalse(nonce.isEmpty)
        XCTAssertTrue(policy.contains("'nonce-\(nonce)'"))
    }

    func testCSPBlocksUnapprovedSubresourceSchemes() async throws {
        let requested = expectation(description: "Blocked resource must not be requested")
        requested.isInverted = true
        let configuration = MarkdownWebView.makeSecureConfiguration()
        configuration.setURLSchemeHandler(SchemeProbe(expectation: requested), forURLScheme: "blocked-resource")
        let document = try MarkdownPipeline.defaultHTML().renderHTML(from: .string("Safe"))
        let html = document.html.replacingOccurrences(
            of: "</body>",
            with: "<img src=\"blocked-resource://host/tracker.png\"></body>"
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString(html, baseURL: nil)
        try await waitUntilReady(webView)

        await fulfillment(of: [requested], timeout: 0.5)
    }

    func testCoordinatorCancelsScriptAndFormNavigation() async throws {
        let requested = expectation(description: "Cancelled navigation must not reach its scheme handler")
        requested.isInverted = true
        let configuration = MarkdownWebView.makeSecureConfiguration()
        configuration.setURLSchemeHandler(SchemeProbe(expectation: requested), forURLScheme: "blocked-navigation")
        let parent = MarkdownWebView(html: try MarkdownPipeline.defaultHTML().renderHTML(from: .string("Safe")).html)
        let coordinator = parent.makeCoordinator()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        coordinator.webView = webView
        webView.navigationDelegate = coordinator
        coordinator.authorizeInternalLoad()
        webView.loadHTMLString(parent.html, baseURL: nil)
        try await waitUntilReady(webView)

        _ = try? await webView.evaluateJavaScript("location.href = 'blocked-navigation://host/script'")
        _ = try? await webView.evaluateJavaScript("""
            (() => {
                const form = document.createElement('form');
                form.action = 'blocked-navigation://host/form';
                form.method = 'post';
                document.body.appendChild(form);
                form.submit();
            })()
            """)

        await fulfillment(of: [requested], timeout: 0.5)
        XCTAssertNotEqual(webView.url?.scheme, "blocked-navigation")
    }

    private func waitUntilReady(_ webView: WKWebView) async throws {
        for _ in 0..<100 {
            let ready = try? await webView.evaluateJavaScript("""
                document.readyState === 'complete' &&
                    document.querySelector('meta[http-equiv="Content-Security-Policy"]') !== null
                """) as? Bool
            if ready == true { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Expected WebKit document to finish loading.")
    }
}

private final class SchemeProbe: NSObject, WKURLSchemeHandler {
    private let expectation: XCTestExpectation

    init(expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        expectation.fulfill()
        urlSchemeTask.didFailWithError(URLError(.cancelled))
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

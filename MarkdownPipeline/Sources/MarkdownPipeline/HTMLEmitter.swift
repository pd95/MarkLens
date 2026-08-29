import Foundation

struct HTMLEmitter {
    func render(
        bodyHTML: String,
        title: String?,
        theme: PipelineContext.Theme = .auto,
        additionalStyles: String = "",
        additionalScripts: String = "",
        overrideStyles: String? = nil,
        securityPolicy: PipelineContext = PipelineContext()
    ) throws -> String {
        var template = try ResourceLoader.stringResource("template.html")
        let markdownCSS = try ResourceLoader.stringResource("markdown-style.css")
        let cssBlock = "<style>\n\(markdownCSS)\n\(additionalStyles)\n</style>"

        let overrideBlock = overrideStyles.map {
            "<style id=\"\(HTMLFeature.customCSSStyleElementID)\">\n\(escapedStyleContent($0))\n</style>"
        } ?? ""

        template = template.replacingOccurrences(
            of: "{{STYLES}}",
            with: cssBlock + "\n" + overrideBlock
        )
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let scripts = additionalScripts.replacingOccurrences(
            of: "<script",
            with: "<script nonce=\"\(nonce)\""
        )
        template = template.replacingOccurrences(of: "{{SCRIPTS}}", with: scripts)
        template = template.replacingOccurrences(of: "{{SCRIPT_NONCE}}", with: nonce)
        template = template.replacingOccurrences(
            of: "{{CONTENT_SECURITY_POLICY}}",
            with: contentSecurityPolicy(nonce: nonce, policy: securityPolicy).encodedHTMLAttribute()
        )
        template = template.replacingOccurrences(of: "{{THEME}}", with: theme.rawValue)

        let resolvedTitle = (title ?? "MarkLens").encodedHTMLEntities()
        template = template
            .replacingOccurrences(of: "{{HTML}}", with: bodyHTML)
            .replacingOccurrences(of: "{{FILENAME}}", with: resolvedTitle)

        return template
    }

    private func contentSecurityPolicy(nonce: String, policy: PipelineContext) -> String {
        let remote = policy.allowsRemoteResources ? " http: https:" : ""
        let localImages = policy.allowsLocalResources ? " file: marklens-local-image:" : ""
        return [
            "default-src 'none'",
            "script-src 'nonce-\(nonce)' marklens-resource:",
            "style-src 'unsafe-inline'\(remote)",
            "img-src data: marklens-resource:\(localImages)\(remote)",
            "font-src data: marklens-resource:\(remote)",
            "connect-src 'none'",
            "media-src 'none'",
            "object-src 'none'",
            "frame-src 'none'",
            "base-uri 'none'",
            "form-action 'none'",
        ].joined(separator: "; ")
    }

    private func escapedStyleContent(_ css: String) -> String {
        css.replacingOccurrences(of: "<", with: "\\3C ")
    }
}

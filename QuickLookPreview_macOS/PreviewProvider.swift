//
//  PreviewProvider.swift
//  QuickLookPreview
//
//  Created by Philipp on 02.01.2026.
//

#if os(macOS)
import QuickLookUI
#endif
import QuickLook
import MarkdownPipeline
import UniformTypeIdentifiers
#if canImport(os)
import os
#endif

class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    private static let pipeline = MarkdownPipeline(
        plugins: [
            .syntaxHighlighting(),
            .math(),
            .mermaid(rendering: .sourceWithAppHint),
        ]
    )

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let reply = QLPreviewReply(dataOfContentType: .html, contentSize: .defaultWindowSize) { [self] reply in
            try PreviewPerformanceInstrumentation.measure("QuickLookPreview") {
                let document = try PreviewPerformanceInstrumentation.measure("QuickLookRender") {
                    try self.renderHTML(for: request.fileURL)
                }
                let output = PreviewPerformanceInstrumentation.measure("QuickLookAttachments") {
                    var html = document.html
                    var attachments: [String: QLPreviewReplyAttachment] = [:]
                    for resource in document.resources {
                        let identifier = resource.contentIdentifier
                        html = html.replacingOccurrences(of: resource.url.absoluteString, with: "cid:\(identifier)")
                        let contentType = UTType(mimeType: resource.contentType) ?? .data
                        attachments[identifier] = QLPreviewReplyAttachment(
                            data: resource.data,
                            contentType: contentType
                        )
                    }
                    return (html, attachments)
                }
                reply.attachments = output.1
                return output.0.data(using: .utf8) ?? Data()
            }
        }

        return reply
    }

    private func renderHTML(for url: URL) throws -> HTMLDocument {
        let context = PipelineContext(
            title: url.lastPathComponent,
            mermaidRendering: .sourceWithAppHint,
            rawHTMLPolicy: .escaped,
            allowsRemoteResources: false,
            allowsLocalResources: false
        )
        return try Self.pipeline.renderHTML(from: .file(url), context: context)
    }
}

private enum PreviewPerformanceInstrumentation {
#if canImport(os)
    private static let log = OSLog(subsystem: "ch.doapp.MarkLens", category: "QuickLook")
#endif

    static func measure<Result>(
        _ name: StaticString,
        operation: () throws -> Result
    ) rethrows -> Result {
#if canImport(os)
        let signpostID = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: signpostID)
        defer {
            os_signpost(.end, log: log, name: name, signpostID: signpostID)
        }
#endif
        return try operation()
    }
}

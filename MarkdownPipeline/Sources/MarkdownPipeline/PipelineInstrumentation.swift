#if canImport(os)
import os
#endif

enum PipelineInstrumentation {
#if canImport(os)
    private static let log = OSLog(
        subsystem: "ch.doapp.MarkLens",
        category: "MarkdownPipeline"
    )
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

import Combine
import Foundation

#if os(macOS)
nonisolated enum LinkedFileAccessResult: Sendable {
    case readable
    case permissionDenied
    case failure(String)
}

@MainActor
final class LinkedFilePreview: ObservableObject {
    @Published var previewURL: URL?
    @Published private(set) var accessRequest: URL?
    @Published private(set) var errorDescription: String?

    private var generation = 0
    private var work: Task<Void, Never>?
    private var accessedFiles: [URL: URL] = [:]
    private let checkAccess: @Sendable (URL) -> LinkedFileAccessResult
    private let releaseAccess: (URL) -> Void

    init(
        checkAccess: @escaping @Sendable (URL) -> LinkedFileAccessResult = LinkedFilePreview.checkAccess,
        releaseAccess: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
    ) {
        self.checkAccess = checkAccess
        self.releaseAccess = releaseAccess
    }

    deinit {
        work?.cancel()
        accessedFiles.values.forEach(releaseAccess)
    }

    func preview(_ url: URL) {
        guard let fileURL = LocalLinkDestination(url: url)?.fileURL else { return }
        generation += 1
        let requestGeneration = generation
        work?.cancel()
        accessRequest = nil
        errorDescription = nil
        let accessibleURL = accessedFiles[fileURL] ?? fileURL
        let hasIndividualGrant = accessedFiles[fileURL] != nil
        let checkAccess = checkAccess
        let check = Task.detached(priority: .userInitiated) { checkAccess(accessibleURL) }
        work = Task { [weak self] in
            let result = await check.value
            guard let self, !Task.isCancelled, self.generation == requestGeneration else { return }
            switch result {
            case .readable:
                self.previewURL = accessibleURL
            case .permissionDenied:
                if hasIndividualGrant {
                    self.errorDescription = "Unable to preview \(fileURL.lastPathComponent): the file is still not readable."
                } else {
                    self.accessRequest = fileURL
                }
            case .failure(let description):
                self.errorDescription = description
            }
        }
    }

    // Open panels return URLs with active security scope. Keep the original URL
    // until the document window closes, including when Quick Look is dismissed.
    func authorize(_ selectedURL: URL, for requestedURL: URL) {
        guard accessRequest == requestedURL else {
            releaseAccess(selectedURL)
            return
        }
        guard selectedURL.standardizedFileURL.resolvingSymlinksInPath()
                == requestedURL.standardizedFileURL.resolvingSymlinksInPath() else {
            releaseAccess(selectedURL)
            accessRequest = nil
            errorDescription = "Choose \(requestedURL.lastPathComponent) to preview the linked item."
            return
        }
        if let previous = accessedFiles.updateValue(selectedURL, forKey: requestedURL) {
            releaseAccess(previous)
        }
        preview(requestedURL)
    }

    func cancelAccessRequest() {
        accessRequest = nil
    }

    func close() {
        generation += 1
        work?.cancel()
        work = nil
        previewURL = nil
        accessRequest = nil
        errorDescription = nil
        accessedFiles.values.forEach(releaseAccess)
        accessedFiles.removeAll()
    }

    nonisolated static func checkAccess(to url: URL) -> LinkedFileAccessResult {
        do {
            // Resource values describe a symlink itself. Check its target's type
            // while preserving the original URL for Quick Look and its scope.
            let values = try url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values.isDirectory == true {
                // FileHandle cannot open directories on macOS. Quick Look uses
                // the folder itself rather than a file data stream.
                return FileManager.default.isReadableFile(atPath: url.path) ? .readable : .permissionDenied
            }
            guard values.isRegularFile == true else {
                return .failure("\(url.lastPathComponent) is not a file or folder that can be previewed.")
            }
            let file = try FileHandle(forReadingFrom: url)
            try file.close()
            return .readable
        } catch {
            if isPermissionError(error) { return .permissionDenied }
            return .failure("Unable to preview \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    nonisolated private static func isPermissionError(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileReadNoPermission.rawValue {
            return true
        }
        if error.domain == NSPOSIXErrorDomain && (error.code == EACCES || error.code == EPERM) {
            return true
        }
        return (error.userInfo[NSUnderlyingErrorKey] as? Error).map(isPermissionError) ?? false
    }
}
#endif

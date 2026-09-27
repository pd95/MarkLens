import Foundation

#if os(macOS)
import AppKit
import Combine

struct DocumentViewHandoff: Equatable {
    let id = UUID()
    let scrollPosition: DocumentScrollPosition
    let findText: String
    let findPresented: Bool
    let frontMatterExpanded: Bool
}

@MainActor
final class DocumentTabCoordinator: ObservableObject {
    private(set) var handoffs: [URL: DocumentViewHandoff] = [:]
    let handoffRequests = PassthroughSubject<URL, Never>()

    func window(for fileURL: URL?) -> NSWindow? {
        guard let fileURL,
              let document = NSDocumentController.shared.document(for: fileURL) else { return nil }
        return document.windowControllers.compactMap(\.window).first
    }

    func enqueue(_ handoff: DocumentViewHandoff, for url: URL) {
        let key = url.standardizedFileURL
        handoffs[key] = handoff
        handoffRequests.send(key)
    }

    func takeHandoff(for url: URL, id: UUID) -> DocumentViewHandoff? {
        let key = url.standardizedFileURL
        guard let handoff = handoffs[key], handoff.id == id else { return nil }
        handoffs.removeValue(forKey: key)
        return handoff
    }

    func cancelHandoff(for url: URL) {
        handoffs.removeValue(forKey: url.standardizedFileURL)
    }

    func openInTab(_ url: URL, beside sourceWindow: NSWindow?) async throws {
        let (document, alreadyOpen) = try await openDocument(at: url, display: true)

        guard let destination = document.windowControllers.compactMap(\.window).first else {
            throw CocoaError(.fileReadUnknown)
        }
        if !alreadyOpen, let sourceWindow, sourceWindow !== destination {
            sourceWindow.addTabbedWindow(destination, ordered: .above)
        }
        destination.makeKeyAndOrderFront(nil)
    }

    func openInWindow(_ url: URL) async throws {
        let (document, alreadyOpen) = try await openDocument(at: url, display: false)
        if !alreadyOpen, document.windowControllers.isEmpty {
            document.makeWindowControllers()
        }
        guard let destination = document.windowControllers.compactMap(\.window).first else {
            throw CocoaError(.fileReadUnknown)
        }
        if !alreadyOpen {
            destination.tabbingMode = .disallowed
            document.showWindows()
        }
        destination.makeKeyAndOrderFront(nil)
    }

    private func openDocument(at url: URL, display: Bool) async throws -> (NSDocument, Bool) {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<(NSDocument, Bool), Error>) in
            NSDocumentController.shared.openDocument(withContentsOf: url, display: display) {
                document, alreadyOpen, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let document {
                    continuation.resume(returning: (document, alreadyOpen))
                } else {
                    continuation.resume(throwing: CocoaError(.fileReadUnknown))
                }
            }
        }
    }
}
#endif

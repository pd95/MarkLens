#if os(macOS)
import AppKit
import SwiftUI

/// Gives AppKit a stable frame autosave name for each document window.
@MainActor
final class DocumentWindowFrameAutosave {
    private let namespace: String
    private weak var registeredWindow: NSWindow?
    private var registeredName: String?

    init(namespace: String = "MarkLens.DocumentWindow") {
        self.namespace = namespace
    }

    func update(window: NSWindow, fileURL: URL?) {
        guard let fileURL else { return }

        let name = frameName(for: fileURL)
        guard registeredWindow !== window || registeredName != name else { return }

        // Save As and windows joining a tab group keep their current placement.
        if registeredWindow === window || (window.tabGroup?.windows.count ?? 0) > 1 {
            window.saveFrame(usingName: name)
        }

        guard window.setFrameAutosaveName(name) else { return }
        registeredWindow = window
        registeredName = name

        let screens = [NSScreen.main].compactMap { $0 }
            + NSScreen.screens.filter { $0 !== NSScreen.main }
        if let frame = Self.fittedFrame(window.frame, to: screens.map(\.visibleFrame)),
           frame != window.frame {
            window.setFrame(frame, display: true)
        }
    }

    func frameName(for fileURL: URL) -> String {
        let path = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        return "\(namespace).File.\(path)"
    }

    /// Fits a restored frame wholly within the best available screen.
    static func fittedFrame(_ frame: NSRect, to visibleFrames: [NSRect]) -> NSRect? {
        guard frame.width.isFinite, frame.height.isFinite, frame.minX.isFinite, frame.minY.isFinite,
              frame.width > 0, frame.height > 0 else { return nil }

        let screens = visibleFrames.filter { $0.width > 0 && $0.height > 0 }
        guard let preferred = screens.first else { return nil }
        if isFullyVisible(frame, on: screens) { return frame }

        let screen = screens.dropFirst().reduce(preferred) { best, candidate in
            let bestOverlap = frame.intersection(best)
            let candidateOverlap = frame.intersection(candidate)
            let bestArea = bestOverlap.width * bestOverlap.height
            let candidateArea = candidateOverlap.width * candidateOverlap.height
            return candidateArea > bestArea ? candidate : best
        }
        let width = min(frame.width, screen.width)
        let height = min(frame.height, screen.height)
        return NSRect(
            x: min(max(frame.minX, screen.minX), screen.maxX - width),
            y: min(max(frame.minY, screen.minY), screen.maxY - height),
            width: width,
            height: height
        )
    }

    private static func isFullyVisible(_ frame: NSRect, on screens: [NSRect]) -> Bool {
        var uncovered = [frame]
        for screen in screens {
            uncovered = uncovered.flatMap { area -> [NSRect] in
                let overlap = area.intersection(screen)
                guard overlap.width > 0, overlap.height > 0 else { return [area] }

                return [
                    NSRect(x: area.minX, y: area.minY, width: overlap.minX - area.minX, height: area.height),
                    NSRect(x: overlap.maxX, y: area.minY, width: area.maxX - overlap.maxX, height: area.height),
                    NSRect(x: overlap.minX, y: area.minY, width: overlap.width, height: overlap.minY - area.minY),
                    NSRect(x: overlap.minX, y: overlap.maxY, width: overlap.width, height: area.maxY - overlap.maxY),
                ].filter { $0.width > 0 && $0.height > 0 }
            }
            if uncovered.isEmpty { return true }
        }
        return false
    }
}

/// A zero-size SwiftUI child supplies its containing document window to AppKit.
final class DocumentWindowFrameAutosaveView: NSView {
    let autosave = DocumentWindowFrameAutosave()
    var fileURL: URL? {
        didSet { updateAutosaveName() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAutosaveName()
    }

    private func updateAutosaveName() {
        guard let window else { return }
        autosave.update(window: window, fileURL: fileURL)
    }
}

struct DocumentWindowFrameAutosaveBridge: NSViewRepresentable {
    let fileURL: URL?

    func makeNSView(context: Context) -> DocumentWindowFrameAutosaveView {
        DocumentWindowFrameAutosaveView(frame: .zero)
    }

    func updateNSView(_ view: DocumentWindowFrameAutosaveView, context: Context) {
        view.fileURL = fileURL
    }
}
#endif

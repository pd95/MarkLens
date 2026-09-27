#if os(macOS)
import AppKit
import SwiftUI

/// Persists document window frames through AppKit's named frame storage.
@MainActor
final class WindowPlacementCoordinator {
    private final class WindowEntry {
        weak var window: NSWindow?
        var fileURL: URL?
        var awaitingFileURL: Bool
        var isRestoring = false

        init(window: NSWindow, fileURL: URL?, awaitingFileURL: Bool) {
            self.window = window
            self.fileURL = fileURL
            self.awaitingFileURL = awaitingFileURL
        }
    }

    private let namespace: String
    private var windows: [ObjectIdentifier: WindowEntry] = [:]
    private var pendingSaves: [ObjectIdentifier: Timer] = [:]
    private weak var lastActiveWindow: NSWindow?

    init(namespace: String = "MarkLens.DocumentWindow") {
        self.namespace = namespace
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowGeometryChanged(_:)), name: NSWindow.didMoveNotification, object: nil)
        center.addObserver(self, selector: #selector(windowGeometryChanged(_:)), name: NSWindow.didResizeNotification, object: nil)
        center.addObserver(self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: nil)
        center.addObserver(self, selector: #selector(windowBecameKey(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(applicationWillTerminate(_:)), name: NSApplication.willTerminateNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func track(_ window: NSWindow, fileURL: URL?, isUntitled: Bool) {
        let id = ObjectIdentifier(window)
        if let entry = windows[id] {
            guard entry.fileURL != fileURL else { return }
            if entry.awaitingFileURL, fileURL != nil {
                entry.fileURL = fileURL
                entry.awaitingFileURL = false
                restore(window, for: fileURL, entry: entry)
                return
            }

            // Save As adopts the current frame without moving the open window.
            if let oldURL = entry.fileURL, !window.styleMask.contains(.fullScreen) {
                window.saveFrame(usingName: frameName(for: oldURL))
            }
            entry.fileURL = fileURL
            if let fileURL, !window.styleMask.contains(.fullScreen) {
                window.saveFrame(usingName: frameName(for: fileURL))
            }
            return
        }

        let entry = WindowEntry(window: window, fileURL: fileURL, awaitingFileURL: fileURL == nil && !isUntitled)
        windows[id] = entry
        if window.isKeyWindow { lastActiveWindow = window }
        if !entry.awaitingFileURL {
            restore(window, for: fileURL, entry: entry)
        }
    }

    func frameName(for fileURL: URL) -> String {
        let path = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        return "\(namespace).File.\(path)"
    }

    var fallbackFrameName: String { "\(namespace).LastDocument" }

    private func restore(_ window: NSWindow, for fileURL: URL?, entry: WindowEntry) {
        // A document joining an existing tab group must keep the group's frame.
        guard (window.tabGroup?.windows.count ?? 0) <= 1 else { return }
        entry.isRestoring = true
        defer { entry.isRestoring = false }
        let restoredFileFrame = fileURL.map { window.setFrameUsingName(frameName(for: $0)) } ?? false
        let restored = restoredFileFrame || window.setFrameUsingName(fallbackFrameName)
        guard restored else { return }

        let screens = NSScreen.screens
        let orderedScreens = [NSScreen.main].compactMap { $0 } + screens.filter { $0 !== NSScreen.main }
        if let frame = Self.constrainedFrame(window.frame, to: orderedScreens.map(\.visibleFrame)),
           frame != window.frame {
            window.setFrame(frame, display: true)
        }
    }

    /// Preserves reachable frames, fitting only those whose title bar is no longer reachable.
    static func constrainedFrame(_ frame: NSRect, to visibleFrames: [NSRect]) -> NSRect? {
        guard frame.width.isFinite, frame.height.isFinite, frame.minX.isFinite, frame.minY.isFinite,
              frame.width > 0, frame.height > 0 else { return nil }
        let screens = visibleFrames.filter { $0.width > 0 && $0.height > 0 }
        guard let first = screens.first else { return nil }
        let titleBarHeight = min(frame.height, 32)
        let titleBar = NSRect(
            x: frame.minX,
            y: frame.maxY - titleBarHeight,
            width: frame.width,
            height: titleBarHeight
        )
        if screens.contains(where: { screen in
            let reachable = titleBar.intersection(screen)
            return reachable.width >= min(frame.width, 80)
                && reachable.height >= min(titleBarHeight, 20)
        }) {
            return frame
        }
        let screen = screens.max { first, second in
            let firstOverlap = frame.intersection(first)
            let secondOverlap = frame.intersection(second)
            return firstOverlap.width * firstOverlap.height < secondOverlap.width * secondOverlap.height
        } ?? first
        let width = min(frame.width, screen.width)
        let height = min(frame.height, screen.height)
        return NSRect(
            x: min(max(frame.minX, screen.minX), screen.maxX - width),
            y: min(max(frame.minY, screen.minY), screen.maxY - height),
            width: width,
            height: height
        )
    }

    func saveNow(_ window: NSWindow, updateFallback: Bool = true) {
        guard let entry = windows[ObjectIdentifier(window)], !entry.awaitingFileURL, !entry.isRestoring,
              !window.styleMask.contains(.fullScreen) else { return }

        // A tab group has one visible frame. Give each document tab that frame.
        for member in window.tabGroup?.windows ?? [window] {
            if let fileURL = windows[ObjectIdentifier(member)]?.fileURL {
                window.saveFrame(usingName: frameName(for: fileURL))
            }
        }
        if updateFallback {
            window.saveFrame(usingName: fallbackFrameName)
        }
    }

    @objc private func windowGeometryChanged(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let id = ObjectIdentifier(window)
        guard let entry = windows[id], !entry.awaitingFileURL, !entry.isRestoring else { return }
        pendingSaves[id]?.invalidate()
        pendingSaves[id] = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self, weak window] _ in
            Task { @MainActor [weak self, weak window] in
                self?.pendingSaves.removeValue(forKey: id)
                if let window { self?.saveNow(window) }
            }
        }
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let id = ObjectIdentifier(window)
        guard windows[id] != nil else { return }
        pendingSaves.removeValue(forKey: id)?.invalidate()
        saveNow(window)
        windows.removeValue(forKey: id)
    }

    @objc private func windowBecameKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              windows[ObjectIdentifier(window)] != nil else { return }
        lastActiveWindow = window
    }

    @objc private func applicationWillTerminate(_ notification: Notification) {
        for (id, entry) in windows {
            pendingSaves.removeValue(forKey: id)?.invalidate()
            if let window = entry.window {
                saveNow(window, updateFallback: false)
            }
        }
        if let window = lastActiveWindow, windows[ObjectIdentifier(window)] != nil {
            saveNow(window)
        } else if let window = windows.values.compactMap(\.window).first {
            saveNow(window)
        }
    }
}

/// A zero-size document child view supplies its containing NSWindow to the coordinator.
final class DocumentWindowPlacementView: NSView {
    weak var placement: WindowPlacementCoordinator?
    var fileURL: URL?
    var isUntitled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportWindow()
    }

    func reportWindow() {
        guard let window, let placement else { return }
        placement.track(window, fileURL: fileURL, isUntitled: isUntitled)
    }
}

struct DocumentWindowPlacement: NSViewRepresentable {
    let fileURL: URL?
    let isUntitled: Bool
    let placement: WindowPlacementCoordinator

    func makeNSView(context: Context) -> DocumentWindowPlacementView {
        DocumentWindowPlacementView(frame: .zero)
    }

    func updateNSView(_ view: DocumentWindowPlacementView, context: Context) {
        view.placement = placement
        view.fileURL = fileURL
        view.isUntitled = isUntitled
        view.reportWindow()
    }
}
#endif

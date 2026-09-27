import Cocoa

/// App delegate used to control macOS application behaviour.
/// The `applicationShouldTerminateAfterLastWindowClosed` method returns
/// `true` when the *Automatic Quit* mode is enabled. The mode can be
/// toggled by writing to the `exitAfterLastWindow`.
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var exitAfterLastWindow: Bool = false
    let lineNavigation = LineNavigationCoordinator()
    let localDocumentAccess = LocalDocumentAccess()
    
    // MARK: - NSApplicationDelegate
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return exitAfterLastWindow
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let destination = LineNavigationCoordinator.incomingDestination(from: url) else {
                showOpenError("This MarkLens link is not valid.")
                continue
            }
            openIncomingDocument(destination.fileURL, line: destination.line)
        }
    }

    private func openIncomingDocument(_ fileURL: URL, line: Int) {
        lineNavigation.enqueue(fileURL: fileURL, line: line)
        NSDocumentController.shared.openDocument(withContentsOf: fileURL, display: true) {
            [weak self] _, _, error in
            guard let self, let error else { return }
            if self.localDocumentAccess.hasAccess(to: fileURL) {
                self.lineNavigation.cancel(for: fileURL)
                self.showOpenError(error.localizedDescription)
            } else {
                self.requestAccess(to: fileURL, line: line)
            }
        }
    }

    private func requestAccess(to fileURL: URL, line: Int) {
        let folder = fileURL.deletingLastPathComponent()
        let panel = NSOpenPanel()
        panel.title = "Allow Access to Linked Document"
        panel.message = "Choose the \(folder.lastPathComponent) folder to open \(fileURL.lastPathComponent)."
        panel.prompt = "Allow Access"
        panel.directoryURL = folder
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard let self else { return }
            guard response == .OK, let selected = panel.url else {
                self.lineNavigation.cancel(for: fileURL)
                return
            }
            guard LocalDocumentAccess.sameFolder(selected, folder) else {
                selected.stopAccessingSecurityScopedResource()
                self.lineNavigation.cancel(for: fileURL)
                self.showOpenError("Choose the \(folder.lastPathComponent) folder.")
                return
            }
            do {
                try self.localDocumentAccess.authorize(folder: selected)
                self.openIncomingDocument(fileURL, line: line)
            } catch {
                self.lineNavigation.cancel(for: fileURL)
                self.showOpenError(error.localizedDescription)
            }
        }
    }

    private func showOpenError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Unable to Open Link"
        alert.informativeText = message
        alert.runModal()
    }
}

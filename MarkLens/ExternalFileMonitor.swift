#if os(macOS)
import AppKit
import Darwin
import Dispatch
import Foundation

@MainActor
final class ExternalFileMonitor {
    struct Timing {
        var quietPeriod: Duration
        var maximumDelay: Duration
        var reconnectDelay: Duration

        nonisolated static let standard = Timing(
            quietPeriod: .milliseconds(350),
            maximumDelay: .seconds(2),
            reconnectDelay: .milliseconds(250)
        )
    }

    typealias ChangeHandler = @MainActor () -> Void

    private let fileURL: URL
    private let changeHandler: ChangeHandler
    private let timing: Timing
    private let clock = ContinuousClock()
    private var source: DispatchSourceFileSystemObject?
    private var deliveryTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var pendingChangeStartedAt: ContinuousClock.Instant?
    private var lastChangeDetectedAt: ContinuousClock.Instant?
    private var generation: UInt64 = 0
    private var sourceGeneration: UInt64 = 0
    private var isActive = true
    private var observedContents: Data?

    init(
        fileURL: URL,
        timing: Timing = .standard,
        changeHandler: @escaping ChangeHandler
    ) {
        self.fileURL = fileURL.standardizedFileURL
        self.changeHandler = changeHandler
        self.timing = timing
        observedContents = try? Data(contentsOf: self.fileURL)

        if installSource() == false {
            scheduleReconnect()
        }
    }

    deinit {
        deliveryTask?.cancel()
        reconnectTask?.cancel()
        source?.cancel()
    }

    func stop() {
        isActive = false
        generation &+= 1
        sourceGeneration &+= 1
        deliveryTask?.cancel()
        deliveryTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        source?.cancel()
        source = nil
        pendingChangeStartedAt = nil
        lastChangeDetectedAt = nil
    }

    private func recordDetectedChange() {
        guard isActive else { return }
        let now = clock.now
        if pendingChangeStartedAt == nil {
            pendingChangeStartedAt = now
        }
        lastChangeDetectedAt = now
        scheduleDelivery()
    }

    private func scheduleDelivery() {
        guard isActive,
              let pendingChangeStartedAt,
              let lastChangeDetectedAt else {
            return
        }

        generation &+= 1
        let deliveryGeneration = generation
        deliveryTask?.cancel()
        let deadline = min(
            lastChangeDetectedAt + timing.quietPeriod,
            pendingChangeStartedAt + timing.maximumDelay
        )
        let delay = clock.now.duration(to: deadline)
        deliveryTask = Task { [weak self] in
            do {
                if delay > .zero {
                    try await Task.sleep(for: delay)
                }
                guard let self,
                      isActive,
                      generation == deliveryGeneration else {
                    return
                }
                deliveryTask = nil
                self.pendingChangeStartedAt = nil
                self.lastChangeDetectedAt = nil
                let fileURL = self.fileURL
                let observedContents = self.observedContents
                let snapshot = await Task.detached(priority: .utility) {
                    let contents = try? Data(contentsOf: fileURL)
                    return (contents: contents, changed: contents != observedContents)
                }.value
                guard isActive,
                      generation == deliveryGeneration,
                      snapshot.changed else {
                    return
                }
                self.observedContents = snapshot.contents
                changeHandler()
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func scheduleReconnect() {
        guard isActive else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            do {
                guard let self else { return }
                try await Task.sleep(for: timing.reconnectDelay)
                guard isActive else { return }
                if installSource() {
                    reconnectTask = nil
                    recordDetectedChange()
                } else {
                    scheduleReconnect()
                }
            } catch {
                return
            }
        }
    }

    private func installSource() -> Bool {
        guard isActive else { return false }
        let descriptor = open(fileURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return false }

        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .attrib, .extend, .link, .revoke],
            queue: .main
        )
        sourceGeneration &+= 1
        let installedGeneration = sourceGeneration
        newSource.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.sourceDidChange(installedGeneration: installedGeneration)
            }
        }
        newSource.setCancelHandler {
            close(descriptor)
        }
        source = newSource
        newSource.resume()
        return true
    }

    private func sourceDidChange(installedGeneration: UInt64) {
        guard isActive, sourceGeneration == installedGeneration else { return }
        recordDetectedChange()
        sourceGeneration &+= 1
        source?.cancel()
        source = nil
        if installSource() == false {
            scheduleReconnect()
        }
    }
}

@MainActor
protocol ManagedDocumentReloading: AnyObject {
    var hasLocalChanges: Bool { get }
    func markLocalVersionForSaving()
    func reloadFromDisk() throws
}

@MainActor
private final class AppKitManagedDocument: ManagedDocumentReloading {
    private let document: NSDocument

    init(document: NSDocument) {
        self.document = document
    }

    var hasLocalChanges: Bool {
        document.isDocumentEdited || document.hasUnautosavedChanges
    }

    func markLocalVersionForSaving() {
        document.updateChangeCount(.changeDone)
    }

    func reloadFromDisk() throws {
        guard let fileURL = document.fileURL, let fileType = document.fileType else {
            throw CocoaError(.fileNoSuchFile)
        }
        try document.revert(toContentsOf: fileURL, ofType: fileType)
    }
}

@MainActor
final class ExternalDocumentReloadCoordinator {
    enum Result {
        case deferred
        case reloaded
        case unavailable
        case failed(Error)
    }

    typealias Resolver = @MainActor (URL) -> (any ManagedDocumentReloading)?
    private let fileURL: URL
    private let resolver: Resolver
    private(set) var hasDeferredChange = false
    private var hasPendingLocalVersion = false
    private var didRequestPendingLocalSave = false
    private var didObservePendingLocalChanges = false

    init(fileURL: URL, resolver: Resolver? = nil) {
        self.fileURL = fileURL.standardizedFileURL
        self.resolver = resolver ?? ExternalDocumentReloadCoordinator.resolveDocument
    }

    func handleChange(isEditing: Bool) -> Result {
        guard let document = resolver(fileURL) else {
            hasDeferredChange = true
            return .unavailable
        }

        if hasPendingLocalVersion {
            if didRequestPendingLocalSave == false {
                document.markLocalVersionForSaving()
                didRequestPendingLocalSave = true
            }
            if document.hasLocalChanges {
                didObservePendingLocalChanges = true
                hasDeferredChange = true
                return .deferred
            }
            guard didObservePendingLocalChanges else {
                hasDeferredChange = true
                return .deferred
            }
            hasPendingLocalVersion = false
            didRequestPendingLocalSave = false
            didObservePendingLocalChanges = false
        }

        guard isEditing == false, document.hasLocalChanges == false else {
            hasDeferredChange = true
            return .deferred
        }

        do {
            try document.reloadFromDisk()
            hasDeferredChange = false
            return .reloaded
        } catch {
            hasDeferredChange = true
            return .failed(error)
        }
    }

    func resumeDeferredChange(isEditing: Bool) -> Result? {
        guard hasDeferredChange else { return nil }
        return handleChange(isEditing: isEditing)
    }

    func preserveLocalVersionForSaving() {
        hasDeferredChange = true
        hasPendingLocalVersion = true
        didRequestPendingLocalSave = false
        didObservePendingLocalChanges = false
        guard let document = resolver(fileURL) else { return }
        document.markLocalVersionForSaving()
        didRequestPendingLocalSave = true
        didObservePendingLocalChanges = document.hasLocalChanges
    }

    private static func resolveDocument(at fileURL: URL) -> (any ManagedDocumentReloading)? {
        guard let document = NSDocumentController.shared.document(for: fileURL) else {
            return nil
        }
        return AppKitManagedDocument(document: document)
    }
}
#endif

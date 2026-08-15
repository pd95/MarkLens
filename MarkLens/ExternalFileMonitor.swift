#if os(macOS)
import Darwin
import Dispatch
import Foundation

@MainActor
final class ExternalFileMonitor {
    struct ReloadTiming {
        var appendDelay: Duration
        var rewriteQuietPeriod: Duration
        var maximumRewriteDelay: Duration
        var stabilityInterval: Duration
        var reconnectDelay: Duration

        static let standard = ReloadTiming(
            appendDelay: .seconds(1),
            rewriteQuietPeriod: .seconds(3),
            maximumRewriteDelay: .seconds(10),
            stabilityInterval: .milliseconds(75),
            reconnectDelay: .milliseconds(250)
        )
    }

    enum InspectionResult {
        case unchanged
        case changed(String)
        case unavailable(Error)
        case cancelled
    }

    enum ReplacementError: Error {
        case fileChanged(String)
    }

    typealias ChangeHandler = @MainActor (String) -> Void

    private let fileURL: URL
    private let changeHandler: ChangeHandler
    private let timing: ReloadTiming
    private let clock = ContinuousClock()
    private var source: DispatchSourceFileSystemObject?
    private var reloadTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var lastContents: Data
    private var pendingChangeStartedAt: ContinuousClock.Instant?
    private var lastChangeDetectedAt: ContinuousClock.Instant?
    private var pendingChangeIsRewrite = false
    private var generation: UInt64 = 0
    private var sourceGeneration: UInt64 = 0
    private var isActive = true

    init(
        fileURL: URL,
        initialText: String,
        timing: ReloadTiming = .standard,
        changeHandler: @escaping ChangeHandler
    ) {
        self.fileURL = fileURL.standardizedFileURL
        self.changeHandler = changeHandler
        self.timing = timing
        self.lastContents = Data(initialText.utf8)

        if installSource() {
            refresh()
        } else {
            scheduleReconnect()
        }
    }

    deinit {
        reloadTask?.cancel()
        reconnectTask?.cancel()
        source?.cancel()
    }

    func refresh() {
        recordDetectedChange()
    }

    func stop() {
        invalidatePendingWork()
        isActive = false
        sourceGeneration &+= 1
        source?.cancel()
        source = nil
    }

    func inspectForExternalChange() async -> InspectionResult {
        let operationGeneration = beginResolution()
        do {
            let contents = try await stableContents()
            guard isCurrent(operationGeneration) else {
                return .cancelled
            }
            replaceSource()
            guard contents != lastContents else {
                return .unchanged
            }
            guard let text = String(data: contents, encoding: .utf8) else {
                return .unavailable(CocoaError(.fileReadInapplicableStringEncoding))
            }
            lastContents = contents
            return .changed(text)
        } catch {
            guard isCurrent(operationGeneration) else {
                return .cancelled
            }
            replaceSource()
            return .unavailable(error)
        }
    }

    func replaceFile(with text: String) async throws {
        let operationGeneration = beginResolution()
        guard isCurrent(operationGeneration) else {
            throw CancellationError()
        }
        let expectedContents = lastContents
        let currentContents = try await stableContents()
        guard isCurrent(operationGeneration) else {
            throw CancellationError()
        }
        guard currentContents == expectedContents else {
            replaceSource()
            guard let currentText = String(data: currentContents, encoding: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            lastContents = currentContents
            throw ReplacementError.fileChanged(currentText)
        }

        let fileURL = fileURL
        let contents = Data(text.utf8)
        try await Task.detached(priority: .userInitiated) {
            try contents.write(to: fileURL, options: .atomic)
        }.value

        guard isCurrent(operationGeneration) else {
            throw CancellationError()
        }
        lastContents = contents
        replaceSource()
    }

    func currentFileText() async throws -> String {
        let operationGeneration = beginResolution()
        guard isCurrent(operationGeneration) else {
            throw CancellationError()
        }
        let contents = try await stableContents()
        guard isCurrent(operationGeneration) else {
            throw CancellationError()
        }
        guard let text = String(data: contents, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        lastContents = contents
        replaceSource()
        return text
    }

    private func scheduleReload() {
        guard isActive,
              let pendingChangeStartedAt,
              let lastChangeDetectedAt else {
            return
        }
        generation &+= 1
        let reloadGeneration = generation
        reloadTask?.cancel()
        let deadline: ContinuousClock.Instant
        if pendingChangeIsRewrite {
            deadline = min(
                lastChangeDetectedAt + timing.rewriteQuietPeriod,
                pendingChangeStartedAt + timing.maximumRewriteDelay
            )
        } else {
            deadline = pendingChangeStartedAt + timing.appendDelay
        }
        let delay = clock.now.duration(to: deadline)
        reloadTask = Task { [weak self] in
            do {
                if delay > .zero {
                    try await Task.sleep(for: delay)
                }
                guard let self else { return }
                try await evaluatePendingChange(generation: reloadGeneration)
            } catch is CancellationError {
                return
            } catch {
                guard let self, isCurrent(reloadGeneration) else { return }
                reinstallSourceAfterReadFailure()
            }
        }
    }

    private func evaluatePendingChange(generation reloadGeneration: UInt64) async throws {
        let contents = try await readContents()
        guard isCurrent(reloadGeneration) else {
            return
        }
        guard contents != lastContents else {
            clearPendingChange()
            return
        }

        if contents.count > lastContents.count, contents.starts(with: lastContents) {
            deliver(contents)
            return
        }

        pendingChangeIsRewrite = true
        guard let pendingChangeStartedAt, let lastChangeDetectedAt else {
            return
        }
        let now = clock.now
        if now >= pendingChangeStartedAt + timing.maximumRewriteDelay {
            deliver(contents)
        } else if now >= lastChangeDetectedAt + timing.rewriteQuietPeriod {
            let stableContents = try await stableContents(startingWith: contents)
            guard isCurrent(reloadGeneration) else {
                return
            }
            deliver(stableContents)
        } else {
            scheduleReload()
        }
    }

    private func deliver(_ contents: Data) {
        guard let text = String(data: contents, encoding: .utf8) else {
            scheduleRetry()
            return
        }
        lastContents = contents
        clearPendingChange()
        changeHandler(text)
    }

    private func recordDetectedChange() {
        guard isActive else {
            return
        }
        let now = clock.now
        if pendingChangeStartedAt == nil {
            pendingChangeStartedAt = now
            pendingChangeIsRewrite = false
        }
        lastChangeDetectedAt = now
        scheduleReload()
    }

    private func scheduleRetry(after delay: Duration? = nil) {
        guard isActive else {
            return
        }
        generation &+= 1
        let reloadGeneration = generation
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            do {
                guard let self else { return }
                try await Task.sleep(for: delay ?? timing.stabilityInterval)
                try await evaluatePendingChange(generation: reloadGeneration)
            } catch is CancellationError {
                return
            } catch {
                guard let self, isCurrent(reloadGeneration) else { return }
                reinstallSourceAfterReadFailure()
            }
        }
    }

    private func clearPendingChange() {
        reloadTask = nil
        pendingChangeStartedAt = nil
        lastChangeDetectedAt = nil
        pendingChangeIsRewrite = false
    }

    private func restartPendingChangeWindow() {
        generation &+= 1
        reloadTask?.cancel()
        clearPendingChange()
        recordDetectedChange()
    }

    private func stableContents() async throws -> Data {
        let first = try await readContents()
        return try await stableContents(startingWith: first)
    }

    private func stableContents(startingWith first: Data) async throws -> Data {
        try await Task.sleep(for: timing.stabilityInterval)
        let second = try await readContents()
        guard first == second else {
            throw CocoaError(.fileReadUnknown)
        }
        return second
    }

    private func readContents() async throws -> Data {
        let fileURL = fileURL
        return try await Task.detached(priority: .userInitiated) {
            try Data(contentsOf: fileURL)
        }.value
    }

    private func beginResolution() -> UInt64 {
        invalidatePendingWork()
        sourceGeneration &+= 1
        source?.cancel()
        source = nil
        return generation
    }

    private func invalidatePendingWork() {
        generation &+= 1
        reloadTask?.cancel()
        reloadTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        pendingChangeStartedAt = nil
        lastChangeDetectedAt = nil
        pendingChangeIsRewrite = false
    }

    private func isCurrent(_ operationGeneration: UInt64) -> Bool {
        isActive && generation == operationGeneration && Task.isCancelled == false
    }

    private func replaceSource() {
        sourceGeneration &+= 1
        source?.cancel()
        source = nil
        guard isActive else {
            return
        }
        if installSource() {
            recordDetectedChange()
        } else {
            scheduleReconnect()
        }
    }

    private func reinstallSourcePreservingPendingChange() {
        sourceGeneration &+= 1
        source?.cancel()
        source = nil
        guard isActive else {
            return
        }
        if installSource() == false {
            scheduleReconnect()
        }
    }

    private func reinstallSourceAfterReadFailure() {
        reinstallSourcePreservingPendingChange()
        if source != nil {
            scheduleRetry(after: timing.reconnectDelay)
        }
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            do {
                try await Task.sleep(for: timing.reconnectDelay)
                guard let self, isActive else { return }
                if installSource() {
                    restartPendingChangeWindow()
                } else {
                    scheduleReconnect()
                }
            } catch {
                return
            }
        }
    }

    private func installSource() -> Bool {
        guard isActive else {
            return false
        }
        let descriptor = open(fileURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            return false
        }

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
        guard isActive, sourceGeneration == installedGeneration else {
            return
        }
        recordDetectedChange()
        reinstallSourcePreservingPendingChange()
    }
}
#endif

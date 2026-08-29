import Foundation
import MarkdownPipeline
import SwiftUI
import WebKit
#if canImport(os)
import os
#endif

#if os(macOS)
import AppKit
typealias PlatformViewRepresentable = NSViewRepresentable
typealias PlatformView = NSView
typealias PlatformImage = NSImage
typealias PlatformImageView = NSImageView
#else
import UIKit
typealias PlatformViewRepresentable = UIViewRepresentable
typealias PlatformView = UIView
typealias PlatformImage = UIImage
typealias PlatformImageView = UIImageView
#endif

struct MarkdownWebView: PlatformViewRepresentable {

    var html: String
    var contentIdentity: String
    var resources: [HTMLResource]
    var customCSS: String
    var documentURL: URL?
    var openDocument: (URL) async throws -> Void
    var openWikiLink: (String) -> Void
    var requestLocalDocumentAccess: (URL, String) -> Void
    var localImagePermissionDenied: (URL) -> Void
    var reloadRequest: Int
    @Binding var outputRequest: RenderedDocumentOutputRequest?
    @Binding var activeOutputOperationID: UUID?
    var outputFailed: (String, String) -> Void
    @Binding var findMatchCount: Int
    @Binding var findCurrentIndex: Int
    var findTerm: String
    var findRequest: Int
    var findBackwards: Bool
    var findAnchorRequest: Int
    var findSelectionAction: (String) -> Void
    @Binding var scrollPosition: DocumentScrollPosition
    var scrollTarget: DocumentScrollPosition
    var scrollRequest: Int
    private var baseURL: URL? {
        documentURL
    }

    init(
        html: String,
        contentIdentity: String = "",
        resources: [HTMLResource] = [],
        customCSS: String = "",
        documentURL: URL? = nil,
        openDocument: @escaping (URL) async throws -> Void = { _ in },
        openWikiLink: @escaping (String) -> Void = { _ in },
        requestLocalDocumentAccess: @escaping (URL, String) -> Void = { _, _ in },
        localImagePermissionDenied: @escaping (URL) -> Void = { _ in },
        reloadRequest: Int = 0,
        outputRequest: Binding<RenderedDocumentOutputRequest?> = .constant(nil),
        activeOutputOperationID: Binding<UUID?> = .constant(nil),
        outputFailed: @escaping (String, String) -> Void = { _, _ in },
        findMatchCount: Binding<Int> = .constant(0),
        findCurrentIndex: Binding<Int> = .constant(0),
        findTerm: String = "",
        findRequest: Int = 0,
        findBackwards: Bool = false,
        findAnchorRequest: Int = 0,
        findSelectionAction: @escaping (String) -> Void = { _ in },
        scrollPosition: Binding<DocumentScrollPosition> = .constant(.top),
        scrollTarget: DocumentScrollPosition = .top,
        scrollRequest: Int = 0
    ) {
        self.html = html
        self.contentIdentity = contentIdentity
        self.resources = resources
        self.customCSS = customCSS
        self.documentURL = documentURL
        self.openDocument = openDocument
        self.openWikiLink = openWikiLink
        self.requestLocalDocumentAccess = requestLocalDocumentAccess
        self.localImagePermissionDenied = localImagePermissionDenied
        self.reloadRequest = reloadRequest
        self._outputRequest = outputRequest
        self._activeOutputOperationID = activeOutputOperationID
        self.outputFailed = outputFailed
        self._findMatchCount = findMatchCount
        self._findCurrentIndex = findCurrentIndex
        self.findTerm = findTerm
        self.findRequest = findRequest
        self.findBackwards = findBackwards
        self.findAnchorRequest = findAnchorRequest
        self.findSelectionAction = findSelectionAction
        self._scrollPosition = scrollPosition
        self.scrollTarget = scrollTarget
        self.scrollRequest = scrollRequest
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    static func makeSecureConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        return configuration
    }

    func makeView(context: Context) -> WKWebView {
        let config = Self.makeSecureConfiguration()
        let resourceHandler = HTMLResourceSchemeHandler()
        resourceHandler.update(resources: resources)
        config.setURLSchemeHandler(resourceHandler, forURLScheme: Self.resourceScheme)
        config.userContentController.add(context.coordinator, name: Self.scrollMessageHandler)
        config.userContentController.addUserScript(WKUserScript(
            source: Self.scrollPositionScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        context.coordinator.resourceHandler = resourceHandler
#if os(macOS)
        let localImageHandler = LocalImageSchemeHandler()
        localImageHandler.documentURL = documentURL
        localImageHandler.allowedImageURLs = localImageURLs
        localImageHandler.permissionDenied = { [weak coordinator = context.coordinator] url in
            coordinator?.localImagePermissionDenied(url)
        }
        config.setURLSchemeHandler(localImageHandler, forURLScheme: Self.localImageScheme)
        config.userContentController.addUserScript(WKUserScript(
            source: Self.localImageScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        context.coordinator.localImageHandler = localImageHandler
#endif
        let webView = WKWebView(frame: .zero, configuration: config)
#if os(macOS)
        webView.setValue(false, forKey: "drawsBackground")
        webView.setAccessibilityIdentifier("previewWebView")
#else
        webView.accessibilityIdentifier = "previewWebView"
#endif
        webView.allowsLinkPreview = false
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.latestContentVersion = contentVersion

#if DEBUG && os(macOS)
        webView.isInspectable = true
#endif
        context.coordinator.authorizeInternalLoad()
        context.coordinator.beginWebViewLoad()
        webView.loadHTMLString(html, baseURL: baseURL)

        return webView
    }

    func updateView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self

        if context.environment.isPresented {
            context.coordinator.updateState()
        }
    }

    static func dismantleView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
#if DEBUG && os(macOS)
        view.isInspectable = false
#endif
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: Self.scrollMessageHandler)
        coordinator.searchGeneration += 1
        coordinator.cancelOutput()
        coordinator.removeReloadSnapshot()
        coordinator.endWebViewLoad()
        coordinator.endWebViewPostProcessing()
        coordinator.webView = nil
    }

#if os(macOS)
    func makeNSView(context: Context) -> WKWebView {
        makeView(context: context)
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        updateView(view, context: context)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        dismantleView(view, coordinator: coordinator)
    }
#else
    func makeUIView(context: Context) -> WKWebView {
        makeView(context: context)
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        updateView(view, context: context)
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        dismantleView(view, coordinator: coordinator)
    }
#endif

    // MARK: - Coordinator

    fileprivate struct ContentVersion: Equatable {
        let identity: String
        let documentURL: URL?
        let reloadRequest: Int
    }

    private var contentVersion: ContentVersion {
        ContentVersion(
            identity: contentIdentity,
            documentURL: documentURL,
            reloadRequest: reloadRequest
        )
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: MarkdownWebView
        weak var webView: WKWebView?
        var resourceHandler: HTMLResourceSchemeHandler?
#if os(macOS)
        weak var localImageHandler: LocalImageSchemeHandler?
#endif

        var isPageReady = false
        fileprivate var latestContentVersion: ContentVersion?
        var latestFindTerm = ""
        var latestFindRequest = 0
        var latestFindAnchorRequest = 0
        var latestCustomCSS: String?
        var isSearchInstalled = false
        var searchGeneration = 0
        var pendingOutputRequest: RenderedDocumentOutputRequest?
        var activeOutputRequest: RenderedDocumentOutputRequest?
        var latestScrollRequest = 0
        weak var reloadSnapshotView: PlatformImageView?
        var reloadGeneration = 0
        private var isInternalLoadAuthorized = false
#if canImport(os)
        private static let performanceLog = OSLog(
            subsystem: "ch.doapp.MarkLens",
            category: "WebView"
        )
        private var webViewLoadSignpostID: OSSignpostID?
        private var webViewPostProcessingSignpostID: OSSignpostID?
#endif

        init(parent: MarkdownWebView) {
            self.parent = parent
            super.init()
        }

        fileprivate func beginWebViewLoad() {
#if canImport(os)
            endWebViewLoad()
            let signpostID = OSSignpostID(log: Self.performanceLog)
            webViewLoadSignpostID = signpostID
            os_signpost(
                .begin,
                log: Self.performanceLog,
                name: "WebViewLoad",
                signpostID: signpostID
            )
#endif
        }

        fileprivate func authorizeInternalLoad() {
            isInternalLoadAuthorized = true
        }

        fileprivate func endWebViewLoad() {
#if canImport(os)
            guard let signpostID = webViewLoadSignpostID else { return }
            os_signpost(
                .end,
                log: Self.performanceLog,
                name: "WebViewLoad",
                signpostID: signpostID
            )
            webViewLoadSignpostID = nil
#endif
        }

        private func beginWebViewPostProcessing() {
#if canImport(os)
            endWebViewPostProcessing()
            let signpostID = OSSignpostID(log: Self.performanceLog)
            webViewPostProcessingSignpostID = signpostID
            os_signpost(
                .begin,
                log: Self.performanceLog,
                name: "WebViewPostProcessing",
                signpostID: signpostID
            )
#endif
        }

        fileprivate func endWebViewPostProcessing() {
#if canImport(os)
            guard let signpostID = webViewPostProcessingSignpostID else { return }
            os_signpost(
                .end,
                log: Self.performanceLog,
                name: "WebViewPostProcessing",
                signpostID: signpostID
            )
            webViewPostProcessingSignpostID = nil
#endif
        }

        func updateState() {
            let newContentVersion = parent.contentVersion
            let markdownChanged = newContentVersion != latestContentVersion
            let findTermChanged = parent.findTerm != latestFindTerm
            let findChanged = findTermChanged || parent.findRequest != latestFindRequest
            let findAnchorChanged = parent.findAnchorRequest != latestFindAnchorRequest
            let customCSSChanged = parent.customCSS != latestCustomCSS
            let scrollChanged = parent.scrollRequest != latestScrollRequest
            let restoreAfterSearch: (() -> Void)? = scrollChanged ? { [weak self] in
                self?.restoreScrollPosition()
            } : nil
            var searchUpdateScheduled = false

            if isPageReady && markdownChanged {
#if os(macOS)
                localImageHandler?.documentURL = parent.documentURL
                localImageHandler?.allowedImageURLs = parent.localImageURLs
#endif
                resourceHandler?.update(resources: parent.resources)
                isPageReady = false
                isSearchInstalled = false
                searchGeneration += 1
                reloadPage(animated: scrollChanged)
                latestContentVersion = newContentVersion
            } else if isPageReady {
                if customCSSChanged {
                    applyCustomCSS()
                }
                if findAnchorChanged {
                    latestFindAnchorRequest = parent.findAnchorRequest
                    if findChanged {
                        updateSearch(
                            command: findTermChanged ? "search" : searchCommand(),
                            includeSelection: true,
                            completion: restoreAfterSearch
                        )
                        searchUpdateScheduled = true
                        latestFindTerm = parent.findTerm
                        latestFindRequest = parent.findRequest
                    } else {
                        updateSearch(command: "anchor", completion: restoreAfterSearch)
                        searchUpdateScheduled = true
                    }
                } else if findChanged {
                    updateSearch(
                        command: findTermChanged ? "search" : searchCommand(),
                        completion: restoreAfterSearch
                    )
                    searchUpdateScheduled = true
                    latestFindTerm = parent.findTerm
                    latestFindRequest = parent.findRequest
                }
                if scrollChanged && searchUpdateScheduled == false {
                    restoreScrollPosition()
                }
            }

            handleOutputRequest()
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == MarkdownWebView.scrollMessageHandler,
                  let value = message.body as? [String: Any] else { return }

            let line = Self.optionalIntValue(value["line"])
            let progress = (value["progress"] as? NSNumber)?.doubleValue ?? 0
            let anchorIdentity = value["anchor"] as? String
            let anchorOccurrence = Self.optionalIntValue(value["occurrence"])
            let previousAnchorIdentity = value["previousAnchor"] as? String
            let nextAnchorIdentity = value["nextAnchor"] as? String
            let viewportOffset = (value["offset"] as? NSNumber)?.doubleValue ?? 0
            let position = DocumentScrollPosition(
                sourceLine: line,
                progress: min(max(progress, 0), 1),
                anchorIdentity: anchorIdentity,
                anchorOccurrence: anchorOccurrence,
                previousAnchorIdentity: previousAnchorIdentity,
                nextAnchorIdentity: nextAnchorIdentity,
                viewportOffset: min(max(viewportOffset, -100_000), 100_000)
            )
            Task { @MainActor in
                self.parent.scrollPosition = position
            }
        }

        private func restoreScrollPosition(completion: (() -> Void)? = nil) {
            guard let webView else {
                completion?()
                return
            }
            latestScrollRequest = parent.scrollRequest
            let arguments: [String: Any] = [
                "line": parent.scrollTarget.sourceLine.map { $0 as Any } ?? NSNull(),
                "progress": parent.scrollTarget.progress,
                "anchor": parent.scrollTarget.anchorIdentity.map { $0 as Any } ?? NSNull(),
                "occurrence": parent.scrollTarget.anchorOccurrence.map { $0 as Any } ?? NSNull(),
                "previousAnchor": parent.scrollTarget.previousAnchorIdentity.map { $0 as Any } ?? NSNull(),
                "nextAnchor": parent.scrollTarget.nextAnchorIdentity.map { $0 as Any } ?? NSNull(),
                "offset": parent.scrollTarget.viewportOffset
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: arguments),
                  let json = String(data: data, encoding: .utf8) else {
                completion?()
                return
            }
            webView.evaluateJavaScript("window.MarkLensScroll.restore(\(json));") { _, _ in
                completion?()
            }
        }

        private func reloadPage(animated: Bool) {
            guard let webView else { return }
            reloadGeneration += 1
            let generation = reloadGeneration
            removeReloadSnapshot()
            let html = parent.html
            let baseURL = parent.baseURL
            guard animated, reloadAnimationsEnabled else {
                authorizeInternalLoad()
                beginWebViewLoad()
                webView.loadHTMLString(html, baseURL: baseURL)
                return
            }

            webView.takeSnapshot(with: nil) { [weak self, weak webView] image, _ in
                guard let self,
                      let webView,
                      self.webView === webView,
                      self.reloadGeneration == generation else { return }
                if let image {
                    self.installReloadSnapshot(image, over: webView)
                }
                self.authorizeInternalLoad()
                self.beginWebViewLoad()
                webView.loadHTMLString(html, baseURL: baseURL)
            }
        }

        private var reloadAnimationsEnabled: Bool {
#if os(macOS)
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false
#else
            UIAccessibility.isReduceMotionEnabled == false
#endif
        }

        private func installReloadSnapshot(_ image: PlatformImage, over webView: WKWebView) {
            removeReloadSnapshot()
            let snapshotView = PlatformImageView(frame: webView.bounds)
#if os(macOS)
            snapshotView.image = image
            snapshotView.imageScaling = .scaleAxesIndependently
            snapshotView.autoresizingMask = [.width, .height]
            snapshotView.setAccessibilityElement(false)
#else
            snapshotView.image = image
            snapshotView.contentMode = .scaleToFill
            snapshotView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            snapshotView.isUserInteractionEnabled = false
            snapshotView.isAccessibilityElement = false
#endif
            webView.addSubview(snapshotView)
            reloadSnapshotView = snapshotView
        }

        private func finishReloadTransition() {
            guard let snapshotView = reloadSnapshotView else { return }
            if reloadAnimationsEnabled == false {
                removeReloadSnapshot()
                return
            }
#if os(macOS)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                snapshotView.animator().alphaValue = 0
            } completionHandler: { [weak self, weak snapshotView] in
                snapshotView?.removeFromSuperview()
                if self?.reloadSnapshotView === snapshotView {
                    self?.reloadSnapshotView = nil
                }
            }
#else
            UIView.animate(
                withDuration: 0.2,
                delay: 0,
                options: [.beginFromCurrentState, .curveEaseInOut]
            ) {
                snapshotView.alpha = 0
            } completion: { [weak self, weak snapshotView] _ in
                snapshotView?.removeFromSuperview()
                if self?.reloadSnapshotView === snapshotView {
                    self?.reloadSnapshotView = nil
                }
            }
#endif
        }

        fileprivate func removeReloadSnapshot() {
            reloadSnapshotView?.removeFromSuperview()
            reloadSnapshotView = nil
        }

        func localImagePermissionDenied(_ url: URL) {
            Task { @MainActor in
                parent.localImagePermissionDenied(url)
            }
        }

        private func searchCommand() -> String {
            parent.findBackwards ? "previous" : "next"
        }

        private func updateSearch(
            command: String,
            includeSelection: Bool = false,
            completion: (() -> Void)? = nil
        ) {
            guard let webView else {
                completion?()
                return
            }
            searchGeneration += 1
            let generation = searchGeneration

            installSearchIfNeeded(generation: generation) {
                self.runSearchCommand(
                    command,
                    includeSelection: includeSelection,
                    generation: generation,
                    in: webView,
                    completion: completion
                )
            }
        }

        private func installSearchIfNeeded(generation: Int, completion: @escaping () -> Void) {
            guard let webView else { return }

            if isSearchInstalled {
                completion()
                return
            }

            webView.evaluateJavaScript(Self.searchScript) { [weak self] _, _ in
                guard let self, generation == self.searchGeneration else { return }

                self.isSearchInstalled = true
                completion()
            }
        }

        private func runSearchCommand(
            _ command: String,
            includeSelection: Bool,
            generation: Int,
            in webView: WKWebView,
            completion: (() -> Void)? = nil
        ) {
            guard let jsonData = try? JSONSerialization.data(withJSONObject: [
                "command": command,
                "term": parent.findTerm,
                "includeSelection": includeSelection
            ]),
                  let jsonString = String(data: jsonData, encoding: .utf8) else {
                completion?()
                return
            }

            webView.evaluateJavaScript("window.MarkLensSearch.run(\(jsonString));") { [weak self] result, _ in
                guard let self, generation == self.searchGeneration else { return }

                let dictionary = result as? [String: Any]
                let count = Self.intValue(dictionary?["count"])
                let index = Self.intValue(dictionary?["index"])
                let selection = dictionary?["selection"] as? String

                Task { @MainActor in
                    self.parent.findMatchCount = count
                    self.parent.findCurrentIndex = index
                    if let selection, selection.isEmpty == false {
                        self.parent.findSelectionAction(selection)
                    }
                }
                completion?()
            }
        }

        private static func intValue(_ value: Any?) -> Int {
            if let int = value as? Int {
                return int
            }
            if let number = value as? NSNumber {
                return number.intValue
            }
            return 0
        }

        private static func optionalIntValue(_ value: Any?) -> Int? {
            guard let number = value as? NSNumber else { return nil }
            return number.intValue
        }

        private func applyCustomCSS(completion: (() -> Void)? = nil) {
            latestCustomCSS = parent.customCSS
            guard let webView else {
                completion?()
                return
            }
            webView.evaluateJavaScript(
                MarkdownWebView.customCSSUpdateScript(for: parent.customCSS)
            ) { _, _ in
                completion?()
            }
        }

        private static let searchScript: String = {
            guard let url = Bundle.main.url(forResource: "WebResources/preview-search", withExtension: "js"),
                  let script = try? String(contentsOf: url, encoding: .utf8) else {
                assertionFailure("Missing preview-search.js resource")
                return "window.MarkLensSearch = { run() { return { count: 0, index: 0 }; }, clear() { return { count: 0, index: 0 }; } };"
            }

            return script
        }()

        func handleOutputRequest() {
            guard let request = parent.outputRequest else { return }
            clearOutputBinding(for: request)
            guard activeOutputRequest == nil else { return }
            if isPageReady {
                scheduleOutput(request)
            } else {
                pendingOutputRequest = request
            }
        }

        private func scheduleOutput(_ request: RenderedDocumentOutputRequest) {
            guard activeOutputRequest == nil else { return }
            activeOutputRequest = request
            pendingOutputRequest = nil

            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                runOutput(request)
            }
        }

        func runOutput(_ request: RenderedDocumentOutputRequest) {
            guard let webView else {
                finishOutput(success: false)
                return
            }

#if os(macOS)
            let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
            printInfo.horizontalPagination = .fit
            printInfo.verticalPagination = .automatic

            let cmToPrint: Double = 72/2.54
            printInfo.leftMargin = 1.0 * cmToPrint
            printInfo.rightMargin = 1.0 * cmToPrint
            printInfo.topMargin = 1.0 * cmToPrint
            printInfo.bottomMargin = 1.0 * cmToPrint

            switch request.destination {
            case .print:
                printInfo.jobDisposition = .spool
            case .preview:
                printInfo.jobDisposition = .preview
            case .pdf(let url):
                printInfo.jobDisposition = .save
                printInfo.dictionary().setObject(
                    url as NSURL,
                    forKey: NSPrintInfo.AttributeKey.jobSavingURL.rawValue as NSString
                )
            }

            let printOperation = webView.printOperation(with: printInfo)
            printOperation.showsPrintPanel = request.destination == .print
            printOperation.showsProgressPanel = true
            printOperation.view?.frame = webView.bounds

            if let window = webView.window {
                printOperation.runModal(
                    for: window,
                    delegate: self,
                    didRun: #selector(printOperationDidRun(_:success:contextInfo:)),
                    contextInfo: nil
                )
            } else {
                finishOutput(success: printOperation.run())
            }
#else
            guard request.destination == .print else {
                finishOutput(success: false)
                return
            }
            let printController = UIPrintInteractionController.shared
            let printInfo = UIPrintInfo.printInfo()
            printInfo.jobName = "MarkLens"
            printController.printInfo = printInfo
            printController.printFormatter = webView.viewPrintFormatter()

            let wasPresented: Bool
            if UIDevice.current.userInterfaceIdiom == .pad {
                wasPresented = printController.present(
                    from: webView.bounds,
                    in: webView,
                    animated: true,
                    completionHandler: printCompletion
                )
            } else {
                wasPresented = printController.present(
                    animated: true,
                    completionHandler: printCompletion
                )
            }
            if wasPresented == false {
                finishOutput(success: false)
            }
#endif
        }

#if os(macOS)
        @objc private func printOperationDidRun(
            _ operation: NSPrintOperation,
            success: Bool,
            contextInfo: UnsafeMutableRawPointer?
        ) {
            finishOutput(success: success)
        }
#else
        private func printCompletion(
            _ controller: UIPrintInteractionController,
            _ completed: Bool,
            _ error: Error?
        ) {
            finishOutput(success: error == nil)
        }
#endif

        private func finishOutput(success: Bool) {
            guard let completedRequest = activeOutputRequest else { return }
            activeOutputRequest = nil
            pendingOutputRequest = nil
            if parent.activeOutputOperationID == completedRequest.id {
                parent.activeOutputOperationID = nil
            }

            guard success == false else { return }
            switch completedRequest.destination {
            case .print:
                break
            case .preview:
                parent.outputFailed(
                    "Unable to Open in Preview",
                    "The rendered document could not be opened in Preview."
                )
            case .pdf:
                parent.outputFailed(
                    "Unable to Export PDF",
                    "The rendered document could not be exported as a PDF."
                )
            }
        }

        func cancelOutput() {
            let canceledRequestIDs = Set([
                activeOutputRequest?.id,
                pendingOutputRequest?.id,
                parent.outputRequest?.id,
            ].compactMap { $0 })
            let outputRequestBinding = parent.$outputRequest
            let activeOperationBinding = parent.$activeOutputOperationID
            activeOutputRequest = nil
            pendingOutputRequest = nil

            Task { @MainActor in
                guard let operationID = activeOperationBinding.wrappedValue,
                      canceledRequestIDs.contains(operationID) else { return }
                if outputRequestBinding.wrappedValue?.id == operationID {
                    outputRequestBinding.wrappedValue = nil
                }
                activeOperationBinding.wrappedValue = nil
            }
        }

        private func clearOutputBinding(for request: RenderedDocumentOutputRequest) {
            Task { @MainActor [weak self] in
                guard let self, self.parent.outputRequest?.id == request.id else { return }
                self.parent.outputRequest = nil
            }
        }

        private func failPendingOutput() {
            guard activeOutputRequest == nil,
                  let request = pendingOutputRequest ?? parent.outputRequest else { return }
            activeOutputRequest = request
            pendingOutputRequest = nil
            clearOutputBinding(for: request)
            finishOutput(success: false)
        }

        private func openExternalURL(_ url: URL) {
#if os(macOS)
            NSWorkspace.shared.open(url)
#else
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
#endif
        }

        private func urlWithoutFragment(_ url: URL) -> URL? {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.fragment = nil
            return components?.url
        }

        private func isSameDocumentAnchor(_ url: URL, in webView: WKWebView) -> Bool {
            guard url.fragment != nil, let currentURL = webView.url else { return false }
            return urlWithoutFragment(url) == urlWithoutFragment(currentURL)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.targetFrame?.isMainFrame != false else {
                decisionHandler(.cancel)
                return
            }

            if isInternalLoadAuthorized, navigationAction.navigationType == .other {
                isInternalLoadAuthorized = false
                decisionHandler(.allow)
                return
            }

            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }

            if isSameDocumentAnchor(url, in: webView) {
                decisionHandler(.allow)
                return
            }

            if url.scheme?.caseInsensitiveCompare("marklens-wikilink") == .orderedSame {
                if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                   components.host == "open",
                   let target = components.queryItems?.first(where: { $0.name == "target" })?.value,
                   target.isEmpty == false {
                    parent.openWikiLink(target)
                }
                decisionHandler(.cancel)
                return
            }

            if url.isFileURL {
#if os(macOS)
                guard let documentURL = urlWithoutFragment(url) else {
                    decisionHandler(.cancel)
                    return
                }
                Task { @MainActor in
                    do {
                        try await parent.openDocument(documentURL)
                    } catch {
                        parent.requestLocalDocumentAccess(documentURL, error.localizedDescription)
                    }
                }
#else
                openExternalURL(url)
#endif
            } else {
                openExternalURL(url)
            }
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            endWebViewLoad()
            beginWebViewPostProcessing()
            isPageReady = true
            isSearchInstalled = false
            let generation = searchGeneration
            applyCustomCSS { [weak self] in
                guard let self,
                      self.isPageReady,
                      generation == self.searchGeneration else { return }
                let shouldRestoreScroll = self.parent.scrollRequest != self.latestScrollRequest
                self.updateSearch(command: "search") {
                    if shouldRestoreScroll {
                        self.restoreScrollPosition {
                            self.finishReloadTransition()
                        }
                    } else {
                        self.finishReloadTransition()
                    }
                }
                self.latestFindTerm = self.parent.findTerm
                self.latestFindRequest = self.parent.findRequest

                if let request = self.pendingOutputRequest ?? self.parent.outputRequest {
                    self.clearOutputBinding(for: request)
                    self.scheduleOutput(request)
                }
                self.endWebViewPostProcessing()
            }
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            endWebViewLoad()
            endWebViewPostProcessing()
            isPageReady = false
            removeReloadSnapshot()
            failPendingOutput()
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            endWebViewLoad()
            endWebViewPostProcessing()
            isPageReady = false
            removeReloadSnapshot()
            failPendingOutput()
        }
    }

    private static let localImageScheme = "marklens-local-image"
    private static let resourceScheme = "marklens-resource"
    private static let scrollMessageHandler = "marklensScrollPosition"

    static let scrollPositionScript = """
        (() => {
            const anchors = Array.from(
                document.querySelectorAll('[data-marklens-source-line]')
            );
            const identityForAnchor = element => {
                const text = (element.textContent || '').replace(/\\s+/g, ' ').trim();
                const value = `${element.tagName}:${text}`;
                let hash = 2166136261;
                for (let index = 0; index < value.length; index += 1) {
                    hash ^= value.charCodeAt(index);
                    hash = Math.imul(hash, 16777619);
                }
                return `${element.tagName}:${text.length}:${(hash >>> 0).toString(16)}`;
            };
            const sourceAnchors = anchors
                .map(element => ({
                    element,
                    line: Number(element.dataset.marklensSourceLine),
                    identity: identityForAnchor(element)
                }))
                .filter(anchor => Number.isFinite(anchor.line))
                .sort((left, right) => left.line - right.line);
            const anchorByElement = new WeakMap();
            const occurrenceCounts = new Map();
            sourceAnchors.forEach((anchor, index) => {
                anchor.index = index;
                anchor.occurrence = occurrenceCounts.get(anchor.identity) || 0;
                occurrenceCounts.set(anchor.identity, anchor.occurrence + 1);
                anchorByElement.set(anchor.element, anchor);
            });
            const visibleAnchors = new Set();
            const progress = () => {
                const maximum = Math.max(0, document.documentElement.scrollHeight - innerHeight);
                return maximum === 0 ? 0 : scrollY / maximum;
            };
            const report = () => {
                let line = null;
                let anchor = null;
                let occurrence = null;
                let previousAnchor = null;
                let nextAnchor = null;
                let offset = 0;
                let closestDistance = Infinity;
                visibleAnchors.forEach(element => {
                    const rect = element.getBoundingClientRect();
                    if (rect.bottom < 0 || rect.top > innerHeight) return;
                    const distance = Math.abs(rect.top);
                    if (distance < closestDistance) {
                        const sourceAnchor = anchorByElement.get(element);
                        closestDistance = distance;
                        line = sourceAnchor?.line ?? null;
                        anchor = sourceAnchor?.identity ?? null;
                        occurrence = sourceAnchor?.occurrence ?? null;
                        previousAnchor = sourceAnchors[sourceAnchor?.index - 1]?.identity ?? null;
                        nextAnchor = sourceAnchors[sourceAnchor?.index + 1]?.identity ?? null;
                        offset = rect.top;
                    }
                });
                window.webkit.messageHandlers.marklensScrollPosition.postMessage({
                    line: Number.isFinite(line) ? line : null,
                    progress: progress(),
                    anchor,
                    occurrence,
                    previousAnchor,
                    nextAnchor,
                    offset
                });
            };
            let scheduled = false;
            let lastReportTime = -Infinity;
            const minimumReportInterval = 100;
            const scheduleReport = () => {
                if (scheduled) return;
                scheduled = true;
                const delay = Math.max(
                    0,
                    minimumReportInterval - (Date.now() - lastReportTime)
                );
                const runReport = () => requestAnimationFrame(() => {
                    scheduled = false;
                    lastReportTime = Date.now();
                    report();
                });
                if (delay === 0) {
                    runReport();
                } else {
                    setTimeout(runReport, delay);
                }
            };
            const visibilityObserver = new IntersectionObserver(entries => {
                entries.forEach(entry => {
                    if (entry.isIntersecting) {
                        visibleAnchors.add(entry.target);
                    } else {
                        visibleAnchors.delete(entry.target);
                    }
                });
                scheduleReport();
            });
            anchors.forEach(anchor => visibilityObserver.observe(anchor));
            addEventListener('scroll', scheduleReport, { passive: true });

            const targetForLine = requestedLine => {
                let lower = 0;
                let upper = sourceAnchors.length;
                while (lower < upper) {
                    const middle = Math.floor((lower + upper) / 2);
                    if (sourceAnchors[middle].line <= requestedLine) {
                        lower = middle + 1;
                    } else {
                        upper = middle;
                    }
                }
                return sourceAnchors[Math.max(0, lower - 1)]?.element || null;
            };
            const targetForAnchor = position => {
                if (typeof position.anchor !== 'string') return null;
                const matches = sourceAnchors.filter(anchor => anchor.identity === position.anchor);
                if (matches.length === 0) return null;
                if (matches.length === 1) return matches[0].element;

                const requestedOccurrence = position.occurrence === null
                    ? NaN
                    : Number(position.occurrence);
                const requestedProgress = Math.min(
                    Math.max(Number(position.progress) || 0, 0),
                    1
                );
                const maximum = Math.max(
                    1,
                    document.documentElement.scrollHeight - innerHeight
                );
                const rank = candidate => {
                    let contextMatches = 0;
                    if (typeof position.previousAnchor === 'string'
                        && sourceAnchors[candidate.index - 1]?.identity === position.previousAnchor) {
                        contextMatches += 1;
                    }
                    if (typeof position.nextAnchor === 'string'
                        && sourceAnchors[candidate.index + 1]?.identity === position.nextAnchor) {
                        contextMatches += 1;
                    }
                    const occurrenceDistance = Number.isFinite(requestedOccurrence)
                        ? Math.abs(candidate.occurrence - requestedOccurrence)
                        : Infinity;
                    const top = scrollY + candidate.element.getBoundingClientRect().top;
                    const progressDistance = Math.abs((top / maximum) - requestedProgress);
                    return { contextMatches, occurrenceDistance, progressDistance };
                };
                let best = matches[0];
                let bestRank = rank(best);
                matches.slice(1).forEach(candidate => {
                    const candidateRank = rank(candidate);
                    const isBetter = candidateRank.contextMatches > bestRank.contextMatches
                        || (candidateRank.contextMatches === bestRank.contextMatches
                            && candidateRank.occurrenceDistance < bestRank.occurrenceDistance)
                        || (candidateRank.contextMatches === bestRank.contextMatches
                            && candidateRank.occurrenceDistance === bestRank.occurrenceDistance
                            && candidateRank.progressDistance < bestRank.progressDistance);
                    if (isBetter) {
                        best = candidate;
                        bestRank = candidateRank;
                    }
                });
                return best.element;
            };
            let activeRestoration = null;
            let restorationTimeout = null;
            const cancelRestoration = () => {
                activeRestoration = null;
                clearTimeout(restorationTimeout);
                restorationTimeout = null;
            };
            const applyRestoration = () => {
                if (!activeRestoration) return;
                const requestedLine = activeRestoration.line === null
                    ? NaN
                    : Number(activeRestoration.line);
                const target = targetForAnchor(activeRestoration)
                    || (Number.isFinite(requestedLine) ? targetForLine(requestedLine) : null);
                if (target) {
                    const requestedOffset = Number(activeRestoration.offset);
                    const offset = Number.isFinite(requestedOffset) ? requestedOffset : 0;
                    const top = scrollY + target.getBoundingClientRect().top - offset;
                    scrollTo(0, top);
                } else {
                    const maximum = Math.max(
                        0,
                        document.documentElement.scrollHeight - innerHeight
                    );
                    const requestedProgress = Math.min(
                        Math.max(Number(activeRestoration.progress) || 0, 0),
                        1
                    );
                    scrollTo(0, maximum * requestedProgress);
                }
                scheduleReport();
            };
            const layoutObserver = new ResizeObserver(() => {
                if (activeRestoration) requestAnimationFrame(applyRestoration);
            });
            layoutObserver.observe(document.documentElement);
            ['wheel', 'touchstart', 'pointerdown', 'keydown'].forEach(eventName => {
                addEventListener(eventName, cancelRestoration, { passive: true });
            });

            window.MarkLensScroll = {
                restore(position) {
                    activeRestoration = position;
                    clearTimeout(restorationTimeout);
                    restorationTimeout = setTimeout(cancelRestoration, 5000);
                    applyRestoration();
                },
                resolve(position) {
                    const requestedLine = position.line === null ? NaN : Number(position.line);
                    const element = targetForAnchor(position)
                        || (Number.isFinite(requestedLine) ? targetForLine(requestedLine) : null);
                    const anchor = element ? anchorByElement.get(element) : null;
                    return anchor ? {
                        line: anchor.line,
                        occurrence: anchor.occurrence,
                        index: anchor.index
                    } : null;
                },
                report
            };
            scheduleReport();
        })();
        """

    static func customCSSUpdateScript(for css: String) -> String {
        guard let identifierData = try? JSONEncoder().encode(HTMLFeature.customCSSStyleElementID),
              let identifier = String(data: identifierData, encoding: .utf8),
              let cssData = try? JSONEncoder().encode(css),
              let encodedCSS = String(data: cssData, encoding: .utf8) else {
            return ""
        }
        return """
        (() => {
            const style = document.getElementById(\(identifier));
            if (style) style.textContent = \(encodedCSS);
        })();
        """
    }

    private var localImageURLs: Set<URL> {
        guard let documentURL,
              let regex = try? NSRegularExpression(
                  pattern: "data-marklens-local-image=\\\"([^\\\"]+)\\\""
              ) else {
            return []
        }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return Set(regex.matches(in: html, range: range).compactMap { match in
            guard let capabilityRange = Range(match.range(at: 1), in: html),
                  let data = Data(base64Encoded: String(html[capabilityRange])),
                  let source = String(data: data, encoding: .utf8),
                  let url = URL(string: source, relativeTo: documentURL)?.absoluteURL,
                  url.isFileURL else {
                return nil
            }
            return url.standardizedFileURL.resolvingSymlinksInPath()
        })
    }

    private static let localImageScript = """
        document.querySelectorAll('img[data-marklens-local-image]').forEach(image => {
            const source = image.getAttribute('src');
            if (!source) return;
            const resolved = new URL(source, document.baseURI);
            if (resolved.protocol !== 'file:') return;
            image.src = '\(localImageScheme)://resource?url=' + encodeURIComponent(resolved.href);
        });
        """
}

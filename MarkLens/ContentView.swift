//
//  ContentView.swift
//  MarkLens
//
//  Created by Philipp on 02.01.2026.
//

import SwiftUI
import UniformTypeIdentifiers
import MarkdownPipeline
#if canImport(os)
import os
#endif
#if os(macOS)
import AppKit
#endif

nonisolated struct DocumentScrollPosition: Equatable, Sendable {
    var sourceLine: Int?
    var progress: Double
    var anchorIdentity: String? = nil
    var anchorOccurrence: Int? = nil
    var previousAnchorIdentity: String? = nil
    var nextAnchorIdentity: String? = nil
    var viewportOffset: Double = 0

    static let top = DocumentScrollPosition(sourceLine: nil, progress: 0)

#if DEBUG
    var diagnosticDescription: String {
        let line = sourceLine.map(String.init) ?? "nil"
        let occurrence = anchorOccurrence.map(String.init) ?? "nil"
        return "line=\(line) progress=\(progress) anchor=\(anchorIdentity ?? "nil") occurrence=\(occurrence) offset=\(viewportOffset)"
    }
#endif
}

private final class PreviewScrollPositionStore {
    var position = DocumentScrollPosition.top
}

nonisolated enum WikiRefreshScrollRestoration {
    case live
    case requested(position: DocumentScrollPosition, request: Int)

    func resolvedPosition(
        currentPosition: DocumentScrollPosition,
        confirmedRequest: Int
    ) -> DocumentScrollPosition {
        switch self {
        case .live:
            return currentPosition
        case .requested(let position, let request):
            return confirmedRequest >= request ? currentPosition : position
        }
    }
}

nonisolated enum WikiScrollDiagnostics {
#if DEBUG && canImport(os)
    private static let logger = Logger(
        subsystem: "ch.doapp.MarkLens",
        category: "WikiScroll"
    )

    static func captured(
        action: String,
        from: String,
        to: String,
        position: DocumentScrollPosition
    ) {
        logger.debug(
            "CAPTURE action=\(action, privacy: .public) from=\(from, privacy: .private) to=\(to, privacy: .private) \(position.diagnosticDescription, privacy: .private)"
        )
    }

    static func restoreRequested(
        location: String,
        request: Int,
        position: DocumentScrollPosition
    ) {
        logger.debug(
            "REQUEST location=\(location, privacy: .private) request=\(request, privacy: .public) \(position.diagnosticDescription, privacy: .private)"
        )
    }

    static func loadFinished(
        location: String,
        requested: Int,
        applied: Int,
        requiresRestore: Bool
    ) {
        logger.debug(
            "LOAD_FINISHED location=\(location, privacy: .private) requested=\(requested, privacy: .public) applied=\(applied, privacy: .public) pending=\(requiresRestore, privacy: .public)"
        )
    }

    static func restoreApplied(
        location: String,
        request: Int,
        position: DocumentScrollPosition
    ) {
        logger.debug(
            "APPLY location=\(location, privacy: .private) request=\(request, privacy: .public) \(position.diagnosticDescription, privacy: .private)"
        )
    }

    static func restoreConfirmed(
        location: String,
        request: Int,
        position: DocumentScrollPosition
    ) {
        logger.debug(
            "CONFIRM location=\(location, privacy: .private) request=\(request, privacy: .public) \(position.diagnosticDescription, privacy: .private)"
        )
    }
#else
    static func captured(
        action: String,
        from: String,
        to: String,
        position: DocumentScrollPosition
    ) {}

    static func restoreRequested(
        location: String,
        request: Int,
        position: DocumentScrollPosition
    ) {}

    static func loadFinished(
        location: String,
        requested: Int,
        applied: Int,
        requiresRestore: Bool
    ) {}

    static func restoreApplied(
        location: String,
        request: Int,
        position: DocumentScrollPosition
    ) {}

    static func restoreConfirmed(
        location: String,
        request: Int,
        position: DocumentScrollPosition
    ) {}
#endif
}

private enum FrontMatterPageKey: Hashable {
    case root
    case wiki(URL)
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
#if os(macOS)
    @Environment(\.openDocument) private var openDocument
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var releaseNotesCoordinator: ReleaseNotesCoordinator
    @EnvironmentObject private var updateChecker: UpdateChecker
#endif
    @EnvironmentObject private var localDocumentAccess: LocalDocumentAccess
    @AppStorage(AppearancePreferences.customCSSKey)
    private var customCSS = AppearancePreferences.starterCSS
    @AppStorage(SecurityPreferences.rendersRawHTMLKey)
    private var rendersRawHTML = false
    @AppStorage(SecurityPreferences.loadsRemoteResourcesKey)
    private var loadsRemoteResources = false
    @AppStorage(SecurityPreferences.rendersMermaidKey)
    private var rendersMermaid = true
    @AppStorage(SecurityPreferences.loadsLocalImagesKey)
    private var loadsLocalImages = true
    @ObservedObject var document: MarkdownDocument
    @StateObject private var wikiNavigation: WikiNavigationModel
    let fileURL: URL?
#if os(macOS)
    @State private var pendingLocalAccessRequest: LocalAccessRequest?
    @State private var externalFileMonitor: ExternalFileMonitor?
    @State private var wikiFileMonitor: ExternalFileMonitor?
    @State private var externalDocumentReloadCoordinator: ExternalDocumentReloadCoordinator?
    @State private var externalReloadRetryTask: Task<Void, Never>?
    @State private var externalReloadRetryAttempt = 0
    @State private var externalReloadErrorDescription: String?
    @State private var isUpdatePopoverPresented = false
    @State private var failedLocalImageURLs: Set<URL> = []
    @State private var wikiLinkMatches: [URL] = []
    @State private var wikiLinkMatchesRoot: URL?
    @State private var wikiResolutionGeneration = 0
    @State private var isResolvingWikiLink = false
    @State private var wikiResolutionWork: Task<WikiLinkResolution, Never>?
#endif
    @State private var localDocumentError: String?
    @State private var outputRequest: RenderedDocumentOutputRequest?
    @State private var activeOutputOperationID: UUID?
    @State private var outputErrorTitle: String?
    @State private var outputErrorDescription: String?
    @State private var isHTMLFilteringInfoPresented = false
    @State private var isRawEditing = false
    @State private var showFind = false
    @State private var previewFindText = ""
    @State private var isPreviewFindPresented = false
    @State private var previewFindRequest = 0
    @State private var previewFindBackwards = false
    @State private var previewFindAnchorRequest = 0
    @State private var previewFindFocusRequest = 0
    @State private var previewFindMatchCount = 0
    @State private var previewFindCurrentIndex = 0
    // Scroll reports are navigation state, not rendered state. Publishing each
    // report would reevaluate the full view hierarchy throughout a gesture.
    @State private var previewScrollPositionStore = PreviewScrollPositionStore()
    @State private var sourceScrollPosition = DocumentScrollPosition.top
    @State private var previewScrollTarget = DocumentScrollPosition.top
    @State private var sourceScrollTarget = DocumentScrollPosition.top
    @State private var previewScrollRequest = 0
    @State private var previewConfirmedScrollRequest = 0
    @State private var sourceScrollRequest = 0
    @State private var sourceSelectionLine: Int?
    @State private var expandedFrontMatterPages: Set<FrontMatterPageKey> = []
    @State private var sourceEditPositionRequest: UUID?
    @State private var isPreparingRawEditing = false

    init(document: MarkdownDocument, fileURL: URL? = nil) {
        self.document = document
        self.fileURL = fileURL
        self._wikiNavigation = StateObject(wrappedValue: WikiNavigationModel())
    }

    var body: some View {
        presentedContent
    }

    private var contentWithToolbar: some View {
        ZStack {
            markdownPreview
            .allowsHitTesting(!isRawEditing && !isWikiNavigationLoading)
            .zIndex(0)

            if isRawEditing {
                RawEditorView(
                    text: sourceTextBinding,
                    showFind: $showFind,
                    scrollPosition: $sourceScrollPosition,
                    scrollTarget: sourceScrollTarget,
                    scrollRequest: sourceScrollRequest,
                    selectionLine: sourceSelectionLine
                )
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
            }

            if isWikiNavigationLoading {
                ProgressView("Loading Wiki Page…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .zIndex(2)
            }
        }
        .accessibilityIdentifier("contentView")
#if os(macOS)
        .safeAreaInset(edge: .top, spacing: 0) {
            if isPreviewFindPresented && isRawEditing == false {
                PreviewFindBar(
                    text: $previewFindText,
                    statusText: findStatusText,
                    canNavigate: previewFindMatchCount > 0,
                    focusRequest: previewFindFocusRequest,
                    previous: findPrevious,
                    next: findNext,
                    close: closePreviewFind
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
#endif
        .animation(.snappy, value: isRawEditing)
        .animation(.snappy, value: isPreviewFindPresented)
        .toolbar {
            if isRawEditing {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel) {
                        requestFinishRawEditing(commitChanges: false)
                    }
                    .keyboardShortcut(.cancelAction)
                }

#if os(macOS)
                if #available(macOS 26.0, *) {
                    ToolbarSpacer()
                }
#endif

                ToolbarItem(placement: .primaryAction) {
                    Toggle(isOn: $showFind) {
                        Label("Find", systemImage: "magnifyingglass")
                    }
                    .keyboardShortcut("f")
                }

#if os(macOS)
                if #available(macOS 26.0, *) {
                    ToolbarSpacer()
                }
#endif

                ToolbarItem(placement: .confirmationAction) {
                    Button("Update", systemImage: "checkmark") {
                        requestFinishRawEditing(commitChanges: true)
                    }
                    .keyboardShortcut("s")
                }
            } else {
                if displayedFilteredHTMLFragmentCount > 0 {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            isHTMLFilteringInfoPresented = true
                        } label: {
                            Label(htmlFilteringToolbarLabel, systemImage: htmlFilteringToolbarIcon)
                        }
                        .buttonStyle(.bordered)
                        .tint(displayedHTMLContentAdjustmentReason == .unsafeContentBlocked ? .orange : .gray)
                        .help(htmlFilteringToolbarHelp)
                        .accessibilityLabel(htmlFilteringAccessibilityLabel)
                        .accessibilityIdentifier("htmlFilteredButton")
                    }
                }

#if os(macOS)
                if wikiNavigation.hasBrowserHistory {
                    ToolbarItemGroup(placement: .navigation) {
                        Button {
                            navigateWikiBack()
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                        .accessibilityIdentifier("wikiBackButton")
                        .keyboardShortcut("[", modifiers: .command)
                        .disabled(wikiNavigation.canGoBack == false || isWikiNavigationLoading)

                        Button {
                            navigateWikiForward()
                        } label: {
                            Label("Forward", systemImage: "chevron.right")
                        }
                        .accessibilityIdentifier("wikiForwardButton")
                        .keyboardShortcut("]", modifiers: .command)
                        .disabled(wikiNavigation.canGoForward == false || isWikiNavigationLoading)
                    }
                }

                if let page = wikiNavigation.currentPage {
                    if #available(macOS 26.0, *) {
                        ToolbarItem(placement: .principal) {
                            WikiPageToolbarTitle(path: page.displayPath)
                        }
                        .sharedBackgroundVisibility(.hidden)
                    } else {
                        ToolbarItem(placement: .principal) {
                            WikiPageToolbarTitle(path: page.displayPath)
                        }
                    }
                }

                if shouldOfferWikiFolderAccess {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            pendingLocalAccessRequest = .wikiFolder(nil)
                        } label: {
                            Label("Allow Wiki Folder Access", systemImage: "folder.badge.plus")
                        }
                        .accessibilityIdentifier("allowWikiFolderAccessButton")
                    }
                }

                if failedLocalImageURLs.isEmpty == false {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            requestLocalImageAccess()
                        } label: {
                            Label("Load Local Images", systemImage: "photo.badge.exclamationmark")
                        }
                        .accessibilityIdentifier("loadLocalImagesButton")
                    }
                }

                if let release = updateChecker.availableRelease {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            isUpdatePopoverPresented = true
                        } label: {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.down.circle")
                                        .foregroundStyle(Color.accentColor)
                                    Text("Update Available")
                                }

                                Image(systemName: "arrow.down.circle")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .buttonStyle(.bordered)
                        .help("MarkLens \(release.displayVersion) is available")
                        .accessibilityLabel("Update available: MarkLens \(release.displayVersion)")
                        .accessibilityIdentifier("updateAvailableButton")
                        .popover(isPresented: $isUpdatePopoverPresented, arrowEdge: .top) {
                            UpdateAvailablePopover(
                                release: release,
                                installedVersion: updateChecker.currentVersion,
                                onCheckLater: updateChecker.checkLater,
                                onSkipVersion: updateChecker.skipAvailableVersion
                            )
                        }
                    }

                    if #available(macOS 26.0, *) {
                        ToolbarSpacer()
                    }
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        requestRenderedOutput(.print)
                    } label: {
                        Label("Print", systemImage: "printer")
                    }
                    .keyboardShortcut("p")
                    .disabled(canProduceRenderedOutput == false)

                    Button {
                        beginPreviewFind()
                    } label: {
                        Label("Find", systemImage: "magnifyingglass")
                    }
                    .accessibilityIdentifier("previewFindButton")
                    .keyboardShortcut("f")
                }
#else
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        beginPreviewFind()
                    } label: {
                        Label("Find", systemImage: "magnifyingglass")
                    }
                    .accessibilityIdentifier("previewFindButton")
                    .keyboardShortcut("f")
                }

                if isPreviewFindPresented || previewFindText.isEmpty == false {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Text(findStatusText)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .accessibilityIdentifier("previewFindStatus")

                        Button {
                            findPrevious()
                        } label: {
                            Label("Previous", systemImage: "chevron.up")
                        }
                        .accessibilityIdentifier("previewFindPreviousButton")
                        .keyboardShortcut("g", modifiers: [.command, .shift])
                        .disabled(previewFindMatchCount == 0)

                        Button {
                            findNext()
                        } label: {
                            Label("Next", systemImage: "chevron.down")
                        }
                        .accessibilityIdentifier("previewFindNextButton")
                        .keyboardShortcut("g", modifiers: .command)
                        .disabled(previewFindMatchCount == 0)
                    }
                }
#endif

                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        beginRawEditing()
                    } label: {
                        Label("Edit Source", systemImage: "square.and.pencil")
                    }
                    .keyboardShortcut("e")
                    .disabled(wikiNavigation.isBrowsing || isPreparingRawEditing)
                }
            }
        }
    }

    private var lifecycleContent: some View {
        contentWithToolbar
        .previewSearchable(
            enabled: !isRawEditing,
            text: $previewFindText,
            isPresented: $isPreviewFindPresented,
            submit: findNext
        )
        .onChange(of: isPreviewFindPresented) {
            if isPreviewFindPresented == false {
                previewFindText = ""
            }
        }
        .onChange(of: isRawEditing) {
            if isRawEditing {
                isPreviewFindPresented = false
            }
        }
        .onChange(of: displayedPageIdentity) {
#if os(macOS)
            failedLocalImageURLs.removeAll()
#endif
            isHTMLFilteringInfoPresented = false
            resetPreviewNavigationState()
        }
        .onAppear {
            applyRenderingPreferences()
        }
        .onChange(of: renderingPreferences) {
            applyRenderingPreferences()
        }
#if os(macOS)
        .task {
            if releaseNotesCoordinator.claimAutomaticPresentation() {
                openWindow(id: ReleaseNotesCoordinator.windowID)
            }
            await updateChecker.checkIfDue()
        }
        .onAppear {
            startExternalFileMonitor()
            restartWikiFileMonitor()
        }
        .onChange(of: fileURL) {
            externalFileMonitor?.stop()
            externalFileMonitor = nil
            externalDocumentReloadCoordinator = nil
            cancelExternalReloadRetry()
            externalReloadErrorDescription = nil
            startExternalFileMonitor()
            restartWikiFileMonitor()
        }
        .onChange(of: wikiNavigation.currentPage?.url) {
            restartWikiFileMonitor()
        }
        .onChange(of: scenePhase) {
            guard scenePhase == .active else {
                return
            }
            resumeDeferredExternalChange()
            Task {
                await updateChecker.checkIfDue()
            }
        }
#endif
        .onDisappear {
#if os(macOS)
            externalFileMonitor?.stop()
            externalFileMonitor = nil
            wikiFileMonitor?.stop()
            wikiFileMonitor = nil
            externalDocumentReloadCoordinator = nil
            cancelExternalReloadRetry()
            externalReloadErrorDescription = nil
            cancelWikiResolution()
#endif
            wikiNavigation.cancelPendingNavigation()
        }
    }

    private var presentedContent: some View {
        lifecycleContent
        .alert(localAccessAlertTitle, isPresented: localAccessAlertPresented) {
#if os(macOS)
            Button("Choose \(localAccessFolderName) Folder") {
                chooseLocalAccessFolder()
            }
            Button("Cancel", role: .cancel) {
                pendingLocalAccessRequest = nil
            }
#endif
        } message: {
#if os(macOS)
            Text(localAccessExplanation)
#endif
        }
        .alert("Unable to Open File", isPresented: localErrorAlertPresented) {
            Button("OK", role: .cancel) {
                localDocumentError = nil
                wikiNavigation.errorDescription = nil
            }
        } message: {
            Text(activeErrorDescription ?? "The linked document could not be opened.")
        }
        .alert(outputErrorTitle ?? "Unable to Complete Request", isPresented: outputErrorAlertPresented) {
            Button("OK", role: .cancel) {
                outputErrorTitle = nil
                outputErrorDescription = nil
            }
        } message: {
            Text(outputErrorDescription ?? "The rendered document could not be produced.")
        }
#if os(macOS)
        .alert("Unable to Reload File", isPresented: externalReloadErrorAlertPresented) {
            Button("Reload Again") {
                retryExternalReload()
            }
            Button("OK", role: .cancel) {
                externalReloadErrorDescription = nil
            }
        } message: {
            Text(externalReloadErrorDescription ?? "The file could not be reloaded.")
        }
#endif
        .alert(htmlFilteringAlertTitle, isPresented: $isHTMLFilteringInfoPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(htmlFilteringExplanation)
        }
#if os(macOS)
        .sheet(isPresented: wikiLinkMatchChooserPresented) {
            wikiLinkMatchChooser
        }
#endif
#if os(macOS)
        .focusedSceneValue(\.printAction, focusedPrintAction)
        .focusedSceneValue(\.exportAction, focusedExportAction)
        .focusedSceneValue(\.openInPreviewAction, focusedOpenInPreviewAction)
        .focusedSceneValue(\.pageSetupAction, PageSetupAction {
            let printInfo = NSPrintInfo.shared
            let pageLayout = NSPageLayout()

            if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                pageLayout.beginSheet(with: printInfo, modalFor: window, delegate: nil, didEnd: nil, contextInfo: nil)
            } else {
                pageLayout.runModal(with: printInfo)
            }
        })
#endif
    }

    private var markdownPreview: some View {
        MarkdownWebView(
            html: displayedHTML,
            contentIdentity: displayedPageIdentity,
            resources: displayedResources,
            customCSS: customCSS,
            documentURL: displayedURL,
            openDocument: openLocalDocument,
            openWikiLink: openWikiLink,
            requestLocalDocumentAccess: { url, errorDescription in
#if os(macOS)
                handleLocalDocumentOpenFailure(url, errorDescription: errorDescription)
#else
                localDocumentError = errorDescription
#endif
            },
            localImagePermissionDenied: { url in
#if os(macOS)
                handleLocalImagePermissionFailure(url)
#endif
            },
            reloadRequest: localDocumentAccess.accessRevision,
            outputRequest: $outputRequest,
            activeOutputOperationID: $activeOutputOperationID,
            outputFailed: { title, description in
                outputErrorTitle = title
                outputErrorDescription = description
            },
            findMatchCount: $previewFindMatchCount,
            findCurrentIndex: $previewFindCurrentIndex,
            findTerm: isRawEditing ? "" : previewFindText,
            findRequest: previewFindRequest,
            findBackwards: previewFindBackwards,
            findAnchorRequest: previewFindAnchorRequest,
            findSelectionAction: { selection in
                previewFindText = selection
            },
            frontMatterExpanded: frontMatterExpandedBinding,
            sourceEditPositionRequest: sourceEditPositionRequest,
            sourceEditPositionAction: completeBeginRawEditing,
            scrollPosition: Binding(
                get: { previewScrollPositionStore.position },
                set: { previewScrollPositionStore.position = $0 }
            ),
            scrollTarget: previewScrollTarget,
            scrollRequest: previewScrollRequest,
            confirmedScrollRequest: $previewConfirmedScrollRequest
        )
    }

    private func rawString() -> String {
        document.text
    }

    private var sourceTextBinding: Binding<String> {
        Binding(
            get: { document.text },
            set: { document.updateSourceDraft($0) }
        )
    }

#if os(macOS)
    private var wikiLinkMatchChooserPresented: Binding<Bool> {
        Binding(
            get: { wikiLinkMatches.isEmpty == false },
            set: { isPresented in
                if isPresented == false {
                    clearWikiLinkMatches()
                }
            }
        )
    }

    @ViewBuilder
    private var wikiLinkMatchChooser: some View {
        if let root = wikiLinkMatchesRoot {
            WikiLinkMatchChooser(matches: wikiLinkMatches, root: root) { url in
                clearWikiLinkMatches()
                openResolvedWikiDocument(url, wikiRoot: root)
            }
        } else {
            EmptyView()
        }
    }

    private var canProduceRenderedOutput: Bool {
        isRawEditing == false && isWikiNavigationLoading == false && activeOutputOperationID == nil
    }

    private var focusedPrintAction: PrintAction {
        PrintAction(isEnabled: canProduceRenderedOutput) {
            guard canProduceRenderedOutput else { return }
            requestRenderedOutput(.print)
        }
    }

    private var focusedExportAction: ExportAction {
        ExportAction(isEnabled: canProduceRenderedOutput) {
            guard canProduceRenderedOutput else { return }
            presentExportPanel()
        }
    }

    private var focusedOpenInPreviewAction: OpenInPreviewAction {
        OpenInPreviewAction(isEnabled: canProduceRenderedOutput) {
            guard canProduceRenderedOutput else { return }
            requestRenderedOutput(.preview)
        }
    }

    private func requestRenderedOutput(_ destination: RenderedDocumentOutputRequest.Destination) {
        guard activeOutputOperationID == nil else { return }
        let request = RenderedDocumentOutputRequest(destination: destination)
        activeOutputOperationID = request.id
        outputRequest = request
    }

    private func presentExportPanel() {
        let rememberedFormat = ExportPreferences.rememberedFormat()
        let testExportDirectory = uiTestExportDirectory
        let panel = NSSavePanel()
        panel.title = "Export Rendered Document"
        panel.prompt = "Export"
        panel.allowedContentTypes = [.pdf, .html]
        panel.showsContentTypes = true
        panel.currentContentType = rememberedFormat.contentType
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.directoryURL = testExportDirectory ?? displayedURL?.deletingLastPathComponent()
        panel.nameFieldStringValue = "\(suggestedExportName).\(rememberedFormat.pathExtension)"

        let operationID = UUID()
        activeOutputOperationID = operationID
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let selectedURL = panel.url else {
                if activeOutputOperationID == operationID {
                    activeOutputOperationID = nil
                }
                return
            }

            let format = RenderedDocumentExportFormat(contentType: panel.currentContentType)
            let destinationURL = format.normalizedURL(selectedURL)
            if let testExportDirectory,
               LocalDocumentAccess.sameFolder(
                   destinationURL.deletingLastPathComponent(),
                   testExportDirectory
               ) == false {
                activeOutputOperationID = nil
                outputErrorTitle = "Unsafe Test Export Destination"
                outputErrorDescription = "The UI test export was blocked outside its temporary directory."
                return
            }
            ExportPreferences.remember(format)
            switch format {
            case .html:
                exportHTML(to: destinationURL, operationID: operationID)
            case .pdf:
                let request = RenderedDocumentOutputRequest(destination: .pdf(destinationURL))
                activeOutputOperationID = request.id
                outputRequest = request
            }
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    private var suggestedExportName: String {
        let sourceName = displayedURL?.deletingPathExtension().lastPathComponent
            ?? document.filename.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            ?? "Untitled"
        return sourceName.isEmpty ? "Untitled" : sourceName
    }

    private var uiTestExportDirectory: URL? {
#if DEBUG
        guard let path = ProcessInfo.processInfo.environment["MARKLENS_UI_TEST_EXPORT_DIRECTORY"],
              path.isEmpty == false else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
#else
        nil
#endif
    }

    private func exportHTML(to destinationURL: URL, operationID: UUID) {
        let html = displayedHTML
        let resources = displayedResources
        let css = customCSS
        let sourceURL = displayedURL
        let frontMatterExpanded = frontMatterExpandedBinding.wrappedValue

        Task {
            let errorDescription = await Task.detached(priority: .userInitiated) {
                do {
                    try RenderedHTMLExporter.export(
                        html: html,
                        resources: resources,
                        customCSS: css,
                        sourceURL: sourceURL,
                        frontMatterExpanded: frontMatterExpanded,
                        to: destinationURL
                    )
                    return nil as String?
                } catch {
                    return error.localizedDescription
                }
            }.value

            if activeOutputOperationID == operationID {
                activeOutputOperationID = nil
            }
            outputErrorTitle = errorDescription == nil ? nil : "Unable to Export HTML"
            outputErrorDescription = errorDescription
        }
    }
#endif

    private func beginRawEditing() {
        guard isPreparingRawEditing == false else { return }
        isPreparingRawEditing = true
        sourceEditPositionRequest = UUID()
    }

    private func completeBeginRawEditing(request: UUID, selectedSourceLine: Int?) {
        guard sourceEditPositionRequest == request else { return }
        sourceEditPositionRequest = nil
        isPreparingRawEditing = false
        let source = rawString()
        RawEditorPerformanceInstrumentation.event(
            "EditModeRequested",
            value: source.utf8.count
        )
        RawEditorPerformanceInstrumentation.measure("EditModeStatePreparation") {
            document.beginSourceEditing()
            sourceScrollTarget = previewScrollPositionStore.position
            sourceSelectionLine = selectedSourceLine ?? previewScrollPositionStore.position.sourceLine
            sourceScrollRequest += 1
            isRawEditing = true
        }
    }

    private func requestFinishRawEditing(commitChanges: Bool) {
        finishRawEditing(commitChanges: commitChanges)
    }

    private func finishRawEditing(commitChanges: Bool) {
        previewScrollTarget = sourceScrollPosition
        previewScrollRequest += 1
        let selectedLocalVersion: Bool
        if commitChanges {
            selectedLocalVersion = document.commitSourceEditing()
        } else {
            selectedLocalVersion = document.cancelSourceEditing()
        }
#if os(macOS)
        if selectedLocalVersion {
            externalDocumentReloadCoordinator?.preserveLocalVersionForSaving()
        }
#endif
        isRawEditing = false
#if os(macOS)
        Task { @MainActor in
            await Task.yield()
            resumeDeferredExternalChange()
        }
#endif
    }

#if os(macOS)
    private func startExternalFileMonitor() {
        guard externalFileMonitor == nil, let fileURL else {
            return
        }

        externalDocumentReloadCoordinator = ExternalDocumentReloadCoordinator(fileURL: fileURL)
        externalFileMonitor = ExternalFileMonitor(fileURL: fileURL) {
            handleExternalFileChange()
        }
    }

    private func handleExternalFileChange() {
        guard let externalDocumentReloadCoordinator else { return }
        cancelExternalReloadRetry()
        let preservedPosition = previewScrollPositionStore.position
        handleExternalReloadResult(
            externalDocumentReloadCoordinator.handleChange(isEditing: isRawEditing),
            preservedPosition: preservedPosition
        )
    }

    private func resumeDeferredExternalChange() {
        guard let externalDocumentReloadCoordinator,
              let result = externalDocumentReloadCoordinator.resumeDeferredChange(
                  isEditing: isRawEditing
              ) else {
            return
        }
        handleExternalReloadResult(result, preservedPosition: previewScrollPositionStore.position)
    }

    private func handleExternalReloadResult(
        _ result: ExternalDocumentReloadCoordinator.Result,
        preservedPosition: DocumentScrollPosition
    ) {
        switch result {
        case .reloaded:
            cancelExternalReloadRetry()
            externalReloadErrorDescription = nil
            if let pageURL = wikiNavigation.currentPage?.url {
                if let fileURL, sameMonitoredFile(pageURL, fileURL) {
                    refreshDisplayedWikiPage(at: pageURL, scrollRestoration: .live)
                }
                return
            }
            previewScrollTarget = preservedPosition
            Task { @MainActor in
                await Task.yield()
                previewScrollRequest += 1
            }
        case .failed(let error):
            cancelExternalReloadRetry()
            externalReloadErrorDescription = error.localizedDescription
        case .unavailable:
            scheduleExternalReloadRetry()
        case .deferred:
            cancelExternalReloadRetry()
            break
        }
    }

    private func scheduleExternalReloadRetry() {
        guard externalReloadRetryAttempt < 4,
              externalReloadRetryTask == nil,
              let coordinator = externalDocumentReloadCoordinator else {
            externalReloadErrorDescription =
                "The document is not yet available to the system document controller."
            return
        }

        externalReloadRetryAttempt += 1
        externalReloadRetryTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard Task.isCancelled == false,
                  externalDocumentReloadCoordinator === coordinator else {
                return
            }
            externalReloadRetryTask = nil
            resumeDeferredExternalChange()
        }
    }

    private func retryExternalReload() {
        externalReloadErrorDescription = nil
        externalReloadRetryAttempt = 0
        Task { @MainActor in
            await Task.yield()
            resumeDeferredExternalChange()
        }
    }

    private func cancelExternalReloadRetry() {
        externalReloadRetryTask?.cancel()
        externalReloadRetryTask = nil
        externalReloadRetryAttempt = 0
    }

    private func restartWikiFileMonitor() {
        wikiFileMonitor?.stop()
        wikiFileMonitor = nil

        guard let pageURL = wikiNavigation.currentPage?.url else { return }
        if let fileURL, sameMonitoredFile(pageURL, fileURL) {
            return
        }

        let monitoredURL = pageURL.standardizedFileURL
        wikiFileMonitor = ExternalFileMonitor(fileURL: monitoredURL) {
            guard let currentURL = wikiNavigation.currentPage?.url,
                  sameMonitoredFile(currentURL, monitoredURL) else {
                return
            }
            refreshDisplayedWikiPage(at: monitoredURL, scrollRestoration: .live)
        }
    }

    private func refreshDisplayedWikiPage(
        at expectedURL: URL,
        scrollRestoration: WikiRefreshScrollRestoration
    ) {
        wikiNavigation.refreshCurrent(renderingPreferences: renderingPreferences) {
            reloadedURL,
            contentChanged in
            guard sameMonitoredFile(reloadedURL, expectedURL),
                  let currentURL = wikiNavigation.currentPage?.url,
                  sameMonitoredFile(currentURL, expectedURL),
                  contentChanged else {
                return
            }
            // The page remains interactive while the refresh is rendered. Use
            // the position current at completion so a user's intervening scroll
            // is not replaced by the position captured when refresh began.
            restorePreviewScroll(to: scrollRestoration.resolvedPosition(
                currentPosition: previewScrollPositionStore.position,
                confirmedRequest: previewConfirmedScrollRequest
            ))
        }
    }

    @discardableResult
    private func restorePreviewScroll(to position: DocumentScrollPosition) -> Int {
        previewScrollTarget = position
        previewScrollRequest += 1
        WikiScrollDiagnostics.restoreRequested(
            location: displayedURL?.lastPathComponent ?? "untitled",
            request: previewScrollRequest,
            position: position
        )
        return previewScrollRequest
    }

    private func sameMonitoredFile(_ firstURL: URL, _ secondURL: URL) -> Bool {
        firstURL.standardizedFileURL == secondURL.standardizedFileURL
    }
#endif

    private var displayedHTML: String {
        wikiNavigation.currentPage?.html ?? document.renderedHTML
    }

    private var renderingPreferences: RenderingPreferences {
        RenderingPreferences(
            rendersRawHTML: rendersRawHTML,
            loadsRemoteResources: loadsRemoteResources,
            rendersMermaid: rendersMermaid,
            loadsLocalImages: loadsLocalImages
        )
    }

    private func applyRenderingPreferences() {
        document.updateRenderingPreferences(renderingPreferences)
        wikiNavigation.reloadCurrent(renderingPreferences: renderingPreferences)
    }

    private var displayedURL: URL? {
        wikiNavigation.currentPage?.url ?? fileURL
    }

    private var displayedResources: [HTMLResource] {
        wikiNavigation.currentPage?.resources ?? document.renderedResources
    }

    private var displayedFilteredHTMLFragmentCount: Int {
        wikiNavigation.currentPage?.filteredHTMLFragmentCount ?? document.filteredHTMLFragmentCount
    }

    private var displayedHTMLContentAdjustmentReason: HTMLContentAdjustmentReason? {
        wikiNavigation.currentPage?.htmlContentAdjustmentReason ?? document.htmlContentAdjustmentReason
    }

    private var htmlFilteringExplanation: String {
        displayedHTMLContentAdjustmentReason?.explanation(fragmentCount: displayedFilteredHTMLFragmentCount) ?? ""
    }

    private var htmlFilteringToolbarHelp: String {
        displayedHTMLContentAdjustmentReason?.toolbarHelp ?? ""
    }

    private var htmlFilteringToolbarLabel: String {
        displayedHTMLContentAdjustmentReason?.alertTitle ?? "HTML Content Adjusted"
    }

    private var htmlFilteringToolbarIcon: String {
        displayedHTMLContentAdjustmentReason?.toolbarIcon ?? "exclamationmark.shield"
    }

    private var htmlFilteringAlertTitle: String {
        displayedHTMLContentAdjustmentReason?.alertTitle ?? "HTML Content Adjusted"
    }

    private var htmlFilteringAccessibilityLabel: String {
        displayedHTMLContentAdjustmentReason?.accessibilityLabel(
            fragmentCount: displayedFilteredHTMLFragmentCount
        ) ?? "HTML content adjusted"
    }

    private var displayedContainsWikiLinks: Bool {
        wikiNavigation.currentPage?.containsWikiLinks ?? document.containsWikiLinks
    }

    private var displayedFrontMatterPageKey: FrontMatterPageKey {
        wikiNavigation.currentPage.map { .wiki($0.url.standardizedFileURL) } ?? .root
    }

    private var frontMatterExpandedBinding: Binding<Bool> {
        let key = displayedFrontMatterPageKey
        return Binding(
            get: { expandedFrontMatterPages.contains(key) },
            set: { expanded in
                if expanded {
                    expandedFrontMatterPages.insert(key)
                } else {
                    expandedFrontMatterPages.remove(key)
                }
            }
        )
    }

    private var displayedPageIdentity: String {
        if let page = wikiNavigation.currentPage {
            return "wiki:\(page.id.uuidString)"
        }
        return "root:\(document.renderRevision)"
    }

    private var isWikiNavigationLoading: Bool {
#if os(macOS)
        wikiNavigation.isForegroundLoading || isResolvingWikiLink
#else
        wikiNavigation.isForegroundLoading
#endif
    }

    private var openLocalDocument: (URL) async throws -> Void {
#if os(macOS)
        { url in
            try await openDocument(at: url)
        }
#else
        { _ in }
#endif
    }

    private var openWikiLink: (String) -> Void {
        { target in
#if os(macOS)
            resolveWikiLink(target)
#else
            localDocumentError = "Wiki folder navigation is available on macOS."
#endif
        }
    }

    private var findStatusText: String {
        guard previewFindText.isEmpty == false else {
            return ""
        }

        if previewFindMatchCount == 0 {
            return "No Results"
        }

        return "\(previewFindCurrentIndex) of \(previewFindMatchCount)"
    }

    private func findNext() {
        previewFindBackwards = false
        previewFindRequest += 1
    }

    private func findPrevious() {
        previewFindBackwards = true
        previewFindRequest += 1
    }

    private func beginPreviewFind() {
        previewFindAnchorRequest += 1
        previewFindFocusRequest += 1
        isPreviewFindPresented = true
    }

    private func closePreviewFind() {
        isPreviewFindPresented = false
        previewFindText = ""
        previewFindMatchCount = 0
        previewFindCurrentIndex = 0
    }

    private func resetPreviewNavigationState() {
        isPreviewFindPresented = false
        previewFindText = ""
        previewFindMatchCount = 0
        previewFindCurrentIndex = 0
    }

    private var localAccessAlertPresented: Binding<Bool> {
#if os(macOS)
        Binding(
            get: { pendingLocalAccessRequest != nil },
            set: { if !$0 { pendingLocalAccessRequest = nil } }
        )
#else
        .constant(false)
#endif
    }

    private var localErrorAlertPresented: Binding<Bool> {
        Binding(
            get: { activeErrorDescription != nil },
            set: {
                if !$0 {
                    localDocumentError = nil
                    wikiNavigation.errorDescription = nil
                }
            }
        )
    }

    private var outputErrorAlertPresented: Binding<Bool> {
        Binding(
            get: { outputErrorDescription != nil },
            set: {
                if $0 == false {
                    outputErrorTitle = nil
                    outputErrorDescription = nil
                }
            }
        )
    }

#if os(macOS)
    private var externalReloadErrorAlertPresented: Binding<Bool> {
        Binding(
            get: { externalReloadErrorDescription != nil },
            set: {
                if $0 == false {
                    externalReloadErrorDescription = nil
                }
            }
        )
    }
#endif

    private var activeErrorDescription: String? {
        localDocumentError ?? wikiNavigation.errorDescription
    }

    private var localAccessAlertTitle: String {
#if os(macOS)
        switch pendingLocalAccessRequest {
        case .document:
            "Allow Access to Linked Documents?"
        case .images:
            "Allow Access to Local Images?"
        case .wikiFolder:
            "Allow Access to Wiki Folder?"
        case nil:
            "Allow Folder Access?"
        }
#else
        "Allow Folder Access?"
#endif
    }

#if os(macOS)
    private var localAccessFolderURL: URL? {
        guard let request = pendingLocalAccessRequest else { return nil }
        if case .wikiFolder = request {
            return fileURL?.deletingLastPathComponent().standardizedFileURL
        }
        guard let targetURL = request.targetURL else { return nil }
        let documentFolder = displayedURL?.deletingLastPathComponent().standardizedFileURL
        if let documentFolder, LocalDocumentAccess.contains(targetURL, in: documentFolder) {
            return documentFolder
        }
        if case .document = request {
            return targetURL.deletingLastPathComponent().standardizedFileURL
        }
        return nil
    }

    private var localAccessFolderName: String {
        localAccessFolderURL?.lastPathComponent ?? "Containing"
    }

    private var localAccessExplanation: String {
        guard let request = pendingLocalAccessRequest else { return "" }
        switch request {
        case .document(let targetURL):
            return "\(targetURL.lastPathComponent) is inside the \(localAccessFolderName) folder. macOS requires your permission before MarkLens can open linked files in this folder. Access will be limited to \(localAccessFolderName) and used only for local document links."
        case .images:
            return "Some images are inside the \(localAccessFolderName) folder. macOS requires your permission before MarkLens can load local images in this document. Access will be limited to \(localAccessFolderName) and used only for local document resources."
        case .wikiFolder:
            return "Choose the root folder for this wiki. MarkLens will search its Markdown files when you open a wikilink. Access is limited to the selected folder and is remembered until you remove it in Settings."
        }
    }

    private func chooseLocalAccessFolder() {
        guard let request = pendingLocalAccessRequest,
              let expectedFolder = localAccessFolderURL else { return }
        let panelTitle = localAccessAlertTitle.replacingOccurrences(of: "?", with: "")
        pendingLocalAccessRequest = nil

        let panel = NSOpenPanel()
        panel.title = panelTitle
        panel.message = request.isWikiFolder
            ? "Choose this folder or an enclosing folder as the wiki root."
            : "Allow MarkLens to access the current \(expectedFolder.lastPathComponent) folder."
        panel.prompt = "Allow Access"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = expectedFolder

        panel.begin { response in
            guard response == .OK, let selectedFolder = panel.url else { return }
            let selectedFolderIsValid = request.isWikiFolder
                ? (LocalDocumentAccess.contains(fileURL ?? expectedFolder, in: selectedFolder)
                    || LocalDocumentAccess.sameFolder(selectedFolder, expectedFolder))
                : LocalDocumentAccess.sameFolder(selectedFolder, expectedFolder)
            guard selectedFolderIsValid else {
                selectedFolder.stopAccessingSecurityScopedResource()
                localDocumentError = request.isWikiFolder
                    ? "Choose a folder that contains this Markdown document."
                    : "Choose the \(expectedFolder.lastPathComponent) folder to grant the requested access."
                return
            }

            do {
                try localDocumentAccess.authorize(folder: selectedFolder)
                switch request {
                case .document(let targetURL):
                    Task {
                        do {
                            try await openDocument(at: targetURL)
                        } catch {
                            localDocumentError = error.localizedDescription
                        }
                    }
                case .images:
                    failedLocalImageURLs.removeAll()
                case .wikiFolder(let target):
                    if let target {
                        resolveWikiLink(target)
                    }
                }
            } catch {
                localDocumentError = error.localizedDescription
            }
        }
    }

    private func handleLocalDocumentOpenFailure(_ url: URL, errorDescription: String) {
        guard isSupportedMarkdownDocument(url) else {
            localDocumentError = "\(url.lastPathComponent) is not a supported markdown document."
            return
        }
        if localDocumentAccess.hasAccess(to: url) {
            localDocumentError = errorDescription
        } else {
            pendingLocalAccessRequest = .document(url)
        }
    }

    private func handleLocalImagePermissionFailure(_ url: URL) {
        guard let documentFolder = displayedURL?.deletingLastPathComponent(),
              LocalDocumentAccess.contains(url, in: documentFolder),
              localDocumentAccess.hasAccess(to: url) == false else {
            return
        }
        failedLocalImageURLs.insert(url.standardizedFileURL)
    }

    private func requestLocalImageAccess() {
        guard let targetURL = failedLocalImageURLs.first else { return }
        pendingLocalAccessRequest = .images(targetURL)
    }

    private var shouldOfferWikiFolderAccess: Bool {
        guard displayedContainsWikiLinks, let fileURL else { return false }
        return localDocumentAccess.authorizedFolder(containing: fileURL) == nil
    }

    private func resolveWikiLink(_ target: String) {
        guard let fileURL else {
            localDocumentError = "Save this document before opening wikilinks."
            return
        }
        guard let root = activeWikiRoot(containing: fileURL) else {
            pendingLocalAccessRequest = .wikiFolder(target)
            return
        }

        wikiResolutionGeneration += 1
        let generation = wikiResolutionGeneration
        isResolvingWikiLink = true
        wikiResolutionWork?.cancel()
        let work = Task.detached(priority: .userInitiated) {
            do {
                let matches = try WikiLinkResolver().matches(
                    for: target,
                    in: root,
                    shouldCancel: { Task.isCancelled }
                )
                return WikiLinkResolution.success(matches)
            } catch is CancellationError {
                return WikiLinkResolution.cancelled
            } catch {
                return WikiLinkResolution.failure(error.localizedDescription)
            }
        }
        wikiResolutionWork = work
        Task {
            let resolution = await work.value

            guard generation == wikiResolutionGeneration else { return }
            isResolvingWikiLink = false
            wikiResolutionWork = nil

            switch resolution {
            case .success(let matches):
                if matches.count == 1, let match = matches.first {
                    openResolvedWikiDocument(match, wikiRoot: root)
                } else {
                    wikiLinkMatchesRoot = root
                    wikiLinkMatches = matches
                }
            case .failure(let description):
                localDocumentError = description
            case .cancelled:
                break
            }
        }
    }

    private func openResolvedWikiDocument(_ url: URL, wikiRoot: URL) {
        wikiNavigation.navigate(
            to: url,
            wikiRoot: wikiRoot,
            renderingPreferences: renderingPreferences,
            leavingScrollPosition: previewScrollPositionStore.position
        ) { navigation in
            restorePreviewScroll(to: navigation.scrollPosition)
        }
    }

    private func activeWikiRoot(containing fileURL: URL) -> URL? {
        if let root = wikiNavigation.wikiRootURL,
           localDocumentAccess.authorizedFolders.contains(where: {
               LocalDocumentAccess.sameFolder($0, root)
           }) {
            return root
        }
        return localDocumentAccess.authorizedFolder(containing: fileURL)
    }

    private func navigateWikiBack() {
        cancelWikiResolution()
        guard let navigation = wikiNavigation.goBack(
            leavingScrollPosition: previewScrollPositionStore.position
        ) else {
            return
        }
        if case .page(let pageURL) = navigation.location {
            let request = restorePreviewScroll(to: navigation.scrollPosition)
            refreshDisplayedWikiPage(
                at: pageURL,
                scrollRestoration: .requested(
                    position: navigation.scrollPosition,
                    request: request
                )
            )
        } else {
            restorePreviewScroll(to: navigation.scrollPosition)
        }
    }

    private func navigateWikiForward() {
        cancelWikiResolution()
        guard let navigation = wikiNavigation.goForward(
            leavingScrollPosition: previewScrollPositionStore.position
        ) else {
            return
        }
        if case .page(let pageURL) = navigation.location {
            let request = restorePreviewScroll(to: navigation.scrollPosition)
            refreshDisplayedWikiPage(
                at: pageURL,
                scrollRestoration: .requested(
                    position: navigation.scrollPosition,
                    request: request
                )
            )
        } else {
            restorePreviewScroll(to: navigation.scrollPosition)
        }
    }

    private func cancelWikiResolution() {
        wikiResolutionGeneration += 1
        wikiResolutionWork?.cancel()
        wikiResolutionWork = nil
        isResolvingWikiLink = false
    }

    private func clearWikiLinkMatches() {
        wikiLinkMatches = []
        wikiLinkMatchesRoot = nil
    }

    private func isSupportedMarkdownDocument(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return MarkdownDocument.readableContentTypes.contains { type.conforms(to: $0) }
    }
#endif
}

#if os(macOS)
private enum LocalAccessRequest {
    case document(URL)
    case images(URL)
    case wikiFolder(String?)

    var targetURL: URL? {
        switch self {
        case .document(let url), .images(let url):
            url
        case .wikiFolder:
            nil
        }
    }

    var isWikiFolder: Bool {
        if case .wikiFolder = self { return true }
        return false
    }
}

private enum WikiLinkResolution: Sendable {
    case success([URL])
    case failure(String)
    case cancelled
}

private struct WikiPageToolbarTitle: View {
    let path: String

    var body: some View {
        Text(path)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help(path)
            .accessibilityIdentifier("wikiPageTitle")
    }
}

private struct WikiLinkMatchChooser: View {
    @Environment(\.dismiss) private var dismiss

    let matches: [URL]
    let root: URL
    let open: (URL) -> Void
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List(filteredMatches) { match in
                Button(match.path) {
                    dismiss()
                    open(match.url)
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $searchText, prompt: "Filter by path")
            .navigationTitle("Choose a Wiki Document")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 320)
    }

    private var filteredMatches: [Match] {
        let resolved = matches.map { url in
            Match(
                url: url,
                path: WikiLinkResolver().relativePath(of: url, in: root)
            )
        }
        guard searchText.isEmpty == false else { return resolved }
        return resolved.filter { match in
            match.path.localizedCaseInsensitiveContains(searchText)
        }
    }

    private struct Match: Identifiable {
        let url: URL
        let path: String
        var id: URL { url }
    }
}
#endif

private extension View {
    @ViewBuilder
    func previewSearchable(
        enabled: Bool,
        text: Binding<String>,
        isPresented: Binding<Bool>,
        submit: @escaping () -> Void
    ) -> some View {
#if os(macOS)
        self
            .onSubmit(of: .search, submit)
#else
        if enabled {
            self
                .searchable(
                    text: text,
                    isPresented: isPresented,
                    placement: .toolbar,
                    prompt: "Find"
                )
                .onSubmit(of: .search, submit)
        } else {
            self
        }
#endif
    }
}

#if os(macOS)
private struct PreviewFindBar: View {
    @Binding var text: String
    var statusText: String
    var canNavigate: Bool
    var focusRequest: Int
    var previous: () -> Void
    var next: () -> Void
    var close: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            searchField

            Button(action: previous) {
                Label("Previous", systemImage: "chevron.left")
            }
            .accessibilityIdentifier("previewFindPreviousButton")
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(!canNavigate)

            Button(action: next) {
                Label("Next", systemImage: "chevron.right")
            }
            .accessibilityIdentifier("previewFindNextButton")
            .keyboardShortcut("g", modifiers: .command)
            .disabled(!canNavigate)

            Button(action: next) {
                Text("Next Result")
            }
            .keyboardShortcut(.defaultAction)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
            .disabled(!canNavigate)

            Button("Done", action: close)
                .accessibilityIdentifier("previewFindDoneButton")
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .onAppear {
            isFocused = true
        }
        .onChange(of: focusRequest) {
            isFocused = true
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Find", text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .accessibilityIdentifier("previewFindField")
                .onSubmit(next)

            if statusText.isEmpty == false {
                Text(statusText)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(minWidth: 74, alignment: .trailing)
                    .accessibilityIdentifier("previewFindStatus")
            }

            if text.isEmpty == false {
                Button {
                    text = ""
                } label: {
                    Label("Clear", systemImage: "xmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(minWidth: 280, idealWidth: 460, maxWidth: 540)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(.quaternary)
        }
    }
}
#endif

#Preview {
#if os(macOS)
    ContentView(document: MarkdownDocument(text: MarkdownDocument.starterText))
        .environmentObject(LocalDocumentAccess())
        .environmentObject(UpdateChecker())
        .environmentObject(ReleaseNotesCoordinator())
#else
    ContentView(document: MarkdownDocument(text: MarkdownDocument.starterText))
        .environmentObject(LocalDocumentAccess())
#endif
}

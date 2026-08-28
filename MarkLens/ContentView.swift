//
//  ContentView.swift
//  MarkLens
//
//  Created by Philipp on 02.01.2026.
//

import SwiftUI
import UniformTypeIdentifiers
import MarkdownPipeline
#if os(macOS)
import AppKit
#endif

struct DocumentScrollPosition: Equatable {
    var sourceLine: Int?
    var progress: Double
    var anchorIdentity: String? = nil
    var anchorOccurrence: Int? = nil
    var previousAnchorIdentity: String? = nil
    var nextAnchorIdentity: String? = nil
    var viewportOffset: Double = 0

    static let top = DocumentScrollPosition(sourceLine: 1, progress: 0)
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
#if os(macOS)
    @Environment(\.openDocument) private var openDocument
    @EnvironmentObject private var updateChecker: UpdateChecker
#endif
    @EnvironmentObject private var localDocumentAccess: LocalDocumentAccess
    @AppStorage(AppearancePreferences.customCSSKey)
    private var customCSS = AppearancePreferences.starterCSS
    @ObservedObject var document: MarkdownDocument
    @StateObject private var wikiNavigation: WikiNavigationModel
    let fileURL: URL?
#if os(macOS)
    @State private var pendingLocalAccessRequest: LocalAccessRequest?
    @State private var externalFileMonitor: ExternalFileMonitor?
    @State private var isUpdatePopoverPresented = false
    @State private var failedLocalImageURLs: Set<URL> = []
    @State private var wikiLinkMatches: [URL] = []
    @State private var wikiLinkMatchesRoot: URL?
    @State private var wikiResolutionGeneration = 0
    @State private var isResolvingWikiLink = false
    @State private var wikiResolutionWork: Task<WikiLinkResolution, Never>?
#endif
    @State private var pendingExternalText: String?
    @State private var isExternalChangeDetailsPresented = false
    @State private var isExternalConflictPresented = false
    @State private var isResolvingExternalChange = false
    @State private var externalResolutionGeneration = 0
    @State private var localDocumentError: String?
    @State private var outputRequest: RenderedDocumentOutputRequest?
    @State private var activeOutputOperationID: UUID?
    @State private var outputErrorTitle: String?
    @State private var outputErrorDescription: String?
    @State private var isRawEditing = false
    @State private var showFind = false
    @State private var rawDraft = ""
    @State private var previewFindText = ""
    @State private var isPreviewFindPresented = false
    @State private var previewFindRequest = 0
    @State private var previewFindBackwards = false
    @State private var previewFindAnchorRequest = 0
    @State private var previewFindFocusRequest = 0
    @State private var previewFindMatchCount = 0
    @State private var previewFindCurrentIndex = 0
    @State private var previewScrollPosition = DocumentScrollPosition.top
    @State private var sourceScrollPosition = DocumentScrollPosition.top
    @State private var previewScrollTarget = DocumentScrollPosition.top
    @State private var sourceScrollTarget = DocumentScrollPosition.top
    @State private var previewScrollRequest = 0
    @State private var sourceScrollRequest = 0

    init(document: MarkdownDocument, fileURL: URL? = nil) {
        self.document = document
        self.fileURL = fileURL
        self._wikiNavigation = StateObject(wrappedValue: WikiNavigationModel())
    }

    var body: some View {
        ZStack {
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
                scrollPosition: $previewScrollPosition,
                scrollTarget: previewScrollTarget,
                scrollRequest: previewScrollRequest
            )
            .allowsHitTesting(!isRawEditing && !isWikiNavigationLoading)
            .zIndex(0)

            if isRawEditing {
                RawEditorView(
                    text: $rawDraft,
                    showFind: $showFind,
                    scrollPosition: $sourceScrollPosition,
                    scrollTarget: sourceScrollTarget,
                    scrollRequest: sourceScrollRequest
                )
                    .disabled(isResolvingExternalChange)
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
                    .disabled(isResolvingExternalChange)
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

#if os(macOS)
                if pendingExternalText != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            isExternalChangeDetailsPresented = true
                        } label: {
                            Label("Changed Externally", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        .help("This file changed outside MarkLens while you were editing.")
                        .accessibilityIdentifier("externalChangeIndicator")
                        .popover(isPresented: $isExternalChangeDetailsPresented, arrowEdge: .top) {
                            VStack(alignment: .leading, spacing: 10) {
                                Label {
                                    Text("File Changed Externally")
                                        .foregroundStyle(.primary)
                                } icon: {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                }
                                .font(.headline)

                                Text("Your draft is safe. Choose Cancel or Update when you’re ready, and MarkLens will ask which version to keep.")
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(width: 280)
                            .padding()
                        }
                    }
                }
#endif

                ToolbarItem(placement: .confirmationAction) {
                    Button("Update", systemImage: "checkmark") {
                        requestFinishRawEditing(commitChanges: true)
                    }
                    .keyboardShortcut("s")
                    .disabled(isResolvingExternalChange)
                }
            } else {
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
                            UpdateAvailablePopover(release: release)
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
                    .disabled(wikiNavigation.isBrowsing)
                }
            }
        }
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
            resetPreviewNavigationState()
        }
#if os(macOS)
        .task {
            await updateChecker.checkIfDue()
        }
        .onAppear {
            startExternalFileMonitor()
        }
        .onChange(of: fileURL) {
            externalFileMonitor?.stop()
            externalFileMonitor = nil
            pendingExternalText = nil
            externalResolutionGeneration += 1
            isResolvingExternalChange = false
            startExternalFileMonitor()
        }
        .onChange(of: scenePhase) {
            guard scenePhase == .active else {
                return
            }
            externalFileMonitor?.refresh()
            Task {
                await updateChecker.checkIfDue()
            }
        }
#endif
        .onDisappear {
#if os(macOS)
            externalFileMonitor?.stop()
            externalFileMonitor = nil
            externalResolutionGeneration += 1
            isResolvingExternalChange = false
            cancelWikiResolution()
#endif
            wikiNavigation.cancelPendingNavigation()
        }
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
        .alert("File Changed Externally", isPresented: $isExternalConflictPresented) {
            Button("Keep My Draft", role: .destructive) {
                keepRawDraft()
            }
            Button("Use External Version", role: .destructive) {
                useExternalVersion()
            }
            Button("Continue Editing", role: .cancel) {}
        } message: {
            Text("Choose which version to keep. Keeping your draft will replace the file on disk. Using the external version will discard your draft.")
        }
#if os(macOS)
        .sheet(
            isPresented: Binding(
                get: { wikiLinkMatches.isEmpty == false },
                set: { if $0 == false { clearWikiLinkMatches() } }
            )
        ) {
            if let root = wikiLinkMatchesRoot {
                WikiLinkMatchChooser(matches: wikiLinkMatches, root: root) { url in
                    clearWikiLinkMatches()
                    openResolvedWikiDocument(url, wikiRoot: root)
                }
            } else {
                EmptyView()
            }
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

    private func rawString() -> String {
        document.text
    }

#if os(macOS)
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

        Task {
            let errorDescription = await Task.detached(priority: .userInitiated) {
                do {
                    try RenderedHTMLExporter.export(
                        html: html,
                        resources: resources,
                        customCSS: css,
                        sourceURL: sourceURL,
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
        let source = rawString()
        RawEditorPerformanceInstrumentation.event(
            "EditModeRequested",
            value: source.utf8.count
        )
        RawEditorPerformanceInstrumentation.measure("EditModeStatePreparation") {
            rawDraft = source
            sourceScrollTarget = previewScrollPosition
            sourceScrollRequest += 1
            isRawEditing = true
        }
    }

    private func requestFinishRawEditing(commitChanges: Bool) {
        guard pendingExternalText == nil else {
            isExternalConflictPresented = true
            return
        }

#if os(macOS)
        guard let externalFileMonitor else {
            finishRawEditing(commitChanges: commitChanges)
            return
        }
        let draftSnapshot = rawDraft
        externalResolutionGeneration += 1
        let resolutionGeneration = externalResolutionGeneration
        isResolvingExternalChange = true
        Task {
            let result = await externalFileMonitor.inspectForExternalChange()
            guard externalResolutionGeneration == resolutionGeneration,
                  isRawEditing,
                  self.externalFileMonitor === externalFileMonitor else {
                return
            }
            switch result {
            case .unchanged:
                if commitChanges {
                    await keepRawDraft(
                        draftSnapshot,
                        using: externalFileMonitor,
                        resolutionGeneration: resolutionGeneration
                    )
                } else {
                    isResolvingExternalChange = false
                    finishRawEditing(commitChanges: false)
                }
            case .changed(let text):
                pendingExternalText = text
                isResolvingExternalChange = false
                isExternalConflictPresented = true
            case .unavailable(let error):
                isResolvingExternalChange = false
                outputErrorTitle = "Unable to Check File"
                outputErrorDescription = error.localizedDescription
            case .cancelled:
                isResolvingExternalChange = false
            }
        }
#else
        finishRawEditing(commitChanges: commitChanges)
#endif
    }

    private func keepRawDraft() {
#if os(macOS)
        guard let externalFileMonitor else {
            finishRawEditing(commitChanges: true)
            return
        }
        let draftSnapshot = rawDraft
        externalResolutionGeneration += 1
        let resolutionGeneration = externalResolutionGeneration
        isResolvingExternalChange = true
        Task {
            await keepRawDraft(
                draftSnapshot,
                using: externalFileMonitor,
                resolutionGeneration: resolutionGeneration
            )
        }
#else
        finishRawEditing(commitChanges: true)
#endif
    }

    private func useExternalVersion() {
#if os(macOS)
        guard let externalFileMonitor else {
            return
        }
        externalResolutionGeneration += 1
        let resolutionGeneration = externalResolutionGeneration
        isResolvingExternalChange = true
        Task {
            do {
                let currentText = try await externalFileMonitor.currentFileText()
                guard externalResolutionGeneration == resolutionGeneration,
                      isRawEditing,
                      self.externalFileMonitor === externalFileMonitor else { return }
                pendingExternalText = currentText
                isResolvingExternalChange = false
                finishRawEditing(commitChanges: false)
            } catch {
                guard externalResolutionGeneration == resolutionGeneration,
                      self.externalFileMonitor === externalFileMonitor else { return }
                isResolvingExternalChange = false
                outputErrorTitle = "Unable to Load External Version"
                outputErrorDescription = error.localizedDescription
            }
        }
#else
        finishRawEditing(commitChanges: false)
#endif
    }

#if os(macOS)
    private func keepRawDraft(
        _ draft: String,
        using externalFileMonitor: ExternalFileMonitor,
        resolutionGeneration: Int
    ) async {
        do {
            try await externalFileMonitor.replaceFile(with: draft)
            guard externalResolutionGeneration == resolutionGeneration,
                  isRawEditing,
                  self.externalFileMonitor === externalFileMonitor else { return }
            isResolvingExternalChange = false
            finishRawEditing(commitChanges: true, committedText: draft)
        } catch ExternalFileMonitor.ReplacementError.fileChanged(let text) {
            guard externalResolutionGeneration == resolutionGeneration,
                  self.externalFileMonitor === externalFileMonitor else { return }
            pendingExternalText = text
            isResolvingExternalChange = false
            isExternalConflictPresented = true
        } catch {
            guard externalResolutionGeneration == resolutionGeneration,
                  self.externalFileMonitor === externalFileMonitor else { return }
            isResolvingExternalChange = false
            outputErrorTitle = "Unable to Save Draft"
            outputErrorDescription = error.localizedDescription
        }
    }
#endif

    private func finishRawEditing(commitChanges: Bool, committedText: String? = nil) {
        previewScrollTarget = sourceScrollPosition
        previewScrollRequest += 1
        if commitChanges {
            document.updateText(committedText ?? rawDraft)
            pendingExternalText = nil
        } else if let pendingExternalText {
            document.updateText(pendingExternalText)
            self.pendingExternalText = nil
        }
        isExternalChangeDetailsPresented = false
        isRawEditing = false
    }

#if os(macOS)
    private func startExternalFileMonitor() {
        guard externalFileMonitor == nil, let fileURL else {
            return
        }

        externalFileMonitor = ExternalFileMonitor(fileURL: fileURL, initialText: document.text) { text in
            if isRawEditing {
                pendingExternalText = text
            } else {
                previewScrollTarget = previewScrollPosition
                previewScrollRequest += 1
                document.updateText(text)
            }
        }
    }
#endif

    private var displayedHTML: String {
        wikiNavigation.currentPage?.html ?? document.renderedHTML
    }

    private var displayedURL: URL? {
        wikiNavigation.currentPage?.url ?? fileURL
    }

    private var displayedResources: [HTMLResource] {
        wikiNavigation.currentPage?.resources ?? document.renderedResources
    }

    private var displayedContainsWikiLinks: Bool {
        wikiNavigation.currentPage?.containsWikiLinks ?? document.containsWikiLinks
    }

    private var displayedPageIdentity: String {
        if let page = wikiNavigation.currentPage {
            return "wiki:\(page.id.uuidString)"
        }
        return "root:\(document.renderRevision)"
    }

    private var isWikiNavigationLoading: Bool {
#if os(macOS)
        wikiNavigation.isLoading || isResolvingWikiLink
#else
        wikiNavigation.isLoading
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
        wikiNavigation.navigate(to: url, wikiRoot: wikiRoot)
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
        wikiNavigation.goBack()
    }

    private func navigateWikiForward() {
        cancelWikiResolution()
        wikiNavigation.goForward()
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
    ContentView(document: MarkdownDocument())
        .environmentObject(LocalDocumentAccess())
        .environmentObject(UpdateChecker())
#else
    ContentView(document: MarkdownDocument())
        .environmentObject(LocalDocumentAccess())
#endif
}

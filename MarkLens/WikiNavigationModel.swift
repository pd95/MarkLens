import Combine
import Foundation
import MarkdownPipeline

nonisolated struct WikiPage: Equatable, Sendable {
    let id: UUID
    let url: URL
    let html: String
    let resources: [HTMLResource]
    let containsWikiLinks: Bool
    let containsFrontMatter: Bool
    let filteredHTMLFragmentCount: Int
    let htmlContentAdjustmentReason: HTMLContentAdjustmentReason?
    let displayPath: String
    let sourceData: Data?
    let estimatedByteCount: Int

    nonisolated init(
        id: UUID = UUID(),
        url: URL,
        html: String,
        resources: [HTMLResource],
        containsWikiLinks: Bool,
        containsFrontMatter: Bool = false,
        filteredHTMLFragmentCount: Int = 0,
        htmlContentAdjustmentReason: HTMLContentAdjustmentReason? = nil,
        displayPath: String,
        sourceData: Data? = nil,
        estimatedByteCount: Int
    ) {
        self.id = id
        self.url = url
        self.html = html
        self.resources = resources
        self.containsWikiLinks = containsWikiLinks
        self.containsFrontMatter = containsFrontMatter
        self.filteredHTMLFragmentCount = filteredHTMLFragmentCount
        self.htmlContentAdjustmentReason = htmlContentAdjustmentReason
        self.displayPath = displayPath
        self.sourceData = sourceData
        self.estimatedByteCount = estimatedByteCount
    }
}

enum WikiLocation: Equatable, Sendable {
    case root
    case page(URL)
}

struct WikiHistoryNavigation: Equatable {
    let location: WikiLocation
    let scrollPosition: DocumentScrollPosition
}

private struct WikiHistoryEntry {
    let location: WikiLocation
    let scrollPosition: DocumentScrollPosition
}

private struct PendingWikiRefresh {
    let renderingPreferences: RenderingPreferences
    let onReload: (@MainActor (URL, Bool) -> Void)?
}

private enum WikiPageLoadPurpose {
    case navigation
    case reload
    case refresh
}

enum WikiPageLoadResult: Sendable {
    case success(WikiPage)
    case failure(String)
    case cancelled
}

@MainActor
final class WikiNavigationModel: ObservableObject {
    @Published private(set) var current: WikiLocation = .root
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published private(set) var isForegroundLoading = false
    @Published private(set) var currentPage: WikiPage?
    @Published var errorDescription: String?

    private(set) var wikiRootURL: URL?
    private var backStack: [WikiHistoryEntry] = []
    private var forwardStack: [WikiHistoryEntry] = []
    private var navigationGeneration = 0
    private var loadTask: Task<Void, Never>?
    private var pageLoadWork: Task<WikiPageLoadResult, Never>?
    private var activeLoadPurpose: WikiPageLoadPurpose?
    private var pendingRefresh: PendingWikiRefresh?
    private var pageCache: [URL: WikiPage] = [:]
    private let loader: @Sendable (URL, URL, RenderingPreferences) -> WikiPageLoadResult
    private let refreshLoader: @Sendable (
        URL,
        URL,
        RenderingPreferences,
        WikiPage
    ) -> WikiPageLoadResult

    private static let historyLimit = 20
    private static let historyByteLimit = 32 * 1_024 * 1_024

    var isBrowsing: Bool { currentPage != nil }
    var hasBrowserHistory: Bool { canGoBack || canGoForward || isBrowsing }
    var historyEntryCount: Int { backStack.count + forwardStack.count }
    var cachedPageCount: Int { pageCache.count }
    var cachedPageByteCount: Int { cachedHistoryByteCount }

    init() {
        self.loader = WikiPageLoader.load
        self.refreshLoader = WikiPageLoader.refresh
    }

    init(loader: @escaping @Sendable (URL, URL, RenderingPreferences) -> WikiPageLoadResult) {
        self.loader = loader
        self.refreshLoader = { url, root, preferences, _ in
            loader(url, root, preferences)
        }
    }

    deinit {
        loadTask?.cancel()
        pageLoadWork?.cancel()
    }

    func navigate(
        to url: URL,
        wikiRoot: URL,
        renderingPreferences: RenderingPreferences = .secureDefaults,
        leavingScrollPosition: DocumentScrollPosition = .top
    ) {
        navigationGeneration += 1
        let generation = navigationGeneration
        loadTask?.cancel()
        pageLoadWork?.cancel()
        activeLoadPurpose = .navigation
        pendingRefresh = nil
        errorDescription = nil
        isLoading = true
        isForegroundLoading = true

        let loader = self.loader
        let pageLoadWork = Task.detached(priority: .userInitiated) {
            guard isCurrentTaskCancelled() == false else { return WikiPageLoadResult.cancelled }
            return loader(url, wikiRoot, renderingPreferences)
        }
        self.pageLoadWork = pageLoadWork
        loadTask = Task { [weak self] in
            let result = await pageLoadWork.value

            guard let self,
                  Task.isCancelled == false,
                  generation == self.navigationGeneration else {
                return
            }
            self.isLoading = false
            self.isForegroundLoading = false
            self.activeLoadPurpose = nil
            switch result {
            case .success(let page):
                self.backStack.append(WikiHistoryEntry(
                    location: self.current,
                    scrollPosition: leavingScrollPosition
                ))
                self.current = .page(page.url)
                self.currentPage = page
                self.forwardStack.removeAll()
                self.wikiRootURL = wikiRoot
                self.pageCache[page.url] = page
                self.trimHistory()
                self.prunePageCache()
                self.updateHistoryState()
            case .failure(let description):
                self.errorDescription = description
            case .cancelled:
                break
            }
        }
    }

    func reloadCurrent(renderingPreferences: RenderingPreferences) {
        guard let currentPage, let wikiRootURL else { return }
        navigationGeneration += 1
        let generation = navigationGeneration
        loadTask?.cancel()
        pageLoadWork?.cancel()
        activeLoadPurpose = .reload
        pendingRefresh = nil
        isLoading = true
        isForegroundLoading = true
        let loader = self.loader
        let url = currentPage.url
        let work = Task.detached(priority: .userInitiated) {
            loader(url, wikiRootURL, renderingPreferences)
        }
        pageLoadWork = work
        loadTask = Task { [weak self] in
            let result = await work.value
            guard let self, generation == self.navigationGeneration else { return }
            self.isLoading = false
            self.isForegroundLoading = false
            self.activeLoadPurpose = nil
            switch result {
            case .success(let page):
                let rootEntry = self.backStack.first { $0.location == .root }
                    ?? WikiHistoryEntry(location: .root, scrollPosition: .top)
                self.current = .page(page.url)
                self.currentPage = page
                self.backStack = [rootEntry]
                self.forwardStack = []
                self.pageCache = [page.url: page]
                self.updateHistoryState()
            case .failure(let description):
                self.errorDescription = description
            case .cancelled:
                break
            }
            self.startPendingRefreshIfNeeded()
        }
    }

    func refreshCurrent(
        renderingPreferences: RenderingPreferences,
        onReload: (@MainActor (URL, Bool) -> Void)? = nil
    ) {
        guard let currentPage,
              let wikiRootURL else {
            return
        }
        if isLoading {
            guard activeLoadPurpose != .navigation else { return }
            pendingRefresh = PendingWikiRefresh(
                renderingPreferences: renderingPreferences,
                onReload: onReload
            )
            return
        }
        startRefresh(
            url: currentPage.url,
            wikiRootURL: wikiRootURL,
            renderingPreferences: renderingPreferences,
            onReload: onReload
        )
    }

    private func startRefresh(
        url: URL,
        wikiRootURL: URL,
        renderingPreferences: RenderingPreferences,
        onReload: (@MainActor (URL, Bool) -> Void)?
    ) {
        guard let previousPage = currentPage else { return }
        navigationGeneration += 1
        let generation = navigationGeneration
        loadTask?.cancel()
        pageLoadWork?.cancel()
        activeLoadPurpose = .refresh
        errorDescription = nil
        isLoading = true
        isForegroundLoading = false
        let refreshLoader = self.refreshLoader
        let work = Task.detached(priority: .userInitiated) {
            refreshLoader(url, wikiRootURL, renderingPreferences, previousPage)
        }
        pageLoadWork = work
        loadTask = Task { [weak self] in
            let result = await work.value
            guard let self, generation == self.navigationGeneration else { return }
            self.isLoading = false
            self.isForegroundLoading = false
            self.activeLoadPurpose = nil
            switch result {
            case .success(let page):
                let contentChanged = page.id != self.currentPage?.id
                self.current = .page(page.url)
                self.currentPage = page
                self.pageCache[page.url] = page
                self.trimHistory()
                self.prunePageCache()
                self.errorDescription = nil
                onReload?(page.url, contentChanged)
            case .failure(let description):
                self.errorDescription = description
            case .cancelled:
                break
            }
            self.startPendingRefreshIfNeeded()
        }
    }

    @discardableResult
    func goBack(
        leavingScrollPosition: DocumentScrollPosition = .top
    ) -> WikiHistoryNavigation? {
        guard let destination = backStack.popLast() else { return nil }
        cancelLoading()
        errorDescription = nil
        forwardStack.append(WikiHistoryEntry(
            location: current,
            scrollPosition: leavingScrollPosition
        ))
        current = destination.location
        currentPage = page(for: destination.location)
        trimHistory()
        prunePageCache()
        updateHistoryState()
        return WikiHistoryNavigation(
            location: destination.location,
            scrollPosition: destination.scrollPosition
        )
    }

    @discardableResult
    func goForward(
        leavingScrollPosition: DocumentScrollPosition = .top
    ) -> WikiHistoryNavigation? {
        guard let destination = forwardStack.popLast() else { return nil }
        cancelLoading()
        errorDescription = nil
        backStack.append(WikiHistoryEntry(
            location: current,
            scrollPosition: leavingScrollPosition
        ))
        current = destination.location
        currentPage = page(for: destination.location)
        trimHistory()
        prunePageCache()
        updateHistoryState()
        return WikiHistoryNavigation(
            location: destination.location,
            scrollPosition: destination.scrollPosition
        )
    }

    func cancelPendingNavigation() {
        cancelLoading()
    }

    private func cancelLoading() {
        navigationGeneration += 1
        loadTask?.cancel()
        pageLoadWork?.cancel()
        loadTask = nil
        pageLoadWork = nil
        activeLoadPurpose = nil
        pendingRefresh = nil
        isLoading = false
        isForegroundLoading = false
    }

    private func startPendingRefreshIfNeeded() {
        guard let pendingRefresh else { return }
        self.pendingRefresh = nil
        refreshCurrent(
            renderingPreferences: pendingRefresh.renderingPreferences,
            onReload: pendingRefresh.onReload
        )
    }

    private func updateHistoryState() {
        canGoBack = backStack.isEmpty == false
        canGoForward = forwardStack.isEmpty == false
    }

    private func page(for location: WikiLocation) -> WikiPage? {
        guard case .page(let url) = location else { return nil }
        return pageCache[url]
    }

    private func trimHistory() {
        while backStack.count + forwardStack.count > Self.historyLimit {
            guard removeOldestEvictableHistoryEntry() else { break }
        }
        while cachedHistoryByteCount > Self.historyByteLimit {
            guard removeOldestEvictableHistoryEntry() else { break }
        }
    }

    private var cachedHistoryByteCount: Int {
        historyPageURLs.reduce(0) { partial, url in
            partial + (pageCache[url]?.estimatedByteCount ?? 0)
        }
    }

    private var historyPageURLs: Set<URL> {
        Set((backStack + forwardStack).compactMap { entry in
            guard case .page(let url) = entry.location else { return nil }
            return url
        })
    }

    private var referencedPageURLs: Set<URL> {
        let historyLocations = (backStack + forwardStack).map(\.location)
        return Set((historyLocations + [current]).compactMap { location in
            guard case .page(let url) = location else { return nil }
            return url
        })
    }

    private func prunePageCache() {
        let referenced = referencedPageURLs
        pageCache = pageCache.filter { referenced.contains($0.key) }
    }

    private func removeOldestEvictableHistoryEntry() -> Bool {
        if let index = backStack.firstIndex(where: { $0.location != .root }) {
            backStack.remove(at: index)
            return true
        }
        if forwardStack.isEmpty == false {
            forwardStack.removeFirst()
            return true
        }
        return false
    }
}

enum WikiPageLoader {
    nonisolated private static let pipeline = MarkdownPipeline(
        plugins: [.wikiLinks(), .syntaxHighlighting(), .math(), .mermaid(), .customCSS()]
    )

    nonisolated static func load(
        url: URL,
        wikiRoot: URL,
        renderingPreferences: RenderingPreferences
    ) -> WikiPageLoadResult {
        guard isCurrentTaskCancelled() == false else { return .cancelled }
        do {
            let sourceData = try Data(contentsOf: url)
            return render(
                sourceData,
                url: url,
                wikiRoot: wikiRoot,
                renderingPreferences: renderingPreferences
            )
        } catch {
            return .failure("Unable to load \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    nonisolated static func refresh(
        url: URL,
        wikiRoot: URL,
        renderingPreferences: RenderingPreferences,
        currentPage: WikiPage
    ) -> WikiPageLoadResult {
        guard isCurrentTaskCancelled() == false else { return .cancelled }
        do {
            let sourceData = try Data(contentsOf: url)
            guard sourceData != currentPage.sourceData else {
                return .success(currentPage)
            }
            return render(
                sourceData,
                url: url,
                wikiRoot: wikiRoot,
                renderingPreferences: renderingPreferences
            )
        } catch {
            return .failure("Unable to load \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    nonisolated private static func render(
        _ sourceData: Data,
        url: URL,
        wikiRoot: URL,
        renderingPreferences: RenderingPreferences
    ) -> WikiPageLoadResult {
        guard isCurrentTaskCancelled() == false else { return .cancelled }
        do {
            let context = renderingPreferences.pipelineContext(title: url.lastPathComponent)
            let document = try pipeline.renderHTML(from: .data(sourceData), context: context)
            guard isCurrentTaskCancelled() == false else { return .cancelled }
            return .success(WikiPage(
                url: url,
                html: document.html,
                resources: document.resources,
                containsWikiLinks: document.containsWikiLinks,
                containsFrontMatter: document.containsFrontMatter,
                filteredHTMLFragmentCount: document.filteredHTMLFragmentCount,
                htmlContentAdjustmentReason: document.filteredHTMLFragmentCount > 0
                    ? renderingPreferences.htmlContentAdjustmentReason
                    : nil,
                displayPath: WikiLinkResolver().relativePath(of: url, in: wikiRoot),
                sourceData: sourceData,
                estimatedByteCount: document.html.utf8.count + sourceData.count
            ))
        } catch {
            return .failure("Unable to load \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}

nonisolated private func isCurrentTaskCancelled() -> Bool {
    withUnsafeCurrentTask { $0?.isCancelled ?? false }
}

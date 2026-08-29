import Combine
import Foundation
import MarkdownPipeline

struct WikiPage: Equatable, Sendable {
    let id: UUID
    let url: URL
    let html: String
    let resources: [HTMLResource]
    let containsWikiLinks: Bool
    let filteredHTMLFragmentCount: Int
    let htmlContentAdjustmentReason: HTMLContentAdjustmentReason?
    let displayPath: String
    let estimatedByteCount: Int

    nonisolated init(
        id: UUID = UUID(),
        url: URL,
        html: String,
        resources: [HTMLResource],
        containsWikiLinks: Bool,
        filteredHTMLFragmentCount: Int = 0,
        htmlContentAdjustmentReason: HTMLContentAdjustmentReason? = nil,
        displayPath: String,
        estimatedByteCount: Int
    ) {
        self.id = id
        self.url = url
        self.html = html
        self.resources = resources
        self.containsWikiLinks = containsWikiLinks
        self.filteredHTMLFragmentCount = filteredHTMLFragmentCount
        self.htmlContentAdjustmentReason = htmlContentAdjustmentReason
        self.displayPath = displayPath
        self.estimatedByteCount = estimatedByteCount
    }
}

enum WikiLocation: Equatable, Sendable {
    case root
    case page(URL)
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
    @Published private(set) var currentPage: WikiPage?
    @Published var errorDescription: String?

    private(set) var wikiRootURL: URL?
    private var backStack: [WikiLocation] = []
    private var forwardStack: [WikiLocation] = []
    private var navigationGeneration = 0
    private var loadTask: Task<Void, Never>?
    private var pageLoadWork: Task<WikiPageLoadResult, Never>?
    private var pageCache: [URL: WikiPage] = [:]
    private let loader: @Sendable (URL, URL, RenderingPreferences) -> WikiPageLoadResult

    private static let historyLimit = 20
    private static let historyByteLimit = 32 * 1_024 * 1_024

    var isBrowsing: Bool { currentPage != nil }
    var hasBrowserHistory: Bool { canGoBack || canGoForward || isBrowsing }
    var historyEntryCount: Int { backStack.count + forwardStack.count }
    var cachedPageCount: Int { pageCache.count }
    var cachedPageByteCount: Int { cachedHistoryByteCount }

    init(loader: @escaping @Sendable (URL, URL, RenderingPreferences) -> WikiPageLoadResult = WikiPageLoader.load) {
        self.loader = loader
    }

    deinit {
        loadTask?.cancel()
        pageLoadWork?.cancel()
    }

    func navigate(
        to url: URL,
        wikiRoot: URL,
        renderingPreferences: RenderingPreferences = .secureDefaults
    ) {
        navigationGeneration += 1
        let generation = navigationGeneration
        loadTask?.cancel()
        pageLoadWork?.cancel()
        errorDescription = nil
        isLoading = true

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
            switch result {
            case .success(let page):
                self.backStack.append(self.current)
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
        isLoading = true
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
            switch result {
            case .success(let page):
                self.current = .page(page.url)
                self.currentPage = page
                self.backStack = [.root]
                self.forwardStack = []
                self.pageCache = [page.url: page]
                self.updateHistoryState()
            case .failure(let description):
                self.errorDescription = description
            case .cancelled:
                break
            }
        }
    }

    func goBack() {
        guard let destination = backStack.popLast() else { return }
        cancelLoading()
        forwardStack.append(current)
        current = destination
        currentPage = page(for: destination)
        trimHistory()
        prunePageCache()
        updateHistoryState()
    }

    func goForward() {
        guard let destination = forwardStack.popLast() else { return }
        cancelLoading()
        backStack.append(current)
        current = destination
        currentPage = page(for: destination)
        trimHistory()
        prunePageCache()
        updateHistoryState()
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
        isLoading = false
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
        Set((backStack + forwardStack).compactMap { location in
            guard case .page(let url) = location else { return nil }
            return url
        })
    }

    private var referencedPageURLs: Set<URL> {
        let locations = backStack + [current] + forwardStack
        return Set(locations.compactMap { location in
            guard case .page(let url) = location else { return nil }
            return url
        })
    }

    private func prunePageCache() {
        let referenced = referencedPageURLs
        pageCache = pageCache.filter { referenced.contains($0.key) }
    }

    private func removeOldestEvictableHistoryEntry() -> Bool {
        if let index = backStack.firstIndex(where: { $0 != .root }) {
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
            let context = renderingPreferences.pipelineContext(title: url.lastPathComponent)
            let document = try pipeline.renderHTML(from: .file(url), context: context)
            guard isCurrentTaskCancelled() == false else { return .cancelled }
            return .success(WikiPage(
                url: url,
                html: document.html,
                resources: document.resources,
                containsWikiLinks: document.containsWikiLinks,
                filteredHTMLFragmentCount: document.filteredHTMLFragmentCount,
                htmlContentAdjustmentReason: document.filteredHTMLFragmentCount > 0
                    ? renderingPreferences.htmlContentAdjustmentReason
                    : nil,
                displayPath: WikiLinkResolver().relativePath(of: url, in: wikiRoot),
                estimatedByteCount: document.html.utf8.count
            ))
        } catch {
            return .failure("Unable to load \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}

nonisolated private func isCurrentTaskCancelled() -> Bool {
    withUnsafeCurrentTask { $0?.isCancelled ?? false }
}

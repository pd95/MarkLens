import Combine
import Foundation
#if canImport(Darwin)
import Darwin
#endif

final class LocalDocumentAccess: ObservableObject {
#if os(macOS)
    private static let bookmarksKey = "AuthorizedLocalDocumentFoldersV2"

    private struct AccessedFolder {
        let securityScopedURL: URL
        let canonicalURL: URL
    }

    private var accessedFolders: [AccessedFolder] = []
    private var bookmarks: [Data] = []
    @Published private(set) var hasAuthorizedFolders = false
    @Published private(set) var accessRevision = 0
    @Published private(set) var authorizedFolders: [URL] = []

    init() {
        restoreBookmarks()
    }

    deinit {
        accessedFolders.forEach { $0.securityScopedURL.stopAccessingSecurityScopedResource() }
    }

    func authorize(folder: URL) throws {
        let canonicalFolder = Self.canonical(folder)
        guard accessedFolders.contains(where: { $0.canonicalURL == canonicalFolder }) == false else {
            folder.stopAccessingSecurityScopedResource()
            return
        }

        let bookmark: Data
        do {
            bookmark = try folder.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            folder.stopAccessingSecurityScopedResource()
            throw error
        }
        // NSOpenPanel returns a URL whose security-scoped access is already active.
        // Retain that scope and balance it exactly once when access is revoked.
        accessedFolders.append(AccessedFolder(
            securityScopedURL: folder,
            canonicalURL: canonicalFolder
        ))
        bookmarks.append(bookmark)
        persistBookmarks()
        updatePublishedState()
        accessRevision += 1
    }

    func revoke(folder: URL) {
        let canonicalFolder = Self.canonical(folder)
        guard let index = accessedFolders.firstIndex(where: { $0.canonicalURL == canonicalFolder }) else {
            return
        }

        accessedFolders[index].securityScopedURL.stopAccessingSecurityScopedResource()
        accessedFolders.remove(at: index)
        bookmarks.remove(at: index)
        persistBookmarks()
        updatePublishedState()
        accessRevision += 1
    }

    func revokeAll() {
        accessedFolders.forEach { $0.securityScopedURL.stopAccessingSecurityScopedResource() }
        accessedFolders.removeAll()
        bookmarks.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.bookmarksKey)
        UserDefaults.standard.removeObject(forKey: "AuthorizedLocalDocumentFolders")
        updatePublishedState()
        accessRevision += 1
    }

    func hasAccess(to file: URL) -> Bool {
        accessedFolders.contains { Self.contains(file, in: $0.canonicalURL) }
    }

    func authorizedFolder(containing file: URL) -> URL? {
        accessedFolders
            .map(\.canonicalURL)
            .filter { Self.contains(file, in: $0) }
            .max { $0.pathComponents.count < $1.pathComponents.count }
    }

    static func contains(_ file: URL, in folder: URL) -> Bool {
        let fileComponents = canonical(file).pathComponents
        let folderComponents = canonical(folder).pathComponents
        return fileComponents.starts(with: folderComponents) && fileComponents.count > folderComponents.count
    }

    static func sameFolder(_ lhs: URL, _ rhs: URL) -> Bool {
        canonical(lhs) == canonical(rhs)
    }

    private static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func restoreBookmarks() {
        let storedBookmarks = UserDefaults.standard.array(forKey: Self.bookmarksKey) as? [Data] ?? []
        var restoredFolders = Set<URL>()

        for storedBookmark in storedBookmarks {
            var isStale = false
            guard let resolvedURL = try? URL(
                resolvingBookmarkData: storedBookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else {
                continue
            }

            let folder = Self.canonical(resolvedURL)
            guard restoredFolders.insert(folder).inserted,
                  resolvedURL.startAccessingSecurityScopedResource() else {
                continue
            }

            let bookmark: Data
            if isStale,
               let refreshed = try? folder.bookmarkData(
                   options: .withSecurityScope,
                   includingResourceValuesForKeys: nil,
                   relativeTo: nil
               ) {
                bookmark = refreshed
            } else {
                bookmark = storedBookmark
            }
            accessedFolders.append(AccessedFolder(
                securityScopedURL: resolvedURL,
                canonicalURL: folder
            ))
            bookmarks.append(bookmark)
        }

        persistBookmarks()
        updatePublishedState()
    }

    private func persistBookmarks() {
        UserDefaults.standard.set(bookmarks, forKey: Self.bookmarksKey)
    }

    private func updatePublishedState() {
        authorizedFolders = accessedFolders.map(\.canonicalURL).sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        hasAuthorizedFolders = authorizedFolders.isEmpty == false
    }
#else
    let hasAuthorizedFolders = false
    let accessRevision = 0
    let authorizedFolders: [URL] = []
    init() {}
    func authorizedFolder(containing file: URL) -> URL? { nil }
#endif

    static func displayPath(for folder: URL, homeDirectory: URL? = nil) -> String {
        let folderPath = folder.standardizedFileURL.path
        let homePath = (homeDirectory ?? accountHomeDirectory).standardizedFileURL.path
        if folderPath == homePath {
            return "~"
        }
        let homePrefix = homePath.hasSuffix("/") ? homePath : homePath + "/"
        guard folderPath.hasPrefix(homePrefix) else {
            return folderPath
        }
        return "~/" + folderPath.dropFirst(homePrefix.count)
    }

    static func isFolderAvailable(_ folder: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static var accountHomeDirectory: URL {
#if canImport(Darwin)
        if let record = getpwuid(getuid()), let directory = record.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        }
#endif
        return FileManager.default.homeDirectoryForCurrentUser
    }
}

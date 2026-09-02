#if os(macOS)
import Combine
import Foundation

struct ReleaseVersion: Comparable, Equatable {
    private let components: [Int]
    private let prereleaseIdentifiers: [String]?

    var isPrerelease: Bool {
        prereleaseIdentifiers != nil
    }

    init?(_ value: String) {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first?.lowercased() == "v" {
            value.removeFirst()
        }

        let parts = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.isEmpty == false else {
            return nil
        }

        let numericParts = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        let parsedComponents = numericParts.map { Int($0) }
        guard numericParts.isEmpty == false,
            numericParts.allSatisfy({ $0.isEmpty == false }),
            numericParts.allSatisfy({ $0.allSatisfy { $0.isNumber } }),
            parsedComponents.allSatisfy({ $0 != nil })
        else {
            return nil
        }
        var components = parsedComponents.compactMap { $0 }

        while components.count > 1 && components.last == 0 {
            components.removeLast()
        }

        if parts.count == 2 {
            let identifiers = parts[1].split(separator: ".", omittingEmptySubsequences: false)
            guard identifiers.isEmpty == false,
                identifiers.allSatisfy({ $0.isEmpty == false }),
                identifiers.allSatisfy({ identifier in
                    identifier.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
                })
            else {
                return nil
            }
            prereleaseIdentifiers = identifiers.map(String.init)
        } else {
            prereleaseIdentifiers = nil
        }

        self.components = components
    }

    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let componentCount = max(lhs.components.count, rhs.components.count)
        for index in 0..<componentCount {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right {
                return left < right
            }
        }

        switch (lhs.prereleaseIdentifiers, rhs.prereleaseIdentifiers) {
        case (nil, nil):
            return false
        case (nil, .some):
            return false
        case (.some, nil):
            return true
        case (.some(let left), .some(let right)):
            for index in 0..<min(left.count, right.count) {
                if left[index] == right[index] {
                    continue
                }

                let leftNumber = Int(left[index])
                let rightNumber = Int(right[index])
                switch (leftNumber, rightNumber) {
                case (.some(let leftNumber), .some(let rightNumber)):
                    return leftNumber < rightNumber
                case (.some, nil):
                    return true
                case (nil, .some):
                    return false
                case (nil, nil):
                    if let leftParts = splitTrailingNumber(left[index]),
                        let rightParts = splitTrailingNumber(right[index]),
                        leftParts.prefix == rightParts.prefix,
                        leftParts.number != rightParts.number
                    {
                        return leftParts.number < rightParts.number
                    }
                    return left[index] < right[index]
                }
            }
            return left.count < right.count
        }
    }

    private static func splitTrailingNumber(_ value: String) -> (prefix: Substring, number: Int)? {
        guard let lastNonDigit = value.lastIndex(where: { $0.isNumber == false }) else {
            return nil
        }
        let digitStart = value.index(after: lastNonDigit)
        let digits = value[digitStart...]
        guard digitStart != value.endIndex,
            let number = Int(digits)
        else {
            return nil
        }
        return (value[..<digitStart], number)
    }
}

struct AvailableRelease: Codable, Equatable {
    let tagName: String
    let name: String?
    let body: String
    let htmlURL: URL
    let prerelease: Bool
    let changelog: String?
    let downloadURL: URL?

    private enum CodingKeys: String, CodingKey {
        case tagName
        case name
        case body
        case htmlURL
        case prerelease
        case changelog
        case downloadURL
    }

    init(
        tagName: String,
        name: String?,
        body: String,
        htmlURL: URL,
        prerelease: Bool,
        changelog: String? = nil,
        downloadURL: URL? = nil
    ) {
        self.tagName = tagName
        self.name = name
        self.body = body
        self.htmlURL = htmlURL
        self.prerelease = prerelease
        self.changelog = changelog
        self.downloadURL = downloadURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try container.decode(String.self, forKey: .tagName)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        body = try container.decode(String.self, forKey: .body)
        htmlURL = try container.decode(URL.self, forKey: .htmlURL)
        prerelease = try container.decodeIfPresent(Bool.self, forKey: .prerelease)
            ?? ReleaseVersion(tagName)?.isPrerelease
            ?? false
        changelog = try container.decodeIfPresent(String.self, forKey: .changelog)
        downloadURL = try container.decodeIfPresent(URL.self, forKey: .downloadURL)
    }

    var displayVersion: String {
        tagName.first?.lowercased() == "v" ? String(tagName.dropFirst()) : tagName
    }

    func releaseNotes(since installedVersion: String) -> String {
        if let changelog,
           let missedChanges = ReleaseChangelog.missedChanges(
               in: changelog,
               installedVersion: installedVersion,
               releaseTag: tagName
           ) {
            return missedChanges
        }

        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedBody.isEmpty ? "Release notes are unavailable." : trimmedBody
    }

    func releaseNotesContentIdentity(since installedVersion: String) -> String {
        "\(tagName)\n\(installedVersion)\n\(releaseNotes(since: installedVersion))"
    }

    func adding(changelog: String) -> AvailableRelease {
        AvailableRelease(
            tagName: tagName,
            name: name,
            body: body,
            htmlURL: htmlURL,
            prerelease: prerelease,
            changelog: changelog,
            downloadURL: downloadURL
        )
    }
}

enum UpdateSuppressionDisposition: String, Codable, Equatable {
    case checkLater
    case skipVersion
}

struct UpdateSuppression: Codable, Equatable {
    let tagName: String
    let channel: String
    let disposition: UpdateSuppressionDisposition

    var displayVersion: String {
        tagName.first?.lowercased() == "v" ? String(tagName.dropFirst()) : tagName
    }
}

private enum UpdateCheckTrigger {
    case scheduled
    case explicit
}

struct UpdateHTTPResponse {
    let data: Data
    let statusCode: Int
    let etag: String?
}

@MainActor
final class UpdateChecker: ObservableObject {
    typealias HTTPRequest = (URLRequest) async throws -> UpdateHTTPResponse

    @Published private(set) var availableRelease: AvailableRelease?
    @Published private(set) var lastSuccessfulCheck: Date?
    @Published private(set) var lastCheckFailed = false
    @Published private(set) var suppressedUpdate: UpdateSuppression?

    private static let stableReleaseURL = URL(
        string: "https://api.github.com/repos/pd95/MarkLens/releases/latest"
    )!
    private static let allReleasesURL = URL(
        string: "https://api.github.com/repos/pd95/MarkLens/releases?per_page=20"
    )!
    private static let changelogContentsURL = URL(
        string: "https://api.github.com/repos/pd95/MarkLens/contents/CHANGELOG.md"
    )!
    private static let checkInterval: TimeInterval = 7 * 24 * 60 * 60
    private static let lastAttemptKey = "updateChecker.lastAttempt"
    private static let lastSuccessfulCheckKey = "updateChecker.lastSuccessfulCheck"
    private static let lastSuccessfulChannelKey = "updateChecker.lastSuccessfulChannel"
    private static let cachedReleaseKey = "updateChecker.cachedRelease"
    private static let etagKey = "updateChecker.etag"
    private static let cacheSchemaKey = "updateChecker.cacheSchema"
    private static let cacheSchemaVersion = 2
    private static let suppressedUpdateKey = "updateChecker.suppressedUpdate"

    let currentVersion: String
    private let automaticChecksAvailable: Bool
    private let manualChecksEnabled: Bool
    private let defaults: UserDefaults
    private let now: () -> Date
    private let request: HTTPRequest
    private var cachedRelease: AvailableRelease?
    private var activeCheck: Task<Bool, Never>?
    private var activeCheckID = 0
    private var suppressionGeneration = 0

    init(
        currentVersion: String = BuildInfo.tagVersion,
        releaseTag: String = BuildInfo.releaseTag,
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping () -> Date = Date.init,
        request: @escaping HTTPRequest = UpdateChecker.liveRequest
    ) {
        #if DEBUG
        let mockRelease = Self.mockRelease(from: environment)
        #else
        let mockRelease: AvailableRelease? = nil
        #endif
        self.currentVersion = currentVersion == "local" ? BuildInfo.marketingVersion : currentVersion
        self.automaticChecksAvailable = releaseTag != "local" && mockRelease == nil
        self.manualChecksEnabled = mockRelease == nil
        self.defaults = defaults
        self.now = now
        self.request = request
        if defaults.integer(forKey: Self.cacheSchemaKey) < Self.cacheSchemaVersion {
            defaults.removeObject(forKey: Self.etagKey)
            defaults.set(Self.cacheSchemaVersion, forKey: Self.cacheSchemaKey)
        }
        let currentChannel = Self.releaseChannelIdentifier(in: defaults)
        if defaults.string(forKey: Self.lastSuccessfulChannelKey) == currentChannel {
            self.lastSuccessfulCheck = defaults.object(
                forKey: Self.lastSuccessfulCheckKey
            ) as? Date
        }

        if let data = defaults.data(forKey: Self.suppressedUpdateKey),
           let suppression = try? JSONDecoder().decode(UpdateSuppression.self, from: data),
           ReleaseVersion(suppression.tagName) != nil {
            suppressedUpdate = suppression
        } else {
            defaults.removeObject(forKey: Self.suppressedUpdateKey)
        }

        if let mockRelease {
            cachedRelease = mockRelease
            availableRelease = mockRelease
        } else if let data = defaults.data(forKey: Self.cachedReleaseKey),
            let release = try? JSONDecoder().decode(AvailableRelease.self, from: data),
            Self.isTrustedReleaseURL(release.htmlURL),
            Self.isEligible(
                release,
                includesPrereleases: Self.includesPrereleases(in: defaults)
            )
        {
            let trustedRelease = Self.removingUntrustedDownloadURL(from: release)
            cachedRelease = trustedRelease
            restoreAvailableRelease(from: trustedRelease)
        }

        if let suppression = suppressedUpdate,
           Self.isNewer(suppression.tagName, than: self.currentVersion) == false {
            clearSuppression()
        }
    }

    func checkIfDue() async {
        guard automaticChecksAvailable,
              Self.automaticChecksEnabled(in: defaults) else {
            return
        }

        if let activeCheck {
            _ = await activeCheck.value
            return
        }

        let attemptDate = now()
        if let lastAttempt = defaults.object(forKey: Self.lastAttemptKey) as? Date,
            attemptDate.timeIntervalSince(lastAttempt) < Self.checkInterval
        {
            return
        }

        defaults.set(attemptDate, forKey: Self.lastAttemptKey)
        activeCheckID += 1
        let checkID = activeCheckID
        let task = Task<Bool, Never> { [weak self] in
            guard let self else {
                return false
            }
            return await self.performCheck(trigger: .scheduled)
        }
        activeCheck = task
        _ = await task.value
        if activeCheckID == checkID {
            activeCheck = nil
        }
    }

    private static func automaticChecksEnabled(in defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: UpdatePreferences.automaticChecksKey) != nil else {
            return true
        }
        return defaults.bool(forKey: UpdatePreferences.automaticChecksKey)
    }

    func checkNow() async -> Bool {
        guard manualChecksEnabled else {
            return false
        }

        if let activeCheck {
            let startingSuppressionGeneration = suppressionGeneration
            let succeeded = await activeCheck.value
            if succeeded, suppressionGeneration == startingSuppressionGeneration {
                revealCachedReleaseAfterExplicitCheck()
            }
            return succeeded
        }

        defaults.set(now(), forKey: Self.lastAttemptKey)
        activeCheckID += 1
        let checkID = activeCheckID
        let task = Task<Bool, Never> { [weak self] in
            guard let self else {
                return false
            }
            return await self.performCheck(trigger: .explicit)
        }
        activeCheck = task
        let succeeded = await task.value
        if activeCheckID == checkID {
            activeCheck = nil
        }
        return succeeded
    }

    func releaseChannelDidChange() async -> Bool {
        guard manualChecksEnabled else {
            return false
        }

        if let activeCheck {
            activeCheck.cancel()
            _ = await activeCheck.value
            activeCheckID += 1
            self.activeCheck = nil
        }
        defaults.removeObject(forKey: Self.lastAttemptKey)
        defaults.removeObject(forKey: Self.etagKey)
        lastCheckFailed = false
        invalidateSuccessfulCheckIfNeeded()
        if let availableRelease,
            Self.isEligible(
                availableRelease,
                includesPrereleases: Self.includesPrereleases(in: defaults)
            ) == false
        {
            self.availableRelease = nil
        }
        return await checkNow()
    }

    func checkLater() {
        suppressAvailableRelease(as: .checkLater)
    }

    func skipAvailableVersion() {
        suppressAvailableRelease(as: .skipVersion)
    }

    private func performCheck(trigger: UpdateCheckTrigger) async -> Bool {
        let includesPrereleases = Self.includesPrereleases(in: defaults)
        let startingSuppressionGeneration = suppressionGeneration
        let releasesURL = includesPrereleases ? Self.allReleasesURL : Self.stableReleaseURL
        var urlRequest = URLRequest(url: releasesURL)
        urlRequest.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let etag = defaults.string(forKey: Self.etagKey) {
            urlRequest.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        do {
            let response = try await request(urlRequest)
            guard Task.isCancelled == false,
                  includesPrereleases == Self.includesPrereleases(in: defaults) else {
                return false
            }
            if response.statusCode == 304 {
                let enrichedRelease = await changelogEnrichedCachedRelease()
                guard Task.isCancelled == false,
                      includesPrereleases == Self.includesPrereleases(in: defaults) else {
                    return false
                }
                if let enrichedRelease {
                    cache(enrichedRelease)
                }
                publishCachedRelease(
                    after: trigger,
                    includesPrereleases: includesPrereleases,
                    startingSuppressionGeneration: startingSuppressionGeneration
                )
                markCheckSuccessful(includesPrereleases: includesPrereleases)
                return true
            }
            guard response.statusCode == 200 else {
                markCheckFailed()
                return false
            }

            let githubRelease: GitHubRelease
            if includesPrereleases {
                let releases = try JSONDecoder().decode([GitHubRelease].self, from: response.data)
                guard let newestRelease = Self.newestEligibleRelease(in: releases) else {
                    cachedRelease = nil
                    availableRelease = nil
                    defaults.removeObject(forKey: Self.cachedReleaseKey)
                    if let etag = response.etag {
                        defaults.set(etag, forKey: Self.etagKey)
                    } else {
                        defaults.removeObject(forKey: Self.etagKey)
                    }
                    markCheckSuccessful(includesPrereleases: includesPrereleases)
                    return true
                }
                githubRelease = newestRelease
            } else {
                githubRelease = try JSONDecoder().decode(GitHubRelease.self, from: response.data)
            }
            guard githubRelease.draft == false,
                includesPrereleases || githubRelease.prerelease == false,
                Self.isTrustedReleaseURL(githubRelease.htmlURL),
                includesPrereleases == Self.includesPrereleases(in: defaults)
            else {
                markCheckFailed()
                return false
            }

            var release = AvailableRelease(
                tagName: githubRelease.tagName,
                name: githubRelease.name,
                body: githubRelease.body ?? "",
                htmlURL: githubRelease.htmlURL,
                prerelease: githubRelease.prerelease,
                downloadURL: Self.downloadURL(for: githubRelease)
            )
            if Self.isNewer(release.tagName, than: currentVersion),
               let changelog = await loadChangelog(for: release.tagName) {
                release = release.adding(changelog: changelog)
            }
            guard Task.isCancelled == false,
                  includesPrereleases == Self.includesPrereleases(in: defaults) else {
                return false
            }
            cache(release)
            if let etag = response.etag {
                defaults.set(etag, forKey: Self.etagKey)
            } else {
                defaults.removeObject(forKey: Self.etagKey)
            }
            publishCachedRelease(
                after: trigger,
                includesPrereleases: includesPrereleases,
                startingSuppressionGeneration: startingSuppressionGeneration
            )
            markCheckSuccessful(includesPrereleases: includesPrereleases)
            return true
        } catch {
            // Update checks must never interrupt normal document work.
            markCheckFailed()
            return false
        }
    }

    private func changelogEnrichedCachedRelease() async -> AvailableRelease? {
        guard let release = cachedRelease,
              release.changelog == nil,
              let changelog = await loadChangelog(for: release.tagName) else {
            return nil
        }
        return release.adding(changelog: changelog)
    }

    private func loadChangelog(for tagName: String) async -> String? {
        guard ReleaseVersion(tagName) != nil,
              var components = URLComponents(
                  url: Self.changelogContentsURL,
                  resolvingAgainstBaseURL: false
              ) else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: "ref", value: tagName)]
        guard let url = components.url else {
            return nil
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        do {
            let response = try await request(urlRequest)
            guard response.statusCode == 200 else {
                return nil
            }
            return String(data: response.data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    var activeSuppression: UpdateSuppression? {
        guard let suppressedUpdate,
              suppressedUpdate.channel == Self.releaseChannelIdentifier(in: defaults),
              Self.isNewer(suppressedUpdate.tagName, than: currentVersion) else {
            return nil
        }
        return suppressedUpdate
    }

    private func suppressAvailableRelease(as disposition: UpdateSuppressionDisposition) {
        guard let release = availableRelease else {
            return
        }
        let suppression = UpdateSuppression(
            tagName: release.tagName,
            channel: Self.releaseChannelIdentifier(in: defaults),
            disposition: disposition
        )
        suppressedUpdate = suppression
        suppressionGeneration += 1
        if let data = try? JSONEncoder().encode(suppression) {
            defaults.set(data, forKey: Self.suppressedUpdateKey)
        }
        availableRelease = nil
    }

    private func clearSuppression() {
        guard suppressedUpdate != nil
                || defaults.object(forKey: Self.suppressedUpdateKey) != nil else {
            return
        }
        suppressedUpdate = nil
        suppressionGeneration += 1
        defaults.removeObject(forKey: Self.suppressedUpdateKey)
    }

    private func restoreAvailableRelease(from release: AvailableRelease) {
        let includesPrereleases = Self.includesPrereleases(in: defaults)
        guard Self.isNewer(release.tagName, than: currentVersion),
              Self.isEligible(release, includesPrereleases: includesPrereleases) else {
            availableRelease = nil
            return
        }

        guard let suppression = activeSuppression else {
            availableRelease = release
            return
        }
        if Self.isNewer(release.tagName, than: suppression.tagName) {
            clearSuppression()
            availableRelease = release
        } else {
            availableRelease = nil
        }
    }

    private func publishCachedRelease(
        after trigger: UpdateCheckTrigger,
        includesPrereleases: Bool,
        startingSuppressionGeneration: Int
    ) {
        guard let release = cachedRelease,
              Self.isNewer(release.tagName, than: currentVersion),
              Self.isEligible(release, includesPrereleases: includesPrereleases) else {
            availableRelease = nil
            if let suppression = suppressedUpdate,
               Self.isNewer(suppression.tagName, than: currentVersion) == false {
                clearSuppression()
            }
            return
        }

        guard let suppression = activeSuppression else {
            availableRelease = release
            return
        }

        if Self.isNewer(release.tagName, than: suppression.tagName) {
            clearSuppression()
            availableRelease = release
            return
        }

        if suppressionGeneration != startingSuppressionGeneration {
            availableRelease = nil
            return
        }

        switch (trigger, suppression.disposition) {
        case (.explicit, _), (.scheduled, .checkLater):
            clearSuppression()
            availableRelease = release
        case (.scheduled, .skipVersion):
            availableRelease = nil
        }
    }

    private func revealCachedReleaseAfterExplicitCheck() {
        guard let release = cachedRelease,
              Self.isNewer(release.tagName, than: currentVersion),
              Self.isEligible(
                  release,
                  includesPrereleases: Self.includesPrereleases(in: defaults)
              ) else {
            return
        }
        clearSuppression()
        availableRelease = release
    }

    private func cache(_ release: AvailableRelease) {
        cachedRelease = release
        if let cachedData = try? JSONEncoder().encode(release) {
            defaults.set(cachedData, forKey: Self.cachedReleaseKey)
        }
    }

    private func markCheckSuccessful(includesPrereleases: Bool) {
        let checkDate = now()
        lastCheckFailed = false
        lastSuccessfulCheck = checkDate
        defaults.set(checkDate, forKey: Self.lastSuccessfulCheckKey)
        defaults.set(
            Self.releaseChannelIdentifier(includesPrereleases: includesPrereleases),
            forKey: Self.lastSuccessfulChannelKey
        )
    }

    private func markCheckFailed() {
        lastCheckFailed = true
    }

    private func invalidateSuccessfulCheckIfNeeded() {
        let currentChannel = Self.releaseChannelIdentifier(in: defaults)
        guard defaults.string(forKey: Self.lastSuccessfulChannelKey) != currentChannel else {
            return
        }
        lastSuccessfulCheck = nil
        defaults.removeObject(forKey: Self.lastSuccessfulCheckKey)
        defaults.removeObject(forKey: Self.lastSuccessfulChannelKey)
    }

    private static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let candidateVersion = ReleaseVersion(candidate),
            let currentVersion = ReleaseVersion(current)
        else {
            return false
        }
        return candidateVersion > currentVersion
    }

    private static func includesPrereleases(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: UpdatePreferences.includesPrereleasesKey)
    }

    private static func releaseChannelIdentifier(in defaults: UserDefaults) -> String {
        releaseChannelIdentifier(includesPrereleases: includesPrereleases(in: defaults))
    }

    private static func releaseChannelIdentifier(includesPrereleases: Bool) -> String {
        includesPrereleases ? "preview" : "stable"
    }

    private static func isEligible(
        _ release: AvailableRelease,
        includesPrereleases: Bool
    ) -> Bool {
        includesPrereleases || release.prerelease == false
    }

    private static func newestEligibleRelease(in releases: [GitHubRelease]) -> GitHubRelease? {
        releases.compactMap { release -> (release: GitHubRelease, version: ReleaseVersion)? in
            guard release.draft == false,
                isTrustedReleaseURL(release.htmlURL),
                let version = ReleaseVersion(release.tagName)
            else {
                return nil
            }
            return (release, version)
        }
        .max { left, right in
            left.version < right.version
        }?
        .release
    }

    private static func isTrustedReleaseURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "github.com"
    }

    private static func downloadURL(for release: GitHubRelease) -> URL? {
        let expectedName = "MarkLens-\(release.tagName).zip"
        return release.assets.first { asset in
            asset.name == expectedName
                && asset.state == "uploaded"
                && isTrustedDownloadURL(
                    asset.browserDownloadURL,
                    tagName: release.tagName,
                    assetName: expectedName
                )
        }?.browserDownloadURL
    }

    private static func removingUntrustedDownloadURL(
        from release: AvailableRelease
    ) -> AvailableRelease {
        guard let downloadURL = release.downloadURL else {
            return release
        }
        let expectedName = "MarkLens-\(release.tagName).zip"
        guard isTrustedDownloadURL(
            downloadURL,
            tagName: release.tagName,
            assetName: expectedName
        ) else {
            return AvailableRelease(
                tagName: release.tagName,
                name: release.name,
                body: release.body,
                htmlURL: release.htmlURL,
                prerelease: release.prerelease,
                changelog: release.changelog
            )
        }
        return release
    }

    private static func isTrustedDownloadURL(
        _ url: URL,
        tagName: String,
        assetName: String
    ) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == "github.com"
            && url.user == nil
            && url.password == nil
            && url.port == nil
            && url.query == nil
            && url.fragment == nil
            && url.path == "/pd95/MarkLens/releases/download/\(tagName)/\(assetName)"
    }

    #if DEBUG
    private static func mockRelease(from environment: [String: String]) -> AvailableRelease? {
        guard let configuredVersion = environment["MARKLENS_MOCK_UPDATE_VERSION"],
            ReleaseVersion(configuredVersion) != nil
        else {
            return nil
        }

        let tagName =
            configuredVersion.first?.lowercased() == "v"
            ? configuredVersion
            : "v\(configuredVersion)"
        guard
            let releaseURL = URL(
                string: "https://github.com/pd95/MarkLens/releases/tag/\(tagName)"
            ),
            let downloadURL = URL(
                string: "https://github.com/pd95/MarkLens/releases/download/\(tagName)/MarkLens-\(tagName).zip"
            )
        else {
            return nil
        }

        return AvailableRelease(
            tagName: tagName,
            name: "MarkLens \(tagName)",
            body: "Debug preview of the MarkLens update notification.",
            htmlURL: releaseURL,
            prerelease: ReleaseVersion(tagName)?.isPrerelease ?? false,
            changelog: """
                # Changelog

                ## \(configuredVersion)

                - Debug preview of the newest MarkLens improvements.

                ## 98.0.0

                - An earlier update that was missed.
                """,
            downloadURL: downloadURL
        )
    }
    #endif

    static func liveRequest(_ request: URLRequest) async throws -> UpdateHTTPResponse {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return UpdateHTTPResponse(
            data: data,
            statusCode: response.statusCode,
            etag: response.value(forHTTPHeaderField: "ETag")
        )
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: URL
    let draft: Bool
    let prerelease: Bool
    let assets: [GitHubReleaseAsset]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case draft
        case prerelease
        case assets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try container.decode(String.self, forKey: .tagName)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        body = try container.decodeIfPresent(String.self, forKey: .body)
        htmlURL = try container.decode(URL.self, forKey: .htmlURL)
        draft = try container.decode(Bool.self, forKey: .draft)
        prerelease = try container.decode(Bool.self, forKey: .prerelease)
        assets = try container.decodeIfPresent([GitHubReleaseAsset].self, forKey: .assets) ?? []
    }
}

private struct GitHubReleaseAsset: Decodable {
    let name: String
    let browserDownloadURL: URL
    let state: String

    private enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case state
    }
}
#endif

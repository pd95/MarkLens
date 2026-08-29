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

    private enum CodingKeys: String, CodingKey {
        case tagName
        case name
        case body
        case htmlURL
        case prerelease
    }

    init(tagName: String, name: String?, body: String, htmlURL: URL, prerelease: Bool) {
        self.tagName = tagName
        self.name = name
        self.body = body
        self.htmlURL = htmlURL
        self.prerelease = prerelease
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
    }

    var displayVersion: String {
        tagName.first?.lowercased() == "v" ? String(tagName.dropFirst()) : tagName
    }
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

    private static let stableReleaseURL = URL(
        string: "https://api.github.com/repos/pd95/MarkLens/releases/latest"
    )!
    private static let allReleasesURL = URL(
        string: "https://api.github.com/repos/pd95/MarkLens/releases?per_page=20"
    )!
    private static let checkInterval: TimeInterval = 7 * 24 * 60 * 60
    private static let lastAttemptKey = "updateChecker.lastAttempt"
    private static let lastSuccessfulCheckKey = "updateChecker.lastSuccessfulCheck"
    private static let lastSuccessfulChannelKey = "updateChecker.lastSuccessfulChannel"
    private static let cachedReleaseKey = "updateChecker.cachedRelease"
    private static let etagKey = "updateChecker.etag"

    private let currentVersion: String
    private let automaticChecksAvailable: Bool
    private let manualChecksEnabled: Bool
    private let defaults: UserDefaults
    private let now: () -> Date
    private let request: HTTPRequest
    private var activeCheck: Task<Bool, Never>?
    private var activeCheckID = 0

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
        let currentChannel = Self.releaseChannelIdentifier(in: defaults)
        if defaults.string(forKey: Self.lastSuccessfulChannelKey) == currentChannel {
            self.lastSuccessfulCheck = defaults.object(
                forKey: Self.lastSuccessfulCheckKey
            ) as? Date
        }

        if let mockRelease {
            availableRelease = mockRelease
        } else if let data = defaults.data(forKey: Self.cachedReleaseKey),
            let release = try? JSONDecoder().decode(AvailableRelease.self, from: data),
            Self.isTrustedReleaseURL(release.htmlURL),
            Self.isEligible(
                release,
                includesPrereleases: Self.includesPrereleases(in: defaults)
            )
        {
            availableRelease = Self.isNewer(release.tagName, than: self.currentVersion) ? release : nil
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
            return await self.performCheck()
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
            return await activeCheck.value
        }

        defaults.set(now(), forKey: Self.lastAttemptKey)
        activeCheckID += 1
        let checkID = activeCheckID
        let task = Task<Bool, Never> { [weak self] in
            guard let self else {
                return false
            }
            return await self.performCheck()
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

    private func performCheck() async -> Bool {
        let includesPrereleases = Self.includesPrereleases(in: defaults)
        let releasesURL = includesPrereleases ? Self.allReleasesURL : Self.stableReleaseURL
        var urlRequest = URLRequest(url: releasesURL)
        urlRequest.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let etag = defaults.string(forKey: Self.etagKey) {
            urlRequest.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        do {
            let response = try await request(urlRequest)
            guard includesPrereleases == Self.includesPrereleases(in: defaults) else {
                return false
            }
            if response.statusCode == 304 {
                markCheckSuccessful()
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
                    availableRelease = nil
                    defaults.removeObject(forKey: Self.cachedReleaseKey)
                    if let etag = response.etag {
                        defaults.set(etag, forKey: Self.etagKey)
                    } else {
                        defaults.removeObject(forKey: Self.etagKey)
                    }
                    markCheckSuccessful()
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

            let release = AvailableRelease(
                tagName: githubRelease.tagName,
                name: githubRelease.name,
                body: githubRelease.body ?? "",
                htmlURL: githubRelease.htmlURL,
                prerelease: githubRelease.prerelease
            )
            if let cachedData = try? JSONEncoder().encode(release) {
                defaults.set(cachedData, forKey: Self.cachedReleaseKey)
            }
            if let etag = response.etag {
                defaults.set(etag, forKey: Self.etagKey)
            } else {
                defaults.removeObject(forKey: Self.etagKey)
            }
            availableRelease = Self.isNewer(release.tagName, than: currentVersion) ? release : nil
            markCheckSuccessful()
            return true
        } catch {
            // Update checks must never interrupt normal document work.
            markCheckFailed()
            return false
        }
    }

    private func markCheckSuccessful() {
        let checkDate = now()
        lastCheckFailed = false
        lastSuccessfulCheck = checkDate
        defaults.set(checkDate, forKey: Self.lastSuccessfulCheckKey)
        defaults.set(
            Self.releaseChannelIdentifier(in: defaults),
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
        includesPrereleases(in: defaults) ? "preview" : "stable"
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
            )
        else {
            return nil
        }

        return AvailableRelease(
            tagName: tagName,
            name: "MarkLens \(tagName)",
            body: "Debug preview of the MarkLens update notification.",
            htmlURL: releaseURL,
            prerelease: ReleaseVersion(tagName)?.isPrerelease ?? false
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

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case draft
        case prerelease
    }
}
#endif

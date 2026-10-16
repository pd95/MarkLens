#if os(macOS)
import Combine
import Foundation
import Sparkle

@MainActor
protocol UpdateBackend: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    var includesPrereleases: Bool { get set }
    var canCheckForUpdates: Bool { get }
    var lastUpdateCheckDate: Date? { get }
    var onChange: (() -> Void)? { get set }
    func start()
    func checkForUpdates()
    func resetUpdateCycle()
}

@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false
    @Published private(set) var includesPrereleases = false
    @Published private(set) var lastUpdateCheckDate: Date?
    @Published private(set) var unavailableReason: String?

    private let backend: (any UpdateBackend)?
    private let defaults: UserDefaults

    init(
        backend: (any UpdateBackend)? = nil,
        defaults: UserDefaults = .standard,
        releaseTag: String = BuildInfo.releaseTag,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        publicKey: String = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
    ) {
        var selectedBackend = backend
        var selectedDefaults = defaults
        #if DEBUG
        if environment["MARKLENS_UPDATER_UI_TEST"] == "1", backend == nil {
            selectedBackend = PreviewUpdateBackend()
            selectedDefaults = UserDefaults(suiteName: "MarkLens.UpdaterUITest.\(UUID().uuidString)")!
        }
        #endif
        self.defaults = selectedDefaults
        #if DEBUG
        let integrationFeedURL = environment["MARKLENS_UPDATE_TEST_FEED_URL"].flatMap(URL.init(string:))
            .flatMap { $0.scheme == "https" && $0.host != nil ? $0 : nil }
        #else
        let integrationFeedURL: URL? = nil
        #endif
        if selectedBackend == nil {
            if (releaseTag == "local" && integrationFeedURL == nil)
                || environment["XCTestConfigurationFilePath"] != nil
            {
                unavailableReason = "Updates are disabled in local and test builds."
            } else if Data(base64Encoded: publicKey)?.count != 32 {
                unavailableReason =
                    "Updates are unavailable because this build has no update signing key."
            } else {
                selectedBackend = SparkleUpdateBackend(
                    installedVersion: BuildInfo.tagVersion == "local"
                        ? BuildInfo.marketingVersion : BuildInfo.tagVersion,
                    integrationFeedURL: integrationFeedURL
                )
            }
        }
        self.backend = selectedBackend
        guard let selectedBackend else { return }
        UpdatePreferences.migrate(to: selectedBackend, defaults: selectedDefaults)
        selectedBackend.includesPrereleases = selectedDefaults.bool(
            forKey: UpdatePreferences.includesPrereleasesKey)
        selectedBackend.onChange = { [weak self] in self?.refresh() }
        selectedBackend.start()
        refresh()
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        backend?.checkForUpdates()
        refresh()
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        backend?.automaticallyChecksForUpdates = enabled
        refresh()
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        backend?.automaticallyDownloadsUpdates = enabled
        refresh()
    }

    func setIncludesPrereleases(_ enabled: Bool) {
        guard let backend, enabled != includesPrereleases else { return }
        defaults.set(enabled, forKey: UpdatePreferences.includesPrereleasesKey)
        backend.includesPrereleases = enabled
        backend.resetUpdateCycle()
        refresh()
    }

    private func refresh() {
        guard let backend else { return }
        canCheckForUpdates = backend.canCheckForUpdates
        automaticallyChecksForUpdates = backend.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = backend.automaticallyDownloadsUpdates
        includesPrereleases = backend.includesPrereleases
        lastUpdateCheckDate = backend.lastUpdateCheckDate
    }
}

@MainActor
private final class SparkleUpdateBackend: NSObject, UpdateBackend, SPUUpdaterDelegate,
    SPUStandardUserDriverDelegate
{
    private var controller: SPUStandardUpdaterController!
    private var observations: Set<AnyCancellable> = []
    private let installedVersion: String
    private let integrationFeedURL: URL?
    var includesPrereleases = false
    var onChange: (() -> Void)?

    init(installedVersion: String, integrationFeedURL: URL?) {
        self.installedVersion = installedVersion
        self.integrationFeedURL = integrationFeedURL
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).sink { [weak self] _ in
            self?.onChange?()
        }.store(in: &observations)
        updater.publisher(for: \.automaticallyChecksForUpdates).sink { [weak self] _ in
            self?.onChange?()
        }.store(in: &observations)
        updater.publisher(for: \.automaticallyDownloadsUpdates).sink { [weak self] _ in
            self?.onChange?()
        }.store(in: &observations)
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
    var automaticallyDownloadsUpdates: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }
    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }
    var lastUpdateCheckDate: Date? { controller.updater.lastUpdateCheckDate }

    func start() { controller.startUpdater() }
    func checkForUpdates() { controller.checkForUpdates(nil) }
    func resetUpdateCycle() { controller.updater.resetUpdateCycleAfterShortDelay() }

    func feedURLString(for updater: SPUUpdater) -> String? {
        integrationFeedURL?.absoluteString
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        includesPrereleases ? ["preview"] : []
    }

    func updater(
        _ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?
    ) {
        onChange?()
    }

    func standardUserDriverWillShowReleaseNotesText(
        _ text: NSAttributedString,
        forUpdate update: SUAppcastItem,
        withBundleDisplayVersion bundleDisplayVersion: String,
        bundleVersion: String
    ) -> NSAttributedString? {
        UpdateReleaseNotes.filter(
            text, installedVersion: installedVersion, targetVersion: update.displayVersionString)
    }
}

#if DEBUG
@MainActor
private final class PreviewUpdateBackend: UpdateBackend {
    var automaticallyChecksForUpdates = true
    var automaticallyDownloadsUpdates = false
    var includesPrereleases = false
    var canCheckForUpdates = true
    var lastUpdateCheckDate: Date?
    var onChange: (() -> Void)?
    func start() {}
    func resetUpdateCycle() {}
    func checkForUpdates() {
        lastUpdateCheckDate = Date()
        onChange?()
    }
}
#endif
#endif

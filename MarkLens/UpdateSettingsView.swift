import SwiftUI

#if os(macOS)
struct UpdateSettingsView: View {
    private static let automaticChecksExplanation =
        "MarkLens connects to GitHub at most once every seven days to check for new releases. "
        + "You can still check manually when this is off."

    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var updateChecker: UpdateChecker
    @AppStorage(UpdatePreferences.includesPrereleasesKey)
    private var includesPrereleases = false
    @AppStorage(UpdatePreferences.automaticChecksKey)
    private var automaticChecks = true
    @State private var isChecking = false
    @State private var checkGeneration = 0

    var body: some View {
        Form {
            Section("Update Checking") {
                Toggle("Automatically check for updates", isOn: $automaticChecks)
                    .accessibilityIdentifier("automaticUpdateChecksToggle")
                    .accessibilityHint(Self.automaticChecksExplanation)
                Text(Self.automaticChecksExplanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

            Section("Release Channel") {
                Picker("Channel", selection: updateChannel) {
                    ForEach(UpdateChannel.allCases) { channel in
                        Text(channel.title)
                            .tag(channel)
                    }
                }
                .accessibilityIdentifier("updateChannelPicker")
                .accessibilityHint(updateChannel.wrappedValue.explanation)

                Text(updateChannel.wrappedValue.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

            Section {
                HStack {
                    Button("Check Now") {
                        checkForUpdates()
                    }
                    .disabled(isChecking)
                    .accessibilityIdentifier("checkForUpdatesButton")

                    if isChecking {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Checking for updates")
                    }

                    Spacer()

                    if let lastSuccessfulCheck = updateChecker.lastSuccessfulCheck {
                        Text(
                            "Last checked "
                                + lastSuccessfulCheck.formatted(
                                    date: .abbreviated,
                                    time: .shortened
                                )
                        )
                        .foregroundStyle(.secondary)
                    }
                }

                if let checkResult = currentCheckResult {
                    HStack {
                        Text(checkResult.message)
                            .foregroundStyle(checkResult.isFailure ? .red : .secondary)

                        Spacer()

                        if let release = checkResult.release {
                            Button(release.downloadURL == nil ? "View on GitHub" : "Download Update") {
                                openURL(release.downloadURL ?? release.htmlURL)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal)
        .onChange(of: includesPrereleases) {
            checkGeneration += 1
            let generation = checkGeneration
            isChecking = true
            Task {
                _ = await updateChecker.releaseChannelDidChange()
                guard generation == checkGeneration else {
                    return
                }
                isChecking = false
                announceCurrentCheckResult()
            }
        }
    }

    private func checkForUpdates() {
        checkGeneration += 1
        let generation = checkGeneration
        isChecking = true
        Task {
            _ = await updateChecker.checkNow()
            guard generation == checkGeneration else {
                return
            }
            isChecking = false
            announceCurrentCheckResult()
        }
    }

    private func announceCurrentCheckResult() {
        guard let checkResult = currentCheckResult else {
            return
        }
        AccessibilityNotification.Announcement(checkResult.message).post()
    }

    private var currentCheckResult: UpdateCheckResult? {
        if updateChecker.lastCheckFailed {
            if let release = updateChecker.availableRelease {
                return .refreshFailed(release)
            }
            return .failed
        }
        if let release = updateChecker.availableRelease {
            return .updateAvailable(release)
        }
        if updateChecker.lastSuccessfulCheck != nil {
            return .upToDate
        }
        return nil
    }

    private var updateChannel: Binding<UpdateChannel> {
        Binding(
            get: { includesPrereleases ? .preview : .stable },
            set: { includesPrereleases = $0 == .preview }
        )
    }
}

private enum UpdateCheckResult {
    case updateAvailable(AvailableRelease)
    case refreshFailed(AvailableRelease)
    case upToDate
    case failed

    var message: String {
        switch self {
        case .updateAvailable(let release):
            return "MarkLens \(release.displayVersion) is available."
        case .refreshFailed(let release):
            return "Unable to refresh. MarkLens \(release.displayVersion) was previously available."
        case .upToDate:
            return "MarkLens is up to date."
        case .failed:
            return "Unable to check for updates. Try again later."
        }
    }

    var release: AvailableRelease? {
        switch self {
        case .updateAvailable(let release), .refreshFailed(let release):
            return release
        case .upToDate, .failed:
            return nil
        }
    }

    var isFailure: Bool {
        if case .failed = self {
            return true
        }
        if case .refreshFailed = self {
            return true
        }
        return false
    }
}

private enum UpdateChannel: CaseIterable, Identifiable {
    case stable
    case preview

    var id: Self { self }

    var title: String {
        switch self {
        case .stable:
            return "Stable"
        case .preview:
            return "Preview"
        }
    }

    var explanation: String {
        switch self {
        case .stable:
            return "Receive stable releases only."
        case .preview:
            return "Receive release candidates and betas in addition to stable releases. "
                + "Preview versions may be less reliable."
        }
    }
}

#Preview {
    UpdateSettingsView()
        .frame(width: 600, height: 460)
        .environmentObject(UpdateChecker())
}
#endif

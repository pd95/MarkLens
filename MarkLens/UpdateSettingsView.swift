#if os(macOS)
import SwiftUI

struct UpdateSettingsView: View {
    @EnvironmentObject private var appUpdater: AppUpdater

    var body: some View {
        Form {
            Section("Update Checking") {
                Toggle(
                    "Automatically check for updates",
                    isOn: Binding(
                        get: { appUpdater.automaticallyChecksForUpdates },
                        set: appUpdater.setAutomaticallyChecksForUpdates
                    )
                )
                .accessibilityIdentifier("automaticUpdateChecksToggle")
                Text(
                    "MarkLens checks for updates once every seven days. You can check manually at any time."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                Toggle(
                    "Automatically download and install updates",
                    isOn: Binding(
                        get: { appUpdater.automaticallyDownloadsUpdates },
                        set: appUpdater.setAutomaticallyDownloadsUpdates
                    )
                )
                .disabled(!appUpdater.automaticallyChecksForUpdates)
                .accessibilityIdentifier("automaticUpdateInstallationToggle")
                Text("When this is off, you choose when to download and install each update.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .disabled(appUpdater.unavailableReason != nil)

            Section("Release Channel") {
                Picker(
                    "Channel",
                    selection: Binding(
                        get: { appUpdater.includesPrereleases },
                        set: appUpdater.setIncludesPrereleases
                    )
                ) {
                    Text("Stable").tag(false)
                    Text("Preview").tag(true)
                }
                .accessibilityIdentifier("updateChannelPicker")
                .disabled(appUpdater.unavailableReason != nil)
                Text(
                    appUpdater.includesPrereleases
                        ? "Receive betas and release candidates in addition to stable releases. Preview versions may be less reliable."
                        : "Receive stable releases only."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Check Now", action: appUpdater.checkForUpdates)
                        .disabled(!appUpdater.canCheckForUpdates)
                        .accessibilityIdentifier("checkForUpdatesButton")
                    Spacer()
                    if let date = appUpdater.lastUpdateCheckDate {
                        Text("Last checked " + date.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("lastUpdateCheckDate")
                    }
                }
                if let reason = appUpdater.unavailableReason {
                    Text(reason).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal)
    }
}

#Preview {
    UpdateSettingsView()
        .frame(width: 600, height: 460)
        .environmentObject(AppUpdater())
}
#endif

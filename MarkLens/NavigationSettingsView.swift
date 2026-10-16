import SwiftUI

#if os(macOS)
struct NavigationSettingsView: View {
    @AppStorage(ViewModePreferences.defaultKey)
    private var defaultViewMode = false
    @AppStorage(LinkedDocumentOpenPreference.key)
    private var linkedDocumentOpenPreference = LinkedDocumentOpenPreference.followSystem.rawValue
    @AppStorage(LinkedFileOpenPreference.key)
    private var linkedFileOpenPreference = LinkedFileAction.revealInFinder.rawValue
    @AppStorage(LinkedFileOpenPreference.commandClickKey)
    private var linkedFileCommandClickPreference = LinkedFileAction.quickLook.rawValue

    var body: some View {
        Form {
            Section("Document Navigation") {
                Toggle("Browse Links Here by default", isOn: $defaultViewMode)
                    .accessibilityIdentifier("defaultViewModeToggle")
                Text("Local Markdown and wiki links open inside the current document window. "
                    + "You can change this for each file from its toolbar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Picker("When opening linked documents", selection: $linkedDocumentOpenPreference) {
                    Text("Follow macOS").tag(LinkedDocumentOpenPreference.followSystem.rawValue)
                    Text("New Window").tag(LinkedDocumentOpenPreference.newWindow.rawValue)
                    Text("New Tab").tag(LinkedDocumentOpenPreference.newTab.rawValue)
                }
                .accessibilityIdentifier("linkedDocumentOpenPreferencePicker")
                Text("Applies when Browse Links Here is off. Command-click and Open in New Tab still open a tab.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Other Local Files") {
                Picker("Click", selection: $linkedFileOpenPreference) {
                    ForEach(LinkedFileAction.allCases, id: \.self) { action in
                        Text(action.title).tag(action.rawValue)
                    }
                }
                .accessibilityIdentifier("linkedFileOpenPreferencePicker")
                Picker("Command-click", selection: $linkedFileCommandClickPreference) {
                    ForEach(LinkedFileAction.allCases, id: \.self) { action in
                        Text(action.title).tag(action.rawValue)
                    }
                }
                .accessibilityIdentifier("linkedFileCommandClickPreferencePicker")
                Text("Applies to images, text, JSON, other local files, and folders. Open in Default App uses the application assigned to the file in macOS.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal)
    }
}

#Preview {
    NavigationSettingsView()
        .frame(width: 600, height: 460)
}
#endif

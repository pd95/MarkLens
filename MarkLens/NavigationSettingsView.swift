import SwiftUI

#if os(macOS)
struct NavigationSettingsView: View {
    @AppStorage(ViewModePreferences.defaultKey)
    private var defaultViewMode = false
    @AppStorage(LinkedDocumentOpenPreference.key)
    private var linkedDocumentOpenPreference = LinkedDocumentOpenPreference.followSystem.rawValue

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

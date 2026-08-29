import SwiftUI

#if os(macOS)
struct SecuritySettingsView: View {
    @AppStorage(SecurityPreferences.rendersRawHTMLKey)
    private var rendersRawHTML = false
    @AppStorage(SecurityPreferences.loadsRemoteResourcesKey)
    private var loadsRemoteResources = false

    var body: some View {
        Form {
            Section("Document Content") {
                Toggle("Render raw HTML", isOn: $rendersRawHTML)
                    .accessibilityIdentifier("rendersRawHTMLToggle")
                Text("Allowed HTML is sanitized. Scripts, event handlers, forms, and embedded pages are always blocked.")
                    .foregroundStyle(.secondary)

                Toggle("Load remote resources", isOn: $loadsRemoteResources)
                    .accessibilityIdentifier("loadsRemoteResourcesToggle")
                Text("Allows documents and custom CSS to load remote images, styles, and fonts. Links can still be opened when this is off.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
#endif

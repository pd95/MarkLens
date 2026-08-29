import SwiftUI

#if os(macOS)
struct SecuritySettingsView: View {
    @AppStorage(SecurityPreferences.rendersRawHTMLKey)
    private var rendersRawHTML = false
    @AppStorage(SecurityPreferences.loadsRemoteResourcesKey)
    private var loadsRemoteResources = false
    @AppStorage(SecurityPreferences.rendersMermaidKey)
    private var rendersMermaid = true
    @AppStorage(SecurityPreferences.loadsLocalImagesKey)
    private var loadsLocalImages = true

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

            Section("Preview Rendering") {
                Toggle("Render Mermaid diagrams", isOn: $rendersMermaid)
                    .accessibilityIdentifier("rendersMermaidToggle")
                Text("When disabled, Mermaid blocks are shown as source without loading the bundled browser renderer.")
                    .foregroundStyle(.secondary)

                Toggle("Load local linked images", isOn: $loadsLocalImages)
                    .accessibilityIdentifier("loadsLocalImagesToggle")
                Text("Local images remain limited to supported files inside the document folder.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
#endif

import SwiftUI

#if os(macOS)
struct SecuritySettingsView: View {
    @AppStorage(SecurityPreferences.rendersRawHTMLKey)
    private var rendersRawHTML = false
    @AppStorage(SecurityPreferences.loadsRemoteResourcesKey)
    private var loadsRemoteResources = false
    @AppStorage(SecurityPreferences.rendersMermaidKey)
    private var rendersMermaid = true

    var body: some View {
        Form {
            Section("Content Safety") {
                Toggle("Render HTML in Markdown documents", isOn: $rendersRawHTML)
                    .accessibilityIdentifier("rendersRawHTMLToggle")
                Text("Allows supported HTML formatting. Scripts, forms, embedded pages, and event handlers remain blocked.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("External Content") {
                Toggle("Allow remote content", isOn: $loadsRemoteResources)
                    .accessibilityIdentifier("loadsRemoteResourcesToggle")
                Text("Opening a document may contact third-party servers to load images, styles, or fonts, revealing your IP address and when the document was opened. Links remain available when this is off.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Enhanced Rendering") {
                Toggle("Render Mermaid diagrams", isOn: $rendersMermaid)
                    .accessibilityIdentifier("rendersMermaidToggle")
                Text("Converts Mermaid code blocks into diagrams using code included with MarkLens. No network connection is required.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal)
    }
}

#Preview {
    SecuritySettingsView()
        .frame(width: 600, height: 460)
}
#endif

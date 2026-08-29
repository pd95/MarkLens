import SwiftUI

#if os(macOS)
struct SecuritySettingsView: View {
    private static let htmlExplanation =
        "Allows supported HTML formatting. Scripts, forms, embedded pages, and event handlers remain blocked."
    private static let remoteContentExplanation =
        "Opening a document may contact third-party servers to load images, styles, or fonts, "
        + "revealing your IP address and when the document was opened. Links remain available when this is off."
    private static let mermaidExplanation =
        "Converts Mermaid code blocks into diagrams using code included with MarkLens. "
        + "No network connection is required."

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
                    .accessibilityHint(Self.htmlExplanation)
                Text(Self.htmlExplanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

            Section("External Content") {
                Toggle("Allow remote content", isOn: $loadsRemoteResources)
                    .accessibilityIdentifier("loadsRemoteResourcesToggle")
                    .accessibilityHint(Self.remoteContentExplanation)
                Text(Self.remoteContentExplanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

            Section("Enhanced Rendering") {
                Toggle("Render Mermaid diagrams", isOn: $rendersMermaid)
                    .accessibilityIdentifier("rendersMermaidToggle")
                    .accessibilityHint(Self.mermaidExplanation)
                Text(Self.mermaidExplanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
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

import SwiftUI

#if os(macOS)
struct AppearanceSettingsView: View {
    @AppStorage(AppearancePreferences.customCSSKey)
    private var customCSS = AppearancePreferences.starterCSS
    @State private var isRestoreConfirmationPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Custom CSS")
                .font(.headline)

            Text(
                "Override MarkLens fonts, sizes, colors, and layout with CSS. "
                    + "Changes apply immediately to open previews."
            )
                .font(.callout)
                .foregroundStyle(.secondary)

            TextEditor(text: $customCSS)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.quaternary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Custom CSS")
                .accessibilityHint(
                    "CSS applies immediately to open previews. Invalid rules are ignored."
                )
                .accessibilityIdentifier("customCSSEditor")

            HStack {
                Text(customCSS == AppearancePreferences.starterCSS
                    ? "Starter styles are already in use."
                    : "Invalid CSS rules are ignored by the preview.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Restore Starter Styles…") {
                    isRestoreConfirmationPresented = true
                }
                .disabled(customCSS == AppearancePreferences.starterCSS)
                .help(customCSS == AppearancePreferences.starterCSS
                    ? "Starter styles are already in use."
                    : "Replace your custom CSS with the starter styles.")
                .accessibilityIdentifier("restoreCustomCSSButton")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Restore Starter Styles?", isPresented: $isRestoreConfirmationPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Restore", role: .destructive) {
                customCSS = AppearancePreferences.starterCSS
            }
        } message: {
            Text("This replaces your current custom stylesheet.")
        }
    }
}

#Preview {
    AppearanceSettingsView()
        .frame(width: 600, height: 460)
}
#endif

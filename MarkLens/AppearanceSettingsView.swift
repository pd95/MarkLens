import SwiftUI

#if os(macOS)
struct AppearanceSettingsView: View {
    @AppStorage(AppearancePreferences.customCSSKey)
    private var customCSS = AppearancePreferences.starterCSS
    @State private var isRestoreConfirmationPresented = false

    var body: some View {
        Form {
            Section("Custom CSS") {
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
                    .frame(height: 200)
                    .accessibilityLabel("Custom CSS")
                    .accessibilityHint(
                        "CSS applies immediately to open previews. Invalid rules are ignored."
                    )
                    .accessibilityIdentifier("customCSSEditor")

                HStack {
                    Text("Invalid rules are ignored by the preview.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Restore Starter Styles…") {
                        isRestoreConfirmationPresented = true
                    }
                    .disabled(customCSS == AppearancePreferences.starterCSS)
                    .accessibilityIdentifier("restoreCustomCSSButton")
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal)
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
#endif

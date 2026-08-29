import SwiftUI

#if os(macOS)
struct MarkLensSettingsView: View {
    var body: some View {
        TabView {
            AppearanceSettingsView()
                .tabItem {
                    Label("Appearance", systemImage: "paintbrush")
                }

            FolderAccessSettingsView()
                .tabItem {
                    Label("Files & Folders", systemImage: "folder")
                }

            SecuritySettingsView()
                .tabItem {
                    Label("Security & Privacy", systemImage: "lock.shield")
                }

            UpdateSettingsView()
                .tabItem {
                    Label("Updates", systemImage: "arrow.triangle.2.circlepath")
                }
        }
        .frame(width: 600, height: 460)
    }
}

#Preview {
    MarkLensSettingsView()
        .environmentObject(LocalDocumentAccess())
        .environmentObject(UpdateChecker())
}
#endif

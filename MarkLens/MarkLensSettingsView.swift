import SwiftUI

#if os(macOS)
struct MarkLensSettingsView: View {
    var body: some View {
        TabView {
            AppearanceSettingsView()
                .tabItem {
                    Label("Appearance", systemImage: "paintbrush")
                }

            SecuritySettingsView()
                .tabItem {
                    Label("Content & Privacy", systemImage: "lock.shield")
                }

            FolderAccessSettingsView()
                .tabItem {
                    Label("Files & Folders", systemImage: "folder")
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

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

            NavigationSettingsView()
                .tabItem {
                    Label("Navigation", systemImage: "arrow.left.arrow.right")
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
        .frame(width: 680, height: 600)
    }
}

#Preview {
    MarkLensSettingsView()
        .environmentObject(LocalDocumentAccess())
        .environmentObject(UpdateChecker())
}
#endif

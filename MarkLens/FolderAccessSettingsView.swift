import SwiftUI

#if os(macOS)
struct FolderAccessSettingsView: View {
    @EnvironmentObject private var localDocumentAccess: LocalDocumentAccess
    @AppStorage(SecurityPreferences.loadsLocalImagesKey)
    private var loadsLocalImages = true

    var body: some View {
        Form {
            Section("Linked Local Content") {
                Toggle("Show linked images from this Mac", isOn: $loadsLocalImages)
                    .accessibilityIdentifier("loadsLocalImagesToggle")
                Text("Shows supported images linked from the document. MarkLens may ask for access to the document’s folder when an image needs it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Files & Folders") {
                Text("MarkLens uses these folders to open linked documents and show local images.")
                    .foregroundStyle(.secondary)

                if localDocumentAccess.authorizedFolders.isEmpty {
                    ContentUnavailableView(
                        "No Authorized Folders",
                        systemImage: "folder.badge.questionmark",
                        description: Text("Folder access is requested when a local link or image needs it.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    List(localDocumentAccess.authorizedFolders, id: \.self) { folder in
                        HStack {
                            Label(folder.path, systemImage: "folder")
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer()

                            Button("Forget", systemImage: "trash", role: .destructive) {
                                localDocumentAccess.revoke(folder: folder)
                            }
                            .labelStyle(.iconOnly)
                            .help("Forget access to \(folder.lastPathComponent)")
                        }
                    }
                    .frame(minHeight: 140)

                    Button("Forget All Folder Access", role: .destructive) {
                        localDocumentAccess.revokeAll()
                    }
                }
            }

            Section {
                Text("Removing folder access does not remove access to files you opened individually.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 360)
        .padding()
    }
}

#Preview {
    FolderAccessSettingsView()
        .environmentObject(LocalDocumentAccess())
}
#endif

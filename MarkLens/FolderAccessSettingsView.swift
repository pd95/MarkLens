import SwiftUI

#if os(macOS)
struct FolderAccessSettingsView: View {
    private static let linkedImagesExplanation =
        "Shows supported images linked from the document. MarkLens may ask for access to the document’s folder "
        + "when an image needs it."

    @EnvironmentObject private var localDocumentAccess: LocalDocumentAccess
    @AppStorage(SecurityPreferences.loadsLocalImagesKey)
    private var loadsLocalImages = true
    @State private var isForgetAllConfirmationPresented = false

    var body: some View {
        Form {
            Section("Linked Local Content") {
                Toggle("Show linked images from this Mac", isOn: $loadsLocalImages)
                    .accessibilityIdentifier("loadsLocalImagesToggle")
                    .accessibilityHint(Self.linkedImagesExplanation)
                Text(Self.linkedImagesExplanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

            Section("Files & Folders") {
                Text("MarkLens uses these folders to open linked documents and show local images.")
                    .font(.callout)
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
                        isForgetAllConfirmationPresented = true
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
        .padding(.horizontal)
        .alert("Forget All Folder Access?", isPresented: $isForgetAllConfirmationPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Forget All", role: .destructive) {
                localDocumentAccess.revokeAll()
            }
        } message: {
            Text("MarkLens will ask for access again when a linked document or image needs one of these folders.")
        }
    }
}

#Preview {
    FolderAccessSettingsView()
        .frame(width: 600, height: 460)
        .environmentObject(LocalDocumentAccess())
}
#endif

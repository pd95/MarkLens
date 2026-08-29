//
//  MarkLensApp.swift
//  MarkLens
//
//  Created by Philipp on 02.01.2026.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct MarkLensApp: App {
    @StateObject private var localDocumentAccess = LocalDocumentAccess()
#if os(macOS)
    @StateObject private var updateChecker = UpdateChecker()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
#endif
    @FocusedValue(\.printAction) private var printAction
    @FocusedValue(\.exportAction) private var exportAction
    @FocusedValue(\.openInPreviewAction) private var openInPreviewAction
    @FocusedValue(\.pageSetupAction) private var pageSetupAction

    init() {
        AppearancePreferences.registerDefaults()
        SecurityPreferences.registerDefaults()
    }

    var body: some Scene {
        DocumentGroup(
            newDocument: { MarkdownDocument(text: MarkdownDocument.starterText) }
        ) { file in
            ContentView(document: file.document, fileURL: file.fileURL)
                .environmentObject(localDocumentAccess)
#if os(macOS)
                .environmentObject(updateChecker)
                .onAppear {
                    // Make sure the app stops after the last window has been closed
                    appDelegate.exitAfterLastWindow = true
                }
#endif
        }
        .defaultSize(.defaultWindowSize)
#if os(macOS)
        .commands {
            CommandGroup(after: .saveItem) {
                Button {
                    exportAction?.run()
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(exportAction?.isEnabled != true)
            }
            CommandGroup(replacing: .printItem) {
                Button {
                    printAction?.run()
                } label: {
                    Label("Print…", systemImage: "printer")
                }
                .keyboardShortcut("p")
                .disabled(printAction?.isEnabled != true)
            }
            CommandGroup(before: .printItem) {
                Button {
                    openInPreviewAction?.run()
                } label: {
                    Label("Open in Preview", systemImage: "doc.text.magnifyingglass")
                }
                .disabled(openInPreviewAction?.isEnabled != true)

                Button {
                    pageSetupAction?.run()
                } label: {
                    Label("Page Setup…", systemImage: "doc")
                }
                .keyboardShortcut("P", modifiers: [.command, .shift])
                .disabled(pageSetupAction == nil)
            }
            CommandGroup(replacing: .appInfo) {
                Button("About MarkLens") {
                    showAboutPanel()
                }
            }
        }
#endif
#if os(macOS)
        Settings {
            MarkLensSettingsView()
                .environmentObject(localDocumentAccess)
                .environmentObject(updateChecker)
        }
#endif
    }

#if os(macOS)
    private func showAboutPanel() {
        let credits = NSAttributedString(
            string: BuildInfo.releaseDescription,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )

        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "MarkLens",
            .applicationVersion: BuildInfo.displayVersion,
            .credits: credits,
        ])
    }
#endif
}

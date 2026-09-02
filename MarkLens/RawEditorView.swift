//
//  RawEditorView.swift
//  MarkLens
//
//  Created by Philipp on 16.01.2026.
//
import SwiftUI
#if canImport(os)
import os
#endif
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct RawEditorView: View {
    @Binding var text: String
    @Binding var showFind: Bool
    @Binding var scrollPosition: DocumentScrollPosition
    var scrollTarget: DocumentScrollPosition
    var scrollRequest: Int
    var selectionLine: Int?

    @ViewBuilder
    private var standardTextEditor: some View {
        if #available(macOS 26.0, iOS 16.0, *) {
            TextEditor(text: $text)
                .findNavigator(isPresented: $showFind)
        } else {
            TextEditor(text: $text)
        }
    }

    @ViewBuilder
    var body: some View {
        if LargeDocumentEditorPolicy.shouldUseScalableEditor(for: text) {
            LargeDocumentTextEditor(
                text: $text,
                showFind: $showFind,
                scrollPosition: $scrollPosition,
                scrollTarget: scrollTarget,
                scrollRequest: scrollRequest,
                selectionLine: selectionLine
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Markdown source editor")
            .accessibilityTextContentType(.plain)
        } else {
#if os(macOS)
            standardTextEditor
                .background(
                    RawEditorScrollBridge(
                        scrollPosition: $scrollPosition,
                        scrollTarget: scrollTarget,
                        scrollRequest: scrollRequest,
                        selectionLine: selectionLine
                    )
                )
                .font(.system(.body, design: .monospaced))
                .disableAutocorrection(true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Markdown source editor")
                .accessibilityTextContentType(.plain)
#else
            standardTextEditor
                .background(
                    RawEditorScrollBridge(
                        scrollPosition: $scrollPosition,
                        scrollTarget: scrollTarget,
                        scrollRequest: scrollRequest,
                        selectionLine: selectionLine
                    )
                )
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Markdown source editor")
                .accessibilityTextContentType(.plain)
#endif
        }
    }
}

private enum LargeDocumentEditorPolicy {
    static let minimumUTF8ByteCount = 1_048_576

    static func shouldUseScalableEditor(for text: String) -> Bool {
        text.utf8.count >= minimumUTF8ByteCount
    }
}

#if os(macOS)
@MainActor
private func focusEditor(_ textView: NSTextView) {
    guard textView.window?.firstResponder !== textView else { return }
    if let window = textView.window {
        window.makeFirstResponder(textView)
    } else {
        DispatchQueue.main.async { [weak textView] in
            guard let textView else { return }
            textView.window?.makeFirstResponder(textView)
        }
    }
}
#else
@MainActor
private func focusEditor(_ textView: UITextView) {
    guard textView.isFirstResponder == false else { return }
    if textView.becomeFirstResponder() == false {
        DispatchQueue.main.async { [weak textView] in
            textView?.becomeFirstResponder()
        }
    }
}
#endif

#if os(macOS)
private struct LargeDocumentTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var showFind: Bool
    @Binding var scrollPosition: DocumentScrollPosition
    var scrollTarget: DocumentScrollPosition
    var scrollRequest: Int
    var selectionLine: Int?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        RawEditorPerformanceInstrumentation.measure("LargeRawEditorMakeView") {
            let scrollView = NSTextView.scrollableTextView()
            guard let textView = scrollView.documentView as? NSTextView else {
                return scrollView
            }

            textView.isRichText = false
            textView.importsGraphics = false
            textView.allowsUndo = true
            textView.usesFindBar = true
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.isAutomaticTextReplacementEnabled = false
            textView.isAutomaticSpellingCorrectionEnabled = false
            textView.isContinuousSpellCheckingEnabled = false
            textView.isGrammarCheckingEnabled = false
            textView.font = NSFont.monospacedSystemFont(
                ofSize: NSFont.systemFontSize,
                weight: .regular
            )
            textView.layoutManager?.allowsNonContiguousLayout = true

            context.coordinator.connect(textView: textView, scrollView: scrollView)
            context.coordinator.replaceTextIfNeeded(with: text)
            return scrollView
        }
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.replaceTextIfNeeded(with: text)
        context.coordinator.presentFindInterfaceIfNeeded()
        context.coordinator.applyTargetIfNeeded()
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.disconnect()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: LargeDocumentTextEditor
        private weak var textView: NSTextView?
        private weak var scrollView: NSScrollView?
        private var boundsObserver: NSObjectProtocol?
        private var lineIndex: SourceLineIndex?
        private var lineIndexGeneration = 0
        private var lineIndexTask: Task<Void, Never>?
        private var appliedRequest = -1
        private var lastBindingText: String?
        private var lastShowFind = false
        private var reportScheduled = false

        init(parent: LargeDocumentTextEditor) {
            self.parent = parent
        }

        func connect(textView: NSTextView, scrollView: NSScrollView) {
            self.textView = textView
            self.scrollView = scrollView
            textView.delegate = self
            scrollView.contentView.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.schedulePositionReport()
                }
            }
        }

        func disconnect() {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
            boundsObserver = nil
            textView?.delegate = nil
            textView = nil
            scrollView = nil
            lineIndexTask?.cancel()
            lineIndexTask = nil
            lineIndexGeneration += 1
        }

        func replaceTextIfNeeded(with text: String) {
            guard lastBindingText != text, let textView else { return }
            RawEditorPerformanceInstrumentation.measure("LargeRawEditorSetText") {
                textView.string = text
            }
            lastBindingText = text
            rebuildLineIndex(for: text)
        }

        func rebuildLineIndex(for text: String, debounce: Bool = false) {
            lineIndexGeneration += 1
            let generation = lineIndexGeneration
            lineIndexTask?.cancel()
            lineIndexTask = Task { [weak self] in
                if debounce {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    guard Task.isCancelled == false else { return }
                }
                let work = Task.detached(priority: .userInitiated) {
                    RawEditorPerformanceInstrumentation.measure("LargeRawEditorLineIndex") {
                        SourceLineIndex(text: text)
                    }
                }
                let index = await work.value
                guard Task.isCancelled == false,
                      let self,
                      self.lineIndexGeneration == generation else { return }
                self.lineIndex = index
                self.applyTargetIfNeeded()
                self.reportPosition()
            }
        }

        func presentFindInterfaceIfNeeded() {
            guard parent.showFind != lastShowFind, let textView else { return }
            lastShowFind = parent.showFind
            let sender = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
            sender.tag = parent.showFind
                ? NSTextFinder.Action.showFindInterface.rawValue
                : NSTextFinder.Action.hideFindInterface.rawValue
            textView.performTextFinderAction(sender)
        }

        func applyTargetIfNeeded() {
            guard appliedRequest != parent.scrollRequest,
                  let textView,
                  let lineIndex else { return }
            appliedRequest = parent.scrollRequest
            focusEditor(textView)
            RawEditorPerformanceInstrumentation.measure("LargeRawEditorApplyTarget") {
                if let line = parent.selectionLine {
                    let character = lineIndex.characterOffset(forLine: line)
                    textView.setSelectedRange(NSRange(location: character, length: 0))
                }
                if let line = parent.scrollTarget.sourceLine {
                    let character = lineIndex.characterOffset(forLine: line)
                    let range = NSRange(location: character, length: 0)
                    textView.scrollRangeToVisible(range)
                } else {
                    let character = lineIndex.characterOffset(
                        forProgress: parent.scrollTarget.progress
                    )
                    textView.scrollRangeToVisible(NSRange(location: character, length: 0))
                }
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            let updatedText = textView.string
            lastBindingText = updatedText
            parent.text = updatedText
            rebuildLineIndex(for: updatedText, debounce: true)
            schedulePositionReport()
        }

        private func schedulePositionReport() {
            guard reportScheduled == false else { return }
            reportScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { return }
                self.reportScheduled = false
                self.reportPosition()
            }
        }

        private func reportPosition() {
            guard let textView, let lineIndex else { return }
            RawEditorPerformanceInstrumentation.measure("LargeRawEditorReportPosition") {
                let topInset = max(
                    0,
                    textView.safeAreaRect.minY - textView.visibleRect.minY
                )
                let point = NSPoint(
                    x: textView.textContainerOrigin.x,
                    y: textView.visibleRect.minY + topInset
                )
                let character = textView.characterIndexForInsertion(at: point)
                parent.scrollPosition = DocumentScrollPosition(
                    sourceLine: lineIndex.lineNumber(at: character),
                    progress: lineIndex.progress(at: character)
                )
            }
        }
    }
}
#endif

#if os(iOS)
private struct LargeDocumentTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var showFind: Bool
    @Binding var scrollPosition: DocumentScrollPosition
    var scrollTarget: DocumentScrollPosition
    var scrollRequest: Int
    var selectionLine: Int?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UITextView {
        RawEditorPerformanceInstrumentation.measure("LargeRawEditorMakeView") {
            let textView = UITextView(frame: .zero)
            textView.font = UIFont.monospacedSystemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize,
                weight: .regular
            )
            textView.adjustsFontForContentSizeCategory = true
            textView.autocapitalizationType = .none
            textView.autocorrectionType = .no
            textView.smartDashesType = .no
            textView.smartQuotesType = .no
            textView.smartInsertDeleteType = .no
            textView.spellCheckingType = .no
            textView.alwaysBounceVertical = true
            textView.keyboardDismissMode = .interactive
            textView.layoutManager.allowsNonContiguousLayout = true
            if #available(iOS 16.0, *) {
                textView.isFindInteractionEnabled = true
            }

            context.coordinator.connect(textView: textView)
            context.coordinator.replaceTextIfNeeded(with: text)
            return textView
        }
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.replaceTextIfNeeded(with: text)
        context.coordinator.presentFindInterfaceIfNeeded()
        context.coordinator.applyTargetIfNeeded()
    }

    static func dismantleUIView(_ textView: UITextView, coordinator: Coordinator) {
        coordinator.disconnect()
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: LargeDocumentTextEditor
        private weak var textView: UITextView?
        private var lineIndex: SourceLineIndex?
        private var lineIndexGeneration = 0
        private var lineIndexTask: Task<Void, Never>?
        private var appliedRequest = -1
        private var lastBindingText: String?
        private var reportScheduled = false

        init(parent: LargeDocumentTextEditor) {
            self.parent = parent
        }

        func connect(textView: UITextView) {
            self.textView = textView
            textView.delegate = self
        }

        func disconnect() {
            textView?.delegate = nil
            textView = nil
            lineIndex = nil
            lineIndexTask?.cancel()
            lineIndexTask = nil
            lineIndexGeneration += 1
        }

        func replaceTextIfNeeded(with text: String) {
            guard lastBindingText != text, let textView else { return }
            RawEditorPerformanceInstrumentation.measure("LargeRawEditorSetText") {
                textView.text = text
            }
            lastBindingText = text
            rebuildLineIndex(for: text)
        }

        private func rebuildLineIndex(for text: String, debounce: Bool = false) {
            lineIndexGeneration += 1
            let generation = lineIndexGeneration
            lineIndexTask?.cancel()
            lineIndexTask = Task { [weak self] in
                if debounce {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    guard Task.isCancelled == false else { return }
                }
                let work = Task.detached(priority: .userInitiated) {
                    RawEditorPerformanceInstrumentation.measure("LargeRawEditorLineIndex") {
                        SourceLineIndex(text: text)
                    }
                }
                let index = await work.value
                guard Task.isCancelled == false,
                      let self,
                      self.lineIndexGeneration == generation else { return }
                self.lineIndex = index
                self.applyTargetIfNeeded()
                self.reportPosition()
            }
        }

        func presentFindInterfaceIfNeeded() {
            guard #available(iOS 16.0, *), let interaction = textView?.findInteraction else {
                return
            }
            if parent.showFind, interaction.isFindNavigatorVisible == false {
                interaction.presentFindNavigator(showingReplace: false)
            } else if parent.showFind == false, interaction.isFindNavigatorVisible {
                interaction.dismissFindNavigator()
            }
        }

        func applyTargetIfNeeded() {
            guard appliedRequest != parent.scrollRequest,
                  let textView,
                  let lineIndex else { return }
            appliedRequest = parent.scrollRequest
            focusEditor(textView)
            if let line = parent.selectionLine {
                let character = lineIndex.characterOffset(forLine: line)
                textView.selectedRange = NSRange(location: character, length: 0)
            }
            let character: Int
            if let line = parent.scrollTarget.sourceLine {
                character = lineIndex.characterOffset(forLine: line)
            } else {
                character = lineIndex.characterOffset(forProgress: parent.scrollTarget.progress)
            }
            let range = NSRange(location: character, length: 0)
            textView.scrollRangeToVisible(range)
        }

        func textViewDidChange(_ textView: UITextView) {
            let updatedText = textView.text ?? ""
            lastBindingText = updatedText
            parent.text = updatedText
            rebuildLineIndex(for: updatedText, debounce: true)
            schedulePositionReport()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            schedulePositionReport()
        }

        private func schedulePositionReport() {
            guard reportScheduled == false else { return }
            reportScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { return }
                self.reportScheduled = false
                self.reportPosition()
            }
        }

        private func reportPosition() {
            guard let textView, let lineIndex else { return }
            let visiblePoint = CGPoint(
                x: textView.contentOffset.x - textView.textContainerInset.left,
                y: textView.contentOffset.y + textView.adjustedContentInset.top
                    - textView.textContainerInset.top
            )
            let character = textView.layoutManager.characterIndex(
                for: visiblePoint,
                in: textView.textContainer,
                fractionOfDistanceBetweenInsertionPoints: nil
            )
            parent.scrollPosition = DocumentScrollPosition(
                sourceLine: lineIndex.lineNumber(at: character),
                progress: lineIndex.progress(at: character)
            )
        }
    }
}
#endif

#if os(macOS)
private struct RawEditorScrollBridge: NSViewRepresentable {
    @Binding var scrollPosition: DocumentScrollPosition
    var scrollTarget: DocumentScrollPosition
    var scrollRequest: Int
    var selectionLine: Int?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.parent = self
        DispatchQueue.main.async { context.coordinator.connect(from: view) }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.disconnect()
    }

    @MainActor
    final class Coordinator {
        var parent: RawEditorScrollBridge
        weak var textView: NSTextView?
        private var boundsObserver: NSObjectProtocol?
        private var textObserver: NSObjectProtocol?
        private var appliedRequest = -1
        private var connectionAttempts = 0
        private var lineIndex: SourceLineIndex?
        private var lineIndexGeneration = 0
        private var lineIndexTask: Task<Void, Never>?

        init(parent: RawEditorScrollBridge) { self.parent = parent }

        func connect(from marker: NSView) {
            RawEditorPerformanceInstrumentation.measure("RawEditorBridgeConnect") {
                connectAndRestore(from: marker)
            }
        }

        private func connectAndRestore(from marker: NSView) {
            if textView == nil {
                textView = enclosingTextView(from: marker)
                if let textView {
                    RawEditorPerformanceInstrumentation.event(
                        "RawEditorConnected",
                        value: textView.string.utf8.count
                    )
                    rebuildLineIndex(for: textView.string)
                }
                observeScrolling()
                observeTextChanges()
                if textView == nil, connectionAttempts < 5 {
                    connectionAttempts += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak marker] in
                        guard let self, let marker else { return }
                        self.connect(from: marker)
                    }
                    return
                }
            }
            applyTargetIfNeeded()
            reportPosition()
        }

        func disconnect() {
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
            if let textObserver { NotificationCenter.default.removeObserver(textObserver) }
            boundsObserver = nil
            textObserver = nil
            textView = nil
            lineIndex = nil
            lineIndexTask?.cancel()
            lineIndexTask = nil
            lineIndexGeneration += 1
        }

        private func enclosingTextView(from marker: NSView) -> NSTextView? {
            var ancestor = marker.superview
            while let view = ancestor {
                if let textView = firstTextView(in: view) { return textView }
                ancestor = view.superview
            }
            return nil
        }

        private func firstTextView(in view: NSView) -> NSTextView? {
            if let textView = view as? NSTextView { return textView }
            for child in view.subviews {
                if let result = firstTextView(in: child) { return result }
            }
            return nil
        }

        private func observeScrolling() {
            guard let clipView = textView?.enclosingScrollView?.contentView else { return }
            clipView.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.reportPosition()
                }
            }
        }

        private func observeTextChanges() {
            guard let textView else { return }
            textObserver = NotificationCenter.default.addObserver(
                forName: NSText.didChangeNotification,
                object: textView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let textView = self.textView else { return }
                    self.rebuildLineIndex(for: textView.string, debounce: true)
                }
            }
        }

        private func rebuildLineIndex(for text: String, debounce: Bool = false) {
            lineIndexGeneration += 1
            let generation = lineIndexGeneration
            lineIndexTask?.cancel()
            lineIndexTask = Task { [weak self] in
                if debounce {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    guard Task.isCancelled == false else { return }
                }
                let work = Task.detached(priority: .utility) {
                    RawEditorPerformanceInstrumentation.measure("RawEditorLineIndex") {
                        SourceLineIndex(text: text)
                    }
                }
                let index = await work.value
                guard Task.isCancelled == false,
                      let self,
                      self.lineIndexGeneration == generation else { return }
                self.lineIndex = index
                self.applyTargetIfNeeded()
                self.reportPosition()
            }
        }

        private func applyTargetIfNeeded() {
            guard appliedRequest != parent.scrollRequest,
                  let textView,
                  let lineIndex else { return }
            appliedRequest = parent.scrollRequest
            focusEditor(textView)
            if let line = parent.selectionLine {
                let character = lineIndex.characterOffset(forLine: line)
                textView.setSelectedRange(NSRange(location: character, length: 0))
            }
            if let line = parent.scrollTarget.sourceLine,
               let layoutManager = textView.layoutManager,
               let textContainer = textView.textContainer {
                let character = lineIndex.characterOffset(forLine: line)
                let glyphCount = RawEditorPerformanceInstrumentation.measure("RawEditorGlyphCount") {
                    layoutManager.numberOfGlyphs
                }
                if glyphCount > 0 {
                    let glyph = layoutManager.glyphIndexForCharacter(
                        at: min(character, max(0, textView.string.utf16.count - 1))
                    )
                    let rect = RawEditorPerformanceInstrumentation.measure("RawEditorGlyphRect") {
                        layoutManager.boundingRect(
                            forGlyphRange: NSRange(location: glyph, length: 1),
                            in: textContainer
                        )
                    }
                    if let scrollView = textView.enclosingScrollView {
                        let clipView = scrollView.contentView
                        let targetY = rect.minY + textView.textContainerOrigin.y
                            - unobscuredTopInset(in: textView)
                        clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: targetY))
                        scrollView.reflectScrolledClipView(clipView)
                        return
                    }
                }
            }
            if let scrollView = textView.enclosingScrollView {
                let clipView = scrollView.contentView
                let maximum = max(0, textView.bounds.height - scrollView.documentVisibleRect.height)
                clipView.scroll(
                    to: NSPoint(
                        x: clipView.bounds.minX,
                        y: maximum * parent.scrollTarget.progress
                    )
                )
                scrollView.reflectScrolledClipView(clipView)
            }
        }

        private func reportPosition() {
            RawEditorPerformanceInstrumentation.measure("RawEditorReportPosition") {
                reportCurrentPosition()
            }
        }

        private func reportCurrentPosition() {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer,
                  let lineIndex else { return }
            var unobscuredRect = textView.visibleRect
            let topInset = unobscuredTopInset(in: textView)
            unobscuredRect.origin.y += topInset
            unobscuredRect.size.height = max(0, unobscuredRect.height - topInset)
            unobscuredRect.origin.x -= textView.textContainerOrigin.x
            unobscuredRect.origin.y -= textView.textContainerOrigin.y
            let glyphRange = layoutManager.glyphRange(
                forBoundingRect: unobscuredRect,
                in: textContainer
            )
            let character = glyphRange.location < layoutManager.numberOfGlyphs
                ? layoutManager.characterIndexForGlyph(at: glyphRange.location)
                : textView.string.utf16.count
            let maximum = max(0, textView.bounds.height - textView.visibleRect.height)
            let progress = maximum == 0 ? 0 : textView.visibleRect.minY / maximum
            let position = DocumentScrollPosition(
                sourceLine: lineIndex.lineNumber(at: character),
                progress: min(max(progress, 0), 1)
            )
            parent.scrollPosition = position
        }

        private func unobscuredTopInset(in textView: NSTextView) -> CGFloat {
            let safeAreaInset = max(0, textView.safeAreaRect.minY - textView.visibleRect.minY)
            let scrollInset = textView.enclosingScrollView?.contentInsets.top ?? 0
            return max(safeAreaInset, scrollInset)
        }
    }
}
#else
private struct RawEditorScrollBridge: UIViewRepresentable {
    @Binding var scrollPosition: DocumentScrollPosition
    var scrollTarget: DocumentScrollPosition
    var scrollRequest: Int
    var selectionLine: Int?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIView(context: Context) -> UIView { UIView(frame: .zero) }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
        DispatchQueue.main.async { context.coordinator.connect(from: view) }
    }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.disconnect()
    }

    @MainActor
    final class Coordinator {
        var parent: RawEditorScrollBridge
        weak var textView: UITextView?
        private var offsetObservation: NSKeyValueObservation?
        private var textObserver: NSObjectProtocol?
        private var appliedRequest = -1
        private var connectionAttempts = 0
        private var lineIndex: SourceLineIndex?
        private var lineIndexGeneration = 0
        private var lineIndexTask: Task<Void, Never>?

        init(parent: RawEditorScrollBridge) { self.parent = parent }

        func connect(from marker: UIView) {
            if textView == nil {
                textView = enclosingTextView(from: marker)
                if let textView {
                    rebuildLineIndex(for: textView.text)
                }
                offsetObservation = textView?.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                    Task { @MainActor [weak self] in
                        self?.reportPosition()
                    }
                }
                observeTextChanges()
                if textView == nil, connectionAttempts < 5 {
                    connectionAttempts += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak marker] in
                        guard let self, let marker else { return }
                        self.connect(from: marker)
                    }
                    return
                }
            }
            applyTargetIfNeeded()
            reportPosition()
        }

        func disconnect() {
            offsetObservation?.invalidate()
            if let textObserver { NotificationCenter.default.removeObserver(textObserver) }
            offsetObservation = nil
            textObserver = nil
            textView = nil
            lineIndex = nil
            lineIndexTask?.cancel()
            lineIndexTask = nil
            lineIndexGeneration += 1
        }

        private func enclosingTextView(from marker: UIView) -> UITextView? {
            var ancestor = marker.superview
            while let view = ancestor {
                if let textView = firstTextView(in: view) { return textView }
                ancestor = view.superview
            }
            return nil
        }

        private func firstTextView(in view: UIView) -> UITextView? {
            if let textView = view as? UITextView { return textView }
            for child in view.subviews {
                if let result = firstTextView(in: child) { return result }
            }
            return nil
        }

        private func observeTextChanges() {
            guard let textView else { return }
            textObserver = NotificationCenter.default.addObserver(
                forName: UITextView.textDidChangeNotification,
                object: textView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let textView = self.textView else { return }
                    self.rebuildLineIndex(for: textView.text, debounce: true)
                }
            }
        }

        private func rebuildLineIndex(for text: String, debounce: Bool = false) {
            lineIndexGeneration += 1
            let generation = lineIndexGeneration
            lineIndexTask?.cancel()
            lineIndexTask = Task { [weak self] in
                if debounce {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    guard Task.isCancelled == false else { return }
                }
                let work = Task.detached(priority: .utility) {
                    SourceLineIndex(text: text)
                }
                let index = await work.value
                guard Task.isCancelled == false,
                      let self,
                      self.lineIndexGeneration == generation else { return }
                self.lineIndex = index
                self.applyTargetIfNeeded()
                self.reportPosition()
            }
        }

        private func applyTargetIfNeeded() {
            guard appliedRequest != parent.scrollRequest,
                  let textView,
                  let lineIndex else { return }
            appliedRequest = parent.scrollRequest
            focusEditor(textView)
            if let line = parent.selectionLine {
                let character = lineIndex.characterOffset(forLine: line)
                textView.selectedRange = NSRange(location: character, length: 0)
            }
            if let line = parent.scrollTarget.sourceLine,
               textView.layoutManager.numberOfGlyphs > 0 {
                let character = lineIndex.characterOffset(forLine: line)
                let glyph = textView.layoutManager.glyphIndexForCharacter(
                    at: min(character, max(0, (textView.text as NSString).length - 1))
                )
                let rect = textView.layoutManager.boundingRect(
                    forGlyphRange: NSRange(location: glyph, length: 1),
                    in: textView.textContainer
                )
                let maximum = max(
                    -textView.adjustedContentInset.top,
                    textView.contentSize.height - textView.bounds.height
                        + textView.adjustedContentInset.bottom
                )
                let y = min(
                    max(
                        rect.minY + textView.textContainerInset.top
                            - textView.adjustedContentInset.top,
                        -textView.adjustedContentInset.top
                    ),
                    maximum
                )
                textView.setContentOffset(
                    CGPoint(x: textView.contentOffset.x, y: y),
                    animated: false
                )
            } else {
                let maximum = max(0, textView.contentSize.height - textView.bounds.height)
                textView.setContentOffset(
                    CGPoint(x: textView.contentOffset.x, y: maximum * parent.scrollTarget.progress),
                    animated: false
                )
            }
        }

        private func reportPosition() {
            guard let textView, let lineIndex else { return }
            var visibleRect = CGRect(origin: textView.contentOffset, size: textView.bounds.size)
            visibleRect.origin.y += textView.adjustedContentInset.top
            visibleRect.size.height = max(
                0,
                visibleRect.height - textView.adjustedContentInset.top
                    - textView.adjustedContentInset.bottom
            )
            visibleRect.origin.x -= textView.textContainerInset.left
            visibleRect.origin.y -= textView.textContainerInset.top
            let glyphRange = textView.layoutManager.glyphRange(
                forBoundingRect: visibleRect,
                in: textView.textContainer
            )
            let character = glyphRange.location < textView.layoutManager.numberOfGlyphs
                ? textView.layoutManager.characterIndexForGlyph(at: glyphRange.location)
                : (textView.text as NSString).length
            let maximum = max(0, textView.contentSize.height - textView.bounds.height)
            let progress = maximum == 0 ? 0 : max(0, textView.contentOffset.y) / maximum
            let position = DocumentScrollPosition(
                sourceLine: lineIndex.lineNumber(at: character),
                progress: min(max(progress, 0), 1)
            )
            parent.scrollPosition = position
        }
    }
}
#endif

struct SourceLineIndex: Sendable {
    private let lineStarts: [Int]
    private let textLength: Int

    nonisolated init(text: String) {
        var starts = [0]
        starts.reserveCapacity(max(1, text.utf8.count / 80))
        var offset = 0
        for codeUnit in text.utf16 {
            offset += 1
            if codeUnit == 10 {
                starts.append(offset)
            }
        }
        lineStarts = starts
        textLength = offset
    }

    func characterOffset(forLine requestedLine: Int) -> Int {
        let index = min(max(0, requestedLine - 1), lineStarts.count - 1)
        return lineStarts[index]
    }

    func lineNumber(at character: Int) -> Int {
        let target = min(max(0, character), textLength)
        var lowerBound = 0
        var upperBound = lineStarts.count
        while lowerBound < upperBound {
            let midpoint = lowerBound + (upperBound - lowerBound) / 2
            if lineStarts[midpoint] <= target {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        return max(1, lowerBound)
    }

    func characterOffset(forProgress progress: Double) -> Int {
        guard progress.isFinite else { return 0 }
        return Int(Double(textLength) * min(max(progress, 0), 1))
    }

    func progress(at character: Int) -> Double {
        guard textLength > 0 else { return 0 }
        return Double(min(max(character, 0), textLength)) / Double(textLength)
    }
}

enum RawEditorPerformanceInstrumentation {
#if canImport(os)
    nonisolated private static let log = OSLog(
        subsystem: "ch.doapp.MarkLens",
        category: "RawEditor"
    )
#endif

    nonisolated static func event(_ name: StaticString, value: Int) {
#if canImport(os)
        os_signpost(.event, log: log, name: name, "%{public}d", value)
#endif
    }

    nonisolated static func measure<Result>(
        _ name: StaticString,
        operation: () -> Result
    ) -> Result {
#if canImport(os)
        let signpostID = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: signpostID)
        defer {
            os_signpost(.end, log: log, name: name, signpostID: signpostID)
        }
#endif
        return operation()
    }
}

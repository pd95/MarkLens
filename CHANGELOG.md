# Changelog

## 1.6.0

- Improved reliability and responsiveness for very large Markdown documents by limiting syntax-highlighting work, virtualizing code-heavy previews, and using scalable native source editors on macOS and iOS.
- Added polished controls for oversized code blocks, including collapsed previews, line-count reveal controls, persistent collapse actions, and accessible copy feedback.
- Reduced preview work while scrolling and preserved source positions when switching between rendered and editing modes.
- Fixed preview navigation state on iOS and resolved Swift concurrency warnings exposed by clean cross-platform builds.

## 1.5.4

- Improved automatic external-file refreshes by updating append-only files promptly, waiting for rewritten files to settle, and bounding refresh delays for continuously changing content.

## 1.5.3

- Improved automatic external-file refreshes by preserving the current reading position across rendered-content changes and smoothly crossfading updates to avoid flicker.

## 1.5.2

- Improved rendered-preview search by refocusing the find field with Command-F, using selected text as the query, and supporting Return, Command-G, and Shift-Command-G result navigation.

## 1.5.1

- Added automatic refresh for open documents changed or atomically replaced by another application, while preserving active source edits when changes conflict.
- Restored standard Markdown line-break behavior so ordinary newlines remain soft breaks and only trailing spaces or a backslash create visible hard breaks.

## 1.5.0

- Added an opt-in update setting for receiving GitHub pre-release builds and release candidates.
- Added native PDF and portable HTML export, an Open in Preview command, remembered export formats, and self-contained Mermaid and local-image output.
- Improved printed-document pagination by keeping headings with following content, preventing orphaned code-block borders, and wrapping long code lines for paper output.
- Enabled new Markdown documents with an editable starter, native untitled-document behavior, and links to the CommonMark and GitHub Flavored Markdown references.
- Renamed the GitHub repository to MarkLens and corrected the app, Quick Look extension, and test bundle identifiers to use the `ch.doapp` namespace.
- Fixed unsupported Highlight.js languages on macOS and resolved Swift concurrency warnings ahead of Swift 6 migration.

> [!IMPORTANT]
> The bundle identifier changed from `com.doapp.MarkLens` to `ch.doapp.MarkLens`. Existing users may need to reauthorize local folders and select MarkLens again as their default Markdown application.

## 1.4.0

- Added non-intrusive update notifications that check GitHub Releases weekly and provide direct access to the latest release from the toolbar.
- Added synchronized scroll positioning between the rendered preview and raw Markdown editor when switching modes.
- Improved web dependency maintenance with reproducible updates, automated verification, and CI auditing for bundled rendering libraries.

## 1.3.0

- Added LaTeX math rendering with KaTeX.
- Added Mermaid diagram rendering for fenced code blocks.
- Added appearance settings for custom preview styles, including font family, font size, line height, content width, and custom CSS.
- Improved preview typography scaling so custom font sizes apply consistently throughout rendered documents.

## 1.2.0

- Added support for local Markdown links and linked images, resolved relative to the current document.
- Added privacy-focused folder access prompts with persistent permissions that can be managed in Settings.
- Added wiki-style links using `[[note]]`, `[[folder/note]]`, and `[[note|Display text]]` syntax.
- Added recursive wiki-page discovery within a selected folder, including a searchable chooser for duplicate names.
- Added in-place wiki browsing with Back and Forward navigation while keeping linked pages read-only.

## 1.1.0

- Renamed the app from MarkdownPreview to MarkLens.
- Added automated Xcode Cloud release builds.
- Added Developer ID notarization for direct downloads.
- Added GitHub Release uploads for release candidate and final tags.
- Added release tag and commit metadata to the About panel.

## 1.0.6

- Added search in the rendered Markdown preview and raw editor.
- Open Markdown links in the browser.
- Improved rendering performance.
- Fixed bugs in Markdown preview and editing workflows.

## 1.0.5

- Added support for embedded images using `data:image` URLs.

## 1.0.4

- Added printing and page setup support, including macOS PDF generation through the print workflow.
- Added syntax-highlighted Markdown rendering through the shared Markdown pipeline.
- Added copy buttons for rendered code blocks.
- Added raw Markdown editing inside the app.
- Improved Quick Look preview rendering and shared app/extension resources.

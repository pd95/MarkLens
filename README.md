# MarkLens

View Markdown documents on iOS and macOS, with a Quick Look extension for fast previews in Finder.

## Features

- GitHub Flavored Markdown rendering with syntax highlighting and copy buttons for code blocks.
- LaTeX math rendering with KaTeX and Mermaid diagram rendering for fenced code blocks.
- Raw Markdown editing with toolbar shortcuts, search, and synchronized preview/source scrolling.
- Local links and images, source-line links, plus wiki-style links and in-app wiki navigation on macOS.
- Native macOS document tabs, with Command-click or a link’s context menu to open a local Markdown file in a new tab.
- Remembered macOS document window size and position for each file, with the last window placement used for new files.
- Browse local Markdown and wiki links in the current window, with a per-file toggle and a configurable default in Files & Folders settings.
- Choose whether linked documents follow macOS window preferences or open in a new window or tab by default.
- Customizable preview typography, content width, and CSS on macOS.
- PDF and portable HTML export bundling app resources and local images on macOS, plus direct paginated review in Preview; remote content remains linked.
- Printing and page setup on macOS.
- Quick Look previews in Finder.

## Source-line links on macOS

Use a line number after a local Markdown filename to open that file at its source line:

```markdown
[Details](notes.md:12)
[Nested file](folder/notes.md:27)
```

Blank source lines lead to the next rendered content; a line after the last content leads to the end of the page. Other apps can use `marklens://open?file=<encoded-file-URL>&line=12` to open an absolute local Markdown file at a line.

For a ready-made manual check, open [line-link-source.md](MarkLensUITests/Fixtures/line-link-source.md) in MarkLens and follow its links to the adjacent target file.

## Requirements

Development requires Xcode 26 running on a compatible version of macOS.

MarkLens supports:

- macOS 15.6 or later
- iOS 17.6 or later

## Build

Open the project:

```sh
open MarkLens.xcodeproj
```

Build the app from the command line:

```sh
xcodebuild -project MarkLens.xcodeproj -scheme MarkLens -configuration Debug build
```

Build the Quick Look extension:

```sh
xcodebuild -project MarkLens.xcodeproj -scheme QuickLookPreview_macOS -configuration Debug build
```

## Test

Run the Markdown pipeline tests on any supported Swift development platform:

```sh
swift test --package-path MarkdownPipeline
```

Run the app unit and UI tests on macOS:

```sh
xcodebuild -project MarkLens.xcodeproj -scheme MarkLens -destination 'platform=macOS' test
```

## Project Layout

- `MarkLens/` contains the SwiftUI app and app-specific web resources.
- `QuickLookPreview_macOS/` contains the macOS Quick Look extension.
- `MarkdownPipeline/` contains the shared Markdown renderer, bundled web assets, and pipeline tests.
- `Shared/` contains Swift code shared by the app and extension.
- `MarkLensTests/` and `MarkLensUITests/` contain app integration and UI tests.

## Future Tasks

- Consider adding a custom print panel accessory for header/footer toggles and margin presets.

## License

MIT. See `LICENSE`.

## Third-Party Notices

See `THIRD_PARTY_NOTICES`.

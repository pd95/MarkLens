# MarkLens

View Markdown documents on iOS and macOS, with a Quick Look extension for fast previews in Finder.

## Features

- GitHub Flavored Markdown rendering with syntax highlighting and copy buttons for code blocks.
- LaTeX math rendering with KaTeX and Mermaid diagram rendering for fenced code blocks.
- Raw Markdown editing with toolbar shortcuts, search, and synchronized preview/source scrolling.
- Local links and images, source-line links, plus wiki-style links and in-app wiki navigation on macOS.
- Native macOS document tabs, with Command-click or a link’s context menu to open a local Markdown file in a new tab.
- Click local links to navigate to Markdown documents. For other local files on macOS, choose Quick Look, Reveal in Finder, or Open in Default App in Navigation settings, with separate actions for click and Command-click. Folder links always reveal in Finder.
- Peek at local targets with Quick Look from a link’s context menu, including Markdown documents and resolved wiki links. If needed, authorize just the target item.
- Hover over a link to see its destination and click action at the bottom of the preview, including Command-click behavior. Local paths are relative to the current document’s folder.
- macOS remembers each document’s window size and position; new files use the default placement.
- Browse local Markdown and wiki links in the current window, with a per-file toggle and a configurable default in Navigation settings.
- Choose whether linked documents follow macOS window preferences or open in a new window or tab by default.
- Customizable preview typography, content width, and CSS on macOS.
- PDF and portable HTML export bundling app resources and local images on macOS, plus direct paginated review in Preview; remote content remains linked.
- Printing and page setup on macOS.
- Quick Look previews in Finder.
- In-app macOS updates with weekly checks, Stable and Preview channels, cumulative release notes, and optional automatic installation.

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

## Publishing macOS updates

The release workflow uses the original Xcode Cloud publishing script. Keep its
**Notarize – macOS** post-action enabled and Archive deployment preparation set
to **None / Ohne**. Xcode Cloud supplies the Developer ID export; the post-build
script packages it and uploads the ZIP to GitHub using `GITHUB_RELEASE_TOKEN`.
It does not perform a second export or submit a notarization request itself.

The app includes Sparkle, but automatic Sparkle feed publication is paused while
we verify the existing release artifacts. The original uploader does not generate
or update `updates/appcast.xml`. Until we publish a signed feed entry, the new
updater will have no update to offer. Do not advertise an update before its
archive is ready for installation.

Keep `SPARKLE_PUBLIC_ED_KEY` enabled for the Release workflow so the pre-build
script embeds the update verification key in the app. Keep the Sparkle private
key backed up securely for subsequent manual update signing. The original Cloud
uploader does not use `SPARKLE_PRIVATE_KEY` or `APP_STORE_CONNECT_API_*`; these
credentials are not required for its signing, notarization, or upload steps.

The existing `gh-pages` branch and Pages configuration can remain in place. The
feed bootstrap helper is available if needed, but does not publish a release.

### Acceptance before 1.10.0

Install a first signed, notarized release candidate manually, then update it to
another candidate through Sparkle. Verify cumulative notes, Stable/Preview
selection, manual checks with automatic checks disabled, skipping and retrying,
network failure, archive-signature rejection, and opt-in automatic installation.
Test relaunch with saved and unsaved documents, including cancelling a save
prompt; confirm document contents, preferences, and Finder Quick Look afterward.
For an isolated integration run, build Debug with a temporary test public key in
`SPARKLE_PUBLIC_ED_KEY`, then set the launch environment variable
`MARKLENS_UPDATE_TEST_FEED_URL` to your test feed's HTTPS URL. That override is
compiled out of Release builds. Use an isolated account/app copy for installation
and corrupted-archive checks; never point production users at the test feed. Capture the native
update window and Updates settings for release review.

Existing users install their first Sparkle-enabled version manually using the
existing GitHub download. Subsequent releases install within MarkLens.

Run release automation checks without uploading anything:

```sh
bash ci_scripts/tests/test_ci_pre_xcodebuild.sh
bash ci_scripts/tests/test_ci_post_xcodebuild.sh
```

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

Xcode Cloud's **Release (macOS)** workflow archives and notarizes the app.
Keep its **Notarize – macOS** post-action enabled, deployment preparation set to
**None / Ohne**, and `SPARKLE_PUBLIC_ED_KEY` enabled. It no longer uploads an
unfinished ZIP to GitHub. Wait for the entire workflow to succeed before publishing.

One Bash script performs publication, automatically downloading the selected
build's notarized artifact. It uses normal macOS command-line tools, GitHub CLI,
jq, and Sparkle's prebuilt tools. It does not compile the app, export it again,
or submit another notarization request.

### One-time setup on your Mac

If needed, install `gh` and `jq` with `brew install gh jq`, then sign in with
`gh auth login`. The GitHub login needs Contents read/write access to this
repository for Releases and `gh-pages`.

Create `~/.config/marklens/publish.env` with just your Apple issuer ID and the
path to your downloaded API key:

```sh
APP_STORE_CONNECT_API_ISSUER_ID='YOUR_ISSUER_ID'
APP_STORE_CONNECT_API_KEY_PATH='/absolute/path/to/AuthKey_YOUR_KEY_ID.p8'
```

Run `chmod 600 ~/.config/marklens/publish.env`. The key ID is read from Apple's
standard `AuthKey_ID.p8` filename. For a renamed key file, also set
`APP_STORE_CONNECT_API_KEY_ID`. The Apple key is used only to read Cloud build
metadata and download artifacts. Keep it outside the repository.

Sparkle uses your existing login Keychain key under account `ch.doapp.MarkLens`.
No key export or signing-framework build is needed. Its prebuilt 2.10.0 tools
are downloaded with a pinned checksum.

### Publish a release

Copy the completed Release build's App Store Connect URL and run:

```sh
bash ci_scripts/run_publish.sh --check 'PASTE_BUILD_URL_HERE'
bash ci_scripts/run_publish.sh 'PASTE_BUILD_URL_HERE'
```

The first command checks the real artifact without changing GitHub. The second
performs publication. Each run prints seven numbered steps. Without a URL, the
script prompts for one, so no release-specific configuration file edits are needed.

Alternatively, select the shared **Publish** scheme in Xcode, choose **My Mac**,
and use **Product → Build** (⌘B). A dialog asks for the completed build URL.
The aggregate target runs the same Bash script and has no app build dependency.
Xcode may still resolve project packages. Use Build, not Archive.

The first real artifact retrieval still needs a `--check` run: offline tests
cannot establish API-key access or Apple's actual artifact packaging.

### Optional manual publishing in Xcode Cloud

The same Publish scheme can run as a single macOS **Build** action in a separate,
manually started workflow, without a notarization post-action. Start it on the
release **tag** after Release succeeds. Use a new tag containing this implementation;
older tags cannot provide the new Publish scheme. It finds the unique successful Release
build with the same tag and commit. Configure:

- `APP_STORE_CONNECT_API_KEY_ID`, `APP_STORE_CONNECT_API_ISSUER_ID`, and secret
  `APP_STORE_CONNECT_API_PRIVATE_KEY` containing the `.p8` contents.
- Secret `GITHUB_RELEASE_TOKEN` and `SPARKLE_PRIVATE_KEY` for publishing.
  Use a PAT or GitHub App token so the `gh-pages` update triggers Pages deployment.
- Optional `PUBLISH_VALIDATE_ONLY=1` for a validation run. Omit it, or use `0`,
  when publishing. The script installs missing `gh`/`jq` tools with Homebrew in
  Cloud. All other tools come with macOS.

Cloud reads the `.p8` contents from the secret variable and writes a temporary
key file with private permissions; no fixed key path is needed. If more than one Release run
matches, set optional `PUBLISH_SOURCE_BUILD_ID` to the exact build UUID. These
Cloud variables are unnecessary for local publication. The scheme's
availability in Cloud still needs to be confirmed when creating that workflow.

### Release history and retries

The existing `gh-pages` branch is reused; no bootstrap script or new branch is
needed. Keep Pages configured to deploy from `gh-pages`, root directory.

The publisher checks the Release workflow, tag, commit, original app build number,
Developer ID signature, notarization staple and Gatekeeper acceptance. It only
downloads Apple's `STAPLED_NOTARIZED_ARCHIVE`, never an unnotarized fallback.
ZIP and DMG artifacts are supported.

It signs and verifies the ZIP before uploading, verifies GitHub's stored bytes,
then updates the appcast. Existing ZIPs are never replaced, and old feed entries
and release-candidate assets are retained. A retry reuses an existing ZIP only
when it contains the same validated app. A tag with an older unstapled ZIP needs
a new release tag. Build numbers and Stable/Preview release versions must increase; never move
published tags.
Concurrent feed updates retry without overwriting each other. If Apple has not
made the artifact available yet, wait and rerun the script.

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
bash ci_scripts/tests/test_run_publish.sh
```

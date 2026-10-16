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

Release archives are built, Developer ID signed, and notarized by the existing
Xcode Cloud workflow. Starting with 1.10.0, its post-build script requests a
GitHub Actions job that waits for Cloud to finish, downloads its stapled notarized
artifact, signs the update ZIP with Sparkle, and publishes a cumulative appcast
on the `gh-pages` branch. Only
macOS builds embed Sparkle; Quick Look and mobile builds do not run an updater.

### One-time setup before the first release candidate

1. Resolve the pinned Sparkle 2.10.0 package in Xcode. Its tools are in
   `SourcePackages/artifacts/sparkle/Sparkle/bin/` beneath DerivedData. Use that
   version's tools for both local setup and Xcode Cloud.
2. Run `generate_keys` on the maintainer's Mac. Keep the generated private key in
   Keychain, export it with `generate_keys -x <private-key-file>`, and retain an
   encrypted backup. Never commit that file or paste its contents into build logs.
3. In Xcode Cloud, set `SPARKLE_PUBLIC_ED_KEY` to the printed public key.
   The pre-build script embeds it into the app. Normal local builds leave this
   setting empty and cannot self-update. In **GitHub repository Settings → Secrets
   and variables → Actions**, store the exported private key contents as
   `SPARKLE_PRIVATE_KEY`. Cloud no longer needs the private key.
4. Store `GITHUB_RELEASE_TOKEN` in both Xcode Cloud and GitHub Actions secrets.
   Use a maintainer token with repository Contents read/write permission to
   dispatch the workflow, create Releases, and update `gh-pages`. Do not use the
   Actions `GITHUB_TOKEN` for Pages pushes: it does not trigger branch-based
   Pages deployment.
5. Keep the Xcode Cloud **Notarize – macOS** post-action enabled. Create an App
   Store Connect **team API key** with access to this app's Xcode Cloud build
   artifacts (App Store Connect → Users and Access → Integrations → App Store
   Connect API). Download its `.p8` file and keep a secure backup; Apple permits
   downloading it only once. Add these **GitHub Actions secrets**:

   - `APP_STORE_CONNECT_API_PRIVATE_KEY`: complete `.p8` contents.
   - `APP_STORE_CONNECT_API_KEY_ID`: the key ID shown by Apple.
   - `APP_STORE_CONNECT_API_ISSUER_ID`: the issuer ID shown by Apple.

   See [Apple’s API overview](https://developer.apple.com/app-store-connect/api/)
   for Xcode Cloud API access. This key retrieves the completed artifact; it never submits another
   notarization. The publisher requires a successful Cloud run and its
   `STAPLED_NOTARIZED_ARCHIVE`, then verifies the app identity, build, signed source-commit metadata, signature,
   stapled ticket, and Gatekeeper acceptance. Temporary private-key files have
   owner-only permissions and are removed after signing API tokens. Sparkle
   tools are downloaded from the pinned, checksum-verified vendor release.
6. Before the first release, create the dedicated feed branch from your Mac:

   ```sh
   bash ci_scripts/bootstrap_update_pages.sh
   ```

   This pushes only `.nojekyll` and an empty `updates/appcast.xml`, using your
   existing GitHub authentication. It does not switch branches or change your
   working files/index. Add `--dry-run` to inspect the bootstrap commit without
   pushing. If you skip this step, the first successful release publication also
   creates the branch automatically.
7. In GitHub repository Settings → Pages, choose **Deploy from a branch**,
   `gh-pages`, and `/(root)`. Verify that the deployment serves
   `https://pd95.github.io/MarkLens/updates/appcast.xml`. The initial feed contains
   no releases; the GitHub publisher fills it after the first successful signed
   release. Commit and push this implementation, including
   `.github/workflows/publish-updates.yml`, to the default branch **before**
   creating the release tag. Repository dispatch only starts workflows already
   present on the default branch.

### Release rules and recovery

- Use increasing numeric `CI_BUILD_NUMBER` values across the Stable and Preview
  release train. Build the final version after its candidates. Feed ordering uses
  `CFBundleVersion`; display versions retain the complete tag, such as
  `1.10.0-rc2`. The publisher rejects older marketing versions and prerelease tags as well as
  non-increasing build numbers. This is one release train: publishing a stable
  maintenance release after a newer-version preview requires a separate feed
  design and is outside this release.
- Release tags accept the existing `v1.10.0` and `v1.10.0-rc1` forms. Tags with a
  prerelease suffix publish to the Preview channel; tags containing `-test` do not
  publish. Stable users receive default-channel releases; Preview users receive
  both. Returning to Stable does not downgrade an installed preview.
- Finalize the matching changelog section for release. A numbered section marked
  `(Unreleased)` is also accepted for release candidates. The publisher creates
  cumulative Markdown notes from the tagged checkout, bounded by the target
  release; the app shows only the changes missed since its installed version.
- The signed, notarized ZIP is uploaded and verified before its feed entry is
  published. ZIP URLs and bytes are immutable. Retrying the same artifact is
  supported; rebuilding the same tag with different bytes requires a new tag.
  No publication step deletes advertised preview releases or other feed history.
- If feed publication fails after upload, the previous feed remains usable.
  Retry **Publish Notarized Update** from GitHub Actions using its manual inputs:
  the original Cloud build ID/number, release tag, and full commit SHA. This
  retrieves the original artifact rather than rebuilding. Concurrent branch updates are retried
  against the latest feed without force-pushing. Check the GitHub publication workflow and
  GitHub Pages deployment result; the Xcode Cloud success message alone does not
  prove the Pages deployment succeeded.
- To withdraw a bad update, remove its item from the feed and redeploy Pages;
  retain its archive for cached offers. Publish a corrected release with a higher
  build number. Do not lower versions or overwrite an advertised ZIP.
- Archive signatures are mandatory. This initial pipeline does not enable optional
  whole-feed signing or delta updates. Changing the feed URL or signing key needs
  a planned migration; keep the private key backup accessible to the maintainer.

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

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

Release archives are built and Developer ID signed by Xcode Cloud. Starting with
1.10.0, `ci_post_xcodebuild.sh` exports the archive with Developer ID signing,
notarizes the exported app, waits for Apple's
acceptance, staples the ticket, signs the update ZIP with Sparkle, and publishes
the release and cumulative appcast to GitHub. GitHub hosts the release assets and
serves the feed from `gh-pages`; no GitHub Actions publishing job is required.
Only macOS builds embed Sparkle; Quick Look and mobile builds do not run an updater.

### One-time setup before the first release candidate

1. Resolve the pinned Sparkle 2.10.0 package in Xcode. Its tools are in
   `SourcePackages/artifacts/sparkle/Sparkle/bin/` beneath DerivedData. The Cloud
   publisher finds the resolved tools automatically. If discovery fails, set
   `SPARKLE_BIN_DIR` to that package's `bin` directory in the Cloud workflow.
2. Run `generate_keys` on the maintainer's Mac. Keep the generated private key in
   Keychain, export it with `generate_keys -x <private-key-file>`, and retain an
   encrypted backup. Never commit that file or paste its contents into build logs.
3. Configure the following environment variables in the **Xcode Cloud Release
   workflow → Environment** (mark secret values as secrets):

   | Variable | Value | Secret |
   | --- | --- | --- |
   | `SPARKLE_PUBLIC_ED_KEY` | Public key from `generate_keys` | No |
   | `SPARKLE_PRIVATE_KEY` | Exported Sparkle private key contents | Yes |
   | `GITHUB_RELEASE_TOKEN` | Maintainer token with repository Contents read/write permission | Yes |
   | `APP_STORE_CONNECT_API_PRIVATE_KEY` | Complete Apple team API `.p8` file contents | Yes |
   | `APP_STORE_CONNECT_API_KEY_ID` | Apple API key ID | Yes |
   | `APP_STORE_CONNECT_API_ISSUER_ID` | Apple API issuer ID | Yes |

   The public key is embedded in the app by the pre-build script. Normal local
   builds leave it empty and cannot self-update. Use a maintainer GitHub token
   that can create Releases and update `gh-pages`; an Actions `GITHUB_TOKEN` does
   not trigger branch-based Pages deployment.
4. Obtain the Apple key in **App Store Connect → Users and Access → Integrations
   → App Store Connect API → Team Keys**. Generate a team key with **Developer**
   access, download its `.p8` file, and copy the Key ID and Issuer ID from that
   page. The key also authenticates the Developer ID export, so it needs access
   to signing assets and cloud-managed Developer ID certificates. Apple permits
   downloading the private key only once; keep a secure backup. See [Apple's key setup instructions](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api).
   If you already created this key for artifact retrieval, reuse the same values
   in the Cloud variables above. No Apple or Sparkle credentials are needed in
   GitHub Actions for this pipeline; remove those repository secrets if they
   were added solely for the previous publishing workflow.
5. **Disable the built-in Notarize – macOS post-action** in the Cloud Release
   workflow. Keep the Archive action’s **Deployment Preparation** set to
   **None / Ohne**. The script explicitly exports `CI_ARCHIVE_PATH` using
   `xcodebuild -exportArchive`, automatic Developer ID signing, and the Apple API
   credentials above. `ci_scripts/ExportOptions.plist` explicitly selects the
   project's signing team (`P8CC95REUG`), because Cloud archives can lack team
   metadata. Keep that team in sync with `DEVELOPMENT_TEAM` in the project if
   transferring ownership. No `CI_TEAM_ID` variable needs to be configured. If Cloud already supplies
   a Developer ID export, the script reuses it. The original archive is never
   uploaded directly. The script then submits once using
   `notarytool --wait`, checks for `Accepted`, staples the ticket, and verifies
   Gatekeeper acceptance before packaging the final Sparkle update ZIP.
   An already-stapled export skips submission. A rejection, timeout, or validation
   failure stops publication. Private-key files have owner-only permissions and
   are deleted on success or failure. See [Apple's notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).
6. Before the first release, create the dedicated feed branch from your Mac:

   ```sh
   bash ci_scripts/bootstrap_update_pages.sh
   ```

   This pushes only `.nojekyll` and an empty `updates/appcast.xml`, using your
   existing GitHub authentication. It does not switch branches or change your
   working files/index. Add `--dry-run` to inspect the bootstrap commit without
   pushing. If you skip this step, the first successful publication also creates
   the branch automatically. No need to repeat this if the branch already exists.
7. In GitHub repository Settings → Pages, choose **Deploy from a branch**,
   `gh-pages`, and `/(root)`. Verify that the deployment serves
   `https://pd95.github.io/MarkLens/updates/appcast.xml`. The initial feed contains
   no releases; the Cloud publisher fills it after the first successful release.
   Commit and push this implementation before creating the release tag so Cloud
   uses the new scripts. The existing release-script verification workflow in
   GitHub Actions only runs tests; it does not receive release credentials.

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
  Retry publication only with the same original stapled app and exact ZIP bytes;
  run `ci_scripts/release_updates.py` on macOS with the release environment
  (including `CI_COMMIT` matching the app's signed source metadata). Rebuilding
  in Cloud changes the build number and requires a new release tag. Do not retry
  a published tag by overwriting its archive. Concurrent feed updates are retried
  against the latest feed without force-pushing. Check the Cloud post-build log
  and GitHub Pages deployment result; Cloud success alone does not prove that
  Pages finished deploying. If Apple's submission times out (20 minutes), it
  may still be processing; check its status before starting another submission.
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

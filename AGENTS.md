# Repository Guidelines

## Project Structure & Module Organization
- `MarkLens/` contains the main SwiftUI app target (document handling, views, and app entry point).
- `QuickLookPreview_macOS/` hosts the Quick Look extension used for markdown previews.
- `Shared/` holds shared Swift code (UTType helpers, app constants).
- `Icon/` contains source icon assets and design files.
- `MarkLens.xcodeproj/` is the Xcode project workspace and build metadata.

## Build, Test, and Development Commands
- When Xcode MCP tools are available, discover the lazily loaded `mcp__xcode__*` tools first. Use `XcodeListWindows` to obtain the active `tabIdentifier`, then use `BuildProject`, `RunAllTests`/`RunSomeTests`, `GetBuildLog`, and the issue/diagnostic tools for macOS/Xcode validation. Do not conclude that Xcode validation is unavailable merely because the Linux container lacks `xcodebuild`.
- `BuildProject` builds the active Xcode scheme. For the `MarkLens` scheme, inspect the build log to confirm that both `MarkLens.app` and the embedded `QuickLookPreview_macOS.appex` were compiled and validated.
- `open MarkLens.xcodeproj` to work in Xcode (recommended for running and debugging).
- `xcodebuild -project MarkLens.xcodeproj -scheme MarkLens -configuration Debug build` builds the app from the CLI.
- `xcodebuild -project MarkLens.xcodeproj -scheme QuickLookPreview -configuration Debug build` builds the Quick Look extension.
- `MarkLensTests/`, `MarkLensUITests/`, and `MarkdownPipeline/Tests/` contain automated tests. Prefer the Xcode MCP test tools for app/UI tests and `swift test --package-path MarkdownPipeline` for Linux-compatible package tests.
- UI tests can outlast the Xcode MCP call timeout. Start a test run only once and keep waiting on its original tool call while it is pending.
- If `RunAllTests` or `RunSomeTests` itself times out, treat the run's status as unknown: the tests may still be running in Xcode. Do not invoke a test tool again to poll or restart the suite.
- Use read-only Xcode MCP diagnostics such as `XcodeListNavigatorIssues` to inspect reported failures, and report that completion is unverified unless a test result is actually available. The absence of navigator issues or a successful `GetBuildLog` does not prove that tests passed.
- Once the original run has finished and identified failed UI tests, rerun only those failed tests individually with `RunSomeTests`. Do not rerun the entire UI suite to investigate individual failures.
- If `xcodebuild` crashes during device discovery, reset simulator device sets:
  `for DEVICES_SET in playgrounds previews ib test default; do xcrun simctl --set $DEVICES_SET delete all; done`
- To test Quick Look on macOS from the CLI after building, run:
  `qlmanage -r` and `qlmanage -p README.md`.

## Coding Style & Naming Conventions
- Swift code uses 4-space indentation and standard Swift formatting as applied by Xcode.
- Types and protocols use UpperCamelCase (e.g., `MarkdownDocument`); properties and functions use lowerCamelCase (e.g., `stringFromResource`).
- Keep file names aligned with their primary type (e.g., `MarkdownWebView.swift`).
- Aim for best-practice Swift implementations on both iOS and macOS (modern APIs, clear concurrency boundaries, and platform-appropriate design).

## Testing Guidelines
- Add app tests to the existing `MarkLensTests` or `MarkLensUITests` targets, and package tests under `MarkdownPipeline/Tests/MarkdownPipelineTests`.
- Name tests with `test` prefixes (e.g., `testRendersMarkdownLinks`) and keep coverage focused on parser behavior and template rendering.
- Raw HTML is sanitized for GFM-disallowed tags in `MarkdownPipeline/Sources/MarkdownPipeline/HTMLVisitor.swift`; keep tests aligned with that behavior.

## Commit & Pull Request Guidelines
- Recent commits use short, imperative summaries (e.g., "Remove print() and disable \"drawsBackground\"").
- Keep commits focused on a single change area.
- Use multi-line commit messages: a short title plus 2–4 bullets describing the main changes.
- For agent-assisted commits, infer the human maintainer identity from repository history or configuration and preserve it as both author and committer.
- Credit the assisting agent in the commit message with a `Co-Authored by` trailer using that agent's identity.
- PRs should include a brief description, steps to validate, and screenshots for UI changes in the preview rendering.
- Link related issues when applicable and call out any manual testing performed in Xcode.

## Security & Configuration Tips
- The markdown parser sanitizes link and image URLs; be cautious when changing `HTMLVisitor` link handling.

## Testing Notes
- Prefer `@Suite` groupings in `MarkdownPipelineTests` for related behaviors (e.g., Front Matter, HTML Rendering, Convenience API).
- Keep HTML rendering tests at the pipeline level (string input → HTML output) instead of constructing ASTs directly.
- Avoid code highlighting assertions in HTML rendering tests unless explicitly requested; keep those tests separate.

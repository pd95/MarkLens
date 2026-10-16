#!/bin/bash
set -euo pipefail

export SPARKLE_PUBLIC_ED_KEY="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

repository_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/marklens-pre-build-test.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

project_file="$test_root/project.pbxproj"
build_info_file="$test_root/BuildInfo.swift"
changelog_file="$test_root/CHANGELOG.md"
info_plist_file="$test_root/Info-macOS.plist"
checkout_commit="$(git -C "$repository_root" rev-parse HEAD)"
python3 - "$info_plist_file" <<'PYPLIST'
import plistlib, sys
with open(sys.argv[1], "wb") as file:
    plistlib.dump({"MarkLensReleaseCommit": ""}, file)
PYPLIST

printf 'MARKETING_VERSION = 1.0.0; CURRENT_PROJECT_VERSION = 1; SPARKLE_PUBLIC_ED_KEY = "";\n' > "$project_file"
printf 'placeholder\n' > "$build_info_file"
printf '# Changelog\n\n## [2.0.0] (Unreleased)\n\nTest release.\n' > "$changelog_file"

PROJECT_FILE="$project_file" \
BUILD_INFO_FILE="$build_info_file" \
CHANGELOG_FILE="$changelog_file" \
INFO_PLIST_FILE="$info_plist_file" \
CI_TAG="refs/tags/v2.0.0-rc1" \
CI_BUILD_NUMBER="42" \
zsh "$repository_root/ci_scripts/ci_pre_xcodebuild.sh"

python3 - "$info_plist_file" "$checkout_commit" <<'PYPLIST'
import plistlib, sys
with open(sys.argv[1], "rb") as file:
    assert plistlib.load(file)["MarkLensReleaseCommit"] == sys.argv[2]
PYPLIST

grep -F 'MARKETING_VERSION = 2.0.0;' "$project_file"
grep -F 'CURRENT_PROJECT_VERSION = 42;' "$project_file"
grep -F 'nonisolated static let tagVersion = "2.0.0-rc1"' "$build_info_file"

printf '# Changelog\n\n## 1.9.0\n\nOld release.\n' > "$changelog_file"
if PROJECT_FILE="$project_file" \
    BUILD_INFO_FILE="$build_info_file" \
    CHANGELOG_FILE="$changelog_file" \
    INFO_PLIST_FILE="$info_plist_file" \
    CI_TAG="refs/tags/v2.0.0" \
    CI_BUILD_NUMBER="43" \
    zsh "$repository_root/ci_scripts/ci_pre_xcodebuild.sh"; then
    echo "Tagged build unexpectedly accepted a missing changelog section." >&2
    exit 1
fi

printf '# Changelog\n\n## 2.0.0\n\nTest release.\n' > "$changelog_file"
if PROJECT_FILE="$project_file" \
    BUILD_INFO_FILE="$build_info_file" \
    CHANGELOG_FILE="$changelog_file" \
    INFO_PLIST_FILE="$info_plist_file" \
    CI_TAG="refs/tags/v2.0.0" \
    CI_BUILD_NUMBER="43" \
    CI_COMMIT="0000000000000000000000000000000000000000" \
    zsh "$repository_root/ci_scripts/ci_pre_xcodebuild.sh"; then
    echo "Tagged build unexpectedly accepted a mismatched commit." >&2
    exit 1
fi

grep -F 'SPARKLE_PUBLIC_ED_KEY = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";' "$project_file"

echo "ci_pre_xcodebuild changelog and signing-key validation tests passed."

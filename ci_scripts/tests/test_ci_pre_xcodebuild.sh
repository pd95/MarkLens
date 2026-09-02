#!/bin/bash
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/marklens-pre-build-test.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

project_file="$test_root/project.pbxproj"
build_info_file="$test_root/BuildInfo.swift"
changelog_file="$test_root/CHANGELOG.md"

printf 'MARKETING_VERSION = 1.0.0; CURRENT_PROJECT_VERSION = 1;\n' > "$project_file"
printf 'placeholder\n' > "$build_info_file"
printf '# Changelog\n\n## [2.0.0]\n\nTest release.\n' > "$changelog_file"

PROJECT_FILE="$project_file" \
BUILD_INFO_FILE="$build_info_file" \
CHANGELOG_FILE="$changelog_file" \
CI_TAG="refs/tags/v2.0.0-rc1" \
CI_BUILD_NUMBER="42" \
zsh "$repository_root/ci_scripts/ci_pre_xcodebuild.sh"

grep -F 'MARKETING_VERSION = 2.0.0;' "$project_file"
grep -F 'CURRENT_PROJECT_VERSION = 42;' "$project_file"
grep -F 'nonisolated static let tagVersion = "2.0.0-rc1"' "$build_info_file"

printf '# Changelog\n\n## 1.9.0\n\nOld release.\n' > "$changelog_file"
if PROJECT_FILE="$project_file" \
    BUILD_INFO_FILE="$build_info_file" \
    CHANGELOG_FILE="$changelog_file" \
    CI_TAG="refs/tags/v2.0.0" \
    CI_BUILD_NUMBER="43" \
    zsh "$repository_root/ci_scripts/ci_pre_xcodebuild.sh"; then
    echo "Tagged build unexpectedly accepted a missing changelog section." >&2
    exit 1
fi

echo "ci_pre_xcodebuild changelog validation tests passed."

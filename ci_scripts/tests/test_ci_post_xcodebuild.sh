#!/bin/bash
set -euo pipefail
repository_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/marklens-release-test.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT
mkdir "$test_root/bin"
# These hooks must never publish, export or notarize an app themselves.
for tool in curl xcodebuild xcrun; do
    cat > "$test_root/bin/$tool" <<'TOOL'
#!/bin/bash
echo "Unexpected external release operation" >&2
exit 99
TOOL
    chmod +x "$test_root/bin/$tool"
done
for scheme in MarkLens Publish; do
    PATH="$test_root/bin:$PATH" CI_XCODE_SCHEME="$scheme" \
        CI_XCODEBUILD_ACTION=archive CI_XCODEBUILD_EXIT_CODE=0 CI_TAG=v1.10.0-rc2 \
        zsh "$repository_root/ci_scripts/ci_post_xcodebuild.sh"
done
CI_XCODE_SCHEME=Publish CI_XCODEBUILD_ACTION=build CI_TAG=v1.10.0 \
    PROJECT_FILE=/nonexistent zsh "$repository_root/ci_scripts/ci_pre_xcodebuild.sh"
if CI_XCODE_SCHEME=Publish CI_XCODEBUILD_ACTION=archive \
    zsh "$repository_root/ci_scripts/ci_pre_xcodebuild.sh"; then
    echo "Publish workflow unexpectedly accepted an archive action." >&2
    exit 1
fi
echo "Cloud hook separation tests passed."

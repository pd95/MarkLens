#!/bin/bash
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/marklens-release-test.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

mkdir -p "$test_root/bin" "$test_root/tmp" "$test_root/MarkLens.app"
printf 'test app\n' > "$test_root/MarkLens.app/fixture.txt"
printf '# Changelog\n\n## 1.6.0\n\nTest release.\n' > "$test_root/CHANGELOG.md"

cat > "$test_root/bin/curl" <<'SH'
#!/bin/bash
set -euo pipefail

request="GET"
output_path=""
url=""
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --request)
            request="$2"
            shift 2
            ;;
        --output)
            output_path="$2"
            shift 2
            ;;
        --header|--write-out|--data|--data-binary)
            shift 2
            ;;
        --silent|--show-error|--location)
            shift
            ;;
        *)
            url="$1"
            shift
            ;;
    esac
done

printf '%s\t%s\n' "$request" "$url" >> "$FAKE_CURL_LOG"
status="200"
body='{}'

case "$request $url" in
    "GET "*"/releases/tags/"*)
        body='{"id":100}'
        ;;
    "GET "*"/releases/100/assets")
        body='[]'
        ;;
    "POST "*"/releases/100/assets?name="*)
        status="${FAKE_UPLOAD_STATUS:-201}"
        if [[ "$status" == "201" ]]; then
            body='{"browser_download_url":"https://downloads.example/MarkLens.zip"}'
        else
            body='{"message":"simulated upload failure"}'
        fi
        ;;
    "GET "*"/releases?per_page=100&page=1")
        jq --null-input '[
            {"id": 201, "tag_name": "v1.6.0-rc1", "draft": false, "prerelease": true},
            {"id": 203, "tag_name": "v1.6.0-beta1", "draft": false, "prerelease": true},
            {"id": 204, "tag_name": "v1.6.1-rc1", "draft": false, "prerelease": true},
            {"id": 205, "tag_name": "v1.6.0-rc4", "draft": true, "prerelease": true},
            {"id": 206, "tag_name": "v1.6.0-rc5", "draft": false, "prerelease": false},
            {"id": 207, "tag_name": "v1.6.0-rc", "draft": false, "prerelease": true}
        ] + [
            range(0; 94) as $index
            | {
                "id": (1000 + $index),
                "tag_name": ("v0.\($index).0"),
                "draft": false,
                "prerelease": false
            }
        ]' > "$output_path"
        printf '%s' "$status"
        exit 0
        ;;
    "GET "*"/releases?per_page=100&page=2")
        body='[{"id":202,"tag_name":"v1.6.0-rc3","draft":false,"prerelease":true}]'
        ;;
    "DELETE "*"/releases/201"|"DELETE "*"/releases/202"|"DELETE "*"/releases/207")
        status="204"
        body=''
        ;;
    *)
        printf 'Unexpected fake curl request: %s %s\n' "$request" "$url" >&2
        exit 1
        ;;
esac

if [[ -n "$output_path" ]]; then
    printf '%s' "$body" > "$output_path"
fi
printf '%s' "$status"
SH
chmod +x "$test_root/bin/curl"

cat > "$test_root/bin/zip" <<'SH'
#!/bin/bash
set -euo pipefail
printf 'fake zip\n' > "$2"
SH
chmod +x "$test_root/bin/zip"

run_post_build() {
    local tag="$1"
    PATH="$test_root/bin:$PATH" \
    FAKE_CURL_LOG="$test_root/curl.log" \
    FAKE_UPLOAD_STATUS="${FAKE_UPLOAD_STATUS:-201}" \
    CI_XCODEBUILD_ACTION="archive" \
    CI_XCODEBUILD_EXIT_CODE="0" \
    CI_TAG="$tag" \
    CI_DEVELOPER_ID_SIGNED_APP_PATH="$test_root/MarkLens.app" \
    GITHUB_RELEASE_TOKEN="test-token" \
    GITHUB_REPOSITORY="example/MarkLens" \
    GITHUB_API_URL="https://api.example" \
    GITHUB_UPLOADS_URL="https://uploads.example" \
    CHANGELOG_FILE="$test_root/CHANGELOG.md" \
    TMPDIR="$test_root/tmp" \
    zsh "$repository_root/ci_scripts/ci_post_xcodebuild.sh"
}

: > "$test_root/curl.log"
run_post_build "refs/tags/v1.6.0"
grep -F $'DELETE\thttps://api.example/repos/example/MarkLens/releases/201' "$test_root/curl.log"
grep -F $'DELETE\thttps://api.example/repos/example/MarkLens/releases/202' "$test_root/curl.log"
grep -F $'DELETE\thttps://api.example/repos/example/MarkLens/releases/207' "$test_root/curl.log"
if grep -Eq $'DELETE\t.*/releases/(203|204|205|206)$' "$test_root/curl.log"; then
    echo "Final release cleanup deleted a release outside its published RC scope." >&2
    exit 1
fi

: > "$test_root/curl.log"
run_post_build "refs/tags/v1.6.0-rc4"
if grep -Fq '/releases?per_page=' "$test_root/curl.log"; then
    echo "Prerelease upload unexpectedly attempted final-release cleanup." >&2
    exit 1
fi

: > "$test_root/curl.log"
if FAKE_UPLOAD_STATUS="500" run_post_build "refs/tags/v1.6.0"; then
    echo "Simulated final asset upload unexpectedly succeeded." >&2
    exit 1
fi
if grep -Fq '/releases?per_page=' "$test_root/curl.log"; then
    echo "Failed final upload unexpectedly attempted release cleanup." >&2
    exit 1
fi

echo "ci_post_xcodebuild release cleanup tests passed."

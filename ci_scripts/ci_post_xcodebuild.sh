#!/bin/zsh
set -euo pipefail

GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-pd95/MarkLens}"
GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"
GITHUB_UPLOADS_URL="${GITHUB_UPLOADS_URL:-https://uploads.github.com}"
APP_NAME="${APP_NAME:-MarkLens}"
SCRIPT_DIR="${0:A:h}"
REPOSITORY_ROOT="${SCRIPT_DIR:h}"
CHANGELOG_FILE="${CHANGELOG_FILE:-$REPOSITORY_ROOT/CHANGELOG.md}"

if [[ "${CI_XCODEBUILD_ACTION:-}" != "archive" ]]; then
    echo "Not an archive action; skipping GitHub Release upload."
    exit 0
fi

if [[ "${CI_XCODEBUILD_EXIT_CODE:-1}" != "0" ]]; then
    echo "xcodebuild did not finish successfully; skipping GitHub Release upload."
    exit 0
fi

if [[ -z "${CI_TAG:-}" ]]; then
    echo "No CI_TAG set; skipping GitHub Release upload."
    exit 0
fi

TAG_NAME="${CI_TAG#refs/tags/}"
TAG_VERSION="${TAG_NAME#v}"
BASE_VERSION="${TAG_VERSION%%-*}"

if [[ "$TAG_VERSION" == *-test* ]]; then
    echo "Test tag '$TAG_NAME'; skipping GitHub Release upload."
    exit 0
fi

if [[ -z "${GITHUB_RELEASE_TOKEN:-}" ]]; then
    echo "error: GITHUB_RELEASE_TOKEN is not set."
    echo "Add it as a secret environment variable in the Xcode Cloud release workflow."
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "error: jq is required to create and update GitHub Releases."
    exit 1
fi

ARTIFACT_PATH="${CI_DEVELOPER_ID_SIGNED_APP_PATH:-}"
if [[ -z "$ARTIFACT_PATH" || ! -e "$ARTIFACT_PATH" ]]; then
    echo "error: CI_DEVELOPER_ID_SIGNED_APP_PATH is empty or does not exist."
    echo "This upload script expects the Xcode Cloud archive to export a Developer ID signed Mac app."
    exit 1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/marklens-release.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

ASSET_NAME="${APP_NAME}-${TAG_NAME}.zip"
ASSET_PATH="$WORK_DIR/$ASSET_NAME"

APP_PATH="$ARTIFACT_PATH"
if [[ -d "$ARTIFACT_PATH" && "$ARTIFACT_PATH" != *.app ]]; then
    APP_PATH="$ARTIFACT_PATH/$APP_NAME.app"
fi

if [[ ! -d "$APP_PATH" || "$APP_PATH" != *.app ]]; then
    echo "error: Could not find $APP_NAME.app in CI_DEVELOPER_ID_SIGNED_APP_PATH."
    echo "CI_DEVELOPER_ID_SIGNED_APP_PATH=$ARTIFACT_PATH"
    exit 1
fi

echo "Packaging $APP_PATH as $ASSET_NAME"
if command -v ditto >/dev/null 2>&1; then
    ditto -c -k --keepParent "$APP_PATH" "$ASSET_PATH"
elif command -v zip >/dev/null 2>&1; then
    (cd "$(dirname "$APP_PATH")" && zip -qry "$ASSET_PATH" "$(basename "$APP_PATH")")
else
    echo "error: Could not find ditto or zip to create $ASSET_NAME"
    exit 1
fi

IS_PRERELEASE=false
if [[ "$TAG_VERSION" == *-* ]]; then
    IS_PRERELEASE=true
fi

RELEASE_NAME="$APP_NAME $TAG_NAME"
RELEASE_NOTES=""
if [[ -f "$CHANGELOG_FILE" ]]; then
    RELEASE_NOTES="$(awk -v version="$BASE_VERSION" '
        /^##[[:space:]]+/ {
            heading = $0
            sub(/^##[[:space:]]+/, "", heading)
            sub(/[[:space:]]+$/, "", heading)
            if (substr(heading, 1, 1) == "[" && substr(heading, length(heading), 1) == "]") {
                heading = substr(heading, 2, length(heading) - 2)
            }
            if (found) {
                exit
            }
            if (heading == version) {
                found = 1
            }
            next
        }
        found && !started && /^[[:space:]]*$/ {
            next
        }
        found {
            started = 1
            print
        }
    ' "$CHANGELOG_FILE")"
fi

if [[ -z "$RELEASE_NOTES" ]]; then
    RELEASE_NOTES="Automated Xcode Cloud release for $TAG_NAME."
fi

if [[ -n "${CI_BUILD_URL:-}" ]]; then
    RELEASE_NOTES="$RELEASE_NOTES"$'\n\n'"Xcode Cloud build: $CI_BUILD_URL"
fi

auth_header="Authorization: Bearer $GITHUB_RELEASE_TOKEN"
api_version_header="X-GitHub-Api-Version: 2022-11-28"
accept_header="Accept: application/vnd.github+json"

release_json="$WORK_DIR/release.json"
release_status="$WORK_DIR/release.status"

echo "Looking up GitHub Release for $TAG_NAME"
http_code="$(curl --silent --show-error --location \
    --header "$accept_header" \
    --header "$auth_header" \
    --header "$api_version_header" \
    --output "$release_json" \
    --write-out "%{http_code}" \
    "$GITHUB_API_URL/repos/$GITHUB_REPOSITORY/releases/tags/$TAG_NAME")"

if [[ "$http_code" == "404" ]]; then
    echo "Creating GitHub Release for $TAG_NAME"
    jq --null-input \
        --arg tag_name "$TAG_NAME" \
        --arg name "$RELEASE_NAME" \
        --arg body "$RELEASE_NOTES" \
        --argjson prerelease "$IS_PRERELEASE" \
        '{
            tag_name: $tag_name,
            name: $name,
            body: $body,
            draft: false,
            prerelease: $prerelease,
            generate_release_notes: true,
            make_latest: (if $prerelease then "false" else "true" end)
        }' > "$WORK_DIR/create-release.json"

    http_code="$(curl --silent --show-error --location \
        --request POST \
        --header "$accept_header" \
        --header "$auth_header" \
        --header "$api_version_header" \
        --header "Content-Type: application/json" \
        --data @"$WORK_DIR/create-release.json" \
        --output "$release_json" \
        --write-out "%{http_code}" \
        "$GITHUB_API_URL/repos/$GITHUB_REPOSITORY/releases")"
fi

if [[ "$http_code" -lt 200 || "$http_code" -gt 299 ]]; then
    echo "error: GitHub release lookup/create failed with HTTP $http_code"
    jq . "$release_json" || cat "$release_json"
    exit 1
fi

release_id="$(jq --raw-output 'if (.id | type) == "number" then .id else empty end' "$release_json")"
if [[ -z "$release_id" || "$release_id" == "null" ]]; then
    echo "error: GitHub release response did not include an id."
    jq . "$release_json" || cat "$release_json"
    exit 1
fi

echo "Checking for existing release asset named $ASSET_NAME"
assets_json="$WORK_DIR/assets.json"
http_code="$(curl --silent --show-error --location \
    --header "$accept_header" \
    --header "$auth_header" \
    --header "$api_version_header" \
    --output "$assets_json" \
    --write-out "%{http_code}" \
    "$GITHUB_API_URL/repos/$GITHUB_REPOSITORY/releases/$release_id/assets")"

if [[ "$http_code" -lt 200 || "$http_code" -gt 299 ]]; then
    echo "error: GitHub asset lookup failed with HTTP $http_code"
    jq . "$assets_json" || cat "$assets_json"
    exit 1
fi

existing_asset_id="$(jq --raw-output --arg name "$ASSET_NAME" '
    if type == "array" then
        first(.[] | select(.name == $name) | .id) // empty
    else
        empty
    end
' "$assets_json")"
if [[ -n "$existing_asset_id" ]]; then
    echo "Deleting existing release asset $ASSET_NAME"
    http_code="$(curl --silent --show-error --location \
        --request DELETE \
        --header "$accept_header" \
        --header "$auth_header" \
        --header "$api_version_header" \
        --output "$release_status" \
        --write-out "%{http_code}" \
        "$GITHUB_API_URL/repos/$GITHUB_REPOSITORY/releases/assets/$existing_asset_id")"

    if [[ "$http_code" -lt 200 || "$http_code" -gt 299 ]]; then
        echo "error: GitHub asset deletion failed with HTTP $http_code"
        cat "$release_status"
        exit 1
    fi
fi

echo "Uploading $ASSET_NAME to GitHub Release $TAG_NAME"
upload_json="$WORK_DIR/upload.json"
http_code="$(curl --silent --show-error --location \
    --request POST \
    --header "$accept_header" \
    --header "$auth_header" \
    --header "$api_version_header" \
    --header "Content-Type: application/zip" \
    --data-binary @"$ASSET_PATH" \
    --output "$upload_json" \
    --write-out "%{http_code}" \
    "$GITHUB_UPLOADS_URL/repos/$GITHUB_REPOSITORY/releases/$release_id/assets?name=$ASSET_NAME")"

if [[ "$http_code" -lt 200 || "$http_code" -gt 299 ]]; then
    echo "error: GitHub asset upload failed with HTTP $http_code"
    jq . "$upload_json" || cat "$upload_json"
    exit 1
fi

browser_download_url="$(jq --raw-output '.browser_download_url // empty' "$upload_json")"
echo "Uploaded GitHub Release asset: $browser_download_url"

cleanup_release_candidates() {
    local stable_tag="$1"
    local candidates_file="$WORK_DIR/release-candidates.tsv"
    local page=1
    local page_size=100
    local releases_json
    local list_status
    local release_count
    local delete_status

    : > "$candidates_file"
    while true; do
        releases_json="$WORK_DIR/releases-page-$page.json"
        list_status="$(curl --silent --show-error --location \
            --header "$accept_header" \
            --header "$auth_header" \
            --header "$api_version_header" \
            --output "$releases_json" \
            --write-out "%{http_code}" \
            "$GITHUB_API_URL/repos/$GITHUB_REPOSITORY/releases?per_page=$page_size&page=$page")"

        if [[ "$list_status" -lt 200 || "$list_status" -gt 299 ]]; then
            echo "error: GitHub release listing failed with HTTP $list_status"
            jq . "$releases_json" || cat "$releases_json"
            exit 1
        fi

        release_count="$(jq --exit-status '
            if type == "array" then length else error("GitHub release listing was not an array") end
        ' "$releases_json")"
        jq --raw-output --arg prefix "$stable_tag-rc" '
            .[]
            | select(.draft == false and .prerelease == true)
            | select((.id | type) == "number" and (.tag_name | type) == "string")
            | select(.tag_name | startswith($prefix))
            | select((.tag_name | ltrimstr($prefix)) | test("^[0-9]*$"))
            | [.id, .tag_name]
            | @tsv
        ' "$releases_json" >> "$candidates_file"

        if [[ "$release_count" -lt "$page_size" ]]; then
            break
        fi
        (( page += 1 ))
    done

    if [[ ! -s "$candidates_file" ]]; then
        echo "No published release candidates found for $stable_tag."
        return
    fi

    while IFS=$'\t' read -r candidate_id candidate_tag; do
        echo "Deleting superseded GitHub Release $candidate_tag (retaining its Git tag)"
        delete_status="$(curl --silent --show-error --location \
            --request DELETE \
            --header "$accept_header" \
            --header "$auth_header" \
            --header "$api_version_header" \
            --output "$release_status" \
            --write-out "%{http_code}" \
            "$GITHUB_API_URL/repos/$GITHUB_REPOSITORY/releases/$candidate_id")"

        if [[ "$delete_status" != "204" && "$delete_status" != "404" ]]; then
            echo "error: GitHub Release deletion failed for $candidate_tag with HTTP $delete_status"
            cat "$release_status"
            exit 1
        fi
    done < "$candidates_file"
}

if [[ "$IS_PRERELEASE" == "false" ]]; then
    cleanup_release_candidates "$TAG_NAME"
fi

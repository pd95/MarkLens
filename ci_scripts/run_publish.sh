#!/bin/bash
# Publish a completed, natively notarized Xcode Cloud build.
# Usage: bash ci_scripts/run_publish.sh [--check] [BUILD_URL_OR_UUID]
# Xcode's Publish target calls this same script; without an argument it asks for the URL.
set -euo pipefail

repository=pd95/MarkLens
release_workflow='Release (macOS)'
feed_url=https://pd95.github.io/MarkLens/updates/appcast.xml
sparkle_download=https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-for-Swift-Package-Manager.zip
sparkle_checksum=17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959

fail() { echo "error: $*" >&2; exit 1; }
step() { echo; echo "$*"; }
checksum() { shasum -a 256 "$1" | awk '{print $1}'; }
xml() { xmllint --nonet --xpath "$1" "$2"; }
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$2/Contents/Info.plist"; }
base64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# Apple requires an ES256 JWT even for read-only artifact downloads. Keep this
# authentication plumbing together; all API calls below are ordinary GETs.
apple_get() {
    local endpoint=$1 output=$2 header claims message integers integer hex token now
    now=$(date +%s)
    header=$(jq -nc --arg kid "$APP_STORE_CONNECT_API_KEY_ID" '{alg:"ES256",kid:$kid,typ:"JWT"}' | base64url)
    claims=$(jq -nc --arg iss "$APP_STORE_CONNECT_API_ISSUER_ID" --argjson now "$now" \
        '{iss:$iss,iat:($now-30),exp:($now+600),aud:"appstoreconnect-v1"}' | base64url)
    # Apple's audience is appstoreconnect-v1, as documented for App Store Connect JWTs.
    message=$header.$claims
    printf '%s' "$message" | openssl dgst -sha256 -sign "$work/AuthKey.p8" > "$work/signature.der"
    integers=$(openssl asn1parse -inform DER -in "$work/signature.der" | awk -F: '/INTEGER/ {print $NF}')
    [[ $(printf '%s\n' "$integers" | wc -l | tr -d ' ') == 2 ]] || fail 'Could not create Apple API signature.'
    hex=''
    while IFS= read -r integer; do
        while [[ ${#integer} -gt 64 && $integer == 00* ]]; do integer=${integer#00}; done
        [[ $integer =~ ^[0-9A-Fa-f]+$ && ${#integer} -le 64 ]] || fail 'Invalid Apple API signature.'
        integer=$(printf '%064s' "$integer" | tr ' ' 0)
        hex=$hex$integer
    done <<< "$integers"
    token=$message.$(printf '%s' "$hex" | xxd -r -p | base64url)
    printf 'Authorization: Bearer %s\n' "$token" > "$work/apple-header"
    [[ $endpoint == https://api.appstoreconnect.apple.com/v1/* ]] || fail 'Unexpected Apple API URL.'
    curl --fail --silent --show-error --connect-timeout 30 --max-time 120 --header "@$work/apple-header" "$endpoint" --output "$output"
}

apple_list() {
    local endpoint=$1 output=$2 page
    : > "$output.items"
    for ((page=0; page<100; page++)); do
        apple_get "$endpoint" "$work/page.json"
        jq -c '.data[]' "$work/page.json" >> "$output.items"
        endpoint=$(jq -r '.links.next // empty' "$work/page.json")
        if [[ -z $endpoint ]]; then jq -s . "$output.items" > "$output"; return; fi
    done
    fail 'Too many Apple API result pages.'
}

# Cloud already knows which tag the manual Publish run selected. Match its exact
# Git reference and commit to one successful Release run, never "the latest" run.
find_release_build() {
    local product_id reference_id workflow_id
    apple_get "https://api.appstoreconnect.apple.com/v1/ciBuildRuns/$CI_BUILD_ID?include=product,sourceBranchOrTag" "$work/current.json"
    product_id=$(jq -r '.data.relationships.product.data.id' "$work/current.json")
    reference_id=$(jq -r '.data.relationships.sourceBranchOrTag.data.id' "$work/current.json")
    apple_list "https://api.appstoreconnect.apple.com/v1/ciProducts/$product_id/workflows?limit=200" "$work/workflows.json"
    workflow_id=$(jq -er --arg name "$release_workflow" '[.[] | select(.attributes.name == $name)] | if length == 1 then .[0].id else error("Expected one Release workflow") end' "$work/workflows.json")
    apple_list "https://api.appstoreconnect.apple.com/v1/ciProducts/$product_id/buildRuns?include=workflow,sourceBranchOrTag&limit=200" "$work/runs.json"
    jq --arg workflow "$workflow_id" --arg ref "$reference_id" --arg commit "$CI_COMMIT" '
        [.[] | select(.relationships.workflow.data.id == $workflow
            and .relationships.sourceBranchOrTag.data.id == $ref
            and .attributes.sourceCommit.commitSha == $commit
            and .attributes.executionProgress == "COMPLETE"
            and .attributes.completionStatus == "SUCCEEDED"
            and .attributes.isPullRequestBuild != true)]' "$work/runs.json" > "$work/matches.json"
    [[ $(jq length "$work/matches.json") == 1 ]] || fail 'Expected one completed Release build for this tag/commit. Wait for Release, or set PUBLISH_SOURCE_BUILD_ID to resolve multiple matches.'
    source_build=$(jq -r '.[0].id' "$work/matches.json")
}

download() {
    local url=$1 output=$2
    # Avoid printing signed storage URLs, including in curl diagnostics.
    [[ $url == https://* && $url != *$'\n'* && $url != *$'\r'* && $url != *'"'* && $url != *\\* ]] || fail 'Invalid HTTPS download URL.'
    printf 'url = "%s"\n' "$url" > "$work/download.curl"
    curl --fail --silent --connect-timeout 30 --max-time 600 --location --proto '=https' --proto-redir '=https' \
        --config "$work/download.curl" --output "$output" || fail 'Download failed; rerun to obtain a fresh URL.'
}

cleanup() {
    if [[ -n ${mounted:-} ]]; then hdiutil detach "$mounted" >/dev/null 2>&1 || true; fi
    rm -rf "$work"
}

extract_app() {
    local archive=$1 destination=$2
    mkdir -p "$destination"
    if unzip -tq "$archive" >/dev/null 2>&1; then
        # Apple's ZIP is trusted, but reject paths that leave the extraction directory.
        unzip -Z1 "$archive" | awk '/^\// || /\\/ || /(^|\/)\.\.(\/|$)/ {exit 1}' || fail 'Unsafe ZIP paths.'
        ditto -x -k "$archive" "$destination"
    else
        [[ -z ${mounted:-} ]] || fail 'Cannot mount two disk images.'
        hdiutil attach "$archive" -readonly -nobrowse -mountpoint "$destination" >/dev/null
        mounted=$destination
    fi
    find "$destination" -name '*.app' -prune -name MarkLens.app -print > "$work/apps.txt"
    [[ $(wc -l < "$work/apps.txt" | tr -d ' ') == 1 ]] || fail 'Expected exactly one MarkLens.app in the artifact.'
    IFS= read -r extracted_app < "$work/apps.txt"
}

validate_app() {
    local app=$1 public_key
    [[ $(plist CFBundleIdentifier "$app") == ch.doapp.MarkLens && \
       $(plist CFBundleShortVersionString "$app") == "$version" && \
       $(plist CFBundleVersion "$app") == "$build_number" ]] || fail 'App identity/version does not match the selected Cloud build.'
    [[ $(plist SUFeedURL "$app") == "$feed_url" ]] || fail 'Unexpected Sparkle feed URL.'
    [[ $(plist SURequireSignedFeed "$app" 2>/dev/null || true) != true ]] || fail 'Signed-feed mode needs a different publishing setup.'
    public_key=$(plist SUPublicEDKey "$app")
    [[ $(printf '%s' "$public_key" | openssl base64 -d -A | wc -c | tr -d ' ') == 32 ]] || fail 'App is missing its Sparkle public key.'
    [[ -d $app/Contents/PlugIns/QuickLookPreview_macOS.appex && -d $app/Contents/Frameworks/Sparkle.framework ]] || fail 'Quick Look or Sparkle is missing.'
    codesign --verify --deep --strict "$app"
    codesign --verify --strict -R '=anchor apple generic and certificate leaf[subject.OU] = "P8CC95REUG" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$app"
    xcrun stapler validate "$app"
    spctl --assess --type execute "$app"
}

# A missing release is expected on first publication. Other API errors are fatal.
read_release() {
    if gh api "repos/$repository/releases/tags/$tag" > "$work/release.json" 2> "$work/github-error"; then return; fi
    grep -q 'HTTP 404' "$work/github-error" || { cat "$work/github-error" >&2; fail 'GitHub release lookup failed.'; }
    echo null > "$work/release.json"
}

read_assets() {
    gh api --paginate "repos/$repository/releases/$release_id/assets?per_page=100" | jq -s 'add' > "$work/assets.json"
    asset_id=$(jq -r --arg name "$asset_name" '.[] | select(.name == $name) | .id' "$work/assets.json")
}

# Numeric components sort naturally; stable versions sort after their previews.
# BSD sort on macOS supports -V, including rc2 < rc10.
version_key() {
    local value=${1#v} base suffix major minor patch kind=0
    [[ $value =~ ^[0-9]+(\.[0-9]+){1,2}(-[A-Za-z][A-Za-z0-9]*(\.[A-Za-z0-9]+)*)?$ ]] || fail 'Unsupported release version in feed.'
    base=${value%%-*}; suffix=${value#"$base"}
    if [[ -z $suffix ]]; then kind=1; fi
    IFS=. read -r major minor patch <<< "$base"
    printf '%012s.%012s.%012s.%s.%s' "$major" "$minor" "${patch:-0}" "$kind" "$suffix" | tr ' ' 0
}

require_newer_version() {
    local new_key old_key newest
    new_key=$(version_key "$1")
    old_key=$(version_key "$2")
    newest=$(printf '%s\n%s\n' "$old_key" "$new_key" | LC_ALL=C sort -V | tail -n 1)
    [[ $new_key != "$old_key" && $newest == "$new_key" ]] || fail 'Release versions must advance across Stable and Preview.'
}

# Feed publication is a non-forced Git ref update. A concurrent publisher causes
# a conflict and a safe retry, retaining both releases and all previous entries.
read_feed() {
    gh api repos/$repository/git/ref/heads/gh-pages > "$work/feed-ref.json"
    feed_head=$(jq -r .object.sha "$work/feed-ref.json")
    feed_tree=$(gh api "repos/$repository/git/commits/$feed_head" --jq .tree.sha)
    gh api "repos/$repository/contents/updates/appcast.xml?ref=$feed_head" --jq .content | \
        tr -d '\n' | openssl base64 -d -A > "$updates/appcast.xml"
    xmllint --nonet --noout "$updates/appcast.xml"
    [[ $(xml 'count(/rss/channel)' "$updates/appcast.xml") == 1 ]] || fail 'Invalid existing update feed.'
    local published_url existing_build existing_version
    published_url=$(xml "string(/rss/channel/item[*[local-name()='version']='$build_number']/enclosure/@url)" "$updates/appcast.xml")
    if [[ $published_url == "$asset_url" ]]; then
        existing_version=$(xml "string(/rss/channel/item[*[local-name()='version']='$build_number']/*[local-name()='shortVersionString'])" "$updates/appcast.xml")
        [[ $existing_version == "${tag#v}" ]] || fail 'This build already has different release metadata.'
    else
        existing_build=$(xml "count(/rss/channel/item[not(number(*[local-name()='version']) < $build_number)])" "$updates/appcast.xml")
        [[ $existing_build == 0 ]] || fail 'Build numbers must increase; do not replace a published build.'
        [[ $(xml "count(/rss/channel/item[enclosure/@url='$asset_url'])" "$updates/appcast.xml") == 0 ]] || fail 'This tag already has another app build.'
        local item_count item_index old_version
        item_count=$(xml 'count(/rss/channel/item)' "$updates/appcast.xml")
        for ((item_index=1; item_index<=item_count; item_index++)); do
            old_version=$(xml "string(/rss/channel/item[$item_index]/*[local-name()='shortVersionString'])" "$updates/appcast.xml")
            require_newer_version "$tag" "$old_version"
        done
    fi
}

sparkle() {
    local tool=$1; shift
    if [[ -n ${SPARKLE_PRIVATE_KEY:-} ]]; then
        printf '%s\n' "$SPARKLE_PRIVATE_KEY" | "$tools/$tool" --ed-key-file - "$@"
    else
        "$tools/$tool" --account ch.doapp.MarkLens "$@"
    fi
}

write_stylesheet() {
    cat > "$work/version.xsl" <<'XSL'
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <xsl:output method="xml" encoding="UTF-8"/>
  <xsl:param name="build"/><xsl:param name="tag"/>
  <xsl:template match="@*|node()"><xsl:copy><xsl:apply-templates select="@*|node()"/></xsl:copy></xsl:template>
  <xsl:template match="item/sparkle:shortVersionString|item/title">
    <xsl:choose><xsl:when test="../sparkle:version=$build">
      <xsl:copy><xsl:if test="self::title">MarkLens </xsl:if><xsl:value-of select="$tag"/></xsl:copy>
    </xsl:when><xsl:otherwise><xsl:copy><xsl:apply-templates select="@*|node()"/></xsl:copy></xsl:otherwise></xsl:choose>
  </xsl:template>
</xsl:stylesheet>
XSL
}

generate_feed() {
    local signature
    sparkle generate_appcast --maximum-deltas 0 --maximum-versions 0 --versions "$build_number" \
        --download-url-prefix "${asset_url%/*}/" --release-notes-url-prefix "${feed_url%/*}/" ${channel_arguments[@]+"${channel_arguments[@]}"} "$updates"
    xsltproc --nonet --stringparam build "$build_number" --stringparam tag "${tag#v}" \
        "$work/version.xsl" "$updates/appcast.xml" > "$work/appcast.xml"
    mv "$work/appcast.xml" "$updates/appcast.xml"
    local item="/rss/channel/item[*[local-name()='version']='$build_number']"
    [[ $(xml "count($item)" "$updates/appcast.xml") == 1 ]] || fail 'Sparkle did not generate exactly one update.'
    [[ $(xml "string($item/enclosure/@url)" "$updates/appcast.xml") == "$asset_url" ]] || fail 'Generated update URL differs from the upload.'
    [[ $(xml "string($item/enclosure/@length)" "$updates/appcast.xml") == "$(wc -c < "$archive" | tr -d ' ')" ]] || fail 'Generated archive size is wrong.'
    [[ $(xml "string($item/*[local-name()='channel'])" "$updates/appcast.xml") == "$channel" ]] || fail 'Generated update channel is wrong.'
    signature=$(xml "string($item/enclosure/@*[local-name()='edSignature'])" "$updates/appcast.xml")
    [[ -n $signature ]] || fail 'Sparkle did not sign the archive; check the signing key.'
    sparkle sign_update --verify "$archive" "$signature"
}

publish_feed() {
    local path blob entries='[]' tree commit
    for path in updates/appcast.xml "updates/$notes_name" .nojekyll; do
        case "$path" in
            updates/appcast.xml) cp "$updates/appcast.xml" "$work/blob" || return 1 ;;
            updates/*) cp "$updates/$notes_name" "$work/blob" || return 1 ;;
            .nojekyll) : > "$work/blob" || return 1 ;;
        esac
        openssl base64 -A -in "$work/blob" | jq -Rs '{encoding:"base64",content:.}' > "$work/blob.json" || return 1
        blob=$(gh api --method POST "repos/$repository/git/blobs" --input "$work/blob.json" --jq .sha) || return 1
        entries=$(jq -nc --argjson entries "$entries" --arg path "$path" --arg sha "$blob" \
            '$entries + [{path:$path,mode:"100644",type:"blob",sha:$sha}]') || return 1
    done
    jq -n --arg base "$feed_tree" --argjson entries "$entries" '{base_tree:$base,tree:$entries}' > "$work/tree.json" || return 1
    tree=$(gh api --method POST "repos/$repository/git/trees" --input "$work/tree.json" --jq .sha) || return 1
    jq -n --arg tree "$tree" --arg parent "$feed_head" \
        '{message:"Publish signed MarkLens update",tree:$tree,parents:[$parent]}' > "$work/commit.json" || return 1
    commit=$(gh api --method POST "repos/$repository/git/commits" --input "$work/commit.json" --jq .sha) || return 1
    jq -n --arg sha "$commit" '{sha:$sha,force:false}' > "$work/ref.json" || return 1
    gh api --method PATCH "repos/$repository/git/refs/heads/gh-pages" --input "$work/ref.json" > /dev/null
}

main() {
    local check_only=${PUBLISH_VALIDATE_ONLY:-0} source_build=${PUBLISH_SOURCE_BUILD_ID:-}
    if [[ ${1:-} == --help || ${1:-} == -h ]]; then
        echo 'Usage: bash ci_scripts/run_publish.sh [--check] [XCODE_CLOUD_BUILD_URL_OR_UUID]'
        echo 'Without a URL, the script asks for it. --check validates without publishing.'
        return
    fi
    if [[ ${1:-} == --check ]]; then check_only=1; shift; fi
    [[ $# -le 1 ]] || fail 'Pass one Cloud build URL or UUID.'
    [[ $(uname -s) == Darwin ]] || fail 'Run this script on macOS.'
    export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
    if [[ -z ${CI_BUILD_ID:-} && -f ${MARKLENS_PUBLISH_CONFIG:-$HOME/.config/marklens/publish.env} ]]; then
        # One private configuration file for persistent credentials only.
        # shellcheck disable=SC1090
        source "${MARKLENS_PUBLISH_CONFIG:-$HOME/.config/marklens/publish.env}"
    fi
    if [[ -n ${CI_BUILD_ID:-} ]]; then
        [[ ${CI_XCODE_SCHEME:-} == Publish && ${CI_XCODEBUILD_ACTION:-} == build ]] || fail 'Configure a Build action using the Publish scheme.'
        local missing_tools=() dependency
        for dependency in gh jq; do
            if ! command -v "$dependency" >/dev/null; then missing_tools+=("$dependency"); fi
        done
        if [[ ${#missing_tools[@]} -gt 0 ]]; then
            command -v brew >/dev/null || fail 'Homebrew is needed to install gh and jq in Cloud.'
            step 'Installing missing Cloud command-line tools'
            HOMEBREW_NO_AUTO_UPDATE=1 brew install "${missing_tools[@]}"
        fi
    fi
    for tool in gh jq openssl xxd curl xmllint xsltproc ditto codesign xcrun spctl hdiutil unzip shasum; do
        command -v "$tool" >/dev/null || fail "Missing $tool. Install GitHub CLI/jq with: brew install gh jq"
    done
    if [[ -n ${GITHUB_RELEASE_TOKEN:-} ]]; then export GH_TOKEN=$GITHUB_RELEASE_TOKEN; fi
    gh auth status >/dev/null 2>&1 || fail 'Sign in once using: gh auth login'
    # Apple's standard key filename already contains its key ID.
    if [[ -z ${APP_STORE_CONNECT_API_KEY_ID:-} && ${APP_STORE_CONNECT_API_KEY_PATH:-} =~ AuthKey_([A-Za-z0-9]+)\.p8$ ]]; then
        APP_STORE_CONNECT_API_KEY_ID=${BASH_REMATCH[1]}
    fi
    : "${APP_STORE_CONNECT_API_KEY_ID:?Set APP_STORE_CONNECT_API_KEY_ID or use the standard AuthKey_ID.p8 filename}"
    : "${APP_STORE_CONNECT_API_ISSUER_ID:?Set APP_STORE_CONNECT_API_ISSUER_ID in your private configuration}"
    if [[ $check_only != 1 ]]; then check_only=${PUBLISH_VALIDATE_ONLY:-0}; fi
    [[ $check_only == 0 || $check_only == 1 ]] || fail 'PUBLISH_VALIDATE_ONLY must be 0 or 1.'
    source_build=${1:-${PUBLISH_SOURCE_BUILD_ID:-}}
    if [[ -n ${CI_BUILD_ID:-} ]]; then
        [[ ${CI_XCODE_SCHEME:-} == Publish && ${CI_XCODEBUILD_ACTION:-} == build ]] || fail 'Configure a Build action using the Publish scheme.'
        [[ $check_only == 1 || -n ${SPARKLE_PRIVATE_KEY:-} ]] || fail 'Configure SPARKLE_PRIVATE_KEY for Cloud publication.'
    fi
    if [[ -z $source_build && -z ${CI_BUILD_ID:-} ]]; then
        if [[ -t 0 ]]; then read -r -p 'Completed Xcode Cloud build URL or UUID: ' source_build
        else source_build=$(osascript -e 'text returned of (display dialog "Paste the completed Release build URL or UUID:" default answer "" with title "Publish MarkLens")'); fi
    fi
    source_build=${source_build%/}; source_build=${source_build##*/}
    umask 077
    work=$(mktemp -d "${TMPDIR:-/tmp}/marklens-publish.XXXXXX")
    mounted=''
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [[ -n ${APP_STORE_CONNECT_API_KEY_PATH:-} ]]; then cp "$APP_STORE_CONNECT_API_KEY_PATH" "$work/AuthKey.p8"
    else printf '%s\n' "${APP_STORE_CONNECT_API_PRIVATE_KEY:?Configure the Apple .p8 key path or contents}" > "$work/AuthKey.p8"; fi

    if [[ -z $source_build ]]; then
        [[ ${CI_GIT_REF:-} == refs/tags/* && ${CI_COMMIT:-} =~ ^[0-9a-fA-F]{40}$ ]] || fail 'Start Publish on the release tag, or set PUBLISH_SOURCE_BUILD_ID explicitly.'
        find_release_build
    fi
    [[ $source_build =~ ^[0-9A-Fa-f-]{36}$ ]] || fail 'Expected a Cloud build UUID or its App Store Connect URL.'
    [[ $source_build != "${CI_BUILD_ID:-}" ]] || fail 'Select the Release build, not this Publish build.'

    step '1/7 Read the selected completed Release build'
    apple_get "https://api.appstoreconnect.apple.com/v1/ciBuildRuns/$source_build?include=workflow,product,sourceBranchOrTag" "$work/build.json"
    jq -e '.data.attributes | .executionProgress == "COMPLETE" and .completionStatus == "SUCCEEDED" and .isPullRequestBuild != true' "$work/build.json" > /dev/null || fail 'Wait for Release and native notarization to finish successfully.'
    local workflow_id ref_id product_id commit tag version build_number
    workflow_id=$(jq -r '.data.relationships.workflow.data.id' "$work/build.json")
    ref_id=$(jq -r '.data.relationships.sourceBranchOrTag.data.id' "$work/build.json")
    product_id=$(jq -r '.data.relationships.product.data.id' "$work/build.json")
    jq -e --arg id "$workflow_id" --arg name "$release_workflow" \
        '.included[] | select(.type == "ciWorkflows" and .id == $id) | .attributes.name == $name' "$work/build.json" > /dev/null || fail "Select a build from '$release_workflow'."
    tag=$(jq -er --arg id "$ref_id" '.included[] | select(.type == "scmGitReferences" and .id == $id and .attributes.kind == "TAG") | .attributes.canonicalName' "$work/build.json")
    [[ $tag == refs/tags/* ]] || fail 'Release must have built a tag.'
    tag=${tag#refs/tags/}
    [[ $tag =~ ^v?[0-9]+(\.[0-9]+){1,2}(-[A-Za-z][A-Za-z0-9]*(\.[A-Za-z0-9]+)*)?$ && $tag != *-test* ]] || fail 'Unsupported release tag.'
    version=${tag#v}; version=${version%%-*}
    build_number=$(jq -r '.data.attributes.number' "$work/build.json")
    commit=$(jq -r '.data.attributes.sourceCommit.commitSha // empty' "$work/build.json")
    [[ $build_number =~ ^[1-9][0-9]*$ && $commit =~ ^[0-9a-fA-F]{40}$ ]] || fail 'Apple did not return this build number/source commit.'
    apple_get "https://api.appstoreconnect.apple.com/v1/ciProducts/$product_id/app" "$work/product.json"
    [[ $(jq -r .data.attributes.bundleId "$work/product.json") == ch.doapp.MarkLens ]] || fail 'Not a MarkLens build.'
    [[ $(gh api "repos/$repository/commits/$tag" --jq .sha) == "$commit" ]] || fail 'The release tag moved after Cloud built it.'
    echo "$tag — original app build $build_number — commit $commit"

    step '2/7 Download the stapled, notarized Apple artifact'
    apple_list "https://api.appstoreconnect.apple.com/v1/ciBuildRuns/$source_build/actions?limit=200" "$work/actions.json"
    : > "$work/artifacts.items"
    local action artifact_id
    while IFS= read -r action; do
        apple_list "https://api.appstoreconnect.apple.com/v1/ciBuildActions/$action/artifacts?limit=200" "$work/artifacts.json"
        jq -c '.[] | select(.attributes.fileType == "STAPLED_NOTARIZED_ARCHIVE")' "$work/artifacts.json" >> "$work/artifacts.items"
    done < <(jq -r '.[].id' "$work/actions.json")
    jq -s 'unique_by(.id)' "$work/artifacts.items" > "$work/notarized.json"
    [[ $(jq length "$work/notarized.json") == 1 ]] || fail 'Expected one notarized artifact. Wait for Apple artifact processing and retry.'
    artifact_id=$(jq -r '.[0].id' "$work/notarized.json")
    apple_get "https://api.appstoreconnect.apple.com/v1/ciArtifacts/$artifact_id" "$work/artifact.json"
    download "$(jq -r .data.attributes.downloadUrl "$work/artifact.json")" "$work/cloud-artifact"
    [[ $(wc -c < "$work/cloud-artifact" | tr -d ' ') == "$(jq -r .data.attributes.fileSize "$work/artifact.json")" ]] || fail 'Incomplete artifact download.'

    step '3/7 Validate the app signature, version, staple and Gatekeeper acceptance'
    extract_app "$work/cloud-artifact" "$work/cloud-app"
    local app=$extracted_app
    validate_app "$app"
    if [[ $check_only == 1 ]]; then echo 'Validation passed. Nothing published.'; return; fi

    step '4/7 Prepare the ZIP and release notes'
    local updates=$work/update archive asset_name asset_url release_id asset_id notes_name
    mkdir "$updates"
    asset_name=MarkLens-$tag.zip; archive=$updates/$asset_name
    asset_url=https://github.com/$repository/releases/download/$tag/$asset_name
    notes_name=MarkLens-$tag.md
    read_release
    release_id=$(jq -r '.id // empty' "$work/release.json")
    asset_id=''
    if [[ -n $release_id ]]; then
        read_assets
        [[ $(jq -r .draft "$work/release.json") == false ]] || fail 'Existing release is a draft.'
    fi
    if [[ -n $asset_id ]]; then
        gh release download "$tag" --repo "$repository" --pattern "$asset_name" --dir "$updates"
        extract_app "$archive" "$work/existing-app"
        validate_app "$extracted_app"
        diff -rq "$app" "$extracted_app" >/dev/null || fail 'Existing ZIP contains a different app. Use a new release tag.'
        # File bytes and symlink targets must match; compare modes as well.
        (cd "$app" && find . -exec stat -f '%N %p %Y' {} \; | LC_ALL=C sort) > "$work/source-modes"
        (cd "$extracted_app" && find . -exec stat -f '%N %p %Y' {} \; | LC_ALL=C sort) > "$work/existing-modes"
        cmp -s "$work/source-modes" "$work/existing-modes" || fail 'Existing ZIP has different file permissions.'
    else ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"; fi
    gh api "repos/$repository/contents/CHANGELOG.md?ref=$commit" --jq .content | tr -d '\n' | openssl base64 -d -A > "$work/changelog.md"
    awk -v version="$version" '
        /^## / {
            heading=$0; sub(/^## +/,"",heading); sub(/ *\(Unreleased\) *$/,"",heading)
            gsub(/[][]/,"",heading)
            if (heading==version) found=1
            if (found && heading ~ /^[0-9]+\.[0-9]+(\.[0-9]+)?$/) print "## Version " heading
            next
        }
        found {print}
        END {if (!found) exit 1}
    ' "$work/changelog.md" > "$updates/$notes_name" || fail 'Source changelog has no section for this release.'
    awk '/^## Version / {if (found) exit; found=1; next} found {print}' "$updates/$notes_name" > "$work/release-notes.md"

    step '5/7 Download the pinned Sparkle tools and sign the update'
    download "$sparkle_download" "$work/Sparkle.zip"
    [[ $(checksum "$work/Sparkle.zip") == "$sparkle_checksum" ]] || fail 'Sparkle 2.10.0 tool checksum does not match.'
    ditto -x -k "$work/Sparkle.zip" "$work/sparkle"
    local tools=$work/sparkle/bin channel='' channel_arguments=() preview=false
    if [[ ${tag#v} == *-* ]]; then channel=preview; channel_arguments=(--channel preview); preview=true; fi
    if [[ -n $release_id ]]; then
        [[ $(jq -r .prerelease "$work/release.json") == "$preview" ]] || fail 'Existing release has a different Stable/Preview channel.'
    fi
    write_stylesheet
    local feed_head feed_tree
    read_feed
    generate_feed

    step '6/7 Publish the immutable ZIP on GitHub'
    if [[ -z $release_id ]]; then
        local release_arguments=(--verify-tag --target "$commit" --title "MarkLens $tag" --notes-file "$work/release-notes.md")
        if [[ $preview == true ]]; then release_arguments+=(--prerelease); else release_arguments+=(--latest); fi
        gh release create "$tag" --repo "$repository" "${release_arguments[@]}"
    fi
    if [[ -z $asset_id ]]; then gh release upload "$tag" "$archive" --repo "$repository"; fi
    mkdir "$work/upload-check"
    gh release download "$tag" --repo "$repository" --pattern "$asset_name" --dir "$work/upload-check"
    cmp -s "$archive" "$work/upload-check/$asset_name" || fail 'GitHub ZIP differs from the signed archive.'

    step '7/7 Publish the feed after the ZIP is ready'
    local attempt
    for attempt in 1 2 3; do
        if publish_feed; then echo "Published $tag (build $build_number). Check the GitHub Pages deployment."; return; fi
        [[ $attempt != 3 ]] || fail 'Feed publication failed. The ZIP is safe to reuse; rerun this script.'
        read_feed
        generate_feed
    done
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi

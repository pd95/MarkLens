#!/bin/bash
# Offline shell tests: use the real OpenSSL and macOS XML tools; no remote writes.
set -euo pipefail
repository_root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$repository_root/ci_scripts/run_publish.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/marklens-bash-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
updates=$work/update
mkdir "$updates"
feed_head=old-head; feed_tree=old-tree
build_number=81; tag=v1.10.0-rc2
asset_url=https://github.com/pd95/MarkLens/releases/download/$tag/MarkLens-$tag.zip
archive=$updates/MarkLens-$tag.zip
notes_name=MarkLens-$tag.md
printf archive > "$archive"
printf '## Version 1.10.0\nNotes\n' > "$updates/$notes_name"
printf '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><title>Previous</title><sparkle:version>80</sparkle:version><sparkle:shortVersionString>1.10.0-rc1</sparkle:shortVersionString><enclosure url="https://example.test/old.zip"/></item></channel></rss>' > "$work/remote.xml"

# Replace only the transport, leaving XML handling and publication policy real.
gh() {
    printf '%s\n' "$*" >> "$work/gh.log"
    case "$*" in
        *git/ref/heads/gh-pages*) echo '{"object":{"sha":"head"}}' ;;
        *git/commits/head*) echo tree ;;
        *contents/updates/appcast.xml*) openssl base64 -A -in "$work/remote.xml" ;;
        *git/blobs*) [[ ${fail_blob:-0} != 1 ]] || return 1; echo blob ;;
        *git/trees*) echo tree ;;
        *git/commits*) echo commit ;;
        *git/refs/heads/gh-pages*) [[ ${fail_ref:-0} != 1 ]] || return 1; echo '{}' ;;
        *) echo "Unexpected fake gh: $*" >&2; return 1 ;;
    esac
}
read_feed
[[ $feed_head == head && $feed_tree == tree ]]
echo 'PASS: existing feed read and increasing build accepted'
if (build_number=80; read_feed) > "$work/error" 2>&1; then fail 'Duplicate build accepted.'; fi
if (build_number=79; read_feed) > "$work/error" 2>&1; then fail 'Older build accepted.'; fi
echo 'PASS: duplicate and older builds rejected'
require_newer_version v1.10.0-rc10 v1.10.0-rc2
require_newer_version v1.10.0 v1.10.0-rc10
require_newer_version v1.10.0 v1.9.9
if (require_newer_version v1.9.2 v1.10.0-rc1) > "$work/error" 2>&1; then fail 'Marketing version downgrade accepted.'; fi
if (require_newer_version v1.10.0-rc2 v1.10.0) > "$work/error" 2>&1; then fail 'Preview after stable accepted.'; fi
if (require_newer_version v1.10.0-rc2 v1.10.0-rc2) > "$work/error" 2>&1; then fail 'Equal release version accepted.'; fi
if (tag=v1.9.2; read_feed) > "$work/error" 2>&1; then fail 'New build with older release version accepted.'; fi
echo 'PASS: Stable/Preview versions advance together, including numeric rc ordering' 
original_feed=$(cat "$work/remote.xml")
printf broken > "$work/remote.xml"
if (read_feed) > "$work/error" 2>&1; then fail 'Malformed XML accepted.'; fi
printf '%s' "$original_feed" > "$work/remote.xml"
echo 'PASS: malformed feed rejected'

# A publisher's signing key must go to stdin, never a command argument.
tools=$work/bin
mkdir "$tools"
cat > "$tools/sign_update" <<'TOOL'
#!/bin/bash
printf '%s\n' "$*" > "$SIGN_LOG"
if [[ $1 == --ed-key-file ]]; then cat > "$SIGN_INPUT"; fi
TOOL
chmod +x "$tools/sign_update"
export SIGN_LOG=$work/sign.log SIGN_INPUT=$work/sign.input
SPARKLE_PRIVATE_KEY=private-test-value sparkle sign_update --verify test.zip signature
[[ $(cat "$SIGN_LOG") == '--ed-key-file - --verify test.zip signature' ]]
[[ $(cat "$SIGN_INPUT") == private-test-value ]]
sparkle sign_update --verify test.zip signature
[[ $(cat "$SIGN_LOG") == '--account ch.doapp.MarkLens --verify test.zip signature' ]]
echo 'PASS: secret key uses stdin and local signing uses the correct Keychain account'

# Exercise generation with actual xmllint/xsltproc, substituting only Sparkle.
generated_url=$asset_url
sparkle() {
    case "$1" in
        generate_appcast)
            cat > "$updates/appcast.xml" <<XML
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
<item><title>Original</title><sparkle:version>81</sparkle:version><sparkle:shortVersionString>1.10.0</sparkle:shortVersionString><sparkle:channel>preview</sparkle:channel><enclosure url="$generated_url" length="7" sparkle:edSignature="signature"/></item>
<item><title>Previous</title><sparkle:version>80</sparkle:version><sparkle:shortVersionString>1.10.0-rc1</sparkle:shortVersionString></item>
</channel></rss>
XML
            ;;
        sign_update) [[ $2 == --verify && $3 == "$archive" && $4 == signature ]] ;;
        *) return 1 ;;
    esac
}
channel=preview; channel_arguments=(--channel preview)
write_stylesheet
generate_feed
[[ $(xml "string(/rss/channel/item[*[local-name()='version']='81']/*[local-name()='shortVersionString'])" "$updates/appcast.xml") == 1.10.0-rc2 ]]
[[ $(xml "string(/rss/channel/item[*[local-name()='version']='80']/title)" "$updates/appcast.xml") == Previous ]]
echo 'PASS: generated metadata corrected and old feed entries retained'
if (asset_url=https://example.test/wrong; generate_feed) > "$work/error" 2>&1; then fail 'Wrong update URL accepted.'; fi
if (channel=''; channel_arguments=(); generate_feed) > "$work/error" 2>&1; then fail 'Wrong release channel accepted.'; fi
printf 'longer archive' > "$archive"
if (generate_feed) > "$work/error" 2>&1; then fail 'Wrong archive length accepted.'; fi
printf archive > "$archive"
echo 'PASS: wrong URL, channel and archive size rejected'

# Git object failures must stop publication even when the function is inside if.
: > "$work/gh.log"
if fail_blob=1 publish_feed; then fail 'Blob creation failure ignored.'; fi
if grep -q 'git/refs/heads/gh-pages' "$work/gh.log"; then fail 'Ref changed after blob failure.'; fi
if fail_ref=1 publish_feed; then fail 'Concurrent ref update failure ignored.'; fi
publish_feed
jq -e '.force == false and .sha == "commit"' "$work/ref.json" > /dev/null
jq -e '.parents == ["head"]' "$work/commit.json" > /dev/null
echo 'PASS: object errors and concurrent ref updates fail safely; updates never force-push'

# Sign a real Apple JWT using OpenSSL, inspecting its header and claims.
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$work/AuthKey.p8" >/dev/null 2>&1
APP_STORE_CONNECT_API_KEY_ID=KEYID
APP_STORE_CONNECT_API_ISSUER_ID=ISSUER
curl() {
    printf '%s\n' "$*" > "$work/curl.log"
    echo '{}' > "$work/api.json"
}
apple_get https://api.appstoreconnect.apple.com/v1/ciBuildRuns/test "$work/api.json"
jwt=$(sed 's/Authorization: Bearer //' "$work/apple-header")
header=${jwt%%.*}; rest=${jwt#*.}; claims=${rest%%.*}
decode() {
    local text=$1
    while [[ $((${#text} % 4)) != 0 ]]; do text=$text=; done
    printf '%s' "$text" | tr '_-' '/+' | openssl base64 -d -A
}
decode "$header" | jq -e '.alg == "ES256" and .kid == "KEYID"' > /dev/null
decode "$claims" | jq -e '.iss == "ISSUER" and .aud == "appstoreconnect-v1" and .exp > .iat' > /dev/null
[[ $(decode "${rest#*.}" | wc -c | tr -d ' ') == 64 ]]
printf '%s.%s' "$header" "$claims" > "$work/message"
openssl pkey -in "$work/AuthKey.p8" -pubout -out "$work/public.pem" >/dev/null 2>&1
openssl dgst -sha256 -verify "$work/public.pem" -signature "$work/signature.der" "$work/message" >/dev/null
if grep -q 'Bearer\|private-test-value' "$work/curl.log"; then fail 'Credential leaked to command arguments.'; fi
if (apple_get https://untrusted.test/api "$work/api.json") > "$work/error" 2>&1; then fail 'Apple API token forwarded to another host.'; fi
echo 'PASS: real ES256 JWT has correct claims and no bearer token in curl arguments'

# codesign -R accepts inline text only with a leading '='; otherwise it opens
# the requirement as a filename. Exercise validate_app's actual invocation.
(
    app=$work/MarkLens.app
    mkdir -p "$app/Contents/PlugIns/QuickLookPreview_macOS.appex" "$app/Contents/Frameworks/Sparkle.framework"
    version=1.10.0
    plist() {
        case "$1" in
            CFBundleIdentifier) echo ch.doapp.MarkLens ;;
            CFBundleShortVersionString) echo 1.10.0 ;;
            CFBundleVersion) echo 81 ;;
            SUFeedURL) echo "$feed_url" ;;
            SURequireSignedFeed) echo false ;;
            SUPublicEDKey) echo AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= ;;
            *) return 1 ;;
        esac
    }
    codesign() {
        while [[ $# -gt 0 ]]; do
            if [[ $1 == -R ]]; then
                [[ $2 == '=anchor apple generic'* && $2 == *P8CC95REUG* && $2 == *1.2.840.113635.100.6.1.13* ]] || return 2
                echo checked > "$work/requirement-checked"
                break
            fi
            shift
        done
    }
    xcrun() { [[ $1 == stapler && $2 == validate ]]; }
    spctl() { [[ $1 == --assess ]]; }
    validate_app "$app"
    [[ -f $work/requirement-checked ]]
)
echo 'PASS: Developer ID verification passes an inline requirement, not a filename'

# Cloud selection must match the reference, commit and Release workflow together.
CI_BUILD_ID=publish-run
CI_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
apple_get() {
    cat > "$2" <<'JSON'
{"data":{"relationships":{"product":{"data":{"id":"product"}},"sourceBranchOrTag":{"data":{"id":"release-tag"}}}}}
JSON
}
apple_list() {
    if [[ $1 == */workflows* ]]; then
        echo '[{"id":"release-workflow","attributes":{"name":"Release (macOS)"}}]' > "$2"
    else
        jq -n --arg commit "$CI_COMMIT" --arg ambiguous "${ambiguous:-0}" '
            {id:"expected-release",relationships:{workflow:{data:{id:"release-workflow"}},sourceBranchOrTag:{data:{id:"release-tag"}}},
             attributes:{sourceCommit:{commitSha:$commit},executionProgress:"COMPLETE",completionStatus:"SUCCEEDED",isPullRequestBuild:false}} as $run
            | [$run, ($run | .id="running" | .attributes.executionProgress="RUNNING"),
                ($run | .id="publisher" | .relationships.workflow.data.id="publish-workflow"),
                ($run | .id="other-commit" | .attributes.sourceCommit.commitSha="other"),
                ($run | .id="other-tag" | .relationships.sourceBranchOrTag.data.id="another-tag")]
              + (if $ambiguous == "1" then [($run | .id="another-release")] else [] end)' > "$2"
    fi
}
find_release_build
[[ $source_build == expected-release ]]
if (ambiguous=1; find_release_build) > "$work/error" 2>&1; then fail 'Ambiguous Release build selected.'; fi
echo 'PASS: Cloud selection matches exact tag/commit/workflow and rejects ambiguity'

echo 'Bash publisher checks passed; real Apple artifact retrieval and macOS validation remain integration checks.'

#!/bin/bash
# Create the feed branch without checking out files or touching the working index.
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repository_root"

if [[ "${1:-}" != "" && "${1:-}" != "--dry-run" ]]; then
    echo "Usage: bash ci_scripts/bootstrap_update_pages.sh [--dry-run]" >&2
    exit 1
fi

if git ls-remote --exit-code --heads origin refs/heads/gh-pages >/dev/null; then
    echo "gh-pages already exists. Select it in GitHub Settings > Pages."
    exit 0
else
    lookup_status=$?
    if [[ "$lookup_status" != "2" ]]; then
        echo "Could not check the remote branch. Check GitHub authentication and try again." >&2
        exit 1
    fi
fi

bootstrap_directory="$(mktemp -d "${TMPDIR:-/tmp}/marklens-pages.XXXXXX")"
trap 'rm -rf "$bootstrap_directory"' EXIT
export GIT_INDEX_FILE="$bootstrap_directory/index"
git read-tree --empty

nojekyll_blob="$(git hash-object -w --stdin </dev/null)"
feed_blob="$(git hash-object -w --stdin <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>MarkLens Updates</title>
    <link>https://github.com/pd95/MarkLens/releases</link>
    <description>Signed MarkLens updates will appear here after the first release.</description>
  </channel>
</rss>
XML
)"
git update-index --add --cacheinfo "100644,$nojekyll_blob,.nojekyll"
git update-index --add --cacheinfo "100644,$feed_blob,updates/appcast.xml"
bootstrap_tree="$(git write-tree)"

# Preserve the maintainer's identity; use repository history when no identity is configured.
maintainer_name="$(git config user.name || git log -1 --format=%an)"
maintainer_email="$(git config user.email || git log -1 --format=%ae)"
export GIT_AUTHOR_NAME="$maintainer_name" GIT_COMMITTER_NAME="$maintainer_name"
export GIT_AUTHOR_EMAIL="$maintainer_email" GIT_COMMITTER_EMAIL="$maintainer_email"
bootstrap_commit="$(git commit-tree "$bootstrap_tree" <<'MESSAGE'
Initialize MarkLens update feed

- Add an empty Sparkle appcast for initial Pages setup
- Serve generated files without Jekyll processing

Co-Authored-By: Codex <codex@openai.com>
MESSAGE
)"

if [[ "${1:-}" == "--dry-run" ]]; then
    git show --stat --oneline "$bootstrap_commit"
    echo "Dry run: no local branch or remote ref was changed."
    exit 0
fi

# The empty expected value prevents overwriting a branch created concurrently.
git push --force-with-lease=refs/heads/gh-pages: origin "$bootstrap_commit:refs/heads/gh-pages"
echo "Created gh-pages. In GitHub Settings > Pages, select Deploy from a branch, gh-pages, /(root)."
echo "The feed will be https://pd95.github.io/MarkLens/updates/appcast.xml after deployment."

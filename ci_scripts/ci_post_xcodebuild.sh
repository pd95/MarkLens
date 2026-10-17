#!/bin/zsh
set -euo pipefail

if [[ "${CI_XCODE_SCHEME:-}" == "Publish" ]]; then
    echo "Publish target finished with xcodebuild exit code ${CI_XCODEBUILD_EXIT_CODE:-unknown}."
else
    echo "Release artifacts remain in Xcode Cloud until native notarization completes."
    echo "Run the Publish target separately to publish a completed Release build."
fi

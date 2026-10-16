#!/usr/bin/env python3
"""Request publication, then let the Cloud notarization post-action finish."""
import os
import sys
from cloud_artifact import publication_request
from release_updates import GitHub, ReleaseError


def request_publication(environment=os.environ):
    tag = environment.get("CI_TAG", "").removeprefix("refs/tags/")
    if (environment.get("CI_XCODEBUILD_ACTION") != "archive"
            or environment.get("CI_XCODEBUILD_EXIT_CODE", "1") != "0"
            or not tag or "-test" in tag):
        print("Not a successful release archive; skipping publication request.")
        return
    request = publication_request({"CLOUD_BUILD_ID": environment.get("CI_BUILD_ID", ""),
                                   "CLOUD_BUILD_NUMBER": environment.get("CI_BUILD_NUMBER", ""),
                                   "RELEASE_TAG": tag, "RELEASE_COMMIT": environment.get("CI_COMMIT", "")})
    token = environment.get("GITHUB_RELEASE_TOKEN")
    if not token:
        raise ReleaseError("Configure GITHUB_RELEASE_TOKEN in Xcode Cloud")
    GitHub(environment.get("GITHUB_REPOSITORY", "pd95/MarkLens"), token).request(
        "POST", "dispatches", {"event_type": "publish-notarized-update", "client_payload": request})
    print("Requested GitHub publication. It will wait for Cloud notarization to finish.")


if __name__ == "__main__":
    try:
        request_publication()
    except (ReleaseError, OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)

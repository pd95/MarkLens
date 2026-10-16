#!/usr/bin/env python3
"""Expand Apple's original ZIP on macOS without dropping bundle metadata."""
import os
from pathlib import Path
import plistlib
import sys
import tempfile
from release_updates import ReleaseError, run


def prepare(archive, destination, expected_build, expected_commit):
    with tempfile.TemporaryDirectory(prefix="marklens-cloud-artifact-") as temporary:
        run(["ditto", "-x", "-k", archive, temporary])
        matches = []
        for root, directories, _ in os.walk(temporary):
            if "MarkLens.app" in directories:
                matches.append(Path(root) / "MarkLens.app")
            directories[:] = [name for name in directories if not name.endswith(".app") and name != "__MACOSX"]
        if len(matches) != 1:
            raise ReleaseError("Apple artifact must contain exactly one MarkLens.app")
        app = matches[0]
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        if info.get("CFBundleIdentifier") != "ch.doapp.MarkLens" or str(info.get("CFBundleVersion")) != expected_build:
            raise ReleaseError("Notarized app identity/build does not match the requested release")
        if info.get("MarkLensReleaseCommit") != expected_commit:
            raise ReleaseError("Notarized app commit does not match the requested release")
        run(["codesign", "--verify", "--deep", "--strict", app])
        run(["xcrun", "stapler", "validate", app])
        if destination.exists():
            raise ReleaseError("Refusing to replace an existing app at the publication destination")
        run(["ditto", app, destination])


if __name__ == "__main__":
    try:
        prepare(Path(sys.argv[1]), Path(sys.argv[2]), os.environ["CLOUD_BUILD_NUMBER"], os.environ["RELEASE_COMMIT"])
    except (ReleaseError, OSError, ValueError, KeyError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)

#!/usr/bin/env python3
"""Fetch the same checksum-pinned binary distribution used by the Xcode package."""
import hashlib
from pathlib import Path
import sys
import tempfile
import urllib.request
import subprocess

VERSION = "2.10.0"
CHECKSUM = "17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959"
URL = f"https://github.com/sparkle-project/Sparkle/releases/download/{VERSION}/Sparkle-for-Swift-Package-Manager.zip"


def fetch(destination):
    with urllib.request.urlopen(URL, timeout=120) as response:
        content = response.read()
    if hashlib.sha256(content).hexdigest() != CHECKSUM:
        raise ValueError("Sparkle tools checksum mismatch")
    with tempfile.TemporaryDirectory() as temporary:
        archive = Path(temporary) / "Sparkle.zip"
        archive.write_bytes(content)
        # ditto preserves the executable permissions in the pinned distribution.
        subprocess.run(["ditto", "-x", "-k", str(archive), str(destination)], check=True)
    matches = list(destination.glob("**/bin/generate_appcast"))
    if len(matches) != 1:
        raise ValueError("Cannot locate the pinned Sparkle tools")
    return matches[0].parent


if __name__ == "__main__":
    tools = fetch(Path(sys.argv[1]))
    with open(sys.argv[2], "a") as environment:
        environment.write(f"SPARKLE_BIN_DIR={tools}\n")

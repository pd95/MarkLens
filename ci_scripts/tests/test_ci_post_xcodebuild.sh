#!/bin/bash
set -euo pipefail
repository_root="$(cd "$(dirname "$0")/../.." && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 "$repository_root/ci_scripts/tests/test_release_updates.py"
PYTHONDONTWRITEBYTECODE=1 python3 "$repository_root/ci_scripts/tests/test_notarization.py"
PYTHONDONTWRITEBYTECODE=1 python3 "$repository_root/ci_scripts/tests/test_export.py"

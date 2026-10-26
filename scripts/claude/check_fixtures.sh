#!/bin/bash
# Regenerate the Swift parity fixtures and fail if they differ from the
# committed ones: a Python behaviour change must update them in the same commit.
# 2026-10-26. Usage: scripts/claude/check_fixtures.sh
set -euo pipefail
root="$(CDPATH= cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
uv run python scripts/claude/gen_fixtures.py
git diff --exit-code -- swift/Tests/ZIrisCoreTests/Fixtures
untracked="$(git ls-files --others --exclude-standard -- swift/Tests/ZIrisCoreTests/Fixtures)"
if [ -n "$untracked" ]; then
	echo "untracked fixtures: $untracked" >&2
	exit 1
fi

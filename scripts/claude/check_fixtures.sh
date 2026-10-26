#!/bin/bash
# Regenerate the Swift parity fixtures and emoji table and fail if they differ
# from the committed ones: a Python behaviour change must update them in the
# same commit.
# 2026-10-26. Usage: scripts/claude/check_fixtures.sh
set -euo pipefail
root="$(CDPATH= cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
uv run python scripts/claude/gen_fixtures.py
uv run python scripts/claude/dump_emoji.py
generated=(swift/Tests/ZIrisCoreTests/Fixtures swift/Sources/ZIrisCore/Resources)
git diff --exit-code -- "${generated[@]}"
untracked="$(git ls-files --others --exclude-standard -- "${generated[@]}")"
if [ -n "$untracked" ]; then
	echo "untracked fixtures: $untracked" >&2
	exit 1
fi

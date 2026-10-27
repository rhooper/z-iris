#!/bin/bash
# The app's version, from git tags (vMAJOR.MINOR.PATCH). 2026-10-27.
# Usage: version.sh          the current version (the latest tag's; 0.0.0 before any)
#        version.sh next     the next release: the latest tag bumped by the
#                            largest change since it. A commit message with a
#                            "Semver: major" trailer or "BREAKING CHANGE" is
#                            major, "Semver: minor" is minor, anything else patch.
#        version.sh build    the build number: commits on HEAD
set -euo pipefail
CDPATH= cd "$(dirname "$0")/../.." >/dev/null
tag="$(git describe --tags --match 'v[0-9]*.[0-9]*.[0-9]*' --abbrev=0 2>/dev/null || true)"
current="${tag#v}"
current="${current:-0.0.0}"

case "${1:-}" in
"")
	echo "$current"
	;;
build)
	git rev-list --count HEAD
	;;
next)
	range="${tag:+$tag..}HEAD"
	messages="$(git log --format='%B%x00' "$range")"
	[ -n "$messages" ] || { echo "no commits since $tag" >&2; exit 1; }
	IFS=. read -r major minor patch <<<"$current"
	if grep -qiE '^Semver: *major$|BREAKING CHANGE' <<<"$messages"; then
		echo "$((major + 1)).0.0"
	elif grep -qiE '^Semver: *minor$' <<<"$messages"; then
		echo "$major.$((minor + 1)).0"
	else
		echo "$major.$minor.$((patch + 1))"
	fi
	;;
*)
	echo "usage: version.sh [next|build]" >&2
	exit 2
	;;
esac

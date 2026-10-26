#!/bin/bash
# Build self-contained z-iris.app and z-iris-priority.app for publishing: each
# carries its own Python (uv's relocatable standalone CPython 3.13) and the
# installed z-iris package, with nothing pointing back at this checkout.
# Date: 2026-10-21
# Usage: build_release.sh [out-dir]          (default ./dist)
# Env:
#   Z_IRIS_SIGN_IDENTITY     "Developer ID Application: ..." or its SHA-1;
#                            unset or "-" signs ad hoc (for testing only)
#   Z_IRIS_PROFILE           Developer ID provisioning profile for z-iris.app
#   Z_IRIS_PRIORITY_PROFILE  ... for z-iris-priority.app (enable sender faces
#                            and time-sensitive alerts; optional)
#   Z_IRIS_NOTARY_PROFILE    notarytool keychain profile; set to notarize and staple
# Needs: uv (it installs the Python), clang, codesign; sox at run time.
set -euo pipefail

root="$(CDPATH= cd "$(dirname "$0")/../.." && pwd)"
. "$root/scripts/claude/bundle_lib.sh"
out="${1:-$root/dist}"
identity="${Z_IRIS_SIGN_IDENTITY:--}"
main_profile="${Z_IRIS_PROFILE:-}"
priority_profile="${Z_IRIS_PRIORITY_PROFILE:-}"
notary="${Z_IRIS_NOTARY_PROFILE:-}"
version="$(sed -n 's/^version = "\(.*\)"/\1/p' "$root/pyproject.toml" | head -1)"

uv python install 3.13 >/dev/null
py="$(uv python find 3.13 --managed-python)"
pyroot="$(CDPATH= cd "$(dirname "$py")/.." && pwd -P)"
[ -f "$pyroot/lib/libpython3.13.dylib" ] || { echo "no libpython in $pyroot" >&2; exit 1; }

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

# One payload for both apps: Python without tests, Tk or IDLE, and z-iris installed.
mkdir -p "$stage/python/lib"
cp "$pyroot/lib/libpython3.13.dylib" "$stage/python/lib/"
chmod u+w "$stage/python/lib/libpython3.13.dylib"
install_name_tool -id @rpath/libpython3.13.dylib "$stage/python/lib/libpython3.13.dylib"
rsync -a \
	--exclude test/ --exclude tests/ --exclude idlelib/ --exclude tkinter/ \
	--exclude turtledemo/ --exclude ensurepip/ --exclude __pycache__/ \
	--exclude site-packages/ --exclude 'config-3.13-darwin/' --exclude '_tkinter*' \
	"$pyroot/lib/python3.13" "$stage/python/lib/"
uv pip install --quiet --python "$py" --target "$stage/site-packages" "$root"
rm -rf "$stage/site-packages/bin"
"$py" -m compileall -q -j0 "$stage/python/lib/python3.13" "$stage/site-packages" >/dev/null

# sign_code path [entitlements]: hardened runtime and a timestamp for a real
# identity (notarization needs both); ad hoc otherwise.
sign_code() {
	local path="$1" entitlements="${2:-}" flags=(--force)
	if [ "$identity" = "-" ]; then
		flags+=(-s -)
	else
		flags+=(-s "$identity" --options runtime --timestamp)
	fi
	[ -n "$entitlements" ] && flags+=(--entitlements "$entitlements")
	codesign "${flags[@]}" "$path"
}

# build_one app id name executable module extra-plist base-entitlements profile
build_one() {
	local app="$1" id="$2" name="$3" executable="$4" module="$5" extra="$6"
	local entitlements="$7" profile="$8" merged key value
	rm -rf "$app"
	mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
	cp "$root/src/z_iris/static/z-iris.icns" "$app/Contents/Resources/"
	write_info_plist "$app" "$id" "$name" "$executable" "$extra" "$version"
	cp -R "$stage/python" "$stage/site-packages" "$app/Contents/Resources/"
	clang -O2 -Wall -Werror -DZ_IRIS_EMBEDDED -DZ_IRIS_MODULE="\"$module\"" \
		-I"$pyroot/include/python3.13" "$root/scripts/claude/launcher.c" \
		-L"$stage/python/lib" -lpython3.13 \
		-Wl,-rpath,@executable_path/../Resources/python/lib \
		-o "$app/Contents/MacOS/$executable"

	# Inside out: every library, then the app with its entitlements.
	find "$app/Contents/Resources" -type f \( -name '*.so' -o -name '*.dylib' \) -print0 |
		while IFS= read -r -d '' library; do sign_code "$library"; done
	merged="$stage/$id.entitlements"
	cp "$root/scripts/claude/release.entitlements" "$merged"
	if [ -n "$profile" ] && [ "$identity" != "-" ]; then
		# The restricted entitlements need the profile's app and team identifiers.
		cp "$profile" "$app/Contents/embedded.provisionprofile"
		security cms -D -i "$profile" > "$stage/$id.profile.plist"
		for key in $(/usr/libexec/PlistBuddy -c "Print :" "$entitlements" | sed -n 's/^    \([a-z.-]*\) = .*/\1/p'); do
			/usr/libexec/PlistBuddy -c "Add :$key bool true" "$merged"
		done
		for key in com.apple.application-identifier com.apple.developer.team-identifier; do
			value="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:$key" "$stage/$id.profile.plist")"
			/usr/libexec/PlistBuddy -c "Add :$key string $value" "$merged"
		done
	fi
	sign_code "$app" "$merged"
	codesign --verify --strict "$app"
	# Nothing may point back at this machine's checkout or home directory.
	if strings "$app/Contents/MacOS/$executable" | grep -q "$HOME"; then
		echo "$app: launcher still refers to $HOME" >&2; exit 1
	fi
	echo "built $app"
}

mkdir -p "$out"
# Absolute, because the zip step runs from inside $out.
out="$(CDPATH= cd "$out" && pwd)"
build_one "$out/z-iris.app" ca.toybox.z-iris z-iris z-iris z_iris "" \
	"$root/scripts/claude/z-iris.entitlements" "$main_profile"
build_one "$out/z-iris-priority.app" ca.toybox.z-iris.priority "z-iris priority" z-iris-priority \
	z_iris.priority $'\n\t<key>NSUserNotificationAlertStyle</key><string>alert</string>' \
	"$root/scripts/claude/priority.entitlements" "$priority_profile"

zip="$out/z-iris-$version-macos-arm64.zip"
rm -f "$zip"
(cd "$out" && ditto -c -k --keepParent --sequesterRsrc z-iris.app z-iris-priority.app "$zip" 2>/dev/null) ||
	(cd "$out" && zip -qry "$zip" z-iris.app z-iris-priority.app)
if [ -n "$notary" ]; then
	xcrun notarytool submit "$zip" --keychain-profile "$notary" --wait
	xcrun stapler staple "$out/z-iris.app"
	xcrun stapler staple "$out/z-iris-priority.app"
	rm -f "$zip"
	(cd "$out" && zip -qry "$zip" z-iris.app z-iris-priority.app)
fi
echo "packed $zip"

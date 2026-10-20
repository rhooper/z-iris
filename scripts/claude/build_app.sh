#!/bin/bash
# Build z-iris.app and, beside it, z-iris-priority.app: small native launchers
# (launcher.c) that embed Homebrew's framework Python, each with its own bundle
# id, so UNUserNotificationCenter and the menubar treat them as apps.
# z-iris-priority shows sticky alerts; its notification style defaults to Alerts.
# Usage: build_app.sh [dest.app]   (default ~/Applications/z-iris.app)
#   The priority app goes next to dest. macOS only offers notification
#   permission to it from a real location such as ~/Applications.
# Env: PYTHON_FRAMEWORK overrides the Python.framework version to embed.
#   Z_IRIS_PROFILE and Z_IRIS_PRIORITY_PROFILE (.provisionprofile files) with
#   Z_IRIS_SIGN_IDENTITY (a certificate's SHA-1) sign each app with its
#   entitlements (z-iris.entitlements, priority.entitlements): sender faces and
#   time-sensitive alerts. Without a profile an app is signed ad hoc and its
#   notifications are plain. A profile expiring within 7 days is refused: once
#   it expires, macOS will not launch the app at all.
# The project .venv must be built with that Python:
#   uv sync --python /opt/homebrew/opt/python@3.13/bin/python3.13
set -euo pipefail

root="$(CDPATH= cd "$(dirname "$0")/../.." && pwd)"
dest="${1:-$HOME/Applications/z-iris.app}"
dest="${dest%/}"
# rm -rf below: only ever remove something that is named like an app bundle.
case "$(basename "$dest")" in
	?*.app) ;;
	*) echo "refusing: destination must be a path ending in .app (got $dest)" >&2; exit 1 ;;
esac
priority="$(dirname "$dest")/z-iris-priority.app"
framework="${PYTHON_FRAMEWORK:-/opt/homebrew/opt/python@3.13/Frameworks/Python.framework/Versions/3.13}"
icon="$root/src/z_iris/static/z-iris.icns"
main_profile="${Z_IRIS_PROFILE:-}"
priority_profile="${Z_IRIS_PRIORITY_PROFILE:-}"
identity="${Z_IRIS_SIGN_IDENTITY:-}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

[ -f "$framework/Python" ] && [ -f "$framework/Headers/Python.h" ] \
	|| { echo "no Python.framework at $framework" >&2; exit 1; }
sites="$root/.venv/lib/python3.13/site-packages"
[ -d "$sites" ] || { echo "no 3.13 venv: uv sync --python /opt/homebrew/opt/python@3.13/bin/python3.13" >&2; exit 1; }
# check_profile file: exists, an identity is given, and it has 7+ days left.
check_profile() {
	local file="$1" name expires left
	[ -f "$file" ] || { echo "no provisioning profile at $file" >&2; exit 1; }
	[ -n "$identity" ] || { echo "a profile needs Z_IRIS_SIGN_IDENTITY" >&2; exit 1; }
	name="$work/$(basename "$file").plist"
	security cms -D -i "$file" > "$name"
	expires="$(/usr/libexec/PlistBuddy -c "Print :ExpirationDate" "$name")"
	expires="$(date -j -f "%a %b %d %T %Z %Y" "$expires" +%s)"
	left=$(( (expires - $(date +%s)) / 86400 ))
	[ "$left" -ge 7 ] || { echo "profile $file expires in $left days; renew it in Xcode first" >&2; exit 1; }
}
for file in "$main_profile" "$priority_profile"; do
	[ -z "$file" ] || check_profile "$file"
done

# sign app id entitlements profile: with a profile, its own app and team
# identifiers go beside the entitlements (macOS ignores a restricted entitlement
# without them); otherwise ad hoc, which cannot carry them at all.
sign() {
	local app="$1" id="$2" entitlements="$3" file="$4" key value merged
	if [ -z "$file" ]; then
		codesign --force -s - -i "$id" "$app"
		return
	fi
	cp "$file" "$app/Contents/embedded.provisionprofile"
	merged="$work/$id.entitlements"
	cp "$entitlements" "$merged"
	for key in com.apple.application-identifier com.apple.developer.team-identifier; do
		value="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:$key" "$work/$(basename "$file").plist")"
		/usr/libexec/PlistBuddy -c "Add :$key string $value" "$merged"
	done
	codesign --force -s "$identity" -i "$id" --entitlements "$merged" "$app"
}

# build_bundle app id name executable module extra-plist-keys
build_bundle() {
	local app="$1" id="$2" name="$3" executable="$4" module="$5" extra="$6"
	rm -rf "$app"
	mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
	[ -f "$icon" ] && cp "$icon" "$app/Contents/Resources/z-iris.icns"

	cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>$id</string>
	<key>CFBundleName</key><string>$name</string>
	<key>CFBundleDisplayName</key><string>$name</string>
	<key>CFBundleExecutable</key><string>$executable</string>
	<key>CFBundleIconFile</key><string>z-iris</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>CFBundleShortVersionString</key><string>0.1.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSUserActivityTypes</key><array><string>INSendMessageIntent</string></array>$extra
</dict>
</plist>
PLIST

	# The process must be the bundle's own CFBundleExecutable: when it was a
	# copied Python exec'd from a script, macOS listed the menubar item under
	# whatever launched it (uv, iTerm2). Paths are fixed at build time.
	clang -O2 -Wall -Werror \
		-I"$framework/Headers" \
		-DZ_IRIS_PYTHONPATH="\"$root/src:$sites\"" \
		-DZ_IRIS_MODULE="\"$module\"" \
		"$root/scripts/claude/launcher.c" "$framework/Python" \
		-o "$app/Contents/MacOS/$executable"
}

# No --deep anywhere: it would sign nested code under a generated id.
build_bundle "$dest" ca.toybox.z-iris z-iris z-iris z_iris ""
sign "$dest" ca.toybox.z-iris "$root/scripts/claude/z-iris.entitlements" "$main_profile"
echo "built $dest"

build_bundle "$priority" ca.toybox.z-iris.priority "z-iris priority" z-iris-priority \
	z_iris.priority $'\n\t<key>NSUserNotificationAlertStyle</key><string>alert</string>'
sign "$priority" ca.toybox.z-iris.priority "$root/scripts/claude/priority.entitlements" "$priority_profile"
echo "built $priority"

#!/bin/bash
# Build z-iris.app and, beside it, z-iris-priority.app: small native launchers
# (launcher.c) that embed Homebrew's framework Python, each with its own bundle
# id, so UNUserNotificationCenter and the menubar treat them as apps.
# z-iris-priority shows sticky alerts; its notification style defaults to Alerts.
# Usage: build_app.sh [dest.app]   (default ~/Applications/z-iris.app)
#   The priority app goes next to dest. macOS only offers notification
#   permission to it from a real location such as ~/Applications.
# Env: PYTHON_FRAMEWORK overrides the Python.framework version to embed.
#   Z_IRIS_PRIORITY_PROFILE (a .provisionprofile) and Z_IRIS_SIGN_IDENTITY sign
#   the priority app with priority.entitlements (time-sensitive alerts);
#   without them it is signed ad hoc and its alerts are ordinary ones.
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
profile="${Z_IRIS_PRIORITY_PROFILE:-}"
identity="${Z_IRIS_SIGN_IDENTITY:-}"

[ -f "$framework/Python" ] && [ -f "$framework/Headers/Python.h" ] \
	|| { echo "no Python.framework at $framework" >&2; exit 1; }
sites="$root/.venv/lib/python3.13/site-packages"
[ -d "$sites" ] || { echo "no 3.13 venv: uv sync --python /opt/homebrew/opt/python@3.13/bin/python3.13" >&2; exit 1; }
if [ -n "$profile" ]; then
	[ -f "$profile" ] || { echo "no provisioning profile at $profile" >&2; exit 1; }
	[ -n "$identity" ] || { echo "Z_IRIS_PRIORITY_PROFILE needs Z_IRIS_SIGN_IDENTITY" >&2; exit 1; }
fi

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
	<key>NSHighResolutionCapable</key><true/>$extra
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

build_bundle "$dest" ca.toybox.z-iris z-iris z-iris z_iris ""
# No --deep: it would sign nested code under a generated id.
codesign --force -s - -i ca.toybox.z-iris "$dest"
echo "built $dest"

build_bundle "$priority" ca.toybox.z-iris.priority "z-iris priority" z-iris-priority \
	z_iris.priority $'\n\t<key>NSUserNotificationAlertStyle</key><string>alert</string>'
if [ -n "$profile" ]; then
	cp "$profile" "$priority/Contents/embedded.provisionprofile"
	codesign --force -s "$identity" -i ca.toybox.z-iris.priority \
		--entitlements "$root/scripts/claude/priority.entitlements" "$priority"
else
	# Ad hoc cannot carry the time-sensitive entitlement: macOS kills the app.
	codesign --force -s - -i ca.toybox.z-iris.priority "$priority"
fi
echo "built $priority"

#!/bin/bash
# Build z-iris.app: a small native launcher (launcher.c) that embeds Homebrew's
# framework Python, with its own bundle id, so UNUserNotificationCenter and the
# menubar treat z-iris as an app.
# Usage: build_app.sh [dest.app]   (default ~/Applications/z-iris.app)
# Env: PYTHON_FRAMEWORK overrides the Python.framework version to embed. The
# project .venv must be built with that Python:
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
framework="${PYTHON_FRAMEWORK:-/opt/homebrew/opt/python@3.13/Frameworks/Python.framework/Versions/3.13}"
icon="$root/src/z_iris/static/z-iris.icns"

[ -f "$framework/Python" ] && [ -f "$framework/Headers/Python.h" ] \
	|| { echo "no Python.framework at $framework" >&2; exit 1; }
sites="$root/.venv/lib/python3.13/site-packages"
[ -d "$sites" ] || { echo "no 3.13 venv: uv sync --python /opt/homebrew/opt/python@3.13/bin/python3.13" >&2; exit 1; }

rm -rf "$dest"
mkdir -p "$dest/Contents/MacOS" "$dest/Contents/Resources"
[ -f "$icon" ] && cp "$icon" "$dest/Contents/Resources/z-iris.icns"

cat > "$dest/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>ca.toybox.z-iris</string>
	<key>CFBundleName</key><string>z-iris</string>
	<key>CFBundleDisplayName</key><string>z-iris</string>
	<key>CFBundleExecutable</key><string>z-iris</string>
	<key>CFBundleIconFile</key><string>z-iris</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>CFBundleShortVersionString</key><string>0.1.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# The process must be the bundle's own CFBundleExecutable: when it was a copied
# Python exec'd from a script, macOS listed the menubar item under whatever
# launched it (uv, iTerm2). Paths are fixed at build time.
clang -O2 -Wall -Werror \
	-I"$framework/Headers" \
	-DZ_IRIS_PYTHONPATH="\"$root/src:$sites\"" \
	"$root/scripts/claude/launcher.c" "$framework/Python" \
	-o "$dest/Contents/MacOS/z-iris"

# No --deep: it would sign nested code under a generated id.
codesign --force -s - -i ca.toybox.z-iris "$dest"
echo "built $dest"

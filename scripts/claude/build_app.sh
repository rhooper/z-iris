#!/bin/bash
# Build z-iris.app: a copy of Homebrew's framework Python.app with its own
# bundle id, so UNUserNotificationCenter treats z-iris as an app.
# Usage: build_app.sh [dest.app]   (default ~/Applications/z-iris.app)
# Env: PYTHON_APP overrides the Python.app to copy. The project .venv must be
# built with that Python: uv sync --python /opt/homebrew/opt/python@3.13/bin/python3.13
set -euo pipefail

root="$(CDPATH= cd "$(dirname "$0")/../.." && pwd)"
dest="${1:-$HOME/Applications/z-iris.app}"
dest="${dest%/}"
# rm -rf below: only ever remove something that is named like an app bundle.
case "$(basename "$dest")" in
	?*.app) ;;
	*) echo "refusing: destination must be a path ending in .app (got $dest)" >&2; exit 1 ;;
esac
python_app="${PYTHON_APP:-/opt/homebrew/opt/python@3.13/Frameworks/Python.framework/Versions/3.13/Resources/Python.app}"
icon="$root/src/z_iris/static/z-iris.icns"

[ -x "$python_app/Contents/MacOS/Python" ] || { echo "no Python.app at $python_app" >&2; exit 1; }
sites="$root/.venv/lib/python3.13/site-packages"
[ -d "$sites" ] || { echo "no 3.13 venv: uv sync --python /opt/homebrew/opt/python@3.13/bin/python3.13" >&2; exit 1; }

rm -rf "$dest"
mkdir -p "$dest/Contents/MacOS" "$dest/Contents/Resources"
cp "$python_app/Contents/MacOS/Python" "$dest/Contents/MacOS/Python"
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

# The launcher execs the copied interpreter by its bundle path, so the process
# keeps the bundle identity. Paths are fixed at build time.
cat > "$dest/Contents/MacOS/z-iris" <<LAUNCHER
#!/bin/bash
here="\$(CDPATH= cd "\$(dirname "\$0")" && pwd)"
# Finder, open and login items start with PATH=/usr/bin:/bin:/usr/sbin:/sbin,
# which hides sox's play and terminal-notifier.
export PATH="/opt/homebrew/bin:/usr/local/bin:\$PATH"
export PYTHONPATH="$root/src:$sites"
export PYTHONNOUSERSITE=1
exec "\$here/Python" -m z_iris "\$@"
LAUNCHER
chmod +x "$dest/Contents/MacOS/z-iris"

codesign --force --deep -s - "$dest"
echo "built $dest"

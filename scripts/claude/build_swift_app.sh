#!/bin/bash
# Build the Swift z-iris as an app bundle, 2026-10-26 (Swift port, phase 3).
# Usage: build_swift_app.sh [dest.app]   (default ~/Applications/z-iris-swift.app)
# Env: Z_IRIS_BUNDLE_ID (default ca.toybox.z-iris.swift, a development identity
#   that can run beside the Python app; ca.toybox.z-iris at cut-over).
#   Z_IRIS_SIGN_IDENTITY (a certificate's SHA-1) and Z_IRIS_PROFILE sign it with
#   z-iris.entitlements for sender faces; without them it is signed ad hoc and
#   its banners are plain. Sticky alerts use ~/Applications/z-iris-priority.app.
set -euo pipefail
root="$(CDPATH= cd "$(dirname "$0")/../.." && pwd)"
dest="${1:-$HOME/Applications/z-iris-swift.app}"
id="${Z_IRIS_BUNDLE_ID:-ca.toybox.z-iris.swift}"
identity="${Z_IRIS_SIGN_IDENTITY:-}"
profile="${Z_IRIS_PROFILE:-}"
name="z-iris"
[ "$id" = ca.toybox.z-iris ] || name="z-iris (Swift)"

case "$dest" in
*.app) ;;
*) echo "destination must end in .app: $dest" >&2; exit 2 ;;
esac

(cd "$root/swift" && swift build -c release --product z-iris >/dev/null)
bin="$(cd "$root/swift" && swift build -c release --show-bin-path)"

# rm -rf below: only ever something named like an app bundle (checked above).
rm -rf "$dest"
mkdir -p "$dest/Contents/MacOS" "$dest/Contents/Resources"
cp "$bin/z-iris" "$dest/Contents/MacOS/z-iris"
cp -R "$bin/ZIris_ZIrisCore.bundle" "$dest/Contents/Resources/"
mkdir -p "$dest/Contents/Resources/sounds"
cp "$root"/src/z_iris/sounds/*.wav "$dest/Contents/Resources/sounds/"
cp "$root/src/z_iris/static/z-iris-menubarTemplate.png" "$root/src/z_iris/static/z-iris.icns" "$dest/Contents/Resources/"

cat >"$dest/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>CFBundleIdentifier</key><string>$id</string>
	<key>CFBundleName</key><string>$name</string>
	<key>CFBundleDisplayName</key><string>$name</string>
	<key>CFBundleExecutable</key><string>z-iris</string>
	<key>CFBundleIconFile</key><string>z-iris</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>0.2.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>26.0</string>
	<key>LSUIElement</key><true/>
	<key>NSUserActivityTypes</key><array><string>INSendMessageIntent</string></array>
</dict></plist>
PLIST

if [ -n "$identity" ] && [ -n "$profile" ]; then
	cp "$profile" "$dest/Contents/embedded.provisionprofile"
	codesign --force --options runtime -s "$identity" -i "$id" \
		--entitlements "$root/scripts/claude/z-iris.entitlements" "$dest"
else
	codesign --force -s - -i "$id" "$dest"
fi
codesign --verify --strict "$dest"
echo "built $dest ($id)"

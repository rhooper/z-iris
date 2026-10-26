#!/bin/bash
# Spike (Swift port, phase 3a), 2026-10-26: build ~/Applications/z-iris-spike.app
# with z-iris-spike-helper.app nested in Contents/Helpers, both ad hoc signed
# with their own identifiers (ca.toybox.z-iris.spike and .spike.helper, apart
# from the real apps). The helper asks for the Alerts style.
# Usage: build_helper_identity.sh [--remove]
set -euo pipefail
here="$(CDPATH= cd "$(dirname "$0")" && pwd)"
dest="$HOME/Applications/z-iris-spike.app"

# rm -rf below: only ever the spike bundle.
if [ "${1:-}" = "--remove" ]; then
	rm -rf "$dest"
	exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
swiftc -O -o "$work/spike" "$here/helper_identity.swift"

bundle() { # bundle <app> <id> <name> <extra plist>
	mkdir -p "$1/Contents/MacOS"
	cp "$work/spike" "$1/Contents/MacOS/spike"
	cat >"$1/Contents/Info.plist" <<-PLIST
	<?xml version="1.0" encoding="UTF-8"?>
	<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
	<plist version="1.0"><dict>
		<key>CFBundleIdentifier</key><string>$2</string>
		<key>CFBundleName</key><string>$3</string>
		<key>CFBundleExecutable</key><string>spike</string>
		<key>CFBundlePackageType</key><string>APPL</string>
		<key>CFBundleShortVersionString</key><string>0.0.1</string>
		<key>CFBundleVersion</key><string>1</string>
		<key>LSMinimumSystemVersion</key><string>26.0</string>
		<key>LSUIElement</key><true/>$4
	</dict></plist>
	PLIST
}

rm -rf "$dest"
helper="$dest/Contents/Helpers/z-iris-spike-helper.app"
bundle "$dest" ca.toybox.z-iris.spike "z-iris spike" ""
bundle "$helper" ca.toybox.z-iris.spike.helper "z-iris spike helper" \
	$'\n\t\t<key>NSUserNotificationAlertStyle</key><string>alert</string>'
codesign --force -s - -i ca.toybox.z-iris.spike.helper "$helper"
codesign --force -s - -i ca.toybox.z-iris.spike "$dest"
codesign --verify --strict "$dest"
echo "built $dest"

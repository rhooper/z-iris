#!/bin/bash
# Build z-iris.app and, beside it, z-iris-priority.app from the Swift package.
# z-iris-priority shows sticky alerts; macOS only offers it notification
# permission from a real location such as ~/Applications.
# Usage: build_app.sh [dest.app]   (default ~/Applications/z-iris.app)
# Env: Z_IRIS_PROFILE and Z_IRIS_PRIORITY_PROFILE (.provisionprofile files) with
#   Z_IRIS_SIGN_IDENTITY (a certificate's SHA-1) sign each app with its
#   entitlements (z-iris.entitlements, priority.entitlements): sender faces and
#   time-sensitive alerts. Without a profile an app is signed ad hoc and its
#   notifications are plain. A profile expiring within 7 days is refused: once
#   it expires, macOS will not launch the app at all.
#   Z_IRIS_BUNDLE_ID overrides z-iris's identifier (the helper keeps its own).
# 2026-10-27 (Swift; the Python launcher build is in git history).
set -euo pipefail
root="$(CDPATH= cd "$(dirname "$0")/../.." && pwd)"
dest="${1:-$HOME/Applications/z-iris.app}"

# rm -rf below: only ever remove something that is named like an app bundle.
case "$(basename "$dest")" in
	?*.app) ;;
	*) echo "refusing: destination must be a path ending in .app (got $dest)" >&2; exit 1 ;;
esac
priority="$(dirname "$dest")/z-iris-priority.app"
main_id="${Z_IRIS_BUNDLE_ID:-ca.toybox.z-iris}"
main_profile="${Z_IRIS_PROFILE:-}"
priority_profile="${Z_IRIS_PRIORITY_PROFILE:-}"
identity="${Z_IRIS_SIGN_IDENTITY:-}"
resources="$root/swift/Resources"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

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
	codesign --force --options runtime -s "$identity" -i "$id" --entitlements "$merged" "$app"
}

# bundle app id name executable extra-plist-keys
bundle() {
	local app="$1" id="$2" name="$3" executable="$4" extra="$5"
	rm -rf "$app"
	mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
	cp "$bin/$executable" "$app/Contents/MacOS/$executable"
	cp "$resources/z-iris.icns" "$app/Contents/Resources/"
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
	<key>CFBundleVersion</key><string>0.2.0</string>
	<key>CFBundleShortVersionString</key><string>0.2.0</string>
	<key>LSMinimumSystemVersion</key><string>26.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSUserActivityTypes</key><array><string>INSendMessageIntent</string></array>$extra
</dict>
</plist>
PLIST
}

(cd "$root/swift" && swift build -c release --product z-iris >/dev/null && swift build -c release --product z-iris-priority >/dev/null)
bin="$(cd "$root/swift" && swift build -c release --show-bin-path)"

# No --deep anywhere: it would sign nested code under a generated id.
bundle "$dest" "$main_id" z-iris z-iris ""
cp -R "$bin/ZIris_ZIrisCore.bundle" "$resources/sounds" "$resources/z-iris-menubarTemplate.png" "$dest/Contents/Resources/"
rm -f "$dest/Contents/Resources/sounds/SOURCES.md"
sign "$dest" "$main_id" "$root/scripts/claude/z-iris.entitlements" "$main_profile"
echo "built $dest ($main_id)"

bundle "$priority" ca.toybox.z-iris.priority "z-iris priority" z-iris-priority \
	$'\n\t<key>NSUserNotificationAlertStyle</key><string>alert</string>'
sign "$priority" ca.toybox.z-iris.priority "$root/scripts/claude/priority.entitlements" "$priority_profile"
echo "built $priority"

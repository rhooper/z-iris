#!/bin/bash
# Build, sign, notarize and staple the release: z-iris.app and z-iris-priority.app
# zipped as z-iris-<version>-macos-arm64.zip. 2026-10-27.
# Usage: build_release.sh [out]   (default ./dist)
# Needs Xcode signed into the paid team (R9MHS94TL4) and a notarytool keychain
# profile (Z_IRIS_NOTARY_PROFILE, default z-iris-notary).
#
# The Developer ID profiles come from Xcode's automatic signing: the template
# project in xcode/ is archived and exported as developer-id once per bundle
# id, and the profile Xcode embedded is taken from the export. The apps are
# then built by build_app.sh, signed with the Developer ID certificate that
# profile authorizes and whose key is in this keychain. (A profile that names
# another certificate makes macOS kill the app at launch.)
set -euo pipefail
root="$(CDPATH= cd "$(dirname "$0")/../.." && pwd)"
out="${1:-$root/dist}"
mkdir -p "$out"
out="$(CDPATH= cd "$out" && pwd)"
notary="${Z_IRIS_NOTARY_PROFILE:-z-iris-notary}"
team=R9MHS94TL4
# The next version from the commits since the last tag (version.sh); tagged
# once the release passes its checks. Only from a clean tree.
[ -z "$(git -C "$root" status --porcelain --untracked-files=no)" ] || { echo "commit your changes first" >&2; exit 1; }
version="${Z_IRIS_VERSION:-$("$root/scripts/claude/version.sh" next)}"
echo "releasing $version"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

cat > "$work/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>method</key><string>developer-id</string>
	<key>signingStyle</key><string>automatic</string>
	<key>teamID</key><string>$team</string>
</dict></plist>
PLIST

# profile id entitlements: the Developer ID profile Xcode makes for a bundle id.
profile() {
	local id="$1" entitlements="$2" archive="$work/$1.xcarchive"
	(cd "$root/xcode/z-iris-priority" && xcodebuild -project z-iris-priority.xcodeproj -scheme z-iris-priority \
		-configuration Release -archivePath "$archive" -derivedDataPath "$work/dd" archive \
		-allowProvisioningUpdates DEVELOPMENT_TEAM="$team" PRODUCT_BUNDLE_IDENTIFIER="$id" \
		CODE_SIGN_ENTITLEMENTS="$entitlements" >"$work/$id.log" 2>&1) \
		|| { tail -20 "$work/$id.log" >&2; exit 1; }
	xcodebuild -exportArchive -archivePath "$archive" -exportPath "$work/$id" \
		-exportOptionsPlist "$work/export.plist" -allowProvisioningUpdates >>"$work/$id.log" 2>&1 \
		|| { tail -20 "$work/$id.log" >&2; exit 1; }
	# The template must never stand in for the real app (an alert click would launch it).
	"$LSREGISTER" -u "$work/$id/z-iris-priority.app" 2>/dev/null || true
	cp "$work/$id/z-iris-priority.app/Contents/embedded.provisionprofile" "$work/$id.provisionprofile"
}
profile ca.toybox.z-iris z-iris-priority/z-iris.entitlements
profile ca.toybox.z-iris.priority z-iris-priority/z-iris-priority.entitlements

# The keychain's Developer ID identity that both profiles authorize.
identity=""
for sha in $(security find-identity -v -p codesigning | awk '/Developer ID Application/ {print $2}'); do
	ok=1
	for id in ca.toybox.z-iris ca.toybox.z-iris.priority; do
		security cms -D -i "$work/$id.provisionprofile" > "$work/$id.plist"
		/usr/bin/python3 - "$work/$id.plist" "$sha" <<'PY' || ok=0
import hashlib, plistlib, sys
profile = plistlib.load(open(sys.argv[1], "rb"))
wanted = sys.argv[2].lower()
sys.exit(0 if any(hashlib.sha1(c).hexdigest() == wanted for c in profile["DeveloperCertificates"]) else 1)
PY
	done
	if [ "$ok" = 1 ]; then identity="$sha"; break; fi
done
[ -n "$identity" ] || { echo "no Developer ID identity in this keychain is authorized by the profiles" >&2; exit 1; }
echo "signing with $identity"

Z_IRIS_VERSION="$version" Z_IRIS_SIGN_IDENTITY="$identity" Z_IRIS_PROFILE="$work/ca.toybox.z-iris.provisionprofile" \
	Z_IRIS_PRIORITY_PROFILE="$work/ca.toybox.z-iris.priority.provisionprofile" \
	"$root/scripts/claude/build_app.sh" "$out/z-iris.app" | grep '^built'

zip="$out/z-iris-$version-macos-arm64.zip"
pack() {
	rm -f "$zip"
	(cd "$out" && zip -qry "$zip" z-iris.app z-iris-priority.app)
}
pack
xcrun notarytool submit "$zip" --keychain-profile "$notary" --wait
xcrun stapler staple "$out/z-iris.app"
xcrun stapler staple "$out/z-iris-priority.app"
pack

# What a downloader's Mac will check, and a real launch (a bad profile is only
# caught there: macOS kills the process).
for app in "$out/z-iris.app" "$out/z-iris-priority.app"; do
	codesign --verify --strict "$app"
	spctl -a -vv "$app"
	xcrun stapler validate "$app" >/dev/null
	syspolicy_check distribution "$app" >/dev/null || { syspolicy_check distribution "$app"; exit 1; }
done
set +e
"$out/z-iris.app/Contents/MacOS/z-iris" --not-an-option >/dev/null 2>&1
status=$?
set -e
[ "$status" = 2 ] || { echo "z-iris did not start (exit $status)" >&2; exit 1; }
git -C "$root" tag -a "v$version" -m "z-iris $version"
shasum -a 256 "$zip"
echo "packed $zip, tagged v$version (push the tag and publish: gh release create v$version)"

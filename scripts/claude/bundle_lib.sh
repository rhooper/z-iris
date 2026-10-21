# Shared by build_app.sh and build_release.sh: the bundles' Info.plist.
# 2026-10-21. Source it; do not run it.

# write_info_plist app id name executable extra-plist-keys [version]
write_info_plist() {
	local app="$1" id="$2" name="$3" executable="$4" extra="$5" version="${6:-0.1.0}"
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
	<key>CFBundleVersion</key><string>$version</string>
	<key>CFBundleShortVersionString</key><string>$version</string>
	<key>LSUIElement</key><true/>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSUserActivityTypes</key><array><string>INSendMessageIntent</string></array>$extra
</dict>
</plist>
PLIST
}

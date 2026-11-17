#!/bin/sh
# Builds the Mac app for direct download (Homebrew and GitHub releases):
# signed with Developer ID, notarized by Apple, and zipped. Then, with
# --upload, attaches the zip to the GitHub release for this version.
#
# One-time setup: store notarization credentials in the keychain as the
# "openhabits" profile (an app-specific password from account.apple.com):
#   xcrun notarytool store-credentials openhabits \
#     --apple-id <your Apple ID> --team-id JK252Z5J39
#
# Usage: tool/release_mac.sh [--upload]
set -e
cd "$(dirname "$0")/../apps/apple"

version=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)
out=build/release
zip="OpenHabits-$version-macOS.zip"
rm -rf "$out"
mkdir -p "$out"

echo "Building OpenHabits $version for macOS…"
xcodegen -q
xcodebuild archive -scheme OpenHabits -destination 'generic/platform=macOS' \
  -archivePath "$out/OpenHabits.xcarchive" -allowProvisioningUpdates -quiet

cat > "$out/export.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>developer-id</string>
<key>teamID</key><string>JK252Z5J39</string>
<key>signingStyle</key><string>automatic</string>
</dict></plist>
EOF
xcodebuild -exportArchive -archivePath "$out/OpenHabits.xcarchive" -exportPath "$out" \
  -exportOptionsPlist "$out/export.plist" -allowProvisioningUpdates -quiet

echo "Notarizing (usually a few minutes)…"
ditto -c -k --keepParent "$out/OpenHabits.app" "$out/upload.zip"
xcrun notarytool submit "$out/upload.zip" --keychain-profile openhabits --wait
xcrun stapler staple "$out/OpenHabits.app"
spctl -a -vv "$out/OpenHabits.app"

ditto -c -k --keepParent "$out/OpenHabits.app" "$out/$zip"
sha=$(shasum -a 256 "$out/$zip" | cut -d' ' -f1)
echo "Built $out/$zip"
echo "sha256 $sha"

if [ "$1" = "--upload" ]; then
  gh release upload "v$version" "$out/$zip" --clobber
  echo "Attached to the v$version release."
fi

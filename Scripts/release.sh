#!/bin/zsh

# Builds a notarized disk image of Hypervisaur for distribution outside the Mac App Store.
#
# Usage: Scripts/release.sh <output directory>
#
# Requires a Developer ID Application certificate in the keychain, a Developer ID provisioning profile for the
# app's bundle identifier named by HYPERVISAUR_PROFILE (the app uses the USB accessory entitlement, which needs one),
# and an App Store Connect API key for notarization:
#
#   ASC_KEY_PATH      path to the AuthKey_XXXXXXXXXX.p8 file
#   ASC_KEY_ID        the key's ID
#   ASC_ISSUER_ID     the key's issuer ID
#   HYPERVISAUR_PROFILE  name of the provisioning profile, such as "Hypervisaur Developer ID"

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <output directory>" >&2
    exit 64
fi

for variable in ASC_KEY_PATH ASC_KEY_ID ASC_ISSUER_ID HYPERVISAUR_PROFILE; do
    if [[ -z "${(P)variable:-}" ]]; then
        echo "Set $variable before running this script." >&2
        exit 64
    fi
done

ROOT="${0:A:h:h}"
OUTPUT="${1:A}"
CONFIG="$ROOT/VirtualBuddy/Config"

setting() {
    sed -n "s/^$1 = //p" "$CONFIG/$2" | head -1
}

VERSION="$(setting MARKETING_VERSION Versions.xcconfig)"
TEAM_ID="$(setting VB_DEVELOPMENT_TEAM Security.xcconfig)"
BUNDLE_ID="$(setting VB_BUNDLE_ID_PREFIX Signing.xcconfig)hypervisaur"

ARCHIVE="$OUTPUT/Hypervisaur.xcarchive"
EXPORT="$OUTPUT/export"
APP="$EXPORT/Hypervisaur.app"
DMG="$OUTPUT/Hypervisaur-$VERSION.dmg"

notarize() {
    xcrun notarytool submit "$1" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait --timeout 30m
}

echo "Building Hypervisaur $VERSION for team $TEAM_ID"

rm -rf "$ARCHIVE" "$EXPORT" "$DMG"
mkdir -p "$OUTPUT"

xcodebuild -project "$ROOT/VirtualBuddy.xcodeproj" -scheme VirtualBuddy -configuration Release \
    -destination "generic/platform=macOS" -archivePath "$ARCHIVE" archive

EXPORT_OPTIONS="$OUTPUT/ExportOptions.plist"
cat > "$EXPORT_OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>provisioningProfiles</key>
    <dict>
        <key>$BUNDLE_ID</key>
        <string>$HYPERVISAUR_PROFILE</string>
    </dict>
</dict>
</plist>
EOF

xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" -exportOptionsPlist "$EXPORT_OPTIONS"

echo "Notarizing the app"
APP_ZIP="$OUTPUT/Hypervisaur.zip"
ditto -c -k --keepParent "$APP" "$APP_ZIP"
notarize "$APP_ZIP"
rm "$APP_ZIP"
xcrun stapler staple "$APP"

echo "Creating the disk image"
STAGING="$OUTPUT/dmg"
rm -rf "$STAGING"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/Hypervisaur.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Hypervisaur $VERSION" -srcfolder "$STAGING" -format UDZO -fs APFS "$DMG"
rm -rf "$STAGING"

codesign --sign "Developer ID Application" --timestamp "$DMG"

echo "Notarizing the disk image"
notarize "$DMG"
xcrun stapler staple "$DMG"

spctl --assess --type open --context context:primary-signature --verbose "$DMG"
spctl --assess --type execute --verbose "$APP"

echo "Created $DMG"

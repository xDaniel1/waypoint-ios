#!/bin/bash
# Archives and exports a TestFlight-ready .ipa. Doesn't upload — that last step
# needs an App Store Connect API key or Xcode Organizer, both account setup
# that's on you (see TESTFLIGHT.md).
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f Secrets.xcconfig ]; then
  echo "error: Secrets.xcconfig is missing — the Release build will ship with no Google API key." >&2
  exit 1
fi

BUILD_NUMBER=$(git rev-list --count HEAD)
ARCHIVE_PATH="build/Waypoint.xcarchive"
EXPORT_PATH="build/export"

echo "== Regenerating Xcode project =="
xcodegen generate

echo "== Archiving (build $BUILD_NUMBER) =="
xcodebuild archive \
  -project Waypoint.xcodeproj \
  -scheme Waypoint \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE_PATH" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"

echo "== Exporting .ipa =="
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist exportOptions.plist

echo
echo "Done: $EXPORT_PATH/Waypoint.ipa (build $BUILD_NUMBER)"
echo
echo "Upload with Xcode Organizer / Transporter.app, or once you have an"
echo "App Store Connect API key:"
echo "  xcrun altool --upload-app -f $EXPORT_PATH/Waypoint.ipa -t ios \\"
echo "    --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>"

#!/bin/sh
# Builds Pelican and runs it sandboxed, signed with your Apple Development certificate.
# A stable signature matters: Keychain only hands saved passwords back to the same signed app.
set -e
cd "$(dirname "$0")/.."
IDENTITY="${PELICAN_SIGN_IDENTITY:-Apple Development}"
xcodegen generate >/dev/null
xcodebuild -project Pelican.xcodeproj -scheme Pelican -configuration Debug -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO build | grep -E "error:|BUILD" || true
APP=build/Build/Products/Debug/Pelican.app
codesign --force --deep --options runtime --sign "$IDENTITY" \
  --entitlements Pelican/Resources/Pelican.entitlements "$APP"
pkill -f "$APP/Contents/MacOS/Pelican" 2>/dev/null || true
open "$APP"

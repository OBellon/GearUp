#!/usr/bin/env bash
#
# Builds the Phase 0 diagnostic and assembles it as .build/GearUpProbe.app
#
# The bundle is required: macOS attributes the Bluetooth permission to the
# bundle and reads the usage description from Contents/Info.plist. Launching
# the bare Mach-O executable from a shell instead can abort with
# "attempted to access privacy-sensitive data without a usage description".
#
# Signed the same way as the app, so the probe's own permission is stable too.

set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/bundle.sh
source scripts/sign-identity.sh

CONFIGURATION="${GEARUP_CONFIGURATION:-release}"
APP_PATH=".build/GearUpProbe.app"

echo "==> Building GearUpProbe ($CONFIGURATION)"
swift build -c "$CONFIGURATION" --product GearUpProbe

package_bundle GearUpProbe "$APP_PATH" "scripts/ProbeInfo.plist" "$CONFIGURATION" "$(gearup_sign_identity)"

echo "==> Done: $APP_PATH"

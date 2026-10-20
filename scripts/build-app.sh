#!/usr/bin/env bash
#
# Builds GearUp and assembles a runnable macOS app bundle at .build/GearUp.app
#
# The bundle is signed with GearUp's own identity when scripts/setup-signing.sh
# has been run, so macOS keeps the permissions across rebuilds. Without it, or
# with GEARUP_SIGN_IDENTITY set, see scripts/sign-identity.sh.

set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/bundle.sh
source scripts/sign-identity.sh

CONFIGURATION="${GEARUP_CONFIGURATION:-release}"
APP_PATH=".build/GearUp.app"

echo "==> Building GearUp ($CONFIGURATION)"
swift build -c "$CONFIGURATION" --product GearUp

package_bundle GearUp "$APP_PATH" "scripts/AppInfo.plist" "$CONFIGURATION" "$(gearup_sign_identity)" "Resources/GearUp.icns"

echo "==> Done: $APP_PATH"
echo "    Open it with: open $APP_PATH"

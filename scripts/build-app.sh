#!/usr/bin/env bash
#
# Builds GearUp and assembles a runnable macOS app bundle at .build/GearUp.app
#
# Signing is ad-hoc by default. To use a stable identity (so macOS stops asking
# for permissions after every rebuild), export GEARUP_SIGN_IDENTITY:
#
#   GEARUP_SIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" make app

set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/bundle.sh

CONFIGURATION="${GEARUP_CONFIGURATION:-release}"
APP_PATH=".build/GearUp.app"

echo "==> Building GearUp ($CONFIGURATION)"
swift build -c "$CONFIGURATION" --product GearUp

package_bundle GearUp "$APP_PATH" "scripts/AppInfo.plist" "$CONFIGURATION" "${GEARUP_SIGN_IDENTITY:--}"

echo "==> Done: $APP_PATH"
echo "    Open it with: open $APP_PATH"

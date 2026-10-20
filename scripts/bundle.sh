#!/usr/bin/env bash
#
# Shared helpers for assembling macOS app bundles from SwiftPM products.
#
# A real .app bundle matters for GearUp: macOS attributes Bluetooth and
# local-network permissions to the bundle, and reads the usage descriptions
# from Contents/Info.plist. Running a bare Mach-O executable instead usually
# makes macOS abort the process with a missing-usage-description error.

# package_bundle <product> <app-path> <info-plist> <configuration> <sign-identity> [icon]
package_bundle() {
  local product="$1"
  local app_path="$2"
  local plist="$3"
  local configuration="$4"
  local sign_identity="$5"
  local icon="${6:-}"

  local binary=".build/$configuration/$product"
  if [[ ! -x "$binary" ]]; then
    echo "error: expected a built binary at $binary" >&2
    return 1
  fi

  if [[ ! -f "$plist" ]]; then
    echo "error: missing Info.plist template at $plist" >&2
    return 1
  fi

  rm -rf "$app_path"
  mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"

  cp "$binary" "$app_path/Contents/MacOS/$product"
  cp "$plist" "$app_path/Contents/Info.plist"
  printf 'APPL????' > "$app_path/Contents/PkgInfo"

  # The icon is copied before signing, because signing seals the resources.
  if [[ -n "$icon" ]]; then
    if [[ ! -f "$icon" ]]; then
      echo "error: missing icon at $icon (run make icon)" >&2
      return 1
    fi
    cp "$icon" "$app_path/Contents/Resources/$(basename "$icon")"
  fi

  echo "==> Signing $(basename "$app_path") with identity: $sign_identity"
  codesign --force --deep --sign "$sign_identity" "$app_path"
}

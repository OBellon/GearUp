#!/usr/bin/env bash
#
# Prints the signing identity the build scripts should use.
#
# `GEARUP_SIGN_IDENTITY` always wins, so another Mac or a CI box can point at its
# own identity. Otherwise GearUp's own self-signed identity is used when it has
# been set up (scripts/setup-signing.sh, `make signing`), and ad-hoc signing ("-")
# is the fallback: that works, but every rebuild is a new app as far as macOS is
# concerned, so it asks for Bluetooth and Local Network again each time.

GEARUP_IDENTITY_NAME="${GEARUP_IDENTITY_NAME:-GearUp Dev}"

gearup_sign_identity() {
    if [[ -n "${GEARUP_SIGN_IDENTITY:-}" ]]; then
        printf '%s' "$GEARUP_SIGN_IDENTITY"
        return
    fi

    # `-v` lists identities that are actually usable, which is what a signable
    # certificate has to be.
    if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$GEARUP_IDENTITY_NAME\""; then
        printf '%s' "$GEARUP_IDENTITY_NAME"
        return
    fi

    printf '%s' "-"
}

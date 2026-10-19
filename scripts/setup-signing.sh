#!/usr/bin/env bash
#
# Creates GearUp's local code-signing identity: one certificate, once per Mac.
#
# Why it exists: macOS ties the Bluetooth and Local Network permissions to the
# app's signature, and an ad-hoc signature changes with every build — a new code
# directory hash is a new app, so the permission is asked for again and again. A
# self-signed certificate gives the bundle a stable identity, so the permissions
# are granted once and then kept.
#
# This touches the login keychain. It imports a key pair and a certificate, and
# marks the certificate trusted for code signing — a change to your user trust
# settings, for which macOS may ask for your password. Nothing is signed with it
# except GearUp's own bundles, and only `codesign` and `security` are allowed to
# use the private key.
#
# Idempotent: running it again when the identity is there does nothing.
#
#   ./scripts/setup-signing.sh            # or: make signing
#   GEARUP_IDENTITY_NAME="GearUp Dev 2" ./scripts/setup-signing.sh

set -euo pipefail
cd "$(dirname "$0")/.."

NAME="${GEARUP_IDENTITY_NAME:-GearUp Dev}"
KEYCHAIN="${GEARUP_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
DAYS="${GEARUP_IDENTITY_DAYS:-3650}"

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$NAME\""; then
    echo "==> '$NAME' is already set up; nothing to do."
    exit 0
fi

if [[ ! -f "$KEYCHAIN" ]]; then
    echo "error: no keychain found at $KEYCHAIN" >&2
    exit 1
fi

if ! command -v openssl >/dev/null; then
    echo "error: openssl is needed to make the certificate" >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Generating a self-signed code-signing certificate ('$NAME')"
openssl req -x509 -newkey rsa:2048 -sha256 -days "$DAYS" -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -subj "/CN=$NAME/O=GearUp/C=ES" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning"

# OpenSSL 3 writes AES-256 with a SHA-256 MAC into a PKCS#12 by default, and the
# Security framework refuses those outright ("MAC verification failed during
# PKCS12 import"). `-legacy` writes the older flavour it does read.
echo "==> Packing it for the keychain"
PKCS12_EXTRA=()
if openssl version | grep -q '^OpenSSL 3'; then
    PKCS12_EXTRA+=(-legacy)
fi
openssl pkcs12 -export "${PKCS12_EXTRA[@]}" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$NAME" -out "$WORK/identity.p12" -passout "pass:gearup"

echo "==> Importing it into $KEYCHAIN"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P gearup \
    -T /usr/bin/codesign -T /usr/bin/security

# Trust is what turns the certificate into an identity that `codesign` accepts
# and `security find-identity -v` lists.
echo "==> Trusting it for code signing (macOS may ask for your password)"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo
echo "==> Done. Builds will now sign with '$NAME'."
echo "    The first launch after this switch asks for Bluetooth and Local Network"
echo "    one last time; after that the permission survives every rebuild."

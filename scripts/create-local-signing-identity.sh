#!/usr/bin/env bash
# Creates a stable, self-signed code-signing identity for LOCAL DEBUG BUILDS.
#
# Why this exists
# ---------------
# With no signing identity, Xcode falls back to ad-hoc signing, whose designated
# requirement pins the binary's cdhash:
#
#     designated => cdhash H"17dc41f1..."
#
# The cdhash changes on every single build, so the keychain ACL protecting the
# stored Spotify refresh token never matches the new binary, and macOS prompts
# for the login keychain password after every rebuild. Clicking "Always Allow"
# does not help, because the next build is a different identity again.
#
# A certificate-backed identity produces a designated requirement pinned to the
# certificate instead:
#
#     designated => identifier spotiglass and certificate leaf = H"2732c08a..."
#
# That hash is constant across rebuilds, so one "Always Allow" holds forever.
#
# This identity is for local development only. Releases are signed with a real
# Apple Development / Developer ID certificate; see docs/building-and-testing.md.
# The certificate is deliberately NOT added to the system trust store - codesign
# does not require the identity to be trusted in order to sign with it, and
# adding trust would need admin rights for no benefit.
#
# Safe to re-run: it does nothing if the identity already exists.

set -euo pipefail

IDENTITY_NAME="Spotiglass Local Dev"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning | grep -qF "\"${IDENTITY_NAME}\""; then
    echo "OK: '${IDENTITY_NAME}' already present; nothing to do."
    exit 0
fi

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

cat > "${workdir}/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[dn]
CN = ${IDENTITY_NAME}
[v3]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "${workdir}/key.pem" \
    -out "${workdir}/cert.pem" \
    -config "${workdir}/openssl.cnf" 2>/dev/null

openssl pkcs12 -export \
    -inkey "${workdir}/key.pem" \
    -in "${workdir}/cert.pem" \
    -out "${workdir}/identity.p12" \
    -name "${IDENTITY_NAME}" \
    -passout pass:spotiglass 2>/dev/null

# -T /usr/bin/codesign lets codesign use the private key without a prompt.
security import "${workdir}/identity.p12" \
    -k "${KEYCHAIN}" \
    -P spotiglass \
    -T /usr/bin/codesign >/dev/null

if ! security find-identity -p codesigning | grep -qF "\"${IDENTITY_NAME}\""; then
    echo "Failed to create '${IDENTITY_NAME}'." >&2
    exit 1
fi

echo "OK: created '${IDENTITY_NAME}'. 'make build' will now use it automatically."

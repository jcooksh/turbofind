#!/usr/bin/env bash
# Create a stable, self-signed CODE-SIGNING identity ("TurboFind Local") in your
# login keychain — run ONCE.
#
# Why: swiftc only ad-hoc-signs the app, and an ad-hoc signature's hash changes
# every rebuild. macOS ties Full Disk Access / file-access permissions to that
# hash, so after every update (the in-app Update button rebuilds) or sometimes a
# restart, the grant is forgotten and you're re-prompted. Signing with the SAME
# self-signed identity each build keeps the signature stable, so the permission
# sticks.
#
#   cd menubar && ./make-cert.sh      # once
#   ./build.sh && open TurboFind.app  # now signed with the stable identity
#   then grant Full Disk Access once (the script prints how)
#
# No sudo. Touches only your login keychain. Re-running is a no-op.
set -euo pipefail
cd "$(dirname "$0")"

NAME="TurboFind Local"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "✓ identity '$NAME' already exists — nothing to do."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Use the system LibreSSL: Homebrew's OpenSSL 3 writes a PKCS#12 MAC that the
# macOS Security framework rejects ("MAC verification failed").
OPENSSL=/usr/bin/openssl
[ -x "$OPENSSL" ] || OPENSSL=openssl

cat > "$TMP/cs.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[dn]
CN = TurboFind Local
[v3]
basicConstraints   = critical,CA:FALSE
keyUsage           = critical,digitalSignature
extendedKeyUsage   = critical,codeSigning
EOF

echo "==> generating self-signed code-signing certificate"
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -config "$TMP/cs.cnf" -extensions v3 >/dev/null 2>&1
"$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/tf.p12" -passout pass:turbofind -name "$NAME" >/dev/null 2>&1

KC="$HOME/Library/Keychains/login.keychain-db"
echo "==> importing into the login keychain"
security import "$TMP/tf.p12" -k "$KC" -P turbofind -T /usr/bin/codesign >/dev/null

# Let codesign use the private key without a UI prompt on every build. Best
# effort — if your login keychain has a password this may no-op and the FIRST
# build will pop a keychain dialog where you click "Always Allow".
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KC" >/dev/null 2>&1 || true

echo
echo "✓ created code-signing identity: $NAME"
echo
echo "Next:"
echo "  1) ./build.sh                       (now signs with the stable identity)"
echo "  2) open TurboFind.app"
echo "  3) System Settings → Privacy & Security → Full Disk Access →"
echo "     add TurboFind.app and switch it on."
echo "     (Full Disk Access covers every folder, so no per-folder prompts —"
echo "      and because the signature is now stable, it survives future updates.)"

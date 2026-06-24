#!/usr/bin/env bash
# Create a stable self-signed CODE-SIGNING identity ("TurboFind Local") — run ONCE.
#
# Why: swiftc only ad-hoc-signs the app, and an ad-hoc signature's hash changes
# every rebuild. macOS ties Full Disk Access / file permissions (and a clean
# right-click→Open for downloaded builds) to a STABLE signature. Signing with the
# same self-signed identity each build keeps it stable, so the permission sticks.
#
# It lives in a DEDICATED keychain with a known password, so building never has to
# prompt for your login password (works non-interactively / in CI too).
#
#   cd menubar && ./make-cert.sh        # once
#   ./build.sh && open TurboFind.app    # now signed with the stable identity
#
# No sudo. Re-running is a no-op.
set -euo pipefail
cd "$(dirname "$0")"

NAME="TurboFind Local"
KC="$HOME/Library/Keychains/turbofind.keychain-db"
KCPW="turbofind"

if [ -f "$KC" ] && security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "$NAME"; then
  echo "✓ signing identity '$NAME' already set up — nothing to do."
  exit 0
fi

OPENSSL=/usr/bin/openssl       # LibreSSL writes an Apple-compatible PKCS#12
[ -x "$OPENSSL" ] || OPENSSL=openssl
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

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
  -out "$TMP/tf.p12" -passout "pass:$KCPW" -name "$NAME" >/dev/null 2>&1

echo "==> creating dedicated keychain (signing never needs your login password)"
security create-keychain -p "$KCPW" "$KC" 2>/dev/null || true
security set-keychain-settings "$KC"           # no auto-lock timeout
security unlock-keychain -p "$KCPW" "$KC"
security import "$TMP/tf.p12" -k "$KC" -P "$KCPW" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPW" "$KC" >/dev/null 2>&1 || true

if security find-identity -p codesigning "$KC" | grep -q "$NAME"; then
  echo "✓ created signing identity: $NAME"
  echo "  build.sh will now sign with it (stable across rebuilds)."
else
  echo "!! identity not found after import" >&2
  exit 1
fi

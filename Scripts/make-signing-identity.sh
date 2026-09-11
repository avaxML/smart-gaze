#!/usr/bin/env bash
# Creates a local self-signed code signing identity so that rebuilt copies of
# SmartGaze.app keep their Camera and Screen Recording grants. macOS TCC keys
# grants on the app's designated requirement; with ad-hoc signing that is the
# cdhash, which changes every build. Run once per machine; make-app.sh picks
# the identity up by name.
set -euo pipefail

NAME="${SMART_GAZE_SIGN_IDENTITY:-SmartGaze Local Development}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
  echo "identity '$NAME' already exists"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/ext.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = codesign
prompt = no
[dn]
CN = $NAME
[codesign]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/ext.cnf" 2>/dev/null
PASS="$(openssl rand -hex 16)"
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$NAME" -out "$WORK/identity.p12" -passout "pass:$PASS"

security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" \
  -T /usr/bin/codesign -T /usr/bin/security
# Self-signed leaf: mark it trusted for code signing so codesign accepts it.
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo "created identity '$NAME'"
security find-identity -p codesigning | grep "$NAME"

#!/bin/bash
# Creates a private "VoiceType Local Signing" certificate in the login keychain, once.
# build.sh signs with it so macOS keeps VoiceType's permissions across rebuilds.
set -euo pipefail
if security find-identity 2>/dev/null | grep -q '"VoiceType Local Signing"'; then
  echo "the certificate already exists"
  exit 0
fi
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
cat > "$dir/cert.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = VoiceType Local Signing
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$dir/cert.cnf" \
  -keyout "$dir/key.pem" -out "$dir/cert.pem" 2>/dev/null
# -legacy: the macOS keychain can't read the newer PKCS#12 encryption.
openssl pkcs12 -export -legacy -inkey "$dir/key.pem" -in "$dir/cert.pem" -out "$dir/id.p12" \
  -passout pass:voicetype -name "VoiceType Local Signing" 2>/dev/null
security import "$dir/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P voicetype -T /usr/bin/codesign

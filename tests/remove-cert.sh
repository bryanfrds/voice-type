#!/bin/bash
# Checks remove-cert.sh against a throwaway keychain: both "VoiceType Local Signing" identities
# go, and one merely named like it stays. Run by tests/run.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
dir=$(mktemp -d)
keychain="$dir/test.keychain-db"
trap 'security delete-keychain "$keychain" 2>/dev/null; rm -rf "$dir"' EXIT
security create-keychain -p test "$keychain"
security unlock-keychain -p test "$keychain"

add_identity() {  # $1: certificate name, $2: file prefix
  printf '[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=%s\n[ext]\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n' "$1" > "$dir/$2.cnf"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -config "$dir/$2.cnf" \
    -keyout "$dir/$2.key" -out "$dir/$2.pem" 2>/dev/null
  # OpenSSL 3 needs -legacy for a file the keychain can read; LibreSSL has no such flag.
  openssl pkcs12 -export -legacy -inkey "$dir/$2.key" -in "$dir/$2.pem" -out "$dir/$2.p12" -passout pass:x 2>/dev/null \
    || openssl pkcs12 -export -inkey "$dir/$2.key" -in "$dir/$2.pem" -out "$dir/$2.p12" -passout pass:x
  security import "$dir/$2.p12" -k "$keychain" -P x >/dev/null
}
# Distinct identities with exactly this name (a trusted one is listed twice).
count() { security find-identity "$keychain" | grep -F "\"$1\"" | awk '{print $2}' | sort -u | wc -l | tr -d " "; }

add_identity "VoiceType Local Signing" one
add_identity "VoiceType Local Signing" two
add_identity "VoiceType Local Signing Old" other
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got $2, wanted $3"; fails=$((fails + 1)); fi; }
check "two VoiceType certificates to start with" "$(count "VoiceType Local Signing")" 2
./remove-cert.sh "$keychain" >/dev/null
check "remove-cert.sh deletes both" "$(count "VoiceType Local Signing")" 0
check "a certificate merely named like it stays" "$(count "VoiceType Local Signing Old")" 1
[ "$fails" -eq 0 ] && echo "all passed"

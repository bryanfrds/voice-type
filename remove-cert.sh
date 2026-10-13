#!/bin/bash
# Deletes every "VoiceType Local Signing" identity (certificate and key) that make-cert.sh
# created. With a keychain path, only that keychain is searched; tests use a throwaway one.
# Deleting by hash means a similarly named certificate is never touched.
keychain=("$@")
hashes=$(security find-identity "${keychain[@]}" 2>/dev/null \
  | awk '/"VoiceType Local Signing"/ {print $2}' | sort -u)
for hash in $hashes; do
  if security delete-identity -Z "$hash" "${keychain[@]}" >/dev/null; then
    echo "Removed the VoiceType signing certificate."
  else
    echo "Could not remove a VoiceType signing certificate; delete it in Keychain Access."
  fi
done

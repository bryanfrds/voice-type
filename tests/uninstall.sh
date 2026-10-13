#!/bin/bash
# Checks uninstall.sh entirely inside a sandbox: a temporary HOME, and stand-ins for
# launchctl, pkill and security that only record their calls. Nothing on the real Mac is
# touched, even if the option check were broken. Run by tests/run.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
mkdir -p "$sandbox/bin"
for tool in launchctl pkill security; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/calls"\n' "$tool" "$sandbox" > "$sandbox/bin/$tool"
  chmod +x "$sandbox/bin/$tool"
done
# With FAKE_CERT=stuck, the stand-in security finds a VoiceType certificate but can't delete it.
cat >> "$sandbox/bin/security" <<'STUB'
if [ "${FAKE_CERT:-}" = stuck ]; then
  case "$1" in
    find-identity) echo '  1) ABCDEF "VoiceType Local Signing"' ;;
    delete-identity) exit 1 ;;
  esac
fi
STUB
fresh_home() {
  rm -rf "$sandbox/home" "$sandbox/calls"
  mkdir -p "$sandbox/home/Applications/VoiceType.app" "$sandbox/home/Library/LaunchAgents" \
    "$sandbox/home/.local/share/voice-type"
  touch "$sandbox/home/Library/LaunchAgents/com.bryanfrds.voice-type.plist" \
    "$sandbox/home/.local/share/voice-type/ggml-small.en.bin"
}
run() { HOME="$sandbox/home" PATH="$sandbox/bin:$PATH" ./uninstall.sh "$@" >/dev/null 2>&1; }

fails=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got $2, wanted $3"; fails=$((fails + 1)); fi; }
untouched() {
  [ -d "$sandbox/home/Applications/VoiceType.app" ] && [ -f "$sandbox/home/Library/LaunchAgents/com.bryanfrds.voice-type.plist" ] \
    && [ -d "$sandbox/home/.local/share/voice-type" ] && [ ! -f "$sandbox/calls" ] && echo yes || echo no
}

for bad in "--model" "--models --typo" "--typo --models" "extra words"; do
  fresh_home
  # shellcheck disable=SC2086
  status=$(run $bad; echo $?) || true
  check "'$bad' is refused" "$status" 2
  check "'$bad' touches nothing" "$(untouched)" yes
done

fresh_home
run
check "no options removes the app" "$([ -e "$sandbox/home/Applications/VoiceType.app" ] && echo kept || echo gone)" gone
check "no options keeps the models" "$([ -e "$sandbox/home/.local/share/voice-type" ] && echo kept || echo gone)" kept
check "no options looks for the certificate" "$(grep -c '^security find-identity' "$sandbox/calls")" 1

fresh_home
run --models
check "--models removes the models" "$([ -e "$sandbox/home/.local/share/voice-type" ] && echo kept || echo gone)" gone

fresh_home
status=0
out=$(FAKE_CERT=stuck HOME="$sandbox/home" PATH="$sandbox/bin:$PATH" ./uninstall.sh 2>&1) || status=$?
check "a stuck certificate doesn't stop the uninstall" "$status" 0
check "the app is still removed" "$([ -e "$sandbox/home/Applications/VoiceType.app" ] && echo kept || echo gone)" gone
check "it tried to delete by hash" "$(grep -cx 'security delete-identity -Z ABCDEF' "$sandbox/calls")" 1
check "it warns the certificate may be left" "$(grep -c 'may still be in your login keychain' <<<"$out")" 1
check "remove-cert.sh reports the failure" "$(FAKE_CERT=stuck PATH="$sandbox/bin:$PATH" ./remove-cert.sh >/dev/null 2>&1; echo $?)" 1

[ "$fails" -eq 0 ] && echo "all passed"

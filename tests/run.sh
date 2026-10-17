#!/bin/bash
# Builds and runs the checks in tests/main.swift against every source file that doesn't need
# the running app (main.swift starts it; Recording.swift and Meeting.swift need its log), then the bubble checks,
# then the uninstall checks, which run in a sandbox and a throwaway keychain.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
sources=$(ls Sources/*.swift | grep -vE '/(main|Recording|Meeting)\.swift$')
# shellcheck disable=SC2086
swiftc -swift-version 5 -o "$out/tests" $sources tests/main.swift
"$out/tests"
swiftc -swift-version 5 -o "$out/bubble" Sources/Bubble.swift Sources/Placement.swift tests/bubble/main.swift
"$out/bubble"
tests/remove-cert.sh
tests/uninstall.sh

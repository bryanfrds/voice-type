#!/bin/bash
# Builds and runs the checks in tests/main.swift against every source file that doesn't need
# the running app (main.swift starts it; Recording.swift needs its log), then the uninstall
# certificate checks.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
sources=$(ls Sources/*.swift | grep -vE '/(main|Recording)\.swift$')
# shellcheck disable=SC2086
swiftc -swift-version 5 -o "$out/tests" $sources tests/main.swift
"$out/tests"
tests/remove-cert.sh

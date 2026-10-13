#!/bin/bash
# Builds and runs the checks for Sources/Text.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -swift-version 5 -o "$out/tests" Sources/Text.swift tests/main.swift
"$out/tests"

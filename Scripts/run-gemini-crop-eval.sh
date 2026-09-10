#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

swift build > /dev/null
BIN_PATH="$(swift build --show-bin-path)"

BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gemini-crop-eval.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

swiftc \
  -parse-as-library \
  -I "$BIN_PATH/Modules" \
  -o "$BUILD_DIR/gemini-crop-eval" \
  "$REPO_ROOT/Scripts/gemini-crop-eval.swift" \
  "$BIN_PATH"/GazeKit.build/*.o \
  "$BIN_PATH"/Providers.build/*.o

exec "$BUILD_DIR/gemini-crop-eval" "$@"

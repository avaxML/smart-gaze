#!/usr/bin/env bash
set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly MODEL_PATH="${1:-${SMART_GAZE_MODEL_PATH:-${REPO_ROOT}/Models/blazegaze.mlmodelc}}"

if [[ ! -d "${MODEL_PATH}" ]]; then
  echo "blazegaze.mlmodelc not found at ${MODEL_PATH}; run Scripts/fetch-blazegaze.sh" >&2
  exit 1
fi

swift build --package-path "${REPO_ROOT}" -c release >/dev/null
bin_path="$(swift build --package-path "${REPO_ROOT}" -c release --show-bin-path)"

build_dir="$(mktemp -d)"
cleanup() {
  rm -rf "${build_dir}"
}
trap cleanup EXIT

binary="${build_dir}/benchmark-blazegaze"
swiftc -O -parse-as-library \
  -I "${bin_path}/Modules" \
  -o "${binary}" \
  "${REPO_ROOT}/Scripts/benchmark-blazegaze.swift" \
  "${bin_path}"/GazeKit.build/*.o \
  "${bin_path}"/Perception.build/*.o \
  -framework CoreML \
  -framework Vision \
  -framework AVFoundation \
  -framework CoreGraphics
"${binary}" "${MODEL_PATH}"

#!/usr/bin/env bash
set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly VIDEO="${1:-${SMART_GAZE_VIDEO:-}}"
readonly FACE_MESH="${2:-${SMART_GAZE_FACE_MESH_MODEL_PATH:-${REPO_ROOT}/Models/face_mesh.mlmodelc}}"
readonly BLAZEGAZE="${3:-${SMART_GAZE_MODEL_PATH:-${REPO_ROOT}/Models/blazegaze.mlmodelc}}"
readonly MAX_FRAMES="${4:-200}"

if [[ -z "${VIDEO}" || ! -f "${VIDEO}" ]]; then
  echo "usage: $0 <video.mp4> [face_mesh.mlmodelc] [blazegaze.mlmodelc] [maxFrames]" >&2
  exit 2
fi
for model in "${FACE_MESH}" "${BLAZEGAZE}"; do
  if [[ ! -d "${model}" ]]; then
    echo "model not found at ${model}; run Scripts/fetch-face-mesh.sh and Scripts/fetch-blazegaze.sh" >&2
    exit 1
  fi
done

# Release only. The debug build measures about 21 times slower, so a latency
# number from it says nothing about whether the pipeline fits a frame budget.
swift build --package-path "${REPO_ROOT}" -c release >/dev/null
bin_path="$(swift build --package-path "${REPO_ROOT}" -c release --show-bin-path)"

build_dir="$(mktemp -d)"
cleanup() { rm -rf "${build_dir}"; }
trap cleanup EXIT

binary="${build_dir}/video-gaze-harness"
swiftc -O -parse-as-library \
  -I "${bin_path}/Modules" \
  -o "${binary}" \
  "${REPO_ROOT}/Scripts/video-gaze-harness.swift" \
  "${bin_path}"/GazeKit.build/*.o \
  "${bin_path}"/Perception.build/*.o \
  -framework CoreML \
  -framework Vision \
  -framework AVFoundation \
  -framework CoreGraphics
"${binary}" "${VIDEO}" "${FACE_MESH}" "${BLAZEGAZE}" "${MAX_FRAMES}"

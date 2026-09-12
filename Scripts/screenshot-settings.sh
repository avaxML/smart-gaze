#!/usr/bin/env bash
# Captures one PNG per Settings tab, in light and dark appearance, by launching
# the built app with SMART_GAZE_SETTINGS_SCREENSHOT_DIR set. The app captures
# its own window in-process, so no Screen Recording permission is needed.
set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly OUT_DIR="${1:-/tmp/smart-gaze-settings-shots}"
readonly BUNDLE="${REPO_ROOT}/dist/SmartGaze.app"
readonly TIMEOUT_SECONDS=40

this_worktree_pids() {
  pgrep -fl "SmartGaze.app/Contents/MacOS/SmartGaze" 2>/dev/null \
    | grep -F "${BUNDLE}" \
    | awk '{print $1}' || true
}

cleanup() {
  local pids
  pids="$(this_worktree_pids)"
  if [[ -n "${pids}" ]]; then
    kill -9 ${pids} 2>/dev/null || true
  fi
}
trap cleanup EXIT

bash "${REPO_ROOT}/Scripts/make-app.sh" >/dev/null
cleanup
sleep 1
rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}"

open -n --env "SMART_GAZE_SETTINGS_SCREENSHOT_DIR=${OUT_DIR}" "${BUNDLE}"

elapsed=0
while [[ ${elapsed} -lt ${TIMEOUT_SECONDS} ]]; do
  if [[ "$(find "${OUT_DIR}" -name '*.png' | wc -l | tr -d ' ')" -ge 8 ]]; then
    break
  fi
  sleep 1
  elapsed=$((elapsed + 1))
done

png_count="$(find "${OUT_DIR}" -name '*.png' | wc -l | tr -d ' ')"
if [[ "${png_count}" -lt 8 ]]; then
  echo "FAIL: expected 8 screenshots in ${OUT_DIR} within ${TIMEOUT_SECONDS}s, found ${png_count}." >&2
  exit 1
fi

find "${OUT_DIR}" -name '*.png' | sort

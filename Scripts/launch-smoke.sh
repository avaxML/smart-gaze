#!/usr/bin/env bash
# Launches the built app and asserts it actually starts.
#
# Three shipped defects lived here and all of them passed the unit suite:
# models resolved against a working directory a Finder-launched app does not
# have, a camera state that waited forever with no timeout, and modal alerts
# that blocked before the camera started. A unit test cannot see any of it,
# because none of it happens until the bundle is launched.
set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly TIMEOUT_SECONDS="${SMART_GAZE_LAUNCH_TIMEOUT:-25}"
readonly LOG="$(mktemp)"
readonly BUNDLE="${REPO_ROOT}/dist/SmartGaze.app"

cleanup() {
  pkill -9 -f "SmartGaze.app/Contents/MacOS/SmartGaze" 2>/dev/null || true
  rm -f "${LOG}"
}
trap cleanup EXIT

bash "${REPO_ROOT}/Scripts/make-app.sh" >/dev/null
pkill -9 -f "SmartGaze.app/Contents/MacOS/SmartGaze" 2>/dev/null || true
sleep 1
: > "${LOG}"

open --env "SMART_GAZE_LAUNCH_LOG=${LOG}" "${BUNDLE}"

elapsed=0
while [[ ${elapsed} -lt ${TIMEOUT_SECONDS} ]]; do
  if grep -q "pipeline-ready" "${LOG}" 2>/dev/null \
    && grep -qE "camera-state.*State\.(live|waitingForPermission|permissionDenied|timedOut)" "${LOG}" 2>/dev/null; then
    break
  fi
  sleep 1
  elapsed=$((elapsed + 1))
done

echo "--- launch trace ---"
cat "${LOG}"
echo "--------------------"

if ! grep -q "launch-completed" "${LOG}" 2>/dev/null; then
  echo "FAIL: applicationDidFinishLaunching did not return within ${TIMEOUT_SECONDS}s." >&2
  echo "      A modal alert on the launch path is the usual cause." >&2
  exit 1
fi

# The camera must reach a state that says something. Sitting in 'starting'
# forever was a real shipped defect, so an absent state line fails too.
if ! grep -q "camera-state" "${LOG}" 2>/dev/null; then
  echo "FAIL: the camera never reported a state." >&2
  exit 1
fi

if grep -q "camera-state.*State.starting" "${LOG}" 2>/dev/null \
  && ! grep -qE "camera-state.*State\.(live|waitingForPermission|permissionDenied|timedOut)" "${LOG}"; then
  echo "FAIL: the camera stayed in 'starting' with no resolution." >&2
  exit 1
fi

# A live camera with no gaze model produces nothing, silently. That shipped once,
# because the load failure was swallowed and a Finder launch resolves relative
# model paths against /.
if grep -q "pipeline-ready failed" "${LOG}" 2>/dev/null; then
  echo "FAIL: the gaze pipeline could not load its models." >&2
  grep "pipeline-ready" "${LOG}" >&2
  exit 1
fi
if ! grep -q "pipeline-ready ok" "${LOG}" 2>/dev/null; then
  echo "FAIL: the gaze pipeline never reported readiness." >&2
  exit 1
fi

echo "PASS: launch completed, the camera reported a real state, and the gaze models loaded."

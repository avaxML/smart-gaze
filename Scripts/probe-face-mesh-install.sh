#!/usr/bin/env bash
#
# Proves the face-mesh install verifier behaves: a valid install passes reuse,
# and real content corruption / missing pieces / a held lock fail non-zero.
#
# It never touches the real Models/ tree. Each case runs in a throwaway repo copy
# seeded from the current install. Run Scripts/fetch-face-mesh.sh first.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

INSTALLED="$REPO_ROOT/Models/face-mesh"
COMPILED_NAME="face_mesh.mlmodelc"
if [ ! -d "$INSTALLED/$COMPILED_NAME" ] || [ ! -f "$INSTALLED/compiled.sha256" ]; then
  echo "error: no verified install at $INSTALLED; run Scripts/fetch-face-mesh.sh first" >&2
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/smart-gaze-face-mesh-probe.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
report() {
  if [ "$1" -eq 0 ]; then
    PASS=$((PASS + 1))
    echo "ok   - $2"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL - $2"
  fi
}

new_repo() {
  local dir="$1"
  mkdir -p "$dir/Scripts" "$dir/Models"
  cp "$REPO_ROOT/Scripts/fetch-face-mesh.sh" "$dir/Scripts/"
  cp -R "$INSTALLED" "$dir/Models/face-mesh"
}

SCRIPT_STATUS=1
run_script() {
  set +e
  (cd "$1" && bash Scripts/fetch-face-mesh.sh) >"$1/script.log" 2>&1
  SCRIPT_STATUS=$?
  set -e
}

expect_status() {
  local expected="$1" label="$2"
  if [ "$expected" = ok ] && [ "$SCRIPT_STATUS" -eq 0 ]; then
    report 0 "$label"
  elif [ "$expected" = fail ] && [ "$SCRIPT_STATUS" -ne 0 ]; then
    report 0 "$label"
  else
    report 1 "$label (expected $expected, got $SCRIPT_STATUS)"
  fi
}

case_valid() {
  local dir="$WORK/valid"
  new_repo "$dir"
  run_script "$dir"
  expect_status ok "valid installed cache re-verifies"
  if ! grep -q "already installed and verified" "$dir/script.log"; then
    report 1 "valid cache reports verification"
  else
    report 0 "valid cache reports verification"
  fi
}

case_corrupt_weight() {
  local dir="$WORK/corrupt-weight"
  new_repo "$dir"
  printf 'probe-corruption' >> "$dir/Models/face-mesh/$COMPILED_NAME/model.espresso.weights"
  run_script "$dir"
  expect_status fail "corrupted compiled weights are rejected"
  if [ -d "$dir/Models/face-mesh/$COMPILED_NAME" ]; then
    report 0 "corrupted install is left in place (not deleted)"
  else
    report 1 "corrupted install is left in place (not deleted)"
  fi
}

case_corrupt_nested() {
  local dir="$WORK/corrupt-nested"
  new_repo "$dir"
  printf '\0probe' >> "$dir/Models/face-mesh/$COMPILED_NAME/analytics/coremldata.bin"
  run_script "$dir"
  expect_status fail "corrupted nested compiled file is rejected"
}

case_corrupt_source() {
  local dir="$WORK/corrupt-source"
  new_repo "$dir"
  printf '\0probe' >> "$dir/Models/face-mesh/face_mesh.mlmodel"
  run_script "$dir"
  expect_status fail "corrupted source is rejected"
}

case_missing_manifest() {
  local dir="$WORK/missing-manifest"
  new_repo "$dir"
  rm -f "$dir/Models/face-mesh/compiled.sha256"
  run_script "$dir"
  expect_status fail "missing compiled manifest is rejected"
}

case_missing_required_file() {
  local dir="$WORK/missing-required"
  new_repo "$dir"
  rm -f "$dir/Models/face-mesh/$COMPILED_NAME/model.espresso.shape"
  run_script "$dir"
  expect_status fail "missing required compiled file is rejected"
}

case_held_lock() {
  # No published install, so the script must reach the lock acquisition. The lock
  # is a symlink to a token naming a pid that is not running (a stale lock).
  local dir="$WORK/held-lock"
  mkdir -p "$dir/Scripts" "$dir/Models"
  cp "$REPO_ROOT/Scripts/fetch-face-mesh.sh" "$dir/Scripts/"
  ln -s "999999|1|0" "$dir/Models/.face-mesh-install.lock"
  run_script "$dir"
  expect_status fail "a stale lock is reported instead of proceeding"
  if [ -L "$dir/Models/.face-mesh-install.lock" ]; then
    report 0 "a lock this run does not own is not deleted"
  else
    report 1 "a lock this run does not own is not deleted"
  fi
}

case_incomplete_manifest() {
  local dir="$WORK/incomplete-manifest"
  new_repo "$dir"
  local manifest="$dir/Models/face-mesh/compiled.sha256"
  awk '$2 != "face_mesh.mlmodelc/model.espresso.weights"' "$manifest" > "$manifest.partial"
  mv "$manifest.partial" "$manifest"
  printf 'probe-corruption' >> "$dir/Models/face-mesh/$COMPILED_NAME/model.espresso.weights"
  run_script "$dir"
  expect_status fail "a partial manifest cannot hide corrupted weights"
}

case_directory_lock() {
  local dir="$WORK/directory-lock"
  mkdir -p "$dir/Scripts" "$dir/Models/.face-mesh-install.lock"
  cp "$REPO_ROOT/Scripts/fetch-face-mesh.sh" "$dir/Scripts/"
  printf 'preserve' > "$dir/Models/.face-mesh-install.lock/marker"
  run_script "$dir"
  expect_status fail "a directory lock blocks installation"
  if [ -f "$dir/Models/.face-mesh-install.lock/marker" ]; then
    report 0 "directory lock contents are preserved"
  else
    report 1 "directory lock contents are preserved"
  fi
}

case_valid
case_directory_lock
case_incomplete_manifest
case_corrupt_weight
case_corrupt_nested
case_corrupt_source
case_missing_manifest
case_missing_required_file
case_held_lock

echo
echo "probe: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

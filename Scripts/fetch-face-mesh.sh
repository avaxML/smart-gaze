#!/usr/bin/env bash
#
# Fetch, verify and compile the pinned FaceMesh Core ML model (#032).
#
# The S3 object is mutable, so the artifact is pinned by SHA-256 at every layer:
# the outer tarball, the inner coreml archive, and the .mlmodel itself. Nothing
# is committed: the verified source and compiled model live in the ignored
# Models/ directory as a single published directory:
#
#   Models/face-mesh/
#     face_mesh.mlmodel       (verified source)
#     face_mesh.mlmodelc/     (compiled model)
#     compiled.sha256         (manifest over every compiled file)
#
# Re-running the script verifies the upstream source hash and the compiled
# checksum manifest, and refuses to overwrite corrupted or incomplete artifacts.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

MODELS_DIR="Models"
MLMODEL_FILE="face_mesh.mlmodel"
FINAL_DIR="$MODELS_DIR/face-mesh"
COMPILED_NAME="face_mesh.mlmodelc"
COMPILED="$FINAL_DIR/$COMPILED_NAME"
SOURCE="$FINAL_DIR/$MLMODEL_FILE"
MANIFEST_NAME="compiled.sha256"
MANIFEST="$FINAL_DIR/$MANIFEST_NAME"

LEGACY_SOURCE="$MODELS_DIR/face_mesh.mlmodel"
LEGACY_COMPILED="$MODELS_DIR/face_mesh.mlmodelc"
LOCK_DIR="$MODELS_DIR/.face-mesh-install.lock"

SOURCE_URL="https://s3.ap-northeast-2.wasabisys.com/pinto-model-zoo/032_FaceMesh/032_FaceMesh.tar.gz"
SOURCE_TAR_SHA256="fae6b5b39464fd5f729dbc60f77c96110ba5d03438d72a967c64440cde5f7eb7"
INNER_TAR_SHA256="513097b3c1e736366b7df31089a53502e17ca08235ff167342c8d05324fbee58"
MLMODEL_SHA256="058f184aa7fe7334bcc632307842e9a4866e662ce7071cfd8ece6071299dba51"
INNER_MEMBER="07_coreml/resources.tar.gz"

REQUIRED_COMPILED_FILES=(
  coremldata.bin
  metadata.json
  model.espresso.net
  model.espresso.shape
  model.espresso.weights
  model/coremldata.bin
  analytics/coremldata.bin
  neural_network_optionals/coremldata.bin
)

SCRATCH=""
STAGING=""
LOCK_HELD=0
LOCK_TOKEN=""

cleanup() {
  local status=$?
  trap - EXIT
  if [ -n "$SCRATCH" ] && [ -d "$SCRATCH" ]; then rm -rf "$SCRATCH" || true; fi
  if [ -n "$STAGING" ] && [ -d "$STAGING" ]; then rm -rf "$STAGING" || true; fi
  # Never remove a lock this run did not create. The lock is a symlink whose
  # target is the owner token, so ownership is atomic and unambiguous.
  if [ "$LOCK_HELD" = 1 ] && [ -L "$LOCK_DIR" ] \
    && [ "$(readlink "$LOCK_DIR")" = "$LOCK_TOKEN" ]; then
    rm -f "$LOCK_DIR" || true
  fi
  exit "$status"
}
trap cleanup EXIT

sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

verify_sha() {
  local file="$1" expected="$2" label="$3"
  if [ ! -f "$file" ]; then
    echo "error: $label is missing at $file" >&2
    return 1
  fi
  local actual
  actual="$(sha256 "$file")"
  if [ "$actual" != "$expected" ]; then
    echo "error: $label SHA-256 mismatch" >&2
    echo "  expected $expected" >&2
    echo "  actual   $actual" >&2
    return 1
  fi
}

verify_compiled() {
  local dir="$1" file
  for file in "${REQUIRED_COMPILED_FILES[@]}"; do
    if [ ! -f "$dir/$file" ]; then
      echo "error: compiled model is incomplete: missing $file" >&2
      return 1
    fi
  done
}

# Writes a manifest (sha256, relative path) for every file in the compiled
# directory. The manifest sits next to the compiled model so content corruption
# with intact filenames is detected on reuse.
generate_manifest() {
  local root="$1"
  local out="$root/$MANIFEST_NAME"
  local file
  : > "$out"
  while IFS= read -r file; do
    printf '%s  %s\n' "$(sha256 "$root/$file")" "$file" >> "$out"
  done < <(cd "$root" && find "$COMPILED_NAME" -type f | LC_ALL=C sort)
}

verify_manifest() {
  local root="$1"
  local manifest="$root/$MANIFEST_NAME"
  if [ ! -f "$manifest" ]; then
    echo "error: compiled checksum manifest is missing at $manifest" >&2
    return 1
  fi
  if ! awk 'NF != 2 || length($1) != 64 || $1 ~ /[^0-9a-fA-F]/ { exit 1 }' "$manifest"; then
    echo "error: malformed compiled checksum manifest" >&2
    return 1
  fi
  if ! diff <(cd "$root" && find "$COMPILED_NAME" -type f | LC_ALL=C sort) \
    <(awk '{print $2}' "$manifest" | LC_ALL=C sort) >/dev/null; then
    echo "error: checksum manifest must cover every compiled file exactly once" >&2
    return 1
  fi
  if ! (cd "$root" && shasum -a 256 -c "$MANIFEST_NAME") >/dev/null 2>&1; then
    echo "error: compiled model checksum manifest failed verification" >&2
    echo "       inspect with: (cd $root && shasum -a 256 -c $MANIFEST_NAME)" >&2
    return 1
  fi
}

acquire_lock() {
  mkdir -p "$MODELS_DIR"
  LOCK_TOKEN="$$|$(date +%s)|${RANDOM:-0}"
  # Reject directories too: ln would otherwise create a link inside them.
  if [ ! -e "$LOCK_DIR" ] && [ ! -L "$LOCK_DIR" ] \
    && ln -s "$LOCK_TOKEN" "$LOCK_DIR" 2>/dev/null; then
    LOCK_HELD=1
    return 0
  fi
  local owner="" pid=""
  if [ -L "$LOCK_DIR" ]; then owner="$(readlink "$LOCK_DIR")"; fi
  if [ -n "$owner" ]; then
    pid="${owner%%|*}"
  fi
  if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
    echo "error: stale face-mesh install lock $LOCK_DIR (owner $owner is not running)" >&2
  elif [ -n "$owner" ]; then
    echo "error: another face-mesh install is in progress (lock $LOCK_DIR, owner $owner)" >&2
  else
    echo "error: install lock $LOCK_DIR exists but is not an owned symlink" >&2
  fi
  echo "       this run will not delete a lock it does not own;" >&2
  echo "       if no install is running, remove $LOCK_DIR by hand and retry" >&2
  exit 1
}

# An existing install is verified, never silently overwritten. Corruption or
# incompleteness is reported and the script exits non-zero without deleting
# anything.
if [ -e "$FINAL_DIR" ]; then
  existing_ok=1
  if [ -d "$COMPILED" ]; then
    verify_compiled "$COMPILED" || existing_ok=0
  else
    echo "error: $COMPILED is missing or not a directory; the existing install is incomplete" >&2
    existing_ok=0
  fi
  if [ -f "$SOURCE" ]; then
    verify_sha "$SOURCE" "$MLMODEL_SHA256" "installed source $MLMODEL_FILE" || existing_ok=0
  else
    echo "error: installed source $SOURCE is missing" >&2
    existing_ok=0
  fi
  if [ -f "$MANIFEST" ]; then
    verify_manifest "$FINAL_DIR" || existing_ok=0
  else
    echo "error: compiled checksum manifest $MANIFEST is missing" >&2
    existing_ok=0
  fi
  if [ "$existing_ok" != 1 ]; then
    echo "error: refusing to overwrite the existing $FINAL_DIR artifacts" >&2
    echo "       delete $FINAL_DIR by hand to reinstall" >&2
    exit 1
  fi
  echo "$FINAL_DIR is already installed and verified (source SHA-256 + compiled manifest)."
  exit 0
fi

# Legacy single-file artifacts are left untouched and never silently overwritten.
if [ -e "$LEGACY_COMPILED" ] || [ -e "$LEGACY_SOURCE" ]; then
  echo "note: leaving legacy $MODELS_DIR/face_mesh.* artifacts untouched;" >&2
  echo "      the verified install now lives in $FINAL_DIR" >&2
fi

acquire_lock

# Re-check under the lock so a racing (or stale) publisher cannot be clobbered.
if [ -e "$FINAL_DIR" ]; then
  echo "error: $FINAL_DIR appeared while acquiring the lock; refusing to overwrite" >&2
  exit 1
fi

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/smart-gaze-face-mesh.XXXXXX")"

echo "Downloading pinned source archive..."
curl --fail --location --silent --show-error \
  --output "$SCRATCH/032_FaceMesh.tar.gz" "$SOURCE_URL"
verify_sha "$SCRATCH/032_FaceMesh.tar.gz" "$SOURCE_TAR_SHA256" "source archive"

echo "Extracting only the expected coreml resource archive..."
listing="$SCRATCH/listing.txt"
tar -tzf "$SCRATCH/032_FaceMesh.tar.gz" > "$listing"
member="$(grep -m1 "/${INNER_MEMBER}\$" "$listing" || true)"
if [ -z "$member" ]; then
  echo "error: $INNER_MEMBER was not found in the source archive" >&2
  exit 1
fi
tar -xzf "$SCRATCH/032_FaceMesh.tar.gz" -C "$SCRATCH" "$member"
inner="$SCRATCH/$member"
verify_sha "$inner" "$INNER_TAR_SHA256" "inner coreml archive"

echo "Extracting and verifying $MLMODEL_FILE..."
mkdir -p "$SCRATCH/source"
tar -xzf "$inner" -C "$SCRATCH/source" "$MLMODEL_FILE"
verify_sha "$SCRATCH/source/$MLMODEL_FILE" "$MLMODEL_SHA256" "$MLMODEL_FILE"

echo "Compiling with coremlcompiler..."
mkdir -p "$SCRATCH/compiled"
xcrun coremlcompiler compile "$SCRATCH/source/$MLMODEL_FILE" "$SCRATCH/compiled"
if [ ! -d "$SCRATCH/compiled/$COMPILED_NAME" ]; then
  echo "error: coremlcompiler did not produce $COMPILED_NAME" >&2
  exit 1
fi

echo "Staging the published directory..."
mkdir -p "$MODELS_DIR"
STAGING="$(mktemp -d "$MODELS_DIR/.face-mesh-staging.XXXXXX")"
install_root="$STAGING/face-mesh"
mkdir -p "$install_root"
mv "$SCRATCH/compiled/$COMPILED_NAME" "$install_root/"
mv "$SCRATCH/source/$MLMODEL_FILE" "$install_root/"
generate_manifest "$install_root"

# Verify everything in staging before the single atomic directory publication.
verify_compiled "$install_root/$COMPILED_NAME"
verify_sha "$install_root/$MLMODEL_FILE" "$MLMODEL_SHA256" "staged source $MLMODEL_FILE"
verify_manifest "$install_root"

# Atomic: rename a complete directory into place. No partial final state exists.
mv "$install_root" "$FINAL_DIR"

verify_compiled "$COMPILED"
verify_sha "$SOURCE" "$MLMODEL_SHA256" "installed source $MLMODEL_FILE"
verify_manifest "$FINAL_DIR"

echo "Installed $FINAL_DIR (source, compiled model, compiled.sha256)."

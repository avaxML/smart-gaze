#!/usr/bin/env bash
set -euo pipefail

readonly MODEL_URL="https://github.com/AACTools/MacGaze/releases/download/v0.1.0-assets/blazegaze.mlmodelc.zip"
readonly MODEL_ZIP_SHA256="95663b6961616968d72b253934efd2393b73c325a0385dcba2d32f3c376561ac"
readonly MODEL_WEIGHTS_SHA256="c42886053fc9e0386bb07a2c038ef2239a0b2f417268886c1eb0837fbf5f240a"

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly MODELS_DIR="${REPO_ROOT}/Models"
readonly MODEL_DIR="${MODELS_DIR}/blazegaze.mlmodelc"

readonly REQUIRED_MODEL_FILES=(
  "model.mil"
  "coremldata.bin"
  "metadata.json"
  "weights/weight.bin"
)

verify_existing_model() {
  local model_dir="$1"
  local missing=()
  local relative
  for relative in "${REQUIRED_MODEL_FILES[@]}"; do
    if [[ ! -f "${model_dir}/${relative}" ]]; then
      missing+=("${relative}")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    echo "refusing to use existing artifact at ${model_dir}: missing ${missing[*]}" >&2
    echo "inspect it yourself, then delete that directory and re-run Scripts/fetch-blazegaze.sh" >&2
    exit 1
  fi

  local actual_weights_sha256
  actual_weights_sha256="$(shasum -a 256 "${model_dir}/weights/weight.bin" | cut -d ' ' -f 1)"
  if [[ "${actual_weights_sha256}" != "${MODEL_WEIGHTS_SHA256}" ]]; then
    echo "refusing to use existing artifact at ${model_dir}: weights SHA-256 mismatch" >&2
    echo "expected ${MODEL_WEIGHTS_SHA256}, got ${actual_weights_sha256}" >&2
    echo "inspect it yourself, then delete that directory and re-run Scripts/fetch-blazegaze.sh" >&2
    exit 1
  fi
}

if [[ -d "${MODEL_DIR}" ]]; then
  verify_existing_model "${MODEL_DIR}"
  echo "blazegaze.mlmodelc already present and verified at ${MODEL_DIR}"
  exit 0
fi

mkdir -p "${MODELS_DIR}"
tmp_dir="$(mktemp -d "${MODELS_DIR}/.fetch-blazegaze.XXXXXX")"
cleanup() {
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

zip_path="${tmp_dir}/blazegaze.mlmodelc.zip"
curl --fail --location --silent --show-error "${MODEL_URL}" --output "${zip_path}"

actual_zip_sha256="$(shasum -a 256 "${zip_path}" | cut -d ' ' -f 1)"
if [[ "${actual_zip_sha256}" != "${MODEL_ZIP_SHA256}" ]]; then
  echo "zip SHA-256 mismatch: expected ${MODEL_ZIP_SHA256}, got ${actual_zip_sha256}" >&2
  exit 1
fi

unzip -q "${zip_path}" -d "${tmp_dir}/unpacked"

unpacked_model="${tmp_dir}/unpacked/blazegaze.mlmodelc"
if [[ ! -d "${unpacked_model}" ]]; then
  echo "archive did not contain blazegaze.mlmodelc" >&2
  exit 1
fi

actual_weights_sha256="$(shasum -a 256 "${unpacked_model}/weights/weight.bin" | cut -d ' ' -f 1)"
if [[ "${actual_weights_sha256}" != "${MODEL_WEIGHTS_SHA256}" ]]; then
  echo "weights SHA-256 mismatch: expected ${MODEL_WEIGHTS_SHA256}, got ${actual_weights_sha256}" >&2
  exit 1
fi

mv "${unpacked_model}" "${MODEL_DIR}"
echo "installed ${MODEL_DIR}"

#!/usr/bin/env bash
# Fetches every pinned model the app needs, in one step. Both fetchers verify
# their own SHA-256 and write into the gitignored Models/ directory.
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "${SCRIPT_DIR}/fetch-blazegaze.sh" "$@"
bash "${SCRIPT_DIR}/fetch-face-mesh.sh" "$@"

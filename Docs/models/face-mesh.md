# FaceMesh model (#032)

`FaceMeshEstimator` runs a dense 468-point face mesh on a caller-prepared
`[1, 192, 192, 3]` float32 RGB crop. It is the landmark source for the
preprocessing pipeline; the caller owns cropping, resizing, orientation, colour
conversion and mapping landmarks back to full-image space.

## Artifacts and pinned hashes

The upstream S3 path is mutable, so every layer is pinned by SHA-256. The fetch
script (`Scripts/fetch-face-mesh.sh`) downloads to a scratch file, verifies each
layer, extracts only the expected inner asset, compiles with `coremlcompiler`,
writes a checksum manifest over the compiled files, and publishes the result as a
single directory under the git-ignored `Models/` directory:

```
Models/face-mesh/
  face_mesh.mlmodel        verified source
  face_mesh.mlmodelc/      compiled model
  compiled.sha256          SHA-256 manifest over every compiled file
```

Publication is an atomic directory rename from a unique `Models/.face-mesh-staging.*`
directory; no partial final state is visible. Concurrent installers are serialized
by an owned lock (`Models/.face-mesh-install.lock`): a second run reports the
holder and exits non-zero, and a run never deletes a lock it does not own. On
reuse the script verifies both the pinned source hash and the compiled manifest,
so content corruption with intact filenames is rejected instead of being called
"verified". Existing artifacts are never overwritten; the script exits non-zero
and asks the operator to remove them.

Legacy `Models/face_mesh.mlmodel` / `Models/face_mesh.mlmodelc` files from earlier
runs are left untouched (only noted), never silently overwritten.

| Layer | Value |
| --- | --- |
| Source archive | `https://s3.ap-northeast-2.wasabisys.com/pinto-model-zoo/032_FaceMesh/032_FaceMesh.tar.gz` |
| Source archive SHA-256 | `fae6b5b39464fd5f729dbc60f77c96110ba5d03438d72a967c64440cde5f7eb7` |
| Inner `07_coreml/resources.tar.gz` SHA-256 | `513097b3c1e736366b7df31089a53502e17ca08235ff167342c8d05324fbee58` |
| `face_mesh.mlmodel` SHA-256 | `058f184aa7fe7334bcc632307842e9a4866e662ce7071cfd8ece6071299dba51` |

No model weights are committed. `Models/` is ignored.

## Interface

Compiled with `specificationVersion` 4, `MLModelType_neuralNetwork`,
`storagePrecision Float32`, `computePrecision Float16` (hence the loose
coordinate tolerance in the tests).

- Input `input_1`: `MLMultiArray(Float32 [1, 192, 192, 3])`, RGB, `0...1`,
  top-left origin.
- Output `conv2d_20`: 1404 values = 468 `(x, y, z)` triples in crop-pixel space
  (`x`, `y` in `0...192`; `z` relative depth).
- Output `conv2d_30`: 1 raw face-presence logit; `sigmoid` is the presence score.

Both outputs declare an empty (dynamic) shape. The estimator therefore validates
the declared input shape at load time, and the runtime dtype (`float32`) and
concrete element counts at prediction time; it does not assert fixed declared
output shapes. Engine-owned output arrays are read through `MLMultiArray`
subscripting so non-contiguous strides are honoured. Inputs are allocated by the
estimator, so their storage is copied contiguously.

## Provenance and licence

- The artifact is a third-party conversion of Google's MediaPipe FaceMesh,
  produced with `coremltools 4.0b3` / `tensorflow 2.3.0` (see the model's
  `userDefinedMetadata`).
- The containing PINTO_model_zoo repository is MIT-licensed, but the tarball
  ships **no licence text**. The model lineage is Apache-2.0.
- Licence is therefore recorded as unresolved: MIT tooling, Apache-2.0-derived
  model, third-party conversion, no shipped licence text. This document does not
  claim universal MIT rights over the weights.

## Tests

Unit tests (input validation, sigmoid formula, missing-model error) run by
default. The model integration tests are gated: set
`SMART_GAZE_FACE_MESH_TESTS=1` and optionally
`SMART_GAZE_FACE_MESH_MODEL_PATH` (default `Models/face-mesh/face_mesh.mlmodelc`).
When the flag is set but the model is absent the test fails with `modelMissing`
rather than skipping. The CPU fixture literals come from an independent direct-Core
ML probe and only pin the wiring (row-major input, RGB channel order, 468-triple
decode), not biological accuracy or MediaPipe parity.

Install verification is probed by `Scripts/probe-face-mesh-install.sh`, which
copies a valid install into a temp repo and asserts that a valid cache passes
while a content-corrupted compiled weight, a corrupted source, a missing
manifest, a removed compiled file, and a pre-existing stale lock all fail
non-zero.

Test coverage gaps, stated honestly: only the entry cancellation checkpoint is
tested; the pre-/post-prediction checkpoints and the `validateInterface`
rejection branches (wrong input shape, unexpected/fixed output shapes, wrong
dtype) have no negative tests, and malformed-model paths would need fixture
assets outside this change.

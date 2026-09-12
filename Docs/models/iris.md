# Iris landmark model (049_iris_landmark)

`IrisLandmarkEstimator` runs MediaPipe's 71-point eye-contour and 5-point iris
model on a caller-prepared `[1, 64, 64, 3]` float32 RGB eye crop. It is the
iris source for the gaze pipeline: the base 468-point face mesh has no iris
points, so the mesh eye-baseline depth scales an assumed 6.3 cm interpupillary
distance, which varies about 10 percent across adults, while iris diameter is
11.7 mm with almost no population variance. The iris ruler is therefore
person-independent. The 71 contour points are also what a later calibration
screen draws. The caller owns cropping, resizing, orientation, colour
conversion and mapping points back to full-image space.

## Artifacts and pinned hashes

The upstream S3 path is mutable, so every layer is pinned by SHA-256. The fetch
script (`Scripts/fetch-iris.sh`) downloads to a scratch file, verifies each
layer, extracts only the expected inner asset, compiles with `coremlcompiler`,
writes a checksum manifest over the compiled files, and publishes the result as
a single directory under the git-ignored `Models/` directory:

```
Models/iris/
  iris_landmark_64x64_float32.mlmodel        verified source
  iris_landmark_64x64_float32.mlmodelc/      compiled model
  compiled.sha256                            SHA-256 manifest over every compiled file
```

Publication is an atomic directory rename from a unique `Models/.iris-staging.*`
directory; no partial final state is visible. Concurrent installers are
serialized by an owned lock (`Models/.iris-install.lock`): a second run reports
the holder and exits non-zero, and a run never deletes a lock it does not own.
On reuse the script verifies both the pinned source hash and the compiled
manifest, so content corruption with intact filenames is rejected instead of
being called "verified". Existing artifacts are never overwritten; the script
exits non-zero and asks the operator to remove them.

| Layer | Value |
| --- | --- |
| Source archive | `https://s3.ap-northeast-2.wasabisys.com/pinto-model-zoo/049_iris_landmark/resources.tar.gz` |
| Source archive SHA-256 | `855a639e9ec9718dffb9d5fef857698b56b537b0e8a8746ce80ef4577a5fffe0` |
| Inner `08_coreml/resources.tar.gz` SHA-256 | `b48393f7fae66accebd642919836e6e3682039b831dd6b74acaf11838fa1686a` |
| `iris_landmark_64x64_float32.mlmodel` SHA-256 | `a121e7b2afda92ba0f5f370ef49e15b9eecb7376e1e822a21d2778c674af78bb` |

No model weights are committed. `Models/` is ignored.

## Interface

Compiled with `specificationVersion` 4, `MLModelType_neuralNetwork`,
`storagePrecision Float32`, `computePrecision Float16` (hence the loose
coordinate tolerance in the tests).

- Input `input_1`: `MLMultiArray(Float32 [1, 64, 64, 3])`, RGB, `0...1`,
  top-left origin.
- Output `output_eyes_contours_and_brows`: 213 values = 71 `(x, y, z)` triples
  in crop-pixel space (`x`, `y` in `0...64`; `z` relative depth).
- Output `output_iris`: 15 values = 5 `(x, y, z)` triples: index 0 the iris
  centre, 1 and 3 the horizontal extremes, 2 and 4 the vertical extremes.

Both outputs declare an empty (dynamic) shape. The estimator therefore
validates the declared input shape at load time, and the runtime dtype
(`float32`) and concrete element counts at prediction time; it does not assert
fixed declared output shapes. Engine-owned output arrays are read through
`MLMultiArray` subscripting so non-contiguous strides are honoured. Inputs are
allocated by the estimator, so their storage is copied contiguously.

## Crop convention

MediaPipe's eye ROI is a square centred on the midpoint of the two eye-corner
landmarks, with `side = cornerDistance * 2.3` and
`rotation = atan2(right.y - left.y, right.x - left.x)` folded into
`(-pi/2, pi/2]` exactly like `FaceCrop.tracking`. The square is resampled to a
64-pixel crop through the rotation with `FaceCrop.frameToCrop` and `warpedRGB`.

- Eye A (the image-left eye) uses landmarks 33 (image left corner) and 133
  (image right corner).
- Eye B (the image-right eye) uses landmarks 362 (image left corner) and 263
  (image right corner).
- The camera is not mirrored, so eye A is on the image left. The model was
  trained on left-eye-shaped crops, so eye B's crop is horizontally flipped
  before inference and its output is unflipped (`x' = 63 - x`, `y` and `z`
  unchanged) before it is mapped back. This mirrors MediaPipe, which flips the
  opposite eye rather than running a second model.
- Flipping and unflipping is an assumption about the model's training
  convention, inferred from MediaPipe, not a documented property of this
  third-party conversion.

## Depth

`depthCentimetres = focalLengthPixels * 11.7 / 10 / diameterPixels`, where
`diameterPixels` is the distance between the mapped iris points 1 and 3 in frame
pixels. The pipeline uses the same resolved vertical focal length
(`resolvedVerticalFocalLengthPixels`) that `metricFaceOrigin` uses, so a camera
with a reported intrinsic matrix corrects both rulers consistently. An
`IrisEstimate.depthCentimetres` is the mean of the two eyes' depths.

## Provenance and licence

- The artifact is a third-party Core ML conversion of Google's MediaPipe
  `iris_landmark.tflite`, produced with `coremltools 4.0b3` / `tensorflow 2.3.0`
  (the same converter as the face mesh).
- The containing PINTO_model_zoo repository is MIT-licensed, but the tarball
  ships **no licence text**. The model lineage is Apache-2.0.
- Licence is therefore recorded as unresolved: MIT tooling, Apache-2.0-derived
  model, third-party conversion, no shipped licence text. This document does not
  claim universal MIT rights over the weights.

## Tests

Unit tests (`Tests/GazeKitTests/IrisGeometryTests.swift` for the pure geometry,
plus input validation, missing-model error and the model gate) run by default.
The model integration tests are gated: set `SMART_GAZE_IRIS_TESTS=1` and
optionally `SMART_GAZE_IRIS_MODEL_PATH` (default
`Models/iris/iris_landmark_64x64_float32.mlmodelc`). When the flag is set but
the model is absent the test fails with `modelMissing` rather than skipping. A
mid-grey 64x64 input must yield 71 and 5 finite points with `x` and `y` inside
`-16...80`; that only pins output shape and wiring, not biological accuracy or
MediaPipe parity.

The video harness (`Scripts/video-gaze-harness.sh`) takes an optional iris model
path and prints the number of frames with an iris estimate, the median iris
diameter in pixels per eye, and the median iris depth against the median
eye-baseline depth on the same frames, so the two rulers can be compared.

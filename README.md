# smart-gaze

An ambient macOS menu bar assistant. Hold a modifier, look at the thing you do not
understand, and a floating glass bubble explains it.

The app watches your gaze through the built-in webcam. When your eyes settle on a
region of the screen, it captures just that region, sends it to a vision model you
configure, and streams the explanation back into a bubble next to what you were
looking at. Nothing is written to disk.

Status: early construction. Nothing here works yet.

## Requirements

- Apple Silicon Mac
- macOS 26 or later
- Xcode 26 toolchain (Swift 6.3)

## Build

```
swift build
```

## Architecture

Six targets, layered inward. `GazeKit` is the pure core and depends on nothing.

- `GazeKit` holds the domain types and pure logic. No AppKit, no SwiftUI, no capture.
- `Perception` will own gaze estimation from camera frames.
- `ScreenCapture` will own grabbing the region you looked at.
- `Providers` will own talking to the vision model you configure.
- `OverlayUI` will own the floating bubble.
- `SmartGaze` is the executable that wires the four outer targets together.

The dependency rule runs one way. Every outer target depends on `GazeKit` and on
nothing else in this package, and `SmartGaze` depends on all five. Outer targets
never depend on each other, so a change to the overlay cannot ripple into capture.
`Tests/GazeKitTests/LayeringTests.swift` reads the real dependency graph out of
`swift package dump-package` and fails if any edge is added or removed.

## Build And Package

```
swift build
swift test
bash Scripts/make-app.sh
```

`make-app.sh` produces an ad-hoc signed `dist/SmartGaze.app`. `dist/` is gitignored.

## Tuning

The default dispersion threshold is 160 points. That number is an
uncalibrated placeholder, not a measured value. It stays in place until issue
#21 records real jitter calibration measurements, so do not read precision into
it.

## Model provenance

`Perception` runs the compiled BlazeGaze Core ML model through
`BlazeGazeEstimator`. The estimator takes one already-prepared training-format eye
band (`image [1, 128, 512, 3]` float32, RGB divided by 255), a unit head direction
vector, and a metric face origin in centimetres. It returns the model's normalized
screen point (`Identity [1, 2]`) without clamping. Callers must do the dense-mesh
preprocessing themselves; the estimator does not accept a raw Vision face crop.

The fetched artifact is the third-party Core ML conversion published by
[AACTools/MacGaze](https://github.com/AACTools/MacGaze) in the `v0.1.0-assets`
release. Its source is the Keras weights in
[RedForestAI/WebEyeTrack](https://github.com/RedForestAI/WebEyeTrack) at commit
`75fbd2f5f784f2eb3a39675a8dcbf1b01c697f1c`:

- source weights: `python/webeyetrack/model_weights/blazegaze_mpiifacegaze.keras`
- source weights SHA-256: `5b011cfe82466896e27b1ac3e18130117cafbc02dbc964a1ad7315f62005cc05`
- model archive: `blazegaze.mlmodelc.zip`
- model archive SHA-256: `95663b6961616968d72b253934efd2393b73c325a0385dcba2d32f3c376561ac`

The available weights are the MPIIFaceGaze variant. The paper's 4.56 cm error is
the published result for that variant, not our measured accuracy. We have not run
the live four-corner protocol, so we quote no accuracy of our own. The paper's
separate GazeCapture figure (2.32 cm) belongs to weights we do not ship.

Both upstream code repositories use MIT licenses. We have not independently
verified the source model or MPIIFaceGaze training-data terms. Copied upstream
code must retain its attribution; this runner is a new wrapper.

Assets are never committed. Fetch the compiled model locally:

```
bash Scripts/fetch-blazegaze.sh
```

The script pins the URL and SHA-256, downloads to an ignored `Models/` directory,
verifies the archive and inner weights, and unpacks atomically so repeated runs
are safe. Model-dependent tests stay off unless `SMART_GAZE_MODEL_TESTS=1` and
`SMART_GAZE_MODEL_PATH` are set; CI runs them in an explicit `model-integration`
job after fetching the artifact.

Benchmark the prepared-input inference path with:

```
bash Scripts/benchmark-blazegaze.sh
```

It reports warmup and measured latency for `.cpuOnly` and `.all` on a synthetic
uniform input, plus the `MLComputePlan` planned device assignments per operation.
Planned assignments are not profiler-proven execution, and the 33 ms pipeline
budget is not measured by this model-only benchmark.

### Dense face landmarks

`Perception` also runs a second model. `FaceMeshEstimator` produces the 468 dense
landmarks that the eye band, the head vector and the metric face origin are all
derived from, so it sits upstream of everything BlazeGaze sees.

Its provenance is weaker than BlazeGaze's and is recorded rather than resolved. The
artifact is a third-party conversion of Google's MediaPipe FaceMesh. The repository
that carries it is MIT licensed, the model lineage is Apache-2.0, and the tarball
itself ships **no licence text**. We do not claim MIT rights over those weights.

The upstream path is mutable, so every layer is pinned by SHA-256, including the
source archive, the inner tarball, the uncompiled model and a manifest over every
compiled file. Fetch it the same way, and it lands in the same ignored `Models/`
directory:

```
bash Scripts/fetch-face-mesh.sh
```

Full details, including the pinned hashes and the interface, are in
[`Docs/models/face-mesh.md`](Docs/models/face-mesh.md). The eye-band geometry it
feeds is documented in
[`Docs/models/eye-band-geometry.md`](Docs/models/eye-band-geometry.md).

### What is unresolved

Two things are open and neither is hidden in a comment.

The training-data terms for both models are unverified. BlazeGaze ships the
MPIIFaceGaze variant, and MPIIFaceGaze, Gaze360 and GazeCapture all carry
non-commercial clauses. The MIT tags upstream describe the code, not the weights.
Treat this build as personal and research use until those terms are established.

The metric face origin is an approximation, not a reconstruction. The faithful
upstream method needs `face_width_cm` from iris landmarks 468 to 477, which the base
468-point mesh does not provide. What ships instead scales an assumed 6.3 cm
interpupillary distance against an assumed 60 degree vertical field of view. Neither
constant has been fitted to a real camera yet.

## Licence

MIT. See `LICENSE`.

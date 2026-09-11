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

## Running it for the first time

The app is `LSUIElement`, so it has no Dock icon and no window. Everything is the menu bar item.

```
bash Scripts/fetch-models.sh
bash Scripts/make-app.sh
open dist/SmartGaze.app
```

Then click the menu bar icon and choose Start. The icon tells you what the app is waiting for rather
than leaving you guessing, so read it if nothing seems to happen.

### Two permissions, asked at different moments

**Camera** is requested the first time you press Start. Until you answer, the menu says it is waiting for
permission. The prompt can land on whichever display is not in front of you, which is worth knowing on a
multi-monitor setup.

**Accessibility** is only needed for the default modifier-held activation mode, because watching for a
held Fn or Option key means tapping global events. Without it the app falls back to passive dwell and
says so in the menu. It never blocks startup waiting for you to notice.

### The grant is tied to the exact build

This app is signed ad hoc, so macOS identifies it by the hash of what was built. That hash is stable
across rebuilds of unchanged source, so a grant survives running `make-app.sh` again. **Changing any
source file produces a different app as far as the system is concerned, and the permission has to be
granted again.**

In practice: build once, grant once, then test. If you rebuild after changing code and the camera goes
back to asking for permission, nothing is broken.

### Calibration

Gaze is meaningless without it, so the app does not guess. Until you calibrate, the menu shows an
uncalibrated state with a Calibrate Now action, and frames are deliberately discarded rather than turned
into a gaze point nobody should trust.

Calibration shows nine targets in turn. Hold your gaze on each one. A burst that is too scattered is
thrown away and that target is shown again, so one bad moment does not quietly poison the whole fit.
Escape abandons the run and leaves any previous calibration exactly as it was.

At the end it reports the error it measured against four points it did **not** use in the fit, separately
for horizontal and vertical, because those two axes do not behave the same and one averaged number would
hide the weaker one. That figure is the honest answer to whether this works for you.

## Checking it still works

```
bash Scripts/launch-smoke.sh
```
Launches the built bundle and fails if startup never completes or the camera never reports a state. Three
shipped defects lived in that path with the whole unit suite green.

```
bash Scripts/run-video-gaze-harness.sh <video.mp4> Models/face_mesh.mlmodelc Models/blazegaze.mlmodelc 200
```
Runs real video frames through the gaze pipeline and fails if any frame does not produce a finite gaze
point. Release build only; the debug build is roughly twenty times slower and its latency numbers mean
nothing.

## Model provenance

`Perception` runs the compiled BlazeGaze Core ML model through
`BlazeGazeEstimator`. The estimator takes one already-prepared training-format eye
band (`image [1, 128, 512, 3]` float32, RGB divided by 255), a unit head direction
vector, and a metric face origin in centimetres. It returns the model's screen
point (`Identity [1, 2]`) without clamping; the output is centred on zero and spans
roughly plus or minus 0.5 across a display, and only a fitted `CalibrationMap` turns
it into points. Callers must do the dense-mesh
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
interpupillary distance against a vertical field of view of 32 degrees, fitted on
one MacBook Pro 14 inch built-in camera (`CameraGeometry`), because that camera
reports no intrinsic matrix. The origin is in the camera frame BlazeGaze was
trained on: x image-right, y image-down, z away, centimetres.

The calibration map is fitted at one head position. `HeadTranslationCorrection`
moves the projected point by the head's sideways and vertical displacement since
calibration, using the display's physical density; depth is left to the model,
whose own origin term tracks it.

## Licence

MIT. See `LICENSE`.

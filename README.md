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

## Licence

MIT. See `LICENSE`.

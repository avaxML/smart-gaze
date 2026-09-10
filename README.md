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

## Licence

MIT. See `LICENSE`.

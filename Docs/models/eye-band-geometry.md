# Eye-band geometry

Pure, source-matched geometry for the 512×128 BlazeGaze eye-band input. This
unit computes geometry only: no camera, no model assets, no raster work.

## Scope

`GazeKit.EyeBandGeometry` reproduces the geometric part of WebEyeTrack's
`obtain_eyepatch` (`python/webeyetrack/model_based.py:31-78`) and the MacGaze
`HomographyEyePatchExtractor` port, up to but not including row cropping and
resizing. Raster resampling, pose, metric origin, and camera wiring remain with
#8.

## Formula

1. Landmarks 103/150/379/332 and centre 4 are converted from full-frame
   normalized top-left coordinates to pixels: `px = x·W`, `py = y·H`.
2. Each corner is padded radially away from the centre in pixel space with
   anisotropic coefficients `(0.4, 0.2)`:
   `q = p + (0.4·(p−c).x, 0.2·(p−c).y)`.
   Source order is `[103, 150, 379, 332]` (lefttop, leftbottom, rightbottom,
   righttop). Padding is never clamped to the frame.
3. The projective map `H` sends the padded quad to
   `[(0,0), (0,512), (512,512), (512,0)]`, solved by the direct linear
   transform (DLT) in the `h22 = 1` gauge.
4. Landmarks 151 and 195 are projected through `H`; `y` is truncated toward
   zero and clamped to `0...512`.
5. The band is the half-open range `[top, bottom)`. An empty or reversed range
   (`bottom ≤ top`) is rejected.

`ProjectiveTransform` exposes the forward map, its inverse (analytic 3×3
adjugate), and relative-singularity checks. A non-finite point, a near-zero
homogeneous denominator, or a singular correspondence returns `nil` instead of
crashing.

Matrix coefficients are normalized before products are formed. The map compares
its homogeneous denominator with the terms forming that denominator. The inverse
compares the determinant with its expansion terms, so a large translation alone
does not look singular. It returns the adjugate, avoiding division by a tiny
determinant. Literal tests cover scaled-equivalent matrices, large translations
and cancellation near a singularity.

## Formula sources

- WebEyeTrack `obtain_eyepatch`: landmark indices, padding coefficients,
  destination points, and band indices.
- MacGaze `HomographyEyePatchExtractor.swift`: the same DLT, the `0...512`
  clamp, and the `bottom > top` guard.
- Standard 4-point DLT with partial-pivot Gaussian elimination; the MacGaze
  port uses the identical `8×8` system. No upstream source is copied verbatim.

Both upstream projects are MIT-licensed; no license text needed to be carried
because this is an independent implementation of standard mathematics.

## Parity status

**Geometry parity only.** The literal tests pin the padded quad, the row band,
and the forward/inverse maps. They do not compare pixels.

Upstream warps the whole frame to 512×512 and then resizes the band with
`cv2.resize` (default INTER_LINEAR). MacGaze resizes the extracted band with
`vImageScale_ARGB8888(kvImageEdgeExtend)`. Fused sampling and two-stage
warp-plus-resize are **not** bit-identical, so this unit does not claim
preprocessing pixel parity or any live accuracy.

## Known limits

- Landmark indices 151 and 195 truncate toward zero before clamping, matching
  the Python `np.int32` cast for the values seen; negative results clamp to 0.
- The fixed `h22 = 1` solve cannot represent a transform whose bottom-right
  matrix coefficient must be zero; those correspondences are rejected.
- Only landmark indices below 468 are read, so a 468-point mesh is sufficient.
- Verified against exact rational reference arithmetic; NumPy was not installed
  in the worktree, so no NumPy cross-check was run.

import CoreGraphics
import Foundation

/// Full-frame views of dense-mesh landmarks, derived from the model's
/// crop-pixel output by `mapCropLandmarksToFrame`.
public struct FullFrameLandmarks: Equatable, Sendable {
  /// Top-left normalized `(0...1)` points, `EyeBandGeometry`'s native input.
  public let normalized: [CGPoint]

  /// Frame-pixel-scale, top-left, y-down triples: `x` and `y` in frame
  /// pixels, `z` on the same pixel scale. This is `headPoseInputs`'s
  /// expected landmark space.
  public let pixelSpace: [SIMD3<Double>]
}

public enum FaceMeshMapBackError: Error, Equatable {
  case invalidCrop
  case invalidFrame
}

/// Maps dense-mesh landmarks out of the model's square crop-pixel space
/// (u08 plan §1.3: `0...cropPixelSize`, top-left, `z` relative depth) back
/// onto the full camera frame.
///
/// Getting this wrong is silent: every downstream stage still runs and
/// returns a plausible-looking, wrong gaze point, because nothing else
/// checks that the landmarks landed in the right place in the frame.
///
/// - Parameters:
///   - cropLandmarks: Landmarks in the model's crop-pixel space.
///   - cropPixelSize: The model's square crop side, in crop pixels (192 for
///     the pinned face-mesh model).
///   - cropRect: The crop's rectangle in full-frame pixels, top-left origin.
///     Width and height need not match each other or the frame's aspect.
///   - frameSize: Positive full-frame dimensions in pixels.
public func mapCropLandmarksToFrame(
  cropLandmarks: [SIMD3<Float>],
  cropPixelSize: Double,
  cropRect: CGRect,
  frameSize: CGSize
) throws -> FullFrameLandmarks {
  guard cropPixelSize.isFinite, cropPixelSize > 0 else { throw FaceMeshMapBackError.invalidCrop }
  guard
    cropRect.origin.x.isFinite, cropRect.origin.y.isFinite,
    cropRect.width.isFinite, cropRect.height.isFinite,
    cropRect.width > 0, cropRect.height > 0
  else { throw FaceMeshMapBackError.invalidCrop }
  guard
    frameSize.width.isFinite, frameSize.height.isFinite,
    frameSize.width > 0, frameSize.height > 0
  else { throw FaceMeshMapBackError.invalidFrame }

  let originX = Double(cropRect.origin.x)
  let originY = Double(cropRect.origin.y)
  let scaleX = Double(cropRect.width) / cropPixelSize
  let scaleY = Double(cropRect.height) / cropPixelSize
  let width = Double(frameSize.width)
  let height = Double(frameSize.height)

  var normalized: [CGPoint] = []
  var pixelSpace: [SIMD3<Double>] = []
  normalized.reserveCapacity(cropLandmarks.count)
  pixelSpace.reserveCapacity(cropLandmarks.count)

  for landmark in cropLandmarks {
    let pixelX = originX + Double(landmark.x) * scaleX
    let pixelY = originY + Double(landmark.y) * scaleY
    let pixelZ = Double(landmark.z) * scaleX
    normalized.append(CGPoint(x: pixelX / width, y: pixelY / height))
    pixelSpace.append(SIMD3<Double>(pixelX, pixelY, pixelZ))
  }

  return FullFrameLandmarks(normalized: normalized, pixelSpace: pixelSpace)
}

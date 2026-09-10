import CoreGraphics
import Foundation

public enum EyeBandRasterError: Error, Equatable {
  case noFaceGeometry
}

/// Builds the 512×128 RGB eye band BlazeGaze reads, from a full-frame pixel
/// source and full-frame normalized landmarks.
///
/// Warps the frame through `EyeBandGeometry`'s projective map into a 512×512
/// face crop, then crops and resizes that crop's eye rows down to 512×128.
/// Row-major, matching `BlazeGazeInput.eyeBandShape` `[1, 128, 512, 3]`.
public func eyeBandRGB(
  from source: some PixelSource,
  landmarks: [CGPoint],
  frameSize: CGSize
) throws -> [Float] {
  guard let geometry = EyeBandGeometry.compute(landmarks: landmarks, frameSize: frameSize) else {
    throw EyeBandRasterError.noFaceGeometry
  }

  let side = EyeBandGeometry.faceCropSize
  let warped = try warpedRGB(source, transform: geometry.transform, width: side, height: side)
  guard let warpedSource = ArrayPixelSource(width: side, height: side, rgb: warped) else {
    throw EyeBandRasterError.noFaceGeometry
  }

  let bandHeight = geometry.bandRowRange.count
  let region = CGRect(
    x: 0, y: geometry.bandRowRange.lowerBound, width: side, height: bandHeight)
  return try resampledRGB(warpedSource, from: region, width: side, height: 128)
}

import CoreGraphics
import Foundation

public protocol PixelSource {
  var width: Int { get }
  var height: Int { get }
  func rgb(x: Int, y: Int) -> SIMD3<Float>
}

public enum RasterError: Error, Equatable {
  case emptyOutput(width: Int, height: Int)
  case nonInvertibleTransform
}

public func bilinearRGB(_ source: some PixelSource, x: Double, y: Double) -> SIMD3<Float> {
  let maxX = Double(source.width - 1)
  let maxY = Double(source.height - 1)
  let clampedX = min(max(x, 0), maxX)
  let clampedY = min(max(y, 0), maxY)

  let x0 = Int(clampedX.rounded(.down))
  let y0 = Int(clampedY.rounded(.down))
  let x1 = min(x0 + 1, source.width - 1)
  let y1 = min(y0 + 1, source.height - 1)

  let fx = Float(clampedX - Double(x0))
  let fy = Float(clampedY - Double(y0))

  let topLeft = source.rgb(x: x0, y: y0)
  let topRight = source.rgb(x: x1, y: y0)
  let bottomLeft = source.rgb(x: x0, y: y1)
  let bottomRight = source.rgb(x: x1, y: y1)

  let top = topLeft + (topRight - topLeft) * fx
  let bottom = bottomLeft + (bottomRight - bottomLeft) * fx
  return top + (bottom - top) * fy
}

public func resampledRGB(
  _ source: some PixelSource,
  from region: CGRect,
  width: Int,
  height: Int
) throws -> [Float] {
  guard width >= 1, height >= 1 else {
    throw RasterError.emptyOutput(width: width, height: height)
  }

  var output = [Float](repeating: 0, count: width * height * 3)
  for j in 0..<height {
    // bilinearRGB treats integer coordinates as source pixel centres, so an
    // identity resample over region (0, 0, W, H) with matching output size
    // must land destination j on source pixel centre j, not j + 0.5.
    let sampleY = Double(region.minY) + Double(j) * Double(region.height) / Double(height)
    for i in 0..<width {
      let sampleX = Double(region.minX) + Double(i) * Double(region.width) / Double(width)
      let color = bilinearRGB(source, x: sampleX, y: sampleY)
      let index = (j * width + i) * 3
      output[index] = color.x
      output[index + 1] = color.y
      output[index + 2] = color.z
    }
  }
  return output
}

public func warpedRGB(
  _ source: some PixelSource,
  transform: ProjectiveTransform,
  width: Int,
  height: Int
) throws -> [Float] {
  guard width >= 1, height >= 1 else {
    throw RasterError.emptyOutput(width: width, height: height)
  }
  guard let inverse = transform.inverse else {
    throw RasterError.nonInvertibleTransform
  }

  var output = [Float](repeating: 0, count: width * height * 3)
  for j in 0..<height {
    for i in 0..<width {
      let destination = CGPoint(x: Double(i), y: Double(j))
      guard let sample = inverse.map(destination) else {
        // Points on the transform's horizon stay black rather than failing the warp.
        continue
      }
      let color = bilinearRGB(source, x: Double(sample.x), y: Double(sample.y))
      let index = (j * width + i) * 3
      output[index] = color.x
      output[index + 1] = color.y
      output[index + 2] = color.z
    }
  }
  return output
}

public struct ArrayPixelSource: PixelSource {
  public let width: Int
  public let height: Int
  private let pixels: [Float]

  public init?(width: Int, height: Int, rgb: [Float]) {
    guard rgb.count == width * height * 3 else { return nil }
    self.width = width
    self.height = height
    self.pixels = rgb
  }

  public func rgb(x: Int, y: Int) -> SIMD3<Float> {
    let index = (y * width + x) * 3
    return SIMD3(pixels[index], pixels[index + 1], pixels[index + 2])
  }
}

import CoreVideo
import Foundation
import GazeKit

public enum CVPixelBufferSourceError: Error, Equatable, Sendable {
  case unsupportedPixelFormat(OSType)
  case lockFailed(CVReturn)
}

/// A `PixelSource` over a BGRA `CVPixelBuffer`, the format the capture
/// session and `AVCaptureVideoDataOutput` produce.
///
/// Locks the buffer's base address for the object's lifetime: an instance
/// that finished initializing always unlocks in `deinit`, so a caller that
/// drops it early, via a thrown error or an early return, still releases the
/// lock. A failure partway through `init` (no base address) unlocks
/// immediately, because `deinit` never runs for an object whose
/// initializer did not complete.
public final class CVPixelBufferSource: PixelSource {
  public let width: Int
  public let height: Int

  private let pixelBuffer: CVPixelBuffer
  private let baseAddress: UnsafeMutableRawPointer
  private let bytesPerRow: Int

  public init(pixelBuffer: CVPixelBuffer) throws {
    let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
    guard format == kCVPixelFormatType_32BGRA else {
      throw CVPixelBufferSourceError.unsupportedPixelFormat(format)
    }

    let lockResult = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    guard lockResult == kCVReturnSuccess else {
      throw CVPixelBufferSourceError.lockFailed(lockResult)
    }
    guard let address = CVPixelBufferGetBaseAddress(pixelBuffer) else {
      CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
      throw CVPixelBufferSourceError.lockFailed(kCVReturnError)
    }

    self.pixelBuffer = pixelBuffer
    self.baseAddress = address
    self.bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    self.width = CVPixelBufferGetWidth(pixelBuffer)
    self.height = CVPixelBufferGetHeight(pixelBuffer)
  }

  deinit {
    CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
  }

  public func rgb(x: Int, y: Int) -> SIMD3<Float> {
    let row = baseAddress.advanced(by: y * bytesPerRow)
    let pixel = row.advanced(by: x * 4).assumingMemoryBound(to: UInt8.self)
    let blue = Float(pixel[0]) / 255
    let green = Float(pixel[1]) / 255
    let red = Float(pixel[2]) / 255
    return SIMD3(red, green, blue)
  }
}

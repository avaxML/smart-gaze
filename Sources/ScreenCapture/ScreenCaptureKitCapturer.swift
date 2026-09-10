import AppKit
import CoreGraphics
import Foundation
import GazeKit
import ScreenCaptureKit

public struct CaptureRequest: Equatable, Sendable {
  public let center: CGPoint
  public let size: CGSize
  public let displayID: CGDirectDisplayID

  public init(
    center: CGPoint,
    size: CGSize = CGSize(width: 600, height: 400),
    displayID: CGDirectDisplayID
  ) {
    self.center = center
    self.size = size
    self.displayID = displayID
  }
}

public struct CapturedRegion: Sendable {
  public let jpeg: Data
  public let rect: CGRect
  public let displayID: CGDirectDisplayID

  public init(jpeg: Data, rect: CGRect, displayID: CGDirectDisplayID) {
    self.jpeg = jpeg
    self.rect = rect
    self.displayID = displayID
  }
}

public enum CaptureError: Error, Equatable, Sendable {
  case suppressedApp(bundleID: String)
  case displayNotFound(CGDirectDisplayID)
  case encodingFailed
}

public protocol RegionCapturing: Sendable {
  func capture(_ request: CaptureRequest) async throws -> CapturedRegion
}

public struct ScreenCaptureKitCapturer: RegionCapturing {
  private let denylist: AppDenylist
  private let byteCeiling: Int
  private let frontmostBundleID: @Sendable () -> String?

  public init(
    denylist: AppDenylist = AppDenylist(),
    byteCeiling: Int = 200_000,
    frontmostBundleID: @escaping @Sendable () -> String? = {
      NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
  ) {
    self.denylist = denylist
    self.byteCeiling = byteCeiling
    self.frontmostBundleID = frontmostBundleID
  }

  public func capture(_ request: CaptureRequest) async throws -> CapturedRegion {
    let frontmost = frontmostBundleID()
    guard denylist.allowsCapture(frontmostBundleID: frontmost) else {
      throw CaptureError.suppressedApp(bundleID: frontmost ?? "unknown")
    }

    let content = try await SCShareableContent.excludingDesktopWindows(
      false,
      onScreenWindowsOnly: true
    )
    guard let display = content.displays.first(where: { $0.displayID == request.displayID }) else {
      throw CaptureError.displayNotFound(request.displayID)
    }

    let ownWindows = content.windows.filter {
      $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
    }
    let filter = SCContentFilter(display: display, excludingWindows: ownWindows)

    let displayBounds = CGRect(x: 0, y: 0, width: display.width, height: display.height)
    let rect = clampedCaptureRect(center: request.center, size: request.size, within: displayBounds)

    let configuration = SCStreamConfiguration()
    configuration.sourceRect = rect
    configuration.width = Int(rect.width)
    configuration.height = Int(rect.height)
    configuration.showsCursor = false

    let cgImage = try await SCScreenshotManager.captureImage(
      contentFilter: filter,
      configuration: configuration
    )

    let jpeg = try Self.encodeJPEG(cgImage, byteCeiling: byteCeiling)
    return CapturedRegion(jpeg: jpeg, rect: rect, displayID: request.displayID)
  }

  private static func encodeJPEG(_ cgImage: CGImage, byteCeiling: Int) throws -> Data {
    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    var quality: CGFloat = 0.9
    var lastData: Data?

    while quality >= 0.1 {
      guard
        let data = bitmap.representation(
          using: .jpeg,
          properties: [.compressionFactor: quality]
        )
      else {
        throw CaptureError.encodingFailed
      }
      lastData = data
      if data.count <= byteCeiling {
        return data
      }
      quality -= 0.1
    }

    guard let lastData else { throw CaptureError.encodingFailed }
    return lastData
  }
}

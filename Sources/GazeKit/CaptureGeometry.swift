import CoreGraphics

public func clampedCaptureRect(center: CGPoint, size: CGSize, within bounds: CGRect) -> CGRect {
  let width = min(size.width, bounds.width)
  let height = min(size.height, bounds.height)

  let minX = bounds.minX
  let minY = bounds.minY
  let maxX = bounds.maxX - width
  let maxY = bounds.maxY - height

  let originX = min(max(center.x - width / 2, minX), maxX)
  let originY = min(max(center.y - height / 2, minY), maxY)

  return CGRect(x: originX, y: originY, width: width, height: height)
}

public struct AppDenylist: Sendable {
  public static let seed: Set<String> = [
    "com.1password.1password",
    "com.apple.keychainaccess",
    "com.apple.MobileSMS",
    "com.apple.mail",
  ]

  private let lowercasedBundleIDs: Set<String>

  public init(bundleIDs: Set<String> = AppDenylist.seed) {
    self.lowercasedBundleIDs = Set(bundleIDs.map { $0.lowercased() })
  }

  public func allowsCapture(frontmostBundleID: String?) -> Bool {
    guard let frontmostBundleID else { return true }
    return !lowercasedBundleIDs.contains(frontmostBundleID.lowercased())
  }
}

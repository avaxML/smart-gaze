import CoreGraphics
import Foundation

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

public struct AppDenylist: Codable, Equatable, Sendable {
  public static let seed: Set<String> = [
    "com.1password.1password",
    "com.apple.keychainaccess",
    "com.apple.MobileSMS",
    "com.apple.mail",
  ]

  public private(set) var bundleIDs: Set<String>

  public init(bundleIDs: Set<String> = AppDenylist.seed) {
    self.bundleIDs = Set(bundleIDs.map(Self.normalized).filter { !$0.isEmpty })
  }

  public func allowsCapture(frontmostBundleID: String?) -> Bool {
    guard let frontmostBundleID else { return true }
    return !bundleIDs.contains(Self.normalized(frontmostBundleID))
  }

  public mutating func add(_ bundleID: String) {
    let normalized = Self.normalized(bundleID)
    guard !normalized.isEmpty else { return }
    bundleIDs.insert(normalized)
  }

  public mutating func remove(_ bundleID: String) {
    bundleIDs.remove(Self.normalized(bundleID))
  }

  private static func normalized(_ bundleID: String) -> String {
    bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    self.init(bundleIDs: Set(try container.decode([String].self)))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(bundleIDs.sorted())
  }
}

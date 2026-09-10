import CoreGraphics

/// Quartz global display space (origin at the main display's top-left, y
/// increasing downward, as used by `CGEvent` and `ScreenCaptureKit`) and
/// AppKit screen space (origin at the main display's bottom-left, y
/// increasing upward) share the same horizontal layout and differ by one
/// flip about the main display's height in points.
public enum QuartzCocoaConversion {
  public static func cocoaPoint(fromQuartz point: CGPoint, mainDisplayHeight: CGFloat) -> CGPoint {
    CGPoint(x: point.x, y: mainDisplayHeight - point.y)
  }

  public static func cocoaRect(fromQuartz rect: CGRect, mainDisplayHeight: CGFloat) -> CGRect {
    CGRect(
      x: rect.minX, y: mainDisplayHeight - rect.maxY, width: rect.width, height: rect.height)
  }
}

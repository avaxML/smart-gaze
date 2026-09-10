import CoreGraphics
import Testing

@testable import GazeKit

private let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
private let requestSize = CGSize(width: 600, height: 400)

@Test func centerOfScreenYieldsCenteredRect() {
  let rect = clampedCaptureRect(center: CGPoint(x: 960, y: 540), size: requestSize, within: bounds)
  #expect(rect == CGRect(x: 660, y: 340, width: 600, height: 400))
}

@Test func leftEdgeTranslatesRectFullSize() {
  let rect = clampedCaptureRect(center: CGPoint(x: 0, y: 540), size: requestSize, within: bounds)
  #expect(rect == CGRect(x: 0, y: 340, width: 600, height: 400))
}

@Test func rightEdgeTranslatesRectFullSize() {
  let rect = clampedCaptureRect(center: CGPoint(x: 1920, y: 540), size: requestSize, within: bounds)
  #expect(rect == CGRect(x: 1320, y: 340, width: 600, height: 400))
}

@Test func topEdgeTranslatesRectFullSize() {
  let rect = clampedCaptureRect(center: CGPoint(x: 960, y: 0), size: requestSize, within: bounds)
  #expect(rect == CGRect(x: 660, y: 0, width: 600, height: 400))
}

@Test func bottomEdgeTranslatesRectFullSize() {
  let rect = clampedCaptureRect(center: CGPoint(x: 960, y: 1080), size: requestSize, within: bounds)
  #expect(rect == CGRect(x: 660, y: 680, width: 600, height: 400))
}

@Test func topLeftCornerTranslatesRectFullSize() {
  let rect = clampedCaptureRect(center: CGPoint(x: 0, y: 0), size: requestSize, within: bounds)
  #expect(rect == CGRect(x: 0, y: 0, width: 600, height: 400))
}

@Test func topRightCornerTranslatesRectFullSize() {
  let rect = clampedCaptureRect(center: CGPoint(x: 1920, y: 0), size: requestSize, within: bounds)
  #expect(rect == CGRect(x: 1320, y: 0, width: 600, height: 400))
}

@Test func bottomLeftCornerTranslatesRectFullSize() {
  let rect = clampedCaptureRect(center: CGPoint(x: 0, y: 1080), size: requestSize, within: bounds)
  #expect(rect == CGRect(x: 0, y: 680, width: 600, height: 400))
}

@Test func bottomRightCornerTranslatesRectFullSize() {
  let rect = clampedCaptureRect(
    center: CGPoint(x: 1920, y: 1080), size: requestSize, within: bounds)
  #expect(rect == CGRect(x: 1320, y: 680, width: 600, height: 400))
}

@Test func boundsSmallerThanRequestYieldsBoundsItself() {
  let smallBounds = CGRect(x: 0, y: 0, width: 400, height: 300)
  let rect = clampedCaptureRect(
    center: CGPoint(x: 200, y: 150), size: requestSize, within: smallBounds)
  #expect(rect == smallBounds)
}

@Test func nonZeroOriginDisplayTranslatesWithinItsOwnBounds() {
  let secondDisplay = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
  let rect = clampedCaptureRect(
    center: CGPoint(x: 1920, y: 540), size: requestSize, within: secondDisplay)
  #expect(rect == CGRect(x: 1920, y: 340, width: 600, height: 400))
}

@Test func seededBundleIDIsDenied() {
  let denylist = AppDenylist()
  #expect(denylist.allowsCapture(frontmostBundleID: "com.1password.1password") == false)
}

@Test func arbitraryBundleIDIsAllowed() {
  let denylist = AppDenylist()
  #expect(denylist.allowsCapture(frontmostBundleID: "com.example.notes") == true)
}

@Test func nilFrontmostBundleIDIsAllowed() {
  let denylist = AppDenylist()
  #expect(denylist.allowsCapture(frontmostBundleID: nil) == true)
}

@Test func denylistMatchingIsCaseInsensitive() {
  let denylist = AppDenylist()
  #expect(denylist.allowsCapture(frontmostBundleID: "COM.APPLE.MAIL") == false)
  #expect(denylist.allowsCapture(frontmostBundleID: "Com.Apple.MobileSMS") == false)
}

@Test func customDenylistOverridesSeed() {
  let denylist = AppDenylist(bundleIDs: ["com.example.secret"])
  #expect(denylist.allowsCapture(frontmostBundleID: "com.1password.1password") == true)
  #expect(denylist.allowsCapture(frontmostBundleID: "com.example.secret") == false)
}

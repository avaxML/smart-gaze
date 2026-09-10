import CoreGraphics
import Testing

@testable import GazeKit

@Test func topLeftQuartzOriginMapsToTopOfCocoaSpace() {
  let point = QuartzCocoaConversion.cocoaPoint(
    fromQuartz: CGPoint(x: 0, y: 0), mainDisplayHeight: 1117)
  #expect(point == CGPoint(x: 0, y: 1117))
}

@Test func bottomLeftQuartzPointMapsToCocoaOrigin() {
  let point = QuartzCocoaConversion.cocoaPoint(
    fromQuartz: CGPoint(x: 0, y: 1117), mainDisplayHeight: 1117)
  #expect(point == CGPoint(x: 0, y: 0))
}

@Test func negativeXOnASecondaryDisplayIsPreserved() {
  let point = QuartzCocoaConversion.cocoaPoint(
    fromQuartz: CGPoint(x: -1920, y: 500), mainDisplayHeight: 1117)
  #expect(point == CGPoint(x: -1920, y: 617))
}

@Test func rectConversionFlipsAboutMainDisplayHeight() {
  let rect = QuartzCocoaConversion.cocoaRect(
    fromQuartz: CGRect(x: 100, y: 200, width: 50, height: 30), mainDisplayHeight: 1117)
  #expect(rect == CGRect(x: 100, y: 887, width: 50, height: 30))
}

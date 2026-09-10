import CoreGraphics
import Foundation
import GazeKit
import Testing

private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
private let size = CGSize(width: 380, height: 250)

@Test func placesBubbleToTheRightOfACenteredRegion() {
  let region = CGRect(x: 100, y: 300, width: 200, height: 100)
  let frame = bubbleFrame(anchoredTo: region, size: size, within: bounds)

  #expect(frame == CGRect(x: 312, y: 225, width: 380, height: 250))
  #expect(frame.intersects(region) == false)
}

@Test func placesBubbleToTheLeftOfARegionAtTheRightEdge() {
  let region = CGRect(x: 750, y: 300, width: 200, height: 100)
  let frame = bubbleFrame(anchoredTo: region, size: size, within: bounds)

  #expect(frame == CGRect(x: 358, y: 225, width: 380, height: 250))
  #expect(frame.intersects(region) == false)
}

@Test func fallsToAVerticalPlacementForAWideRegion() {
  let region = CGRect(x: 10, y: 300, width: 980, height: 100)
  let frame = bubbleFrame(anchoredTo: region, size: size, within: bounds)

  #expect(frame == CGRect(x: 310, y: 38, width: 380, height: 250))
  #expect(frame.intersects(region) == false)
  #expect(bounds.contains(frame))
}

@Test func verticallyCentresTheBubbleOnAHorizontalPlacement() {
  let region = CGRect(x: 100, y: 300, width: 200, height: 100)
  let frame = bubbleFrame(anchoredTo: region, size: size, within: bounds)

  #expect(frame.origin.y == 225)
}

@Test func clampsTheBubbleInsideBoundsAtTheTop() {
  let region = CGRect(x: 100, y: 700, width: 200, height: 100)
  let frame = bubbleFrame(anchoredTo: region, size: size, within: bounds)

  #expect(frame.origin.y + 250 <= 800)
  #expect(frame.origin.y >= 0)
}

@Test func clampsTheBubbleInsideBoundsAtTheBottom() {
  let region = CGRect(x: 100, y: 0, width: 200, height: 100)
  let frame = bubbleFrame(anchoredTo: region, size: size, within: bounds)

  #expect(frame.origin.y >= 0)
}

@Test func resultIsAlwaysInsideBounds() {
  let regionSize = CGSize(width: 200, height: 100)

  for x in stride(from: 0, through: 900, by: 100) {
    for y in stride(from: 0, through: 700, by: 100) {
      let region = CGRect(origin: CGPoint(x: x, y: y), size: regionSize)
      let frame = bubbleFrame(anchoredTo: region, size: size, within: bounds)
      #expect(bounds.contains(frame))
    }
  }
}

@Test func resultNeverIntersectsTheRegionWhenThereIsRoom() {
  let regionSize = CGSize(width: 200, height: 100)

  for x in stride(from: 0, through: 900, by: 100) {
    for y in stride(from: 0, through: 700, by: 100) {
      let region = CGRect(origin: CGPoint(x: x, y: y), size: regionSize)
      let frame = bubbleFrame(anchoredTo: region, size: size, within: bounds)
      #expect(frame.intersects(region) == false)
    }
  }
}

@Test func dismissalTimerDoesNotFireBeforeTheGracePeriod() {
  var timer = DismissalTimer(graceperiod: 2.0)

  #expect(timer.update(gazeInside: false, at: 0.0) == false)
  #expect(timer.update(gazeInside: false, at: 1.9) == false)
}

@Test func dismissalTimerFiresAfterTheGracePeriod() {
  var timer = DismissalTimer(graceperiod: 2.0)

  #expect(timer.update(gazeInside: false, at: 0.0) == false)
  #expect(timer.update(gazeInside: false, at: 1.9) == false)
  #expect(timer.update(gazeInside: false, at: 2.1) == true)
}

@Test func dismissalTimerFiresOnlyOnce() {
  var timer = DismissalTimer(graceperiod: 2.0)

  #expect(timer.update(gazeInside: false, at: 0.0) == false)
  #expect(timer.update(gazeInside: false, at: 1.9) == false)
  #expect(timer.update(gazeInside: false, at: 2.1) == true)
  #expect(timer.update(gazeInside: false, at: 3.0) == false)
}

@Test func reEnteringResetsTheCountdown() {
  var timer = DismissalTimer(graceperiod: 2.0)

  #expect(timer.update(gazeInside: false, at: 0.0) == false)
  #expect(timer.update(gazeInside: true, at: 1.0) == false)
  #expect(timer.update(gazeInside: false, at: 1.1) == false)
  #expect(timer.update(gazeInside: false, at: 2.5) == false)
}

@Test func resetReArmsTheTimer() {
  var timer = DismissalTimer(graceperiod: 2.0)

  #expect(timer.update(gazeInside: false, at: 0.0) == false)
  #expect(timer.update(gazeInside: false, at: 2.1) == true)

  timer.reset()

  #expect(timer.update(gazeInside: false, at: 10.0) == false)
  #expect(timer.update(gazeInside: false, at: 12.1) == true)
}

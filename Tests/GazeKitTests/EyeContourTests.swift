import CoreGraphics
import GazeKit
import Testing

private let canonicalContour: [CGPoint] = [
  CGPoint(x: 0, y: 0),
  CGPoint(x: 10, y: 0),
  CGPoint(x: 3, y: -3),
  CGPoint(x: 7, y: -3),
  CGPoint(x: 3, y: 3),
  CGPoint(x: 7, y: 3),
]

@Test func cornersComeFromXExtremes() throws {
  let eyes = try eyeLandmarks(fromContour: canonicalContour)
  #expect(eyes.points[0] == CGPoint(x: 0, y: 0))
  #expect(eyes.points[3] == CGPoint(x: 10, y: 0))
}

@Test func upperAndLowerLidsAreAssignedCorrectly() throws {
  let eyes = try eyeLandmarks(fromContour: canonicalContour)
  #expect(eyes.points[1].y == -3)
  #expect(eyes.points[2].y == -3)
  #expect(eyes.points[4].y == 3)
  #expect(eyes.points[5].y == 3)
}

@Test func canonicalEyeAspectRatioIsPointSix() throws {
  let eyes = try eyeLandmarks(fromContour: canonicalContour)
  #expect(abs(eyeAspectRatio(eyes) - 0.6) < 1e-9)
}

@Test func shufflingTheContourDoesNotChangeTheResult() throws {
  let reference = try eyeLandmarks(fromContour: canonicalContour)

  let reordered = try eyeLandmarks(fromContour: [
    CGPoint(x: 7, y: 3),
    CGPoint(x: 0, y: 0),
    CGPoint(x: 3, y: 3),
    CGPoint(x: 10, y: 0),
    CGPoint(x: 7, y: -3),
    CGPoint(x: 3, y: -3),
  ])
  let reversed = try eyeLandmarks(fromContour: canonicalContour.reversed())

  #expect(reference == reordered)
  #expect(reference == reversed)
}

@Test func extraContourPointsDoNotBreakCorners() throws {
  let extended = try eyeLandmarks(fromContour: [
    CGPoint(x: 0, y: 0),
    CGPoint(x: 10, y: 0),
    CGPoint(x: 2, y: -3),
    CGPoint(x: 3, y: -3),
    CGPoint(x: 7, y: -3),
    CGPoint(x: 8, y: -3),
    CGPoint(x: 2, y: 3),
    CGPoint(x: 3, y: 3),
    CGPoint(x: 7, y: 3),
    CGPoint(x: 8, y: 3),
  ])

  #expect(extended.points[0] == CGPoint(x: 0, y: 0))
  #expect(extended.points[3] == CGPoint(x: 10, y: 0))
  let ear = eyeAspectRatio(extended)
  #expect(ear > 0)
  #expect(ear.isFinite)
}

@Test func fewerThanFourPointsThrows() {
  let three = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 2, y: 0)]
  #expect(throws: EyeContourError.tooFewPoints(got: 3, need: 4)) {
    try eyeLandmarks(fromContour: three)
  }
}

@Test func zeroWidthContourThrows() {
  let sameX = [
    CGPoint(x: 5, y: 0),
    CGPoint(x: 5, y: 1),
    CGPoint(x: 5, y: 2),
    CGPoint(x: 5, y: 3),
  ]
  #expect(throws: EyeContourError.degenerateContour) {
    try eyeLandmarks(fromContour: sameX)
  }
}

@Test func collinearClosedEyeDoesNotThrow() throws {
  let collinear = [
    CGPoint(x: 0, y: 0),
    CGPoint(x: 3, y: 0),
    CGPoint(x: 7, y: 0),
    CGPoint(x: 10, y: 0),
  ]
  let eyes = try eyeLandmarks(fromContour: collinear)
  #expect(eyeAspectRatio(eyes) < 0.05)
}

@Test func tiesOnSmallestXPreferSmallerY() throws {
  let contour = [
    CGPoint(x: 0, y: 5),
    CGPoint(x: 0, y: -1),
    CGPoint(x: 10, y: 0),
    CGPoint(x: 3, y: -3),
    CGPoint(x: 7, y: -3),
    CGPoint(x: 3, y: 3),
    CGPoint(x: 7, y: 3),
  ]
  let eyes = try eyeLandmarks(fromContour: contour)
  #expect(eyes.points[0] == CGPoint(x: 0, y: -1))
}

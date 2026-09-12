import Foundation
import GazeKit
import Testing

@Test func theSmoothingEndpointsAreTheMeasuredCutoffs() {
  let responsive = GazeSmoothing.parameters(forLevel: 0)
  #expect(abs(responsive.minCutoff - 0.5) <= 1e-12)
  #expect(abs(responsive.beta - 0.00375) <= 1e-12)
  #expect(responsive.derivativeCutoff == 0.5)

  let calm = GazeSmoothing.parameters(forLevel: 1)
  #expect(abs(calm.minCutoff - 0.05) <= 1e-12)
  #expect(abs(calm.beta - 0.000375) <= 1e-12)
}

@Test func theMiddleOfTheSliderIsTheGeometricMiddle() {
  let middle = GazeSmoothing.parameters(forLevel: 0.5)
  #expect(abs(middle.minCutoff - (0.5 * 0.05).squareRoot()) <= 1e-12)
}

@Test func outOfRangeAndNonFiniteLevelsAreTamed() {
  #expect(GazeSmoothing.parameters(forLevel: 7) == GazeSmoothing.parameters(forLevel: 1))
  #expect(GazeSmoothing.parameters(forLevel: -3) == GazeSmoothing.parameters(forLevel: 0))
  #expect(GazeSmoothing.parameters(forLevel: .nan) == GazeSmoothing.parameters(forLevel: 0.75))
}

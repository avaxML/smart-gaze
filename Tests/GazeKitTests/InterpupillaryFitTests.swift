import Foundation
import Testing

@testable import GazeKit

@Test func impliedInterpupillaryScalesTheAssumedValueByTheDepthRatio() {
  let implied = InterpupillaryFit.impliedCentimetres(
    irisDepthCentimetres: 60, baselineDepthCentimetres: 50, assumedCentimetres: 6.3)
  #expect(implied == 7.56)
}

@Test func impliedInterpupillaryIsNilForANonPositiveBaseline() {
  #expect(
    InterpupillaryFit.impliedCentimetres(
      irisDepthCentimetres: 60, baselineDepthCentimetres: 0, assumedCentimetres: 6.3) == nil)
}

@Test func fitIsTheMedianSoOneOutlierDoesNotMoveIt() {
  let fitted = InterpupillaryFit.fit(impliedCentimetres: [6.0, 6.2, 6.1, 9.0, 6.3])
  #expect(fitted == 6.2)
}

@Test func fitIsNilBelowTheMinimumSampleCount() {
  #expect(InterpupillaryFit.fit(impliedCentimetres: [6.0, 6.1, 6.2, 6.3]) == nil)
  #expect(InterpupillaryFit.minimumSamples == 5)
}

@Test func fitRejectsAMedianOutsideThePlausibleRange() {
  #expect(InterpupillaryFit.fit(impliedCentimetres: [8.0, 8.0, 8.0, 8.0, 8.0]) == nil)
}

@Test func fitKeepsAMedianInsideThePlausibleRange() {
  #expect(InterpupillaryFit.fit(impliedCentimetres: [5.0, 5.0, 5.0, 5.0, 5.0]) == 5.0)
  #expect(InterpupillaryFit.fit(impliedCentimetres: [7.5, 7.5, 7.5, 7.5, 7.5]) == 7.5)
}

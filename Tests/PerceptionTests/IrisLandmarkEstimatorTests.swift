import CoreML
import Foundation
import Testing

@testable import Perception

private func requireModelURL() throws -> URL {
  guard irisTestsEnabled(ProcessInfo.processInfo.environment) else {
    FileHandle.standardError.write(
      Data(
        "MODEL TEST SKIPPED: Iris contract tests did not run. Set SMART_GAZE_IRIS_TESTS=1 and SMART_GAZE_IRIS_MODEL_PATH.\n"
          .utf8))
    try Test.cancel(
      "set SMART_GAZE_IRIS_TESTS=1 and SMART_GAZE_IRIS_MODEL_PATH to run iris integration tests"
    )
  }
  let path =
    ProcessInfo.processInfo.environment["SMART_GAZE_IRIS_MODEL_PATH"]
    ?? "Models/iris/iris_landmark_64x64_float32.mlmodelc"
  let url = URL(fileURLWithPath: path)
  guard FileManager.default.fileExists(atPath: url.path) else {
    throw IrisLandmarkError.modelMissing(url)
  }
  return url
}

private func uniformInput() throws -> IrisLandmarkInput {
  try IrisLandmarkInput(rgb: [Float](repeating: 0.5, count: IrisLandmarkInput.elementCount))
}

@Suite struct IrisLandmarkInputContractTests {
  @Test func acceptsTheModelElementCount() throws {
    let input = try uniformInput()
    #expect(input.rgb.count == 12_288)
  }

  @Test func rejectsWrongElementCount() {
    #expect(throws: IrisLandmarkError.inputInvalid("RGB input needs 12288 floats, got 3")) {
      try IrisLandmarkInput(rgb: [0.5, 0.5, 0.5])
    }
  }

  @Test func rejectsNonFiniteValue() {
    var rgb = [Float](repeating: 0.5, count: IrisLandmarkInput.elementCount)
    rgb[123] = .nan
    #expect(throws: IrisLandmarkError.inputInvalid("RGB input contains a non-finite value")) {
      try IrisLandmarkInput(rgb: rgb)
    }
  }
}

@Suite struct IrisLandmarkEstimatorLoadTests {
  @Test func missingModelPathIsReported() {
    let url = URL(fileURLWithPath: "/nonexistent/iris_landmark_64x64_float32.mlmodelc")
    #expect(throws: IrisLandmarkError.modelMissing(url)) {
      try IrisLandmarkEstimator(modelURL: url)
    }
  }
}

@Suite struct IrisLandmarkModelIntegrationTests {
  @Test func pinnedModelInterfaceIsExact() throws {
    let url = try requireModelURL()
    let model = try MLModel(contentsOf: url, configuration: MLModelConfiguration())
    let inputs = model.modelDescription.inputDescriptionsByName

    #expect(Set(inputs.keys) == ["input_1"])
    #expect(inputs["input_1"]?.multiArrayConstraint?.shape.map(\.intValue) == [1, 64, 64, 3])
    #expect(inputs["input_1"]?.multiArrayConstraint?.dataType == .float32)

    let outputs = model.modelDescription.outputDescriptionsByName
    #expect(Set(outputs.keys) == ["output_eyes_contours_and_brows", "output_iris"])
    for name in ["output_eyes_contours_and_brows", "output_iris"] {
      #expect(outputs[name]?.multiArrayConstraint?.dataType == .float32)
      #expect(outputs[name]?.multiArrayConstraint?.shape.isEmpty == true)
    }
  }

  @Test func runtimeOutputCountsAreExact() throws {
    let url = try requireModelURL()
    let model = try MLModel(contentsOf: url, configuration: MLModelConfiguration())
    let array = try MLMultiArray(shape: [1, 64, 64, 3], dataType: .float32)
    for index in 0..<array.count { array[index] = 0.5 }
    let provider = try MLDictionaryFeatureProvider(dictionary: [
      "input_1": MLFeatureValue(multiArray: array)
    ])
    let output = try model.prediction(from: provider)

    #expect(
      output.featureValue(for: "output_eyes_contours_and_brows")?.multiArrayValue?.count == 213)
    #expect(output.featureValue(for: "output_iris")?.multiArrayValue?.count == 15)
  }

  @Test func midGreyFixtureYieldsFinitePointsInRange() async throws {
    let estimator = try IrisLandmarkEstimator(modelURL: requireModelURL(), computeUnits: .cpuOnly)
    let result = try await estimator.landmarks(for: uniformInput())

    #expect(result.contour.count == 71)
    #expect(result.iris.count == 5)
    #expect(result.contour.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
    #expect(result.iris.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
    #expect(
      result.contour.allSatisfy { (-16...80).contains($0.x) && (-16...80).contains($0.y) })
    #expect(result.iris.allSatisfy { (-16...80).contains($0.x) && (-16...80).contains($0.y) })
  }

  @Test func midGreyFixtureContourOrderDoesNotCloseAsOneLoop() async throws {
    let estimator = try IrisLandmarkEstimator(modelURL: requireModelURL(), computeUnits: .cpuOnly)
    let result = try await estimator.landmarks(for: uniformInput())

    for (index, point) in result.contour.enumerated() {
      print(String(format: "contour[%d] = (%.4f, %.4f, %.4f)", index, point.x, point.y, point.z))
    }

    // A single closed loop through indices 0...15 would have exactly one large
    // gap. The model instead lays out two lid chains (0...8 and 9...15), each
    // crossing the eye by ~20 crop pixels at 8->9 and 15->0, so the visor
    // keeps the contour as points rather than connecting them.
    var gaps: [Double] = []
    for index in 0..<16 {
      let a = result.contour[index]
      let b = result.contour[(index + 1) % 16]
      let dx = Double(a.x - b.x)
      let dy = Double(a.y - b.y)
      gaps.append((dx * dx + dy * dy).squareRoot())
    }
    let median = gaps.sorted()[8]
    let largeGaps = gaps.filter { $0 > 3 * median }.count
    #expect(largeGaps == 2)
  }

  @Test func alreadyCancelledTaskIsRejectedAtEntry() async throws {
    let estimator = try IrisLandmarkEstimator(modelURL: requireModelURL(), computeUnits: .cpuOnly)
    let input = try uniformInput()
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await estimator.landmarks(for: input)
    }
    let result = await task.result
    #expect(throws: CancellationError.self) {
      try result.get()
    }
  }
}

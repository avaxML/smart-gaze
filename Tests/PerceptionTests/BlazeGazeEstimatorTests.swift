import CoreML
import Foundation
import GazeKit
import Testing

@testable import Perception

private func requireModelURL() throws -> URL {
  guard modelTestsEnabled(ProcessInfo.processInfo.environment) else {
    FileHandle.standardError.write(
      Data(
        "MODEL TEST SKIPPED: BlazeGaze contract tests did not run. Set SMART_GAZE_MODEL_TESTS=1 and SMART_GAZE_MODEL_PATH.\n"
          .utf8))
    try Test.cancel(
      "set SMART_GAZE_MODEL_TESTS=1 and SMART_GAZE_MODEL_PATH to run model integration tests")
  }
  let path =
    ProcessInfo.processInfo.environment["SMART_GAZE_MODEL_PATH"] ?? "Models/blazegaze.mlmodelc"
  let url = URL(fileURLWithPath: path)
  guard FileManager.default.fileExists(atPath: url.path) else {
    throw BlazeGazeError.modelMissing(url)
  }
  return url
}

private func uniformInput() throws -> BlazeGazeInput {
  try BlazeGazeInput(
    eyeBandRGB: [Float](repeating: 0.5, count: BlazeGazeInput.eyeBandElementCount),
    headVector: SIMD3(0, 0, -1),
    faceOriginCentimeters: SIMD3(0, 0, 50))
}

private func eyeBandInput(_ transform: (inout [Float]) -> Void) throws -> BlazeGazeInput {
  var values = [Float](repeating: 0.5, count: BlazeGazeInput.eyeBandElementCount)
  transform(&values)
  return try BlazeGazeInput(
    eyeBandRGB: values,
    headVector: SIMD3(0, 0, -1),
    faceOriginCentimeters: SIMD3(0, 0, 50))
}

private func topLeftBlockZeroInput() throws -> BlazeGazeInput {
  try eyeBandInput { values in
    for row in 0..<64 {
      for column in 0..<256 {
        let base = (row * 512 + column) * 3
        for channel in 0..<3 { values[base + channel] = 0 }
      }
    }
  }
}

private func redChannelZeroInput() throws -> BlazeGazeInput {
  try eyeBandInput { values in
    for index in stride(from: 0, to: values.count, by: 3) { values[index] = 0 }
  }
}

@Suite struct BlazeGazeInputContractTests {
  @Test func acceptsTheTrainingElementCount() throws {
    let input = try uniformInput()
    #expect(input.eyeBandRGB.count == 196_608)
    #expect(input.headVector == SIMD3(0, 0, -1))
    #expect(input.faceOriginCentimeters == SIMD3(0, 0, 50))
  }

  @Test func rejectsWrongEyeBandLength() {
    #expect(throws: BlazeGazeError.inputInvalid("eye band needs 196608 floats, got 3")) {
      try BlazeGazeInput(
        eyeBandRGB: [0.5, 0.5, 0.5],
        headVector: SIMD3(0, 0, -1),
        faceOriginCentimeters: SIMD3(0, 0, 50))
    }
  }

  @Test func rejectsNonFiniteEyeBand() {
    var eyeBand = [Float](repeating: 0.5, count: BlazeGazeInput.eyeBandElementCount)
    eyeBand[17] = .nan
    #expect(throws: BlazeGazeError.inputInvalid("eye band contains a non-finite value")) {
      try BlazeGazeInput(
        eyeBandRGB: eyeBand,
        headVector: SIMD3(0, 0, -1),
        faceOriginCentimeters: SIMD3(0, 0, 50))
    }
  }

  @Test func rejectsNonFiniteHeadVector() {
    #expect(throws: BlazeGazeError.inputInvalid("head vector contains a non-finite value")) {
      try BlazeGazeInput(
        eyeBandRGB: [Float](repeating: 0.5, count: BlazeGazeInput.eyeBandElementCount),
        headVector: SIMD3(0, .infinity, -1),
        faceOriginCentimeters: SIMD3(0, 0, 50))
    }
  }

  @Test func rejectsNonFiniteFaceOrigin() {
    #expect(throws: BlazeGazeError.inputInvalid("face origin contains a non-finite value")) {
      try BlazeGazeInput(
        eyeBandRGB: [Float](repeating: 0.5, count: BlazeGazeInput.eyeBandElementCount),
        headVector: SIMD3(0, 0, -1),
        faceOriginCentimeters: SIMD3(0, 0, .nan))
    }
  }
}

@Suite struct BlazeGazeEstimatorLoadTests {
  @Test func missingModelPathIsReported() {
    let url = URL(fileURLWithPath: "/nonexistent/blazegaze.mlmodelc")
    #expect(throws: BlazeGazeError.modelMissing(url)) {
      try BlazeGazeEstimator(modelURL: url)
    }
  }
}

@Suite struct BlazeGazeModelIntegrationTests {
  @Test func pinnedModelInterfaceIsExact() throws {
    let url = try requireModelURL()
    let model = try MLModel(contentsOf: url, configuration: MLModelConfiguration())
    let inputs = model.modelDescription.inputDescriptionsByName

    #expect(Set(inputs.keys) == ["image", "head_vector", "face_origin_3d"])
    #expect(inputs["image"]?.multiArrayConstraint?.shape.map(\.intValue) == [1, 128, 512, 3])
    #expect(inputs["head_vector"]?.multiArrayConstraint?.shape.map(\.intValue) == [1, 3])
    #expect(inputs["face_origin_3d"]?.multiArrayConstraint?.shape.map(\.intValue) == [1, 3])
    for name in ["image", "head_vector", "face_origin_3d"] {
      #expect(inputs[name]?.multiArrayConstraint?.dataType == .float32)
    }

    let outputs = model.modelDescription.outputDescriptionsByName
    #expect(Set(outputs.keys) == ["Identity"])
    #expect(outputs["Identity"]?.multiArrayConstraint?.shape.map(\.intValue) == [1, 2])
    #expect(outputs["Identity"]?.multiArrayConstraint?.dataType == .float32)
  }

  @Test func estimatorLoadsPinnedArtifact() throws {
    let url = try requireModelURL()
    _ = try BlazeGazeEstimator(modelURL: url, computeUnits: .cpuOnly)
  }

  @Test func cpuUniformBaselineMatchesRecordedFixture() async throws {
    let estimator = try BlazeGazeEstimator(modelURL: requireModelURL(), computeUnits: .cpuOnly)
    let point = try await estimator.estimate(uniformInput())

    #expect(abs(point.x - 0.03115164) < 1e-4)
    #expect(abs(point.y - 0.16168551) < 1e-4)
  }

  // The patterned fixtures below are wiring regression baselines recorded from the
  // independent direct-Core ML probe on CPU. They prove the 128x512x3 eye band is
  // copied into the model with the correct spatial layout and RGB channel order:
  // replacing the image with uniform data, transposing it, or reordering channels
  // moves the output away from these literals. They are NOT upstream Keras
  // equivalence or accuracy evidence; upstream parity is follow-up #8.
  @Test func spatialPatternChangesOutput() async throws {
    let estimator = try BlazeGazeEstimator(modelURL: requireModelURL(), computeUnits: .cpuOnly)
    let baseline = try await estimator.estimate(uniformInput())
    let patterned = try await estimator.estimate(topLeftBlockZeroInput())

    #expect(abs(patterned.x - 0.014020554) < 1e-4)
    #expect(abs(patterned.y - 0.024027810) < 1e-4)
    #expect(abs(patterned.x - baseline.x) > 1e-3)
    #expect(abs(patterned.y - baseline.y) > 1e-3)
  }

  @Test func channelReorderedImageChangesOutput() async throws {
    let estimator = try BlazeGazeEstimator(modelURL: requireModelURL(), computeUnits: .cpuOnly)
    let baseline = try await estimator.estimate(uniformInput())
    let redZero = try await estimator.estimate(redChannelZeroInput())

    #expect(abs(redZero.x - 0.056885011) < 1e-4)
    #expect(abs(redZero.y - 0.041884467) < 1e-4)
    #expect(abs(redZero.x - baseline.x) > 1e-3)
  }

  @Test func changedHeadVectorChangesOutput() async throws {
    let estimator = try BlazeGazeEstimator(modelURL: requireModelURL(), computeUnits: .cpuOnly)
    let baseline = try await estimator.estimate(uniformInput())
    let changed = try await estimator.estimate(
      BlazeGazeInput(
        eyeBandRGB: [Float](repeating: 0.5, count: BlazeGazeInput.eyeBandElementCount),
        headVector: SIMD3(0.3, 0, -1),
        faceOriginCentimeters: SIMD3(0, 0, 50)))

    #expect(abs(changed.x + 0.010134365) < 1e-4)
    #expect(abs(changed.y - 0.17358924) < 1e-4)
    #expect(abs(changed.x - baseline.x) > 0.01)
  }

  @Test func changedFaceOriginChangesOutput() async throws {
    let estimator = try BlazeGazeEstimator(modelURL: requireModelURL(), computeUnits: .cpuOnly)
    let baseline = try await estimator.estimate(uniformInput())
    let changed = try await estimator.estimate(
      BlazeGazeInput(
        eyeBandRGB: [Float](repeating: 0.5, count: BlazeGazeInput.eyeBandElementCount),
        headVector: SIMD3(0, 0, -1),
        faceOriginCentimeters: SIMD3(10, 0, 50)))

    #expect(abs(changed.x + 0.02018322) < 1e-4)
    #expect(abs(changed.y - 0.17751397) < 1e-4)
    #expect(abs(changed.x - baseline.x) > 0.01)
  }

  @Test func alreadyCancelledTaskIsRejectedAtEstimateEntry() async throws {
    let estimator = try BlazeGazeEstimator(modelURL: requireModelURL(), computeUnits: .cpuOnly)
    let input = try uniformInput()
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await estimator.estimate(input)
    }
    let result = await task.result
    #expect(throws: CancellationError.self) {
      try result.get()
    }
  }
}

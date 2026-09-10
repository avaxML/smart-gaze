import CoreML
import Foundation
import Testing

@testable import Perception

private func requireModelURL() throws -> URL {
  guard faceMeshTestsEnabled(ProcessInfo.processInfo.environment) else {
    FileHandle.standardError.write(
      Data(
        "MODEL TEST SKIPPED: FaceMesh contract tests did not run. Set SMART_GAZE_FACE_MESH_TESTS=1 and SMART_GAZE_FACE_MESH_MODEL_PATH.\n"
          .utf8))
    try Test.cancel(
      "set SMART_GAZE_FACE_MESH_TESTS=1 and SMART_GAZE_FACE_MESH_MODEL_PATH to run face-mesh integration tests"
    )
  }
  let path =
    ProcessInfo.processInfo.environment["SMART_GAZE_FACE_MESH_MODEL_PATH"]
    ?? "Models/face-mesh/face_mesh.mlmodelc"
  let url = URL(fileURLWithPath: path)
  guard FileManager.default.fileExists(atPath: url.path) else {
    throw FaceMeshError.modelMissing(url)
  }
  return url
}

private func uniformInput() throws -> FaceMeshInput {
  try FaceMeshInput(rgb: [Float](repeating: 0.5, count: FaceMeshInput.elementCount))
}

/// Zeroes a top-left block of the RGB fixture; the exact geometry only has to be
/// non-uniform, its purpose is to prove spatial wiring, not mesh accuracy.
private func patternedInput() throws -> FaceMeshInput {
  var values = [Float](repeating: 0.5, count: FaceMeshInput.elementCount)
  for row in 0..<64 {
    for column in 0..<96 {
      let base = (row * FaceMeshInput.width + column) * FaceMeshInput.channels
      for channel in 0..<FaceMeshInput.channels { values[base + channel] = 0 }
    }
  }
  return try FaceMeshInput(rgb: values)
}

/// Zeroes only the red channel in a top-left block. Unlike `patternedInput`, this
/// is asymmetric across channels, so a BGR-ordered or channel-collapsed buffer
/// produces different output and the RGB literal below fails. Geometry and values
/// only exist to pin channel wiring, not mesh accuracy.
private func redChannelPatternedInput() throws -> FaceMeshInput {
  var values = [Float](repeating: 0.5, count: FaceMeshInput.elementCount)
  for row in 0..<64 {
    for column in 0..<96 {
      let base = (row * FaceMeshInput.width + column) * FaceMeshInput.channels
      values[base] = 0
    }
  }
  return try FaceMeshInput(rgb: values)
}

@Suite struct FaceMeshInputContractTests {
  @Test func acceptsTheModelElementCount() throws {
    let input = try uniformInput()
    #expect(input.rgb.count == 110_592)
  }

  @Test func rejectsWrongElementCount() {
    #expect(throws: FaceMeshError.inputInvalid("RGB input needs 110592 floats, got 3")) {
      try FaceMeshInput(rgb: [0.5, 0.5, 0.5])
    }
  }

  @Test func rejectsNonFiniteValue() {
    var rgb = [Float](repeating: 0.5, count: FaceMeshInput.elementCount)
    rgb[123] = .nan
    #expect(throws: FaceMeshError.inputInvalid("RGB input contains a non-finite value")) {
      try FaceMeshInput(rgb: rgb)
    }
  }

  @Test func facePresenceIsSigmoidOfTheLogit() {
    #expect(FaceMeshEstimator.facePresence(fromLogit: 0) == 0.5)
    #expect(abs(FaceMeshEstimator.facePresence(fromLogit: 40) - 1) < 1e-6)
    #expect(FaceMeshEstimator.facePresence(fromLogit: -40) < 1e-6)
  }
}

@Suite struct FaceMeshEstimatorLoadTests {
  @Test func missingModelPathIsReported() {
    let url = URL(fileURLWithPath: "/nonexistent/face_mesh.mlmodelc")
    #expect(throws: FaceMeshError.modelMissing(url)) {
      try FaceMeshEstimator(modelURL: url)
    }
  }
}

@Suite struct FaceMeshModelIntegrationTests {
  @Test func pinnedModelInterfaceIsExact() throws {
    let url = try requireModelURL()
    let model = try MLModel(contentsOf: url, configuration: MLModelConfiguration())
    let inputs = model.modelDescription.inputDescriptionsByName

    #expect(Set(inputs.keys) == ["input_1"])
    #expect(inputs["input_1"]?.multiArrayConstraint?.shape.map(\.intValue) == [1, 192, 192, 3])
    #expect(inputs["input_1"]?.multiArrayConstraint?.dataType == .float32)

    let outputs = model.modelDescription.outputDescriptionsByName
    #expect(Set(outputs.keys) == ["conv2d_20", "conv2d_30"])
    for name in ["conv2d_20", "conv2d_30"] {
      #expect(outputs[name]?.multiArrayConstraint?.dataType == .float32)
      #expect(outputs[name]?.multiArrayConstraint?.shape.isEmpty == true)
    }
  }

  @Test func runtimeOutputCountsAreExact() throws {
    let url = try requireModelURL()
    let model = try MLModel(contentsOf: url, configuration: MLModelConfiguration())
    let array = try MLMultiArray(shape: [1, 192, 192, 3], dataType: .float32)
    for index in 0..<array.count { array[index] = 0.5 }
    let provider = try MLDictionaryFeatureProvider(dictionary: [
      "input_1": MLFeatureValue(multiArray: array)
    ])
    let output = try model.prediction(from: provider)

    #expect(output.featureValue(for: "conv2d_20")?.multiArrayValue?.count == 1_404)
    #expect(output.featureValue(for: "conv2d_30")?.multiArrayValue?.count == 1)
  }

  // The literals below were recorded by an independent direct-Core ML probe on CPU
  // (not by FaceMeshEstimator). They pin the wiring contract: the 192x192x3 buffer
  // is copied in row-major RGB and the output is decoded as 468 `(x, y, z)` triples.
  // Compute precision is Float16, hence the loose coordinate tolerance. These are
  // NOT biological accuracy, MediaPipe parity, or a claim about the model's quality.
  @Test func cpuUniformFixtureMatchesRecordedLandmarks() async throws {
    let estimator = try FaceMeshEstimator(modelURL: requireModelURL(), computeUnits: .cpuOnly)
    let result = try await estimator.landmarks(for: uniformInput())

    #expect(result.landmarks.count == 468)
    #expect(result.landmarks.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
    #expect(abs(result.landmarks[0].x - 93.06837) < 0.5)
    #expect(abs(result.landmarks[0].y - 119.6435) < 0.5)
    #expect(abs(result.landmarks[0].z + 9.83197) < 0.5)
    #expect(abs(result.facePresence - 6.772892797512402e-06) < 1e-6)
  }

  @Test func cpuPatternedFixtureChangesOutput() async throws {
    let estimator = try FaceMeshEstimator(modelURL: requireModelURL(), computeUnits: .cpuOnly)
    let baseline = try await estimator.landmarks(for: uniformInput())
    let patterned = try await estimator.landmarks(for: patternedInput())

    #expect(patterned.landmarks.count == 468)
    #expect(patterned.landmarks.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
    #expect(abs(patterned.landmarks[0].x - 112.7435) < 0.5)
    #expect(abs(patterned.landmarks[0].y - 122.4374) < 0.5)
    #expect(abs(patterned.landmarks[0].z + 10.89937) < 0.5)
    #expect(abs(patterned.landmarks[0].x - baseline.landmarks[0].x) > 1)
  }

  // Literals recorded by the independent direct-Core ML CPU probe for a buffer
  // whose top-left block zeroes only the red channel. A BGR read of the same bytes
  // is exactly the green-preserving/blue-block case, whose recorded first-x is
  // 103.538124, so the assertion below fails if channel order is ignored or
  // swapped. This pins wiring only, not accuracy.
  @Test func cpuChannelDistinctFixturePinsRGBOrder() async throws {
    let estimator = try FaceMeshEstimator(modelURL: requireModelURL(), computeUnits: .cpuOnly)
    let rgb = try redChannelPatternedInput()
    let result = try await estimator.landmarks(for: rgb)

    #expect(abs(result.landmarks[0].x - 91.50332) < 0.5)
    #expect(abs(result.landmarks[0].y - 115.58037) < 0.5)
    #expect(abs(result.landmarks[0].z + 11.816351) < 0.5)

    var swapped = rgb.rgb
    for index in stride(from: 0, to: swapped.count, by: 3) {
      swapped.swapAt(index, index + 2)
    }
    let swappedResult = try await estimator.landmarks(for: FaceMeshInput(rgb: swapped))
    #expect(abs(swappedResult.landmarks[0].x - 103.538124) < 0.5)
    #expect(abs(swappedResult.landmarks[0].x - result.landmarks[0].x) > 1)
  }

  // Coverage gap, stated honestly: this exercises only the entry cancellation
  // checkpoint. The pre- and post-prediction checkpoints cannot be hit
  // deterministically through this synchronous API, and `validateInterface`'s
  // rejection paths (wrong input shape, unexpected or fixed output shapes, wrong
  // dtype) have no negative test because crafting those malformed models needs
  // fixture assets outside this change's scope.
  @Test func alreadyCancelledTaskIsRejectedAtEntry() async throws {
    let estimator = try FaceMeshEstimator(modelURL: requireModelURL(), computeUnits: .cpuOnly)
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

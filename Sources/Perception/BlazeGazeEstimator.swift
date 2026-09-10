import CoreML
import Foundation
import GazeKit

public enum BlazeGazeError: Error, Equatable, Sendable {
  case modelMissing(URL)
  case modelInvalid(String)
  case inputInvalid(String)
  case predictionInvalid(String)
}

public struct BlazeGazeInput: Equatable, Sendable {
  public static let eyeBandElementCount = 196_608
  public static let eyeBandShape = [1, 128, 512, 3]

  public let eyeBandRGB: [Float]
  public let headVector: SIMD3<Float>
  public let faceOriginCentimeters: SIMD3<Float>

  public init(
    eyeBandRGB: [Float],
    headVector: SIMD3<Float>,
    faceOriginCentimeters: SIMD3<Float>
  ) throws {
    guard eyeBandRGB.count == Self.eyeBandElementCount else {
      throw BlazeGazeError.inputInvalid(
        "eye band needs \(Self.eyeBandElementCount) floats, got \(eyeBandRGB.count)")
    }
    guard eyeBandRGB.allSatisfy({ $0.isFinite }) else {
      throw BlazeGazeError.inputInvalid("eye band contains a non-finite value")
    }
    guard Self.isFinite(headVector) else {
      throw BlazeGazeError.inputInvalid("head vector contains a non-finite value")
    }
    guard Self.isFinite(faceOriginCentimeters) else {
      throw BlazeGazeError.inputInvalid("face origin contains a non-finite value")
    }

    self.eyeBandRGB = eyeBandRGB
    self.headVector = headVector
    self.faceOriginCentimeters = faceOriginCentimeters
  }

  private static func isFinite(_ vector: SIMD3<Float>) -> Bool {
    vector.x.isFinite && vector.y.isFinite && vector.z.isFinite
  }
}

public actor BlazeGazeEstimator {
  public static let outputFeatureName = "Identity"
  public static let imageFeatureName = "image"
  public static let headVectorFeatureName = "head_vector"
  public static let faceOriginFeatureName = "face_origin_3d"

  private let model: MLModel

  public init(modelURL: URL, computeUnits: MLComputeUnits = .all) throws {
    guard FileManager.default.fileExists(atPath: modelURL.path) else {
      throw BlazeGazeError.modelMissing(modelURL)
    }

    let configuration = MLModelConfiguration()
    configuration.computeUnits = computeUnits

    let model: MLModel
    do {
      model = try MLModel(contentsOf: modelURL, configuration: configuration)
    } catch {
      throw BlazeGazeError.modelInvalid(
        "could not load \(modelURL.lastPathComponent): \(error.localizedDescription)")
    }

    try Self.validateInterface(model.modelDescription)
    self.model = model
  }

  public func estimate(_ input: BlazeGazeInput) throws -> NormalizedGazePoint {
    try Task.checkCancellation()

    let image: MLMultiArray
    let head: MLMultiArray
    let origin: MLMultiArray
    do {
      image = try MLMultiArray(shape: [1, 128, 512, 3], dataType: .float32)
      head = try MLMultiArray(shape: [1, 3], dataType: .float32)
      origin = try MLMultiArray(shape: [1, 3], dataType: .float32)
    } catch {
      throw BlazeGazeError.predictionInvalid(
        "could not allocate model inputs: \(error.localizedDescription)")
    }

    Self.copy(input.eyeBandRGB, into: image)
    Self.copy(input.headVector, into: head)
    Self.copy(input.faceOriginCentimeters, into: origin)

    let provider: MLFeatureProvider
    do {
      provider = try MLDictionaryFeatureProvider(dictionary: [
        Self.imageFeatureName: MLFeatureValue(multiArray: image),
        Self.headVectorFeatureName: MLFeatureValue(multiArray: head),
        Self.faceOriginFeatureName: MLFeatureValue(multiArray: origin),
      ])
    } catch {
      throw BlazeGazeError.predictionInvalid(
        "could not build the feature provider: \(error.localizedDescription)")
    }

    try Task.checkCancellation()

    let output: MLFeatureProvider
    do {
      output = try model.prediction(from: provider)
    } catch {
      throw BlazeGazeError.predictionInvalid("inference failed: \(error.localizedDescription)")
    }

    try Task.checkCancellation()

    guard let array = output.featureValue(for: Self.outputFeatureName)?.multiArrayValue else {
      throw BlazeGazeError.predictionInvalid("missing \(Self.outputFeatureName) output")
    }
    guard array.count == 2 else {
      throw BlazeGazeError.predictionInvalid("expected 2 output values, got \(array.count)")
    }

    let x = array[0].doubleValue
    let y = array[1].doubleValue
    guard x.isFinite, y.isFinite else {
      throw BlazeGazeError.predictionInvalid("output contained a non-finite value")
    }
    return NormalizedGazePoint(x: x, y: y)
  }

  public func estimate(
    eyeBandRGB: [Float],
    headVector: SIMD3<Float>,
    faceOriginCentimeters: SIMD3<Float>
  ) throws -> NormalizedGazePoint {
    try estimate(
      BlazeGazeInput(
        eyeBandRGB: eyeBandRGB,
        headVector: headVector,
        faceOriginCentimeters: faceOriginCentimeters))
  }

  private static func validateInterface(_ description: MLModelDescription) throws {
    let expectedInputs: [String: [Int]] = [
      imageFeatureName: [1, 128, 512, 3],
      headVectorFeatureName: [1, 3],
      faceOriginFeatureName: [1, 3],
    ]
    let inputs = description.inputDescriptionsByName
    guard Set(inputs.keys) == Set(expectedInputs.keys) else {
      throw BlazeGazeError.modelInvalid(
        "expected inputs \(expectedInputs.keys.sorted()), got \(inputs.keys.sorted())")
    }
    for (name, shape) in expectedInputs {
      try requireFloat32MultiArray(inputs[name], name: name, shape: shape)
    }

    let outputs = description.outputDescriptionsByName
    guard outputs.count == 1, let output = outputs[outputFeatureName] else {
      throw BlazeGazeError.modelInvalid(
        "expected a single \(outputFeatureName) output, got \(outputs.keys.sorted())")
    }
    try requireFloat32MultiArray(output, name: outputFeatureName, shape: [1, 2])
  }

  private static func requireFloat32MultiArray(
    _ feature: MLFeatureDescription?,
    name: String,
    shape: [Int]
  ) throws {
    guard let feature, feature.type == .multiArray, let constraint = feature.multiArrayConstraint
    else {
      throw BlazeGazeError.modelInvalid("\(name) must be a multi-array")
    }
    guard constraint.dataType == .float32 else {
      throw BlazeGazeError.modelInvalid("\(name) must be float32")
    }
    guard constraint.shape.map(\.intValue) == shape else {
      throw BlazeGazeError.modelInvalid(
        "\(name) must have shape \(shape), got \(constraint.shape.map(\.intValue))")
    }
  }

  private static func copy(_ values: [Float], into array: MLMultiArray) {
    let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
    values.withUnsafeBufferPointer { buffer in
      pointer.update(from: buffer.baseAddress!, count: buffer.count)
    }
  }

  private static func copy(_ vector: SIMD3<Float>, into array: MLMultiArray) {
    copy([vector.x, vector.y, vector.z], into: array)
  }
}

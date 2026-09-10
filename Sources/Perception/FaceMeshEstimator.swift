import CoreML
import Foundation

public enum FaceMeshError: Error, Equatable, Sendable {
  case modelMissing(URL)
  case modelInvalid(String)
  case inputInvalid(String)
  case predictionInvalid(String)
}

/// Prepared, model-ready RGB pixels: a contiguous `[1, 192, 192, 3]` float32 buffer
/// in 0...1, row-major from the top-left. The caller owns cropping, resizing,
/// channel order, orientation and colour handling.
public struct FaceMeshInput: Equatable, Sendable {
  public static let width = 192
  public static let height = 192
  public static let channels = 3
  public static let elementCount = 110_592
  public static let shape = [1, 192, 192, 3]

  public let rgb: [Float]

  public init(rgb: [Float]) throws {
    guard rgb.count == Self.elementCount else {
      throw FaceMeshError.inputInvalid(
        "RGB input needs \(Self.elementCount) floats, got \(rgb.count)")
    }
    guard rgb.allSatisfy({ $0.isFinite }) else {
      throw FaceMeshError.inputInvalid("RGB input contains a non-finite value")
    }
    self.rgb = rgb
  }
}

/// Immutable dense-mesh output. Landmarks are 468 `(x, y, z)` triples in the
/// 192x192 crop-pixel space (top-left origin, `z` relative depth); `facePresence`
/// is `sigmoid` of the raw face-presence logit. Map back to image space in the caller.
public struct FaceMeshResult: Equatable, Sendable {
  public static let landmarkCount = 468

  public let landmarks: [SIMD3<Float>]
  public let facePresence: Float

  public init(landmarks: [SIMD3<Float>], facePresence: Float) {
    self.landmarks = landmarks
    self.facePresence = facePresence
  }
}

/// Serializes access to the pinned third-party MediaPipe FaceMesh Core ML model
/// (#032, `face_mesh.mlmodel`). The model stays behind the actor; callers hand in
/// already-prepared pixels and receive crop-space landmarks plus a presence score.
public actor FaceMeshEstimator {
  public static let inputFeatureName = "input_1"
  public static let landmarksFeatureName = "conv2d_20"
  public static let facePresenceFeatureName = "conv2d_30"
  public static let landmarkCoordinateCount = 1_404
  public static let facePresenceElementCount = 1

  private let model: MLModel

  public init(modelURL: URL, computeUnits: MLComputeUnits = .all) throws {
    guard FileManager.default.fileExists(atPath: modelURL.path) else {
      throw FaceMeshError.modelMissing(modelURL)
    }

    let configuration = MLModelConfiguration()
    configuration.computeUnits = computeUnits

    let model: MLModel
    do {
      model = try MLModel(contentsOf: modelURL, configuration: configuration)
    } catch {
      throw FaceMeshError.modelInvalid(
        "could not load \(modelURL.lastPathComponent): \(error.localizedDescription)")
    }

    try Self.validateInterface(model.modelDescription)
    self.model = model
  }

  public func landmarks(for input: FaceMeshInput) throws -> FaceMeshResult {
    try Task.checkCancellation()

    let array: MLMultiArray
    do {
      array = try MLMultiArray(
        shape: FaceMeshInput.shape.map { NSNumber(value: $0) }, dataType: .float32)
    } catch {
      throw FaceMeshError.predictionInvalid(
        "could not allocate the input array: \(error.localizedDescription)")
    }
    Self.copy(input.rgb, into: array)

    let provider: MLFeatureProvider
    do {
      provider = try MLDictionaryFeatureProvider(dictionary: [
        Self.inputFeatureName: MLFeatureValue(multiArray: array)
      ])
    } catch {
      throw FaceMeshError.predictionInvalid(
        "could not build the feature provider: \(error.localizedDescription)")
    }

    // `MLModel.prediction` is synchronous and cannot be interrupted once started;
    // cancellation is only observed immediately before and after the call.
    try Task.checkCancellation()

    let output: MLFeatureProvider
    do {
      output = try model.prediction(from: provider)
    } catch {
      throw FaceMeshError.predictionInvalid("inference failed: \(error.localizedDescription)")
    }

    try Task.checkCancellation()

    return try Self.decode(output)
  }

  public func landmarks(rgb: [Float]) throws -> FaceMeshResult {
    try landmarks(for: FaceMeshInput(rgb: rgb))
  }

  /// Sigmoid of the raw face-presence logit, matching `conv2d_30`.
  public static func facePresence(fromLogit logit: Float) -> Float {
    Float(1 / (1 + exp(-Double(logit))))
  }

  private static func decode(_ output: MLFeatureProvider) throws -> FaceMeshResult {
    guard let coordinates = output.featureValue(for: landmarksFeatureName)?.multiArrayValue else {
      throw FaceMeshError.predictionInvalid("missing \(landmarksFeatureName) output")
    }
    guard coordinates.dataType == .float32 else {
      throw FaceMeshError.predictionInvalid("\(landmarksFeatureName) runtime dtype is not float32")
    }
    // The declared shape is dynamic, so only the concrete count is checked. The
    // count already equals the shape product, so a separate product check would
    // be redundant.
    guard coordinates.count == landmarkCoordinateCount else {
      throw FaceMeshError.predictionInvalid(
        "\(landmarksFeatureName) needs \(landmarkCoordinateCount) values, got \(coordinates.count)")
    }

    guard let presence = output.featureValue(for: facePresenceFeatureName)?.multiArrayValue else {
      throw FaceMeshError.predictionInvalid("missing \(facePresenceFeatureName) output")
    }
    guard presence.dataType == .float32 else {
      throw FaceMeshError.predictionInvalid(
        "\(facePresenceFeatureName) runtime dtype is not float32")
    }
    guard presence.count == facePresenceElementCount else {
      throw FaceMeshError.predictionInvalid(
        "\(facePresenceFeatureName) needs \(facePresenceElementCount) value, got \(presence.count)")
    }

    // Index through MLMultiArray's subscript so engine-owned strides are honoured
    // rather than assuming a contiguous buffer.
    var landmarks = [SIMD3<Float>]()
    landmarks.reserveCapacity(FaceMeshResult.landmarkCount)
    for index in 0..<FaceMeshResult.landmarkCount {
      let base = index * 3
      let point = SIMD3(
        coordinates[base].floatValue,
        coordinates[base + 1].floatValue,
        coordinates[base + 2].floatValue)
      guard point.x.isFinite, point.y.isFinite, point.z.isFinite else {
        throw FaceMeshError.predictionInvalid("landmark \(index) contains a non-finite value")
      }
      landmarks.append(point)
    }

    let logit = presence[0].floatValue
    guard logit.isFinite else {
      throw FaceMeshError.predictionInvalid("face-presence logit is not finite")
    }
    return FaceMeshResult(landmarks: landmarks, facePresence: facePresence(fromLogit: logit))
  }

  private static func validateInterface(_ description: MLModelDescription) throws {
    let inputs = description.inputDescriptionsByName
    guard let input = inputs[inputFeatureName], input.type == .multiArray,
      let constraint = input.multiArrayConstraint
    else {
      throw FaceMeshError.modelInvalid("\(inputFeatureName) must be a multi-array")
    }
    guard constraint.dataType == .float32 else {
      throw FaceMeshError.modelInvalid("\(inputFeatureName) must be float32")
    }
    guard constraint.shape.map(\.intValue) == FaceMeshInput.shape else {
      throw FaceMeshError.modelInvalid(
        "\(inputFeatureName) must have shape \(FaceMeshInput.shape), got \(constraint.shape.map(\.intValue))"
      )
    }

    let outputs = description.outputDescriptionsByName
    guard Set(outputs.keys) == [landmarksFeatureName, facePresenceFeatureName] else {
      throw FaceMeshError.modelInvalid(
        "expected outputs \([landmarksFeatureName, facePresenceFeatureName].sorted()), got \(outputs.keys.sorted())"
      )
    }
    try requireDynamicOutput(outputs[landmarksFeatureName], name: landmarksFeatureName)
    try requireDynamicOutput(outputs[facePresenceFeatureName], name: facePresenceFeatureName)
  }

  /// The pinned artifact declares both outputs with an empty (dynamic) shape, so
  /// the concrete element count is validated from the array returned by a
  /// prediction rather than from the declared interface.
  private static func requireDynamicOutput(_ feature: MLFeatureDescription?, name: String) throws {
    guard let feature, feature.type == .multiArray, let constraint = feature.multiArrayConstraint
    else {
      throw FaceMeshError.modelInvalid("\(name) must be a multi-array")
    }
    guard constraint.dataType == .float32 else {
      throw FaceMeshError.modelInvalid("\(name) must be float32")
    }
    guard constraint.shape.isEmpty else {
      throw FaceMeshError.modelInvalid(
        "\(name) is expected to declare a dynamic shape, got \(constraint.shape.map(\.intValue))")
    }
  }

  /// Inputs are allocated by this type, so their storage is contiguous.
  private static func copy(_ values: [Float], into array: MLMultiArray) {
    let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
    values.withUnsafeBufferPointer { buffer in
      pointer.update(from: buffer.baseAddress!, count: buffer.count)
    }
  }
}

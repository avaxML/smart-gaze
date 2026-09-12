import CoreML
import Foundation

public enum IrisLandmarkError: Error, Equatable, Sendable {
  case modelMissing(URL)
  case modelInvalid(String)
  case inputInvalid(String)
  case predictionInvalid(String)
}

/// Prepared, model-ready RGB pixels: a contiguous `[1, 64, 64, 3]` float32
/// buffer in 0...1, row-major from the top-left. The caller owns cropping,
/// resizing, channel order, orientation and colour handling.
public struct IrisLandmarkInput: Equatable, Sendable {
  public static let width = 64
  public static let height = 64
  public static let channels = 3
  public static let elementCount = 12_288
  public static let shape = [1, 64, 64, 3]

  public let rgb: [Float]

  public init(rgb: [Float]) throws {
    guard rgb.count == Self.elementCount else {
      throw IrisLandmarkError.inputInvalid(
        "RGB input needs \(Self.elementCount) floats, got \(rgb.count)")
    }
    guard rgb.allSatisfy({ $0.isFinite }) else {
      throw IrisLandmarkError.inputInvalid("RGB input contains a non-finite value")
    }
    self.rgb = rgb
  }
}

/// Immutable iris output. `contour` is 71 `(x, y, z)` triples of eye-contour and
/// brow points and `iris` is 5 `(x, y, z)` triples — index 0 the iris centre, 1
/// and 3 the horizontal extremes, 2 and 4 the vertical extremes — both in the
/// 64x64 crop-pixel space (top-left origin, `z` relative depth). Map back to
/// image space in the caller.
public struct IrisLandmarkResult: Equatable, Sendable {
  public static let contourCount = 71
  public static let irisCount = 5

  public let contour: [SIMD3<Float>]
  public let iris: [SIMD3<Float>]

  public init(contour: [SIMD3<Float>], iris: [SIMD3<Float>]) {
    self.contour = contour
    self.iris = iris
  }
}

/// Serializes access to the pinned third-party MediaPipe iris landmark Core ML
/// model (`049_iris_landmark`). The model stays behind the actor; callers hand
/// in already-prepared pixels and receive crop-space eye-contour and iris
/// points.
public actor IrisLandmarkEstimator {
  public static let inputFeatureName = "input_1"
  public static let contourFeatureName = "output_eyes_contours_and_brows"
  public static let irisFeatureName = "output_iris"
  public static let contourCoordinateCount = 213
  public static let irisCoordinateCount = 15

  private let model: MLModel

  public init(modelURL: URL, computeUnits: MLComputeUnits = .all) throws {
    guard FileManager.default.fileExists(atPath: modelURL.path) else {
      throw IrisLandmarkError.modelMissing(modelURL)
    }

    let configuration = MLModelConfiguration()
    configuration.computeUnits = computeUnits

    let model: MLModel
    do {
      model = try MLModel(contentsOf: modelURL, configuration: configuration)
    } catch {
      throw IrisLandmarkError.modelInvalid(
        "could not load \(modelURL.lastPathComponent): \(error.localizedDescription)")
    }

    try Self.validateInterface(model.modelDescription)
    self.model = model
  }

  public func landmarks(for input: IrisLandmarkInput) throws -> IrisLandmarkResult {
    try Task.checkCancellation()

    let array: MLMultiArray
    do {
      array = try MLMultiArray(
        shape: IrisLandmarkInput.shape.map { NSNumber(value: $0) }, dataType: .float32)
    } catch {
      throw IrisLandmarkError.predictionInvalid(
        "could not allocate the input array: \(error.localizedDescription)")
    }
    Self.copy(input.rgb, into: array)

    let provider: MLFeatureProvider
    do {
      provider = try MLDictionaryFeatureProvider(dictionary: [
        Self.inputFeatureName: MLFeatureValue(multiArray: array)
      ])
    } catch {
      throw IrisLandmarkError.predictionInvalid(
        "could not build the feature provider: \(error.localizedDescription)")
    }

    // `MLModel.prediction` is synchronous and cannot be interrupted once started;
    // cancellation is only observed immediately before and after the call.
    try Task.checkCancellation()

    let output: MLFeatureProvider
    do {
      output = try model.prediction(from: provider)
    } catch {
      throw IrisLandmarkError.predictionInvalid("inference failed: \(error.localizedDescription)")
    }

    try Task.checkCancellation()

    return try Self.decode(output)
  }

  public func landmarks(rgb: [Float]) throws -> IrisLandmarkResult {
    try landmarks(for: IrisLandmarkInput(rgb: rgb))
  }

  private static func decode(_ output: MLFeatureProvider) throws -> IrisLandmarkResult {
    let coordinates = try Self.requireOutput(
      output, name: contourFeatureName, count: contourCoordinateCount)
    let irisCoordinates = try Self.requireOutput(
      output, name: irisFeatureName, count: irisCoordinateCount)

    let contour = try Self.points(
      from: coordinates, count: IrisLandmarkResult.contourCount, name: contourFeatureName)
    let iris = try Self.points(
      from: irisCoordinates, count: IrisLandmarkResult.irisCount, name: irisFeatureName)
    return IrisLandmarkResult(contour: contour, iris: iris)
  }

  private static func requireOutput(
    _ output: MLFeatureProvider, name: String, count: Int
  ) throws -> MLMultiArray {
    guard let array = output.featureValue(for: name)?.multiArrayValue else {
      throw IrisLandmarkError.predictionInvalid("missing \(name) output")
    }
    guard array.dataType == .float32 else {
      throw IrisLandmarkError.predictionInvalid("\(name) runtime dtype is not float32")
    }
    // The declared shape is dynamic, so only the concrete count is checked.
    guard array.count == count else {
      throw IrisLandmarkError.predictionInvalid(
        "\(name) needs \(count) values, got \(array.count)")
    }
    return array
  }

  /// Index through MLMultiArray's subscript so engine-owned strides are honoured
  /// rather than assuming a contiguous buffer.
  private static func points(
    from array: MLMultiArray, count: Int, name: String
  ) throws -> [SIMD3<Float>] {
    var points = [SIMD3<Float>]()
    points.reserveCapacity(count)
    for index in 0..<count {
      let base = index * 3
      let point = SIMD3(
        array[base].floatValue,
        array[base + 1].floatValue,
        array[base + 2].floatValue)
      guard point.x.isFinite, point.y.isFinite, point.z.isFinite else {
        throw IrisLandmarkError.predictionInvalid(
          "\(name) point \(index) contains a non-finite value")
      }
      points.append(point)
    }
    return points
  }

  private static func validateInterface(_ description: MLModelDescription) throws {
    let inputs = description.inputDescriptionsByName
    guard let input = inputs[inputFeatureName], input.type == .multiArray,
      let constraint = input.multiArrayConstraint
    else {
      throw IrisLandmarkError.modelInvalid("\(inputFeatureName) must be a multi-array")
    }
    guard constraint.dataType == .float32 else {
      throw IrisLandmarkError.modelInvalid("\(inputFeatureName) must be float32")
    }
    guard constraint.shape.map(\.intValue) == IrisLandmarkInput.shape else {
      throw IrisLandmarkError.modelInvalid(
        "\(inputFeatureName) must have shape \(IrisLandmarkInput.shape), got \(constraint.shape.map(\.intValue))"
      )
    }

    let outputs = description.outputDescriptionsByName
    guard Set(outputs.keys) == [contourFeatureName, irisFeatureName] else {
      throw IrisLandmarkError.modelInvalid(
        "expected outputs \([contourFeatureName, irisFeatureName].sorted()), got \(outputs.keys.sorted())"
      )
    }
    try requireDynamicOutput(outputs[contourFeatureName], name: contourFeatureName)
    try requireDynamicOutput(outputs[irisFeatureName], name: irisFeatureName)
  }

  /// The pinned artifact declares both outputs with an empty (dynamic) shape, so
  /// the concrete element count is validated from the array returned by a
  /// prediction rather than from the declared interface.
  private static func requireDynamicOutput(_ feature: MLFeatureDescription?, name: String) throws {
    guard let feature, feature.type == .multiArray, let constraint = feature.multiArrayConstraint
    else {
      throw IrisLandmarkError.modelInvalid("\(name) must be a multi-array")
    }
    guard constraint.dataType == .float32 else {
      throw IrisLandmarkError.modelInvalid("\(name) must be float32")
    }
    guard constraint.shape.isEmpty else {
      throw IrisLandmarkError.modelInvalid(
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

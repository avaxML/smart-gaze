import CoreGraphics
import Foundation

public struct NormalizedGazePoint: Equatable, Sendable, Codable {
  public let x: Double
  public let y: Double

  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }
}

public struct CalibrationSample: Equatable, Sendable {
  public let gaze: NormalizedGazePoint
  public let screenPoint: CGPoint

  public init(gaze: NormalizedGazePoint, screenPoint: CGPoint) {
    self.gaze = gaze
    self.screenPoint = screenPoint
  }
}

public struct CalibrationMap: Equatable, Sendable, Codable {
  /// Bumped whenever the pipeline that feeds the map changes in a way that
  /// moves its fit: v4 added the calibration head sweep and the rotation
  /// reference the map is only valid with. A stored map with an older marker
  /// is dropped on load, which puts the app back in "Calibration needed"
  /// instead of tracking with a stale fit.
  public static let inputSpaceMarker = "normalized-screen-point-affine-v4"

  public let xCoefficients: [Double]
  public let yCoefficients: [Double]

  init(xCoefficients: [Double], yCoefficients: [Double]) {
    self.xCoefficients = xCoefficients
    self.yCoefficients = yCoefficients
  }

  public func project(_ gaze: NormalizedGazePoint) -> CGPoint {
    let x = dot(xCoefficients, xBasis(gaze))
    let y = dot(yCoefficients, yBasis(gaze))
    return CGPoint(x: x, y: y)
  }

  private enum CodingKeys: String, CodingKey {
    case inputSpace
    case xCoefficients
    case yCoefficients
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let inputSpace = try container.decode(String.self, forKey: .inputSpace)
    guard inputSpace == Self.inputSpaceMarker else {
      throw DecodingError.dataCorruptedError(
        forKey: .inputSpace, in: container,
        debugDescription: "Unsupported calibration input space")
    }

    let xCoefficients = try container.decode([Double].self, forKey: .xCoefficients)
    let yCoefficients = try container.decode([Double].self, forKey: .yCoefficients)
    guard xCoefficients.count == 3, yCoefficients.count == 3,
      xCoefficients.allSatisfy({ $0.isFinite }),
      yCoefficients.allSatisfy({ $0.isFinite })
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .xCoefficients, in: container,
        debugDescription: "Calibration needs three finite coefficients per axis")
    }

    self.xCoefficients = xCoefficients
    self.yCoefficients = yCoefficients
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.inputSpaceMarker, forKey: .inputSpace)
    try container.encode(xCoefficients, forKey: .xCoefficients)
    try container.encode(yCoefficients, forKey: .yCoefficients)
  }
}

public enum CalibrationError: Error, Equatable {
  case insufficientSamples(got: Int, need: Int)
  case degenerate
}

public func solveCalibration(_ samples: [CalibrationSample]) throws -> CalibrationMap {
  guard samples.count >= 3 else {
    throw CalibrationError.insufficientSamples(got: samples.count, need: 3)
  }

  let xCoefficients = try solveAxis(samples, basis: xBasis, value: { Double($0.screenPoint.x) })
  let yCoefficients = try solveAxis(samples, basis: yBasis, value: { Double($0.screenPoint.y) })
  return CalibrationMap(xCoefficients: xCoefficients, yCoefficients: yCoefficients)
}

// The model already emits screen-normalized coordinates, so calibration is a
// small affine correction, which is what upstream applies. A nine-point quadratic
// over this input is ill-conditioned: the first live run produced coefficients in
// the millions and a 0.01 change in gaze moved the screen point by 32,819 points.
private func xBasis(_ gaze: NormalizedGazePoint) -> [Double] {
  [1, gaze.x, gaze.y]
}

private func yBasis(_ gaze: NormalizedGazePoint) -> [Double] {
  [1, gaze.x, gaze.y]
}

private func dot(_ coefficients: [Double], _ row: [Double]) -> Double {
  var sum = 0.0
  for index in 0..<row.count {
    sum += coefficients[index] * row[index]
  }
  return sum
}

private func solveAxis(
  _ samples: [CalibrationSample],
  basis: (NormalizedGazePoint) -> [Double],
  value: (CalibrationSample) -> Double
) throws -> [Double] {
  let count = 3
  var matrix = [[Double]](repeating: [Double](repeating: 0, count: count), count: count)
  var rhs = [Double](repeating: 0, count: count)

  for sample in samples {
    let row = basis(sample.gaze)
    let target = value(sample)
    for i in 0..<count {
      rhs[i] += row[i] * target
      for j in 0..<count {
        matrix[i][j] += row[i] * row[j]
      }
    }
  }

  let coefficients = try gaussianSolve(matrix, rhs)
  guard coefficients.allSatisfy({ $0.isFinite }) else {
    throw CalibrationError.degenerate
  }
  return coefficients
}

private func gaussianSolve(_ inputMatrix: [[Double]], _ inputRHS: [Double]) throws -> [Double] {
  let count = inputMatrix.count
  var matrix = inputMatrix
  var rhs = inputRHS

  for column in 0..<count {
    var pivotRow = column
    var pivotMagnitude = abs(matrix[column][column])
    for row in (column + 1)..<count {
      let magnitude = abs(matrix[row][column])
      if magnitude > pivotMagnitude {
        pivotMagnitude = magnitude
        pivotRow = row
      }
    }

    // 1e-12 rejects duplicate or collinear samples whose normal matrix is singular to machine precision.
    guard pivotMagnitude >= 1e-12 else {
      throw CalibrationError.degenerate
    }

    if pivotRow != column {
      matrix.swapAt(pivotRow, column)
      rhs.swapAt(pivotRow, column)
    }

    let pivot = matrix[column][column]
    for row in (column + 1)..<count {
      let factor = matrix[row][column] / pivot
      if factor == 0 {
        continue
      }
      for col in column..<count {
        matrix[row][col] -= factor * matrix[column][col]
      }
      rhs[row] -= factor * rhs[column]
    }
  }

  var solution = [Double](repeating: 0, count: count)
  for row in stride(from: count - 1, through: 0, by: -1) {
    var sum = rhs[row]
    for col in (row + 1)..<count {
      sum -= matrix[row][col] * solution[col]
    }
    solution[row] = sum / matrix[row][row]
  }
  return solution
}

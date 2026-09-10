import CoreGraphics
import Foundation

public struct GazeAngles: Equatable, Sendable, Codable {
  public let yaw: Double
  public let pitch: Double

  public init(yaw: Double, pitch: Double) {
    self.yaw = yaw
    self.pitch = pitch
  }
}

public struct CalibrationSample: Equatable, Sendable {
  public let angles: GazeAngles
  public let screenPoint: CGPoint

  public init(angles: GazeAngles, screenPoint: CGPoint) {
    self.angles = angles
    self.screenPoint = screenPoint
  }
}

public struct CalibrationMap: Equatable, Sendable, Codable {
  public let xCoefficients: [Double]
  public let yCoefficients: [Double]

  public func project(_ angles: GazeAngles) -> CGPoint {
    let x = dot(xCoefficients, xBasis(angles))
    let y = dot(yCoefficients, yBasis(angles))
    return CGPoint(x: x, y: y)
  }
}

public enum CalibrationError: Error, Equatable {
  case insufficientSamples(got: Int, need: Int)
  case degenerate
}

public func solveCalibration(_ samples: [CalibrationSample]) throws -> CalibrationMap {
  guard samples.count >= 6 else {
    throw CalibrationError.insufficientSamples(got: samples.count, need: 6)
  }

  let xCoefficients = try solveAxis(samples, basis: xBasis, value: { Double($0.screenPoint.x) })
  let yCoefficients = try solveAxis(samples, basis: yBasis, value: { Double($0.screenPoint.y) })
  return CalibrationMap(xCoefficients: xCoefficients, yCoefficients: yCoefficients)
}

private func xBasis(_ angles: GazeAngles) -> [Double] {
  let yaw = angles.yaw
  let pitch = angles.pitch
  return [1, yaw, pitch, yaw * yaw, yaw * pitch, pitch * pitch]
}

private func yBasis(_ angles: GazeAngles) -> [Double] {
  let yaw = angles.yaw
  let pitch = angles.pitch
  return [1, pitch, yaw, pitch * pitch, pitch * yaw, yaw * yaw]
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
  basis: (GazeAngles) -> [Double],
  value: (CalibrationSample) -> Double
) throws -> [Double] {
  let count = 6
  var matrix = [[Double]](repeating: [Double](repeating: 0, count: count), count: count)
  var rhs = [Double](repeating: 0, count: count)

  for sample in samples {
    let row = basis(sample.angles)
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

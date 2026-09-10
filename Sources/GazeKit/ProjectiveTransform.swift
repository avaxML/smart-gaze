import CoreGraphics
import Foundation

/// A 2D projective (homography) transform solved from four point
/// correspondences.
///
/// Stores the row-major 3×3 homogeneous matrix
/// `[m00, m01, m02, m10, m11, m12, m20, m21, m22]` mapping `(x, y)` to
/// `((m00x + m01y + m02) / w, (m10x + m11y + m12) / w)`, where
/// `w = m20x + m21y + m22`. Singular and near-pole inputs return `nil`.
///
/// Formula derivation, gauge, and the singularity policy are documented in
/// `Docs/models/eye-band-geometry.md`.
public struct ProjectiveTransform: Equatable, Sendable {
  /// Row-major 3×3 homogeneous matrix.
  public let matrix: [Double]

  /// Relative magnitude below which a pivot, determinant, or homogeneous
  /// denominator is treated as singular.
  static let singularityEpsilon = 1e-12

  /// Creates a transform from a raw matrix. The matrix must contain exactly
  /// nine finite elements.
  public init?(matrix: [Double]) {
    guard matrix.count == 9, matrix.allSatisfy({ $0.isFinite }) else { return nil }
    self.matrix = matrix
  }

  /// Solves the transform mapping each `source` point onto the corresponding
  /// `destination` point. Returns `nil` for a degenerate, singular, or
  /// non-finite correspondence.
  public init?(source: [CGPoint], destination: [CGPoint]) {
    guard source.count == 4, destination.count == 4 else { return nil }
    guard let solution = Self.solve(source: source, destination: destination) else {
      return nil
    }
    self = solution
  }

  /// Applies the transform to `point`, or returns `nil` when the projected
  /// homogeneous denominator is zero, near-zero, or non-finite.
  public func map(_ point: CGPoint) -> CGPoint? {
    let x = Double(point.x)
    let y = Double(point.y)

    guard let m = normalizedMatrix else { return nil }
    let wx = m[6] * x
    let wy = m[7] * y
    let w = wx + wy + m[8]
    let termScale = max(abs(wx), abs(wy), abs(m[8]))
    guard w.isFinite, abs(w) > Self.singularityEpsilon * termScale else { return nil }

    let mappedX = (m[0] * x + m[1] * y + m[2]) / w
    let mappedY = (m[3] * x + m[4] * y + m[5]) / w
    guard mappedX.isFinite, mappedY.isFinite else { return nil }

    return CGPoint(x: mappedX, y: mappedY)
  }

  /// The inverse transform, or `nil` when the matrix is singular.
  public var inverse: ProjectiveTransform? {
    guard let m = normalizedMatrix else { return nil }
    let c00 = m[4] * m[8] - m[5] * m[7]
    let c01 = m[5] * m[6] - m[3] * m[8]
    let c02 = m[3] * m[7] - m[4] * m[6]
    let c10 = m[2] * m[7] - m[1] * m[8]
    let c11 = m[0] * m[8] - m[2] * m[6]
    let c12 = m[1] * m[6] - m[0] * m[7]
    let c20 = m[1] * m[5] - m[2] * m[4]
    let c21 = m[2] * m[3] - m[0] * m[5]
    let c22 = m[0] * m[4] - m[1] * m[3]

    let determinant = m[0] * c00 + m[1] * c01 + m[2] * c02
    guard determinant.isFinite else { return nil }

    let termScale = abs(m[0] * c00) + abs(m[1] * c01) + abs(m[2] * c02)
    guard abs(determinant) > Self.singularityEpsilon * termScale else { return nil }

    // The adjugate represents the same projective inverse without dividing by a tiny determinant.
    return ProjectiveTransform(matrix: [
      c00, c10, c20,
      c01, c11, c21,
      c02, c12, c22,
    ])
  }

  private var normalizedMatrix: [Double]? {
    let gauge = matrix.reduce(0) { max($0, abs($1)) }
    guard gauge > 0 else { return nil }
    return matrix.map { $0 / gauge }
  }

  private static func solve(source: [CGPoint], destination: [CGPoint]) -> ProjectiveTransform? {
    var a = [[Double]](repeating: [Double](repeating: 0, count: 8), count: 8)
    var b = [Double](repeating: 0, count: 8)
    var largest = 0.0

    for i in 0..<4 {
      let x = Double(source[i].x)
      let y = Double(source[i].y)
      let u = Double(destination[i].x)
      let v = Double(destination[i].y)
      guard x.isFinite, y.isFinite, u.isFinite, v.isFinite else { return nil }

      a[i * 2] = [x, y, 1, 0, 0, 0, -u * x, -u * y]
      a[i * 2 + 1] = [0, 0, 0, x, y, 1, -v * x, -v * y]
      b[i * 2] = u
      b[i * 2 + 1] = v
    }

    for row in a {
      for value in row {
        largest = max(largest, abs(value))
      }
    }
    guard largest > 0 else { return nil }

    let threshold = largest * singularityEpsilon

    for column in 0..<8 {
      var pivot = column
      for row in (column + 1)..<8 where abs(a[row][column]) > abs(a[pivot][column]) {
        pivot = row
      }
      if pivot != column {
        a.swapAt(column, pivot)
        b.swapAt(column, pivot)
      }
      guard abs(a[column][column]) > threshold else { return nil }

      for row in (column + 1)..<8 {
        let factor = a[row][column] / a[column][column]
        if factor == 0 { continue }
        a[row][column] = 0
        for j in (column + 1)..<8 {
          a[row][j] -= factor * a[column][j]
        }
        b[row] -= factor * b[column]
      }
    }

    var h = [Double](repeating: 0, count: 8)
    for i in (0..<8).reversed() {
      var sum = b[i]
      for j in (i + 1)..<8 {
        sum -= a[i][j] * h[j]
      }
      h[i] = sum / a[i][i]
    }
    guard h.allSatisfy({ $0.isFinite }) else { return nil }

    return ProjectiveTransform(matrix: [h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7], 1])
  }
}

import CoreGraphics
import Foundation

/// The ellipse through an iris ring's four rim points, fitted from the two
/// conjugate diameter pairs the model reports: horizontal extremes then
/// vertical extremes.
public enum IrisRingGeometry {
  /// - Parameter rim: Four points in order: horizontal maximum, vertical
  ///   maximum, horizontal minimum, vertical minimum.
  /// - Returns: The ellipse's centre and principal axes, or `nil` for fewer
  ///   than four points or a non-finite or zero-area fit.
  public static func ellipse(
    throughRim rim: [CGPoint]
  ) -> (center: CGPoint, semiMajor: Double, semiMinor: Double, angleRadians: Double)? {
    guard rim.count >= 4 else { return nil }

    let first = rim[0]
    let second = rim[1]
    let third = rim[2]
    let fourth = rim[3]
    let center = CGPoint(
      x: (first.x + second.x + third.x + fourth.x) / 4,
      y: (first.y + second.y + third.y + fourth.y) / 4)

    let u = SIMD2(Double(first.x - third.x) / 2, Double(first.y - third.y) / 2)
    let v = SIMD2(Double(second.x - fourth.x) / 2, Double(second.y - fourth.y) / 2)

    // The ellipse is `M (cos t, sin t)` with `M = [u v]`, so its principal
    // axes are the singular values of `M`, the square roots of `M M^T`'s
    // eigenvalues.
    let s11 = u.x * u.x + v.x * v.x
    let s12 = u.x * u.y + v.x * v.y
    let s22 = u.y * u.y + v.y * v.y
    let trace = s11 + s22
    let discriminant = ((s11 - s22) * (s11 - s22) + 4 * s12 * s12).squareRoot()
    let major = (trace + discriminant) / 2
    let minor = (trace - discriminant) / 2
    guard major.isFinite, minor.isFinite, major > 0, minor > 0 else { return nil }

    var angle = s12 == 0 ? (s11 >= s22 ? 0 : .pi / 2) : atan2(major - s11, s12)
    angle = angle.truncatingRemainder(dividingBy: .pi)
    if angle < 0 { angle += .pi }

    return (
      center: center,
      semiMajor: major.squareRoot(),
      semiMinor: minor.squareRoot(),
      angleRadians: angle
    )
  }
}

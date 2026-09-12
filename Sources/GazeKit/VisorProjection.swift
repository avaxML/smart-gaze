import Foundation

/// Perspective projection of a face mesh for the visor: points in the band's
/// pixel space with depth, seen by a virtual camera in front of the face.
///
/// The maths, pinned by `VisorProjectionTests`:
///
/// 1. The cloud's centroid is the mean `(x, y, z)` over the finite points.
///    Depth normalizes to `0...1` over the finite depths' range (a degenerate
///    range maps to `0.5`).
/// 2. Each relative point `(x - cx, y - cy, depthScale * (z - cz))` is rotated
///    about the centroid by `Ry(-parallaxGain * yaw)` then
///    `Rx(-parallaxGain * pitch)`, so turning the head turns a virtual camera
///    the other way and the near side of the mesh swings outward.
/// 3. The rotated point projects through a pinhole `cameraDistance` from the
///    centroid: `factor = cameraDistance / (cameraDistance + q.z)`, and the
///    output is `centroid + (q.x, q.y) * factor`. A nearer point (smaller `z`,
///    so `q.z < 0`) magnifies away from the centroid; a point exactly at the
///    centroid with mean depth is a fixed point of the projection.
/// 4. A point with a non-finite `x`, `y` or `z` cannot take part in the cloud's
///    statistics, so it passes through with depth `1` and its raw `x`, `y`.
public struct VisorProjection: Equatable, Sendable {
  /// In band-height units: the camera sits this far in front of the centroid.
  public static let cameraDistance = 2.4
  /// The raw `z` values are scaled by this before projecting, to exaggerate
  /// the mesh's shallow depth.
  public static let depthScale = 0.9
  /// Radians of virtual camera rotation per radian of head yaw or pitch.
  public static let parallaxGain = 0.35

  /// One projected point in the band's own space, `depth` normalized `0` (near)
  /// to `1` (far) over the input cloud.
  public struct Point: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let depth: Double

    public init(x: Double, y: Double, depth: Double) {
      self.x = x
      self.y = y
      self.depth = depth
    }
  }

  public static func project(
    points: [SIMD2<Double>], depths: [Double], yawRadians: Double, pitchRadians: Double
  ) -> [Point] {
    let count = points.count
    var z = [Double](repeating: 0, count: count)
    var valid = [Bool](repeating: false, count: count)
    for index in 0..<count {
      let depth = index < depths.count ? depths[index] : 0
      z[index] = depth
      let point = points[index]
      valid[index] = point.x.isFinite && point.y.isFinite && depth.isFinite
    }

    var sumX = 0.0
    var sumY = 0.0
    var sumZ = 0.0
    var minZ = Double.infinity
    var maxZ = -Double.infinity
    var validCount = 0
    for index in 0..<count where valid[index] {
      sumX += points[index].x
      sumY += points[index].y
      sumZ += z[index]
      minZ = min(minZ, z[index])
      maxZ = max(maxZ, z[index])
      validCount += 1
    }

    let centroidX = validCount > 0 ? sumX / Double(validCount) : 0
    let centroidY = validCount > 0 ? sumY / Double(validCount) : 0
    let centroidZ = validCount > 0 ? sumZ / Double(validCount) : 0
    let span = maxZ - minZ
    let hasSpan = validCount > 0 && span > 0

    let alpha = parallaxGain * yawRadians
    let beta = parallaxGain * pitchRadians
    let cosAlpha = cos(alpha)
    let sinAlpha = sin(alpha)
    let cosBeta = cos(beta)
    let sinBeta = sin(beta)

    var projected: [Point] = []
    projected.reserveCapacity(count)
    for index in 0..<count {
      guard valid[index] else {
        projected.append(Point(x: points[index].x, y: points[index].y, depth: 1))
        continue
      }

      let rawDepth = z[index]
      let depth = hasSpan ? (rawDepth - minZ) / span : 0.5

      let relativeX = points[index].x - centroidX
      let relativeY = points[index].y - centroidY
      let relativeZ = depthScale * (rawDepth - centroidZ)

      // Ry(-alpha): the virtual camera yaws the opposite way to the head.
      let yawedX = cosAlpha * relativeX - sinAlpha * relativeZ
      let yawedZ = sinAlpha * relativeX + cosAlpha * relativeZ
      // Rx(-beta).
      let pitchedY = cosBeta * relativeY + sinBeta * yawedZ
      let pitchedZ = -sinBeta * relativeY + cosBeta * yawedZ

      let factor = cameraDistance / (cameraDistance + pitchedZ)
      projected.append(
        Point(
          x: centroidX + yawedX * factor,
          y: centroidY + pitchedY * factor,
          depth: depth))
    }
    return projected
  }
}

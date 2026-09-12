import CoreGraphics
import GazeKit
import SwiftUI

/// The setup stage shown before the first calibration dot: a visor that frames
/// the user's eye band with the face mesh, eye contours and iris rings over a
/// live, mirrored camera image.
///
/// Text is allowed here because this stage precedes the first target. The rule
/// that nothing may compete for the eye beside a live target does not apply
/// until the dot sequence starts.
struct CalibrationSetupView: View {
  // The visor arrives as one thick surface, so its scale and the mesh sweep it
  // carries share a single critically damped spring: it settles, never bounces.
  static let presenceSpring = Animation.spring(response: 0.4, dampingFraction: 1.0)
  static let progressSpring = Animation.spring(response: 0.25, dampingFraction: 1.0)
  static let visorRestingScale: CGFloat = 0.96
  static let visorWidthRatio: CGFloat = 0.58
  static let visorAspectRatio: CGFloat = 2.6
  static let visorCornerRadiusRatio: CGFloat = 0.20
  static let visorCenterYRatio: CGFloat = 0.44
  static let guidanceGap: CGFloat = 28
  static let guidanceHeight: CGFloat = 96
  static let guidanceSettleOffset: CGFloat = 4

  // The stagger spans most of the spring's travel so the last column lands as
  // the visor settles, capping the whole sweep at the spring's ~0.5 s.
  static let meshSweepStaggerSpan: Double = 0.7
  static let meshSweepFadeWidth: Double = 0.3
  static let irisPulseDuration: Double = 1.8
  static let irisPulseScale: Double = 0.06

  static let meshEdgeWidth: CGFloat = 1
  static let meshEdgeMinOpacity: Double = 0.10
  static let meshEdgeDepthOpacity: Double = 0.25
  static let meshDotMinOpacity: Double = 0.25
  static let meshDotDepthOpacity: Double = 0.45
  static let meshDotMinDiameter: CGFloat = 1.0
  static let meshDotDepthDiameter: CGFloat = 0.6
  static let contourDotDiameter: CGFloat = 1.25
  static let contourDotOpacity: Double = 0.70
  static let irisRingWidth: CGFloat = 1.75
  static let irisRingOpacity: Double = 0.90
  static let irisDotDiameter: CGFloat = 2.5
  static let bandFeatherFraction: CGFloat = 0.18
  static let borderHairline: CGFloat = 1
  static let borderOpacity: Double = 0.12
  static let borderHighlightOpacity: Double = 0.22

  // Motion: positions settle in `positionSpringResponse`, the iris ring in
  // `irisSpringResponse`, and the one-shot scan uses the same critically
  // damped shape over a longer travel.
  nonisolated static let positionSpringResponse: Double = 0.12
  nonisolated static let irisSpringResponse: Double = 0.25
  nonisolated static let irisRatioReference: Double = 0.30
  nonisolated static let irisMinScale: Double = 0.3
  static let scanSpring = Animation.spring(response: 0.9, dampingFraction: 1.0)
  static let scanWidthFraction: CGFloat = 0.12
  static let scanBoost: Double = 1.6

  static let guidanceTitleTracking: CGFloat = -0.01
  static let progressBarWidth: CGFloat = 160
  static let progressBarHeight: CGFloat = 3

  var face: CalibrationSetupFace?
  var image: CGImage?
  var guidance: CalibrationSetupGuidance
  var frameSize: CGSize

  private let meshEdges: Set<MeshEdge>

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var presence: Double = 1
  @State private var pulse: Double = 0
  @State private var scan: Double = 0
  @State private var animation = VisorAnimation()

  init(
    face: CalibrationSetupFace? = nil,
    image: CGImage? = nil,
    guidance: CalibrationSetupGuidance,
    frameSize: CGSize
  ) {
    self.face = face
    self.image = image
    self.guidance = guidance
    self.frameSize = frameSize
    self.meshEdges = Self.edges(from: FaceMeshTriangulation.triangles)
  }

  var body: some View {
    GeometryReader { proxy in
      let size = proxy.size
      let visorWidth = size.width * Self.visorWidthRatio
      let visorHeight = visorWidth / Self.visorAspectRatio
      let corner = visorHeight * Self.visorCornerRadiusRatio
      let visorCenterY = size.height * Self.visorCenterYRatio

      ZStack {
        Color.black

        visor(width: visorWidth, height: visorHeight, corner: corner)
          .scaleEffect(visorScale)
          .opacity(presence)
          .position(x: size.width / 2, y: visorCenterY)

        ZStack {
          guidanceContent
            .contentTransition(.opacity)
            .id(guidanceKey)
            .transition(
              reduceMotion
                ? .opacity
                : .offset(y: Self.guidanceSettleOffset).combined(with: .opacity))
        }
        .foregroundStyle(.white)
        .frame(width: visorWidth, height: Self.guidanceHeight)
        .animation(Self.presenceSpring, value: guidanceKey)
        .position(
          x: size.width / 2,
          y: visorCenterY + visorHeight / 2 + Self.guidanceGap + Self.guidanceHeight / 2
        )
      }
      .frame(width: size.width, height: size.height)
    }
    .ignoresSafeArea()
    .task {
      // Seed the absent state after the first frame so an offscreen
      // ImageRenderer snapshot still shows the settled visor.
      await Task.yield()
      if face == nil { presence = 0 }
      guard !reduceMotion else { return }
      // The repeating pulse starts one frame after the view settles. Starting
      // it during the first render makes an offscreen ImageRenderer snapshot
      // drop every Text sibling.
      try? await Task.sleep(for: .milliseconds(50))
      withAnimation(
        .easeInOut(duration: Self.irisPulseDuration).repeatForever(autoreverses: true)
      ) {
        pulse = 1
      }
    }
    .onChange(of: face != nil) { _, present in
      withAnimation(Self.presenceSpring) {
        presence = present ? 1 : 0
      }
      guard present, !reduceMotion else {
        scan = 0
        return
      }
      scan = 0
      withAnimation(Self.scanSpring) {
        scan = 1
      }
    }
  }

  private var visorScale: CGFloat {
    guard !reduceMotion else { return 1 }
    return Self.visorRestingScale + (1 - Self.visorRestingScale) * CGFloat(presence)
  }

  /// Case identity for the guidance crossfade. It deliberately ignores the
  /// live `holdStill` progress and `centerFace` offsets so a changing value
  /// updates in place instead of replaying the transition every frame.
  private var guidanceKey: Int {
    switch guidance {
    case .findingFace: 0
    case .moveCloser: 1
    case .moveBack: 2
    case .centerFace: 3
    case .holdStill: 4
    case .ready: 5
    }
  }

  private func visor(width: CGFloat, height: CGFloat, corner: CGFloat) -> some View {
    ZStack {
      TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion)) { timeline in
        Canvas { context, size in
          draw(in: context, size: size, timestamp: timeline.date.timeIntervalSinceReferenceDate)
        }
      }
      .frame(width: width, height: height)
      .background(Color.black)
      .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))

      RoundedRectangle(cornerRadius: corner, style: .continuous)
        .strokeBorder(.white.opacity(borderOpacity), lineWidth: Self.borderHairline)
    }
    .frame(width: width, height: height)
    .animation(Self.presenceSpring, value: guidanceKey)
  }

  private var borderOpacity: Double {
    switch guidance {
    case .holdStill, .ready: return Self.borderHighlightOpacity
    default: return Self.borderOpacity
    }
  }

  private var accent: Color { .accentColor }

  private var feather: Gradient {
    Gradient(stops: [
      .init(color: .black, location: 0),
      .init(color: .clear, location: Self.bandFeatherFraction),
      .init(color: .clear, location: 1 - Self.bandFeatherFraction),
      .init(color: .black, location: 1),
    ])
  }

  private func draw(in context: GraphicsContext, size: CGSize, timestamp: TimeInterval) {
    let band = face?.eyeBand ?? CGRect(x: 0, y: 0, width: 1, height: 1)
    guard band.width > 0, band.height > 0, frameSize.width > 0, frameSize.height > 0 else {
      return
    }

    var mirrored = context
    mirrored.translateBy(x: size.width, y: 0)
    mirrored.scaleBy(x: -1, y: 1)

    if let image {
      mirrored.draw(
        Image(decorative: image, scale: 1),
        in: Self.imageRect(band: band, frameSize: frameSize, visorSize: size))
    }

    let visor = Path(CGRect(origin: .zero, size: size))
    mirrored.fill(visor, with: .color(.black.opacity(0.35)))
    mirrored.fill(
      visor,
      with: .linearGradient(
        feather, startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))

    let targets = meshTargets(band: band, visorSize: size)
    if !targets.isEmpty {
      animation.advance(
        toward: targets, aspectRatios: face?.eyeAspectRatios, at: timestamp,
        reduceMotion: reduceMotion)
    }
    let nodes = animation.currentNodes
    drawMesh(nodes: nodes, size: size, in: mirrored)

    guard let face else { return }
    let rings = animation.ringScales
    draw(contour: face.imageRightEyeContour, band: band, size: size, nodes: nodes, in: mirrored)
    draw(contour: face.imageLeftEyeContour, band: band, size: size, nodes: nodes, in: mirrored)
    draw(
      iris: face.imageRightIris, band: band, size: size, ringScale: rings.right, in: mirrored)
    draw(iris: face.imageLeftIris, band: band, size: size, ringScale: rings.left, in: mirrored)
  }

  private func meshTargets(band: CGRect, visorSize: CGSize) -> [Int: VisorAnimation.Node] {
    guard let face, !face.mesh.isEmpty else { return [:] }
    let base = face.mesh.map { Self.bandPoint($0, band: band, frameSize: frameSize) }
    let yaw = face.rotation.map { headYawRadians(from: headVector(from: $0)) } ?? 0
    let pitch = face.rotation.map { headPitchRadians(from: headVector(from: $0)) } ?? 0
    let projected = VisorProjection.project(
      points: base, depths: face.meshDepth, yawRadians: yaw, pitchRadians: pitch)
    guard !projected.isEmpty else { return [:] }
    let minX = projected.map(\.x).min() ?? 0
    let maxX = projected.map(\.x).max() ?? 1
    let span = max(maxX - minX, 0.0001)
    var targets: [Int: VisorAnimation.Node] = [:]
    targets.reserveCapacity(projected.count)
    for (index, point) in projected.enumerated() {
      targets[index] = VisorAnimation.Node(
        point: Self.visorPoint(point, band: band, frameSize: frameSize, visorSize: visorSize),
        depth: point.depth,
        column: (point.x - minX) / span)
    }
    return targets
  }

  nonisolated private static func edges(from triangles: [SIMD3<Int32>]) -> Set<MeshEdge> {
    var edges: Set<MeshEdge> = []
    edges.reserveCapacity(triangles.count * 3)
    for triangle in triangles {
      edges.insert(MeshEdge(triangle[0], triangle[1]))
      edges.insert(MeshEdge(triangle[1], triangle[2]))
      edges.insert(MeshEdge(triangle[2], triangle[0]))
    }
    return edges
  }

  nonisolated private static func bandPoint(
    _ point: CGPoint, band: CGRect, frameSize: CGSize
  ) -> SIMD2<Double> {
    let bandPixels = pixelBand(band, frameSize: frameSize)
    guard bandPixels.height > 0 else { return SIMD2(0, 0) }
    return SIMD2(
      (Double(point.x) * frameSize.width - bandPixels.minX) / bandPixels.height,
      (Double(point.y) * frameSize.height - bandPixels.minY) / bandPixels.height)
  }

  nonisolated private static func visorPoint(
    _ point: VisorProjection.Point, band: CGRect, frameSize: CGSize, visorSize: CGSize
  ) -> CGPoint {
    let bandPixels = pixelBand(band, frameSize: frameSize)
    let scale = aspectFillScale(band: band, frameSize: frameSize, visorSize: visorSize)
    return CGPoint(
      x: visorSize.width / 2 + (point.x * bandPixels.height - bandPixels.width / 2) * scale,
      y: visorSize.height / 2 + (point.y * bandPixels.height - bandPixels.height / 2) * scale)
  }

  private func scanBoost(visorX: Double, visorWidth: CGFloat) -> Double {
    guard !reduceMotion, scan > 0.001, scan < 0.999 else { return 1 }
    let halfWidth = Double(visorWidth) * Double(Self.scanWidthFraction)
    let distance = abs(visorX - scan * Double(visorWidth))
    guard distance < halfWidth else { return 1 }
    return 1 + (Self.scanBoost - 1) * (1 - distance / halfWidth)
  }

  private func nearestDepth(
    _ visorPoint: CGPoint, nodes: [Int: VisorAnimation.Node]
  ) -> Double {
    var best = 0.5
    var bestDistance = Double.greatestFiniteMagnitude
    for node in nodes.values {
      let dx = Double(node.point.x - visorPoint.x)
      let dy = Double(node.point.y - visorPoint.y)
      let distance = dx * dx + dy * dy
      if distance < bestDistance {
        bestDistance = distance
        best = node.depth
      }
    }
    return best
  }

  nonisolated private static func pixelBand(_ band: CGRect, frameSize: CGSize) -> CGRect {
    CGRect(
      x: band.minX * frameSize.width,
      y: band.minY * frameSize.height,
      width: band.width * frameSize.width,
      height: band.height * frameSize.height
    )
  }

  nonisolated private static func aspectFillScale(
    band: CGRect, frameSize: CGSize, visorSize: CGSize
  ) -> CGFloat {
    let bandPixels = pixelBand(band, frameSize: frameSize)
    return max(visorSize.width / bandPixels.width, visorSize.height / bandPixels.height)
  }

  nonisolated static func project(
    _ point: CGPoint, band: CGRect, frameSize: CGSize, visorSize: CGSize
  ) -> CGPoint {
    let bandPixels = pixelBand(band, frameSize: frameSize)
    let scale = aspectFillScale(band: band, frameSize: frameSize, visorSize: visorSize)
    return CGPoint(
      x: visorSize.width / 2 + (point.x * frameSize.width - bandPixels.midX) * scale,
      y: visorSize.height / 2 + (point.y * frameSize.height - bandPixels.midY) * scale
    )
  }

  nonisolated private static func imageRect(
    band: CGRect, frameSize: CGSize, visorSize: CGSize
  ) -> CGRect {
    let bandPixels = pixelBand(band, frameSize: frameSize)
    let scale = aspectFillScale(band: band, frameSize: frameSize, visorSize: visorSize)
    return CGRect(
      x: visorSize.width / 2 - bandPixels.midX * scale,
      y: visorSize.height / 2 - bandPixels.midY * scale,
      width: frameSize.width * scale,
      height: frameSize.height * scale
    )
  }

  private func drawMesh(
    nodes: [Int: VisorAnimation.Node], size: CGSize, in context: GraphicsContext
  ) {
    guard !nodes.isEmpty else { return }
    for edge in meshEdges {
      guard let a = nodes[edge.a], let b = nodes[edge.b] else { continue }
      let depth = (a.depth + b.depth) / 2
      var opacity = Self.meshEdgeMinOpacity + Self.meshEdgeDepthOpacity * (1 - depth)
      opacity *= sweep(position: (a.column + b.column) / 2)
      opacity *= scanBoost(
        visorX: Double((a.point.x + b.point.x) / 2), visorWidth: size.width)
      opacity = min(opacity, 1)
      guard opacity > 0.004 else { continue }
      var path = Path()
      path.move(to: a.point)
      path.addLine(to: b.point)
      context.stroke(path, with: .color(.white.opacity(opacity)), lineWidth: Self.meshEdgeWidth)
    }
    for node in nodes.values {
      var opacity = Self.meshDotMinOpacity + Self.meshDotDepthOpacity * (1 - node.depth)
      opacity *= sweep(position: node.column)
      opacity *= scanBoost(visorX: Double(node.point.x), visorWidth: size.width)
      opacity = min(opacity, 1)
      guard opacity > 0.004 else { continue }
      let diameter = Self.meshDotMinDiameter + Self.meshDotDepthDiameter * (1 - node.depth)
      drawDot(at: node.point, opacity: opacity, diameter: diameter, in: context)
    }
  }

  private func sweep(position: Double) -> Double {
    guard !reduceMotion else { return 1 }
    let delay = position * Self.meshSweepStaggerSpan
    return min(max((presence - delay) / Self.meshSweepFadeWidth, 0), 1)
  }

  private func drawDot(
    at point: CGPoint, opacity: Double, diameter: CGFloat, in context: GraphicsContext
  ) {
    let radius = diameter / 2
    let rect = CGRect(
      x: point.x - radius, y: point.y - radius, width: diameter, height: diameter)
    context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(opacity)))
  }

  private func draw(
    contour: [CGPoint], band: CGRect, size: CGSize, nodes: [Int: VisorAnimation.Node],
    in context: GraphicsContext
  ) {
    for point in contour {
      let projected = Self.project(point, band: band, frameSize: frameSize, visorSize: size)
      let depth = nearestDepth(projected, nodes: nodes)
      let opacity = Self.contourDotOpacity * (0.5 + 0.5 * (1 - depth))
      drawDot(
        at: projected, opacity: opacity, diameter: Self.contourDotDiameter,
        in: context)
    }
  }

  private func draw(
    iris: [CGPoint], band: CGRect, size: CGSize, ringScale: Double, in context: GraphicsContext
  ) {
    guard iris.count >= 5 else { return }
    let center = Self.project(iris[0], band: band, frameSize: frameSize, visorSize: size)
    let rim = iris.dropFirst().prefix(4).map {
      Self.project($0, band: band, frameSize: frameSize, visorSize: size)
    }
    guard !rim.isEmpty else { return }
    let radius =
      rim.map { hypot(Double($0.x - center.x), Double($0.y - center.y)) }.reduce(0, +)
      / Double(rim.count)
    let scale = ringScale * (1 + Self.irisPulseScale * pulse)
    let ring = CGRect(
      x: center.x - CGFloat(radius * scale),
      y: center.y - CGFloat(radius * scale),
      width: CGFloat(2 * radius * scale),
      height: CGFloat(2 * radius * scale)
    )
    context.stroke(
      Path(ellipseIn: ring), with: .color(accent.opacity(Self.irisRingOpacity)),
      lineWidth: Self.irisRingWidth)
    let dotRadius = Self.irisDotDiameter / 2
    let dot = CGRect(
      x: center.x - dotRadius, y: center.y - dotRadius, width: Self.irisDotDiameter,
      height: Self.irisDotDiameter)
    context.fill(Path(ellipseIn: dot), with: .color(accent))
  }

  @ViewBuilder
  private var guidanceContent: some View {
    switch guidance {
    case .findingFace:
      guidanceStack("Looking for your face", "Sit in front of the camera")
    case .moveCloser:
      guidanceStack("Move a little closer", "About an arm's length from the screen")
    case .moveBack:
      guidanceStack("Move back a little", "About an arm's length from the screen")
    case .centerFace(let offsetX, let offsetY):
      VStack(spacing: 8) {
        HStack(spacing: 10) {
          Image(systemName: arrowSymbol(offsetX: offsetX, offsetY: offsetY))
            .symbolEffect(.pulse, isActive: !reduceMotion)
          guidanceTitle("Center your face")
        }
        guidanceCaption("Keep your eyes level")
      }
    case .holdStill(let progress):
      VStack(spacing: 8) {
        guidanceTitle("Hold still")
        guidanceCaption("Keep your head still")
        progressBar(progress: progress, isReady: false)
      }
    case .ready:
      VStack(spacing: 8) {
        guidanceTitle("Ready")
        guidanceCaption("Follow the dot")
        progressBar(progress: 1, isReady: true)
      }
    }
  }

  private func guidanceTitle(_ text: String) -> some View {
    Text(text)
      .font(.title2.weight(.semibold))
      .tracking(Self.guidanceTitleTracking)
  }

  private func guidanceCaption(_ text: String) -> some View {
    Text(text)
      .font(.callout)
      .foregroundStyle(.secondary)
  }

  private func guidanceStack(_ title: String, _ caption: String) -> some View {
    VStack(spacing: 8) {
      guidanceTitle(title)
      guidanceCaption(caption)
    }
  }

  /// The visor shows the user a mirror, so a horizontal correction points with
  /// the raw offset while a vertical one points against it.
  private func arrowSymbol(offsetX: Double, offsetY: Double) -> String {
    if abs(offsetX) >= abs(offsetY) {
      return offsetX >= 0 ? "arrow.right" : "arrow.left"
    }
    return offsetY >= 0 ? "arrow.up" : "arrow.down"
  }

  private func progressBar(progress: Double, isReady: Bool) -> some View {
    let clamped = min(max(progress, 0), 1)
    return ZStack(alignment: .leading) {
      Capsule().fill(.white.opacity(0.18))
      Capsule()
        .fill(isReady ? accent : .white)
        .frame(width: Self.progressBarWidth * CGFloat(clamped))
    }
    .frame(width: Self.progressBarWidth, height: Self.progressBarHeight)
    .animation(Self.progressSpring, value: clamped)
  }
}

/// An undirected mesh edge, so each of a triangle's three edges is drawn once.
private struct MeshEdge: Hashable {
  let a: Int
  let b: Int

  init(_ first: Int32, _ second: Int32) {
    a = Int(min(first, second))
    b = Int(max(first, second))
  }
}

/// Holds the visor's projected points and iris-ring scales between timeline
/// ticks and steps each toward its target with a critically damped spring, so a
/// head turn or a blink never snaps. Reference-typed because it is advanced
/// during draw rather than through SwiftUI's animation machinery.
private final class VisorAnimation {
  struct Node {
    var point: CGPoint
    var depth: Double
    var column: Double
  }

  private var nodes: [Int: Node] = [:]
  private var velocities: [Int: CGPoint] = [:]
  private var leftRing: Double = 1
  private var rightRing: Double = 1
  private var leftRingVelocity: Double = 0
  private var rightRingVelocity: Double = 0
  private var lastTimestamp: TimeInterval?

  var currentNodes: [Int: Node] { nodes }
  var ringScales: (left: Double, right: Double) { (leftRing, rightRing) }

  func advance(
    toward targets: [Int: Node],
    aspectRatios: (left: Double, right: Double)?,
    at timestamp: TimeInterval,
    reduceMotion: Bool
  ) {
    let leftTarget = Self.ringScale(aspectRatios?.left)
    let rightTarget = Self.ringScale(aspectRatios?.right)

    guard let last = lastTimestamp, !reduceMotion else {
      nodes = targets
      velocities.removeAll()
      leftRing = leftTarget
      rightRing = rightTarget
      leftRingVelocity = 0
      rightRingVelocity = 0
      lastTimestamp = timestamp
      return
    }
    lastTimestamp = timestamp

    let dt = min(max(timestamp - last, 0), 1.0 / 20.0)
    guard dt > 0 else { return }

    let omega = 2 * Double.pi / CalibrationSetupView.positionSpringResponse
    for (index, target) in targets {
      let current = nodes[index] ?? target
      let velocity = velocities[index] ?? .zero
      let accelerationX =
        -2 * omega * Double(velocity.x) - omega * omega * Double(current.point.x - target.point.x)
      let accelerationY =
        -2 * omega * Double(velocity.y) - omega * omega * Double(current.point.y - target.point.y)
      let nextVelocity = CGPoint(
        x: velocity.x + CGFloat(accelerationX * dt),
        y: velocity.y + CGFloat(accelerationY * dt))
      let nextPoint = CGPoint(
        x: current.point.x + nextVelocity.x * CGFloat(dt),
        y: current.point.y + nextVelocity.y * CGFloat(dt))
      nodes[index] = Node(point: nextPoint, depth: target.depth, column: target.column)
      velocities[index] = nextVelocity
    }

    let ringOmega = 2 * Double.pi / CalibrationSetupView.irisSpringResponse
    (leftRing, leftRingVelocity) = Self.step(
      leftRing, leftRingVelocity, toward: leftTarget, omega: ringOmega, dt: dt)
    (rightRing, rightRingVelocity) = Self.step(
      rightRing, rightRingVelocity, toward: rightTarget, omega: ringOmega, dt: dt)
  }

  private static func ringScale(_ ratio: Double?) -> Double {
    guard let ratio, ratio.isFinite else { return 1 }
    return min(
      max(ratio / CalibrationSetupView.irisRatioReference, CalibrationSetupView.irisMinScale), 1)
  }

  private static func step(
    _ value: Double, _ velocity: Double, toward target: Double, omega: Double, dt: Double
  ) -> (Double, Double) {
    let acceleration = -2 * omega * velocity - omega * omega * (value - target)
    let nextVelocity = velocity + acceleration * dt
    return (value + nextVelocity * dt, nextVelocity)
  }
}

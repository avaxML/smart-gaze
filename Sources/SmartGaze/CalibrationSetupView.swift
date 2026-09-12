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

  static let meshDotDiameter: CGFloat = 1.25
  static let meshDotOpacity: Double = 0.45
  static let contourDotDiameter: CGFloat = 1.25
  static let contourDotOpacity: Double = 0.70
  static let irisRingWidth: CGFloat = 1.75
  static let irisRingOpacity: Double = 0.90
  static let irisDotDiameter: CGFloat = 2.5
  static let bandFeatherFraction: CGFloat = 0.18
  static let borderHairline: CGFloat = 1
  static let borderOpacity: Double = 0.12
  static let borderHighlightOpacity: Double = 0.22

  static let guidanceTitleTracking: CGFloat = -0.01
  static let progressBarWidth: CGFloat = 160
  static let progressBarHeight: CGFloat = 3

  var face: CalibrationSetupFace?
  var image: CGImage?
  var guidance: CalibrationSetupGuidance
  var frameSize: CGSize

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var presence: Double = 1
  @State private var pulse: Double = 0

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
      Canvas { context, size in
        draw(in: context, size: size)
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

  private func draw(in context: GraphicsContext, size: CGSize) {
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

    guard let face else { return }
    draw(mesh: face.mesh, band: band, size: size, in: mirrored)
    draw(contour: face.imageRightEyeContour, band: band, size: size, in: mirrored)
    draw(contour: face.imageLeftEyeContour, band: band, size: size, in: mirrored)
    draw(iris: face.imageRightIris, band: band, size: size, in: mirrored)
    draw(iris: face.imageLeftIris, band: band, size: size, in: mirrored)
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

  private func draw(
    mesh: [CGPoint], band: CGRect, size: CGSize, in context: GraphicsContext
  ) {
    guard !mesh.isEmpty else { return }
    let minX = mesh.map(\.x).min() ?? 0
    let maxX = mesh.map(\.x).max() ?? 1
    let span = max(Double(maxX - minX), 0.0001)
    for point in mesh {
      let alpha = Self.meshDotOpacity * sweep(position: Double(point.x - minX) / span)
      guard alpha > 0.004 else { continue }
      let projected = Self.project(point, band: band, frameSize: frameSize, visorSize: size)
      drawDot(at: projected, opacity: alpha, diameter: Self.meshDotDiameter, in: context)
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
    contour: [CGPoint], band: CGRect, size: CGSize, in context: GraphicsContext
  ) {
    for point in contour {
      let projected = Self.project(point, band: band, frameSize: frameSize, visorSize: size)
      drawDot(
        at: projected, opacity: Self.contourDotOpacity, diameter: Self.contourDotDiameter,
        in: context)
    }
  }

  private func draw(
    iris: [CGPoint], band: CGRect, size: CGSize, in context: GraphicsContext
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
    let scale = 1 + Self.irisPulseScale * pulse
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

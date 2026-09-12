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
  var face: CalibrationSetupFace?
  var image: CGImage?
  var guidance: CalibrationSetupGuidance
  var frameSize: CGSize

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var reveal: Double = 1
  @State private var pulse: Double = 0
  @State private var glow = false

  private let guidanceHeight: CGFloat = 96
  private let guidanceGap: CGFloat = 40

  var body: some View {
    GeometryReader { proxy in
      let size = proxy.size
      let visorWidth = size.width * 0.62
      let visorHeight = visorWidth / 2.6
      let corner = visorHeight * 0.22

      ZStack {
        Color.black

        visor(width: visorWidth, height: visorHeight, corner: corner)
          .position(x: size.width / 2, y: size.height / 2)

        guidanceContent
          .frame(width: visorWidth, height: guidanceHeight)
          .position(
            x: size.width / 2,
            y: size.height / 2 + visorHeight / 2 + guidanceGap + guidanceHeight / 2
          )
          .animation(.easeInOut(duration: 0.25), value: guidance)
      }
      .frame(width: size.width, height: size.height)
    }
    .ignoresSafeArea()
    .task {
      guard !reduceMotion else { return }
      // The repeating pulse and glow start one frame after the view settles.
      // Starting them during the first render makes an offscreen ImageRenderer
      // snapshot drop every Text sibling.
      try? await Task.sleep(for: .milliseconds(50))
      startAnimations()
    }
    .onChange(of: face != nil) { _, present in
      if present {
        animateReveal()
      } else {
        reveal = 0
      }
    }
  }

  private func startAnimations() {
    guard !reduceMotion else { return }
    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
      pulse = 1
    }
    withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
      glow = true
    }
  }

  private func animateReveal() {
    if reduceMotion {
      withAnimation(.easeOut(duration: 0.3)) { reveal = 1 }
      return
    }
    reveal = 0
    withAnimation(.easeOut(duration: 0.6)) { reveal = 1 }
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
        .strokeBorder(borderColor, lineWidth: 2)
    }
    .frame(width: width, height: height)
  }

  private var borderColor: Color {
    if face == nil {
      return .white.opacity(0.18 + (glow ? 0.22 : 0))
    }
    return .white.opacity(0.14)
  }

  private var accent: Color { .accentColor }

  private var feather: Gradient {
    Gradient(stops: [
      .init(color: .black, location: 0),
      .init(color: .black.opacity(0.75), location: 0.14),
      .init(color: .clear, location: 0.36),
      .init(color: .clear, location: 0.64),
      .init(color: .black.opacity(0.75), location: 0.86),
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
      let alpha = dotAlpha(position: Double(point.x - minX) / span)
      guard alpha > 0.004 else { continue }
      let projected = Self.project(point, band: band, frameSize: frameSize, visorSize: size)
      drawDot(at: projected, opacity: 0.55 * alpha, in: context)
    }
  }

  private func drawDot(at point: CGPoint, opacity: Double, in context: GraphicsContext) {
    let rect = CGRect(x: point.x - 0.75, y: point.y - 0.75, width: 1.5, height: 1.5)
    context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(opacity)))
  }

  private func dotAlpha(position: Double) -> Double {
    guard !reduceMotion else { return reveal }
    let delay = position * 0.7
    return min(max((reveal - delay) / 0.3, 0), 1)
  }

  private func draw(
    contour: [CGPoint], band: CGRect, size: CGSize, in context: GraphicsContext
  ) {
    for point in contour {
      let projected = Self.project(point, band: band, frameSize: frameSize, visorSize: size)
      drawDot(at: projected, opacity: 0.8 * reveal, in: context)
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
    let scale = 1 + 0.08 * pulse
    let ring = CGRect(
      x: center.x - CGFloat(radius * scale),
      y: center.y - CGFloat(radius * scale),
      width: CGFloat(2 * radius * scale),
      height: CGFloat(2 * radius * scale)
    )
    context.stroke(Path(ellipseIn: ring), with: .color(accent.opacity(reveal)), lineWidth: 1.5)
    let dot = CGRect(x: center.x - 1, y: center.y - 1, width: 2, height: 2)
    context.fill(Path(ellipseIn: dot), with: .color(accent.opacity(reveal)))
  }

  @ViewBuilder
  private var guidanceContent: some View {
    switch guidance {
    case .findingFace:
      captionStack("Looking for your face", "Sit in front of the camera")
    case .moveCloser:
      captionStack("Move a little closer", "About an arm's length from the screen")
    case .moveBack:
      captionStack("Move back a little", "About an arm's length from the screen")
    case .centerFace(let offsetX, let offsetY):
      VStack(spacing: 8) {
        HStack(spacing: 10) {
          Image(systemName: arrowSymbol(offsetX: offsetX, offsetY: offsetY))
          Text("Center your face").font(.title3.weight(.medium))
        }
        Text("Keep your eyes level").font(.caption).foregroundStyle(.secondary)
      }
      .foregroundStyle(.white)
    case .holdStill(let progress):
      VStack(spacing: 8) {
        Text("Hold still").font(.title3.weight(.medium))
        Text("Keep your head still").font(.caption).foregroundStyle(.secondary)
        progressBar(progress: progress)
      }
      .foregroundStyle(.white)
    case .ready:
      captionStack("Ready", "Follow the dot")
    }
  }

  private func captionStack(_ title: String, _ caption: String) -> some View {
    VStack(spacing: 8) {
      Text(title).font(.title3.weight(.medium))
      Text(caption).font(.caption).foregroundStyle(.secondary)
    }
    .foregroundStyle(.white)
  }

  /// The visor shows the user a mirror, so a horizontal correction points with
  /// the raw offset while a vertical one points against it.
  private func arrowSymbol(offsetX: Double, offsetY: Double) -> String {
    if abs(offsetX) >= abs(offsetY) {
      return offsetX >= 0 ? "arrow.right" : "arrow.left"
    }
    return offsetY >= 0 ? "arrow.up" : "arrow.down"
  }

  private func progressBar(progress: Double) -> some View {
    let clamped = min(max(progress, 0), 1)
    return ZStack(alignment: .leading) {
      Capsule().fill(.white.opacity(0.18))
      Capsule().fill(.white).frame(width: 200 * clamped)
    }
    .frame(width: 200, height: 3)
  }
}

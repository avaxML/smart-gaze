import AppKit
import CoreGraphics
import Foundation
import GazeKit
import SwiftUI
import Testing

@testable import SmartGaze

private let renderWidth = 1728
private let renderHeight = 1117

private enum SyntheticSetup {
  static func face(meshDepth: [Double] = []) -> CalibrationSetupFace {
    var mesh = (0..<468).map { index -> CGPoint in
      let angle = 2 * Double.pi * Double(index) / 468
      return CGPoint(x: 0.5 + 0.15 * cos(angle), y: 0.5 + 0.225 * sin(angle))
    }
    let landmarks: [Int: CGPoint] = [
      70: CGPoint(x: 0.28, y: 0.44),
      300: CGPoint(x: 0.72, y: 0.44),
      33: CGPoint(x: 0.36, y: 0.56),
      133: CGPoint(x: 0.44, y: 0.56),
      362: CGPoint(x: 0.56, y: 0.56),
      263: CGPoint(x: 0.64, y: 0.56),
    ]
    for (index, point) in landmarks { mesh[index] = point }

    func ellipse(center: CGPoint, radiusX: Double, radiusY: Double) -> [CGPoint] {
      (0..<71).map { index in
        let angle = 2 * Double.pi * Double(index) / 71
        return CGPoint(x: center.x + radiusX * cos(angle), y: center.y + radiusY * sin(angle))
      }
    }

    func iris(center: CGPoint, radius: Double) -> [CGPoint] {
      [
        center,
        CGPoint(x: center.x + radius, y: center.y),
        CGPoint(x: center.x, y: center.y + radius),
        CGPoint(x: center.x - radius, y: center.y),
        CGPoint(x: center.x, y: center.y - radius),
      ]
    }

    let rightEye = CGPoint(x: 0.40, y: 0.56)
    let leftEye = CGPoint(x: 0.60, y: 0.56)
    return CalibrationSetupFace(
      mesh: mesh,
      imageLeftEyeContour: ellipse(center: leftEye, radiusX: 0.055, radiusY: 0.03),
      imageRightEyeContour: ellipse(center: rightEye, radiusX: 0.055, radiusY: 0.03),
      imageLeftIris: iris(center: leftEye, radius: 0.014),
      imageRightIris: iris(center: rightEye, radius: 0.014),
      depthCentimetres: 60,
      meshDepth: meshDepth)
  }

  static func image() -> CGImage {
    let width = 1280
    let height = 720
    let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.52, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
    context.setFillColor(CGColor(red: 0.78, green: 0.76, blue: 0.72, alpha: 1))
    context.fillEllipse(
      in: CGRect(
        x: CGFloat(width) / 2 - 538, y: CGFloat(height) / 2 - 360, width: 1076, height: 720))
    return context.makeImage()!
  }
}

private func rgbaPixels(_ image: CGImage) -> [UInt8] {
  let width = image.width
  let height = image.height
  var data = [UInt8](repeating: 0, count: width * height * 4)
  data.withUnsafeMutableBytes { buffer in
    guard
      let context = CGContext(
        data: buffer.baseAddress,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
  }
  return data
}

private func isBlack(_ pixels: [UInt8], width: Int, x: Int, y: Int) -> Bool {
  let offset = (y * width + x) * 4
  return pixels[offset] == 0 && pixels[offset + 1] == 0 && pixels[offset + 2] == 0
}

private func luminance(_ pixels: [UInt8], width: Int, x: Int, y: Int) -> Int {
  let offset = (y * width + x) * 4
  return (Int(pixels[offset]) + Int(pixels[offset + 1]) + Int(pixels[offset + 2])) / 3
}

private func maxLuminance(
  _ pixels: [UInt8], width: Int, height: Int, centerX: Int, centerY: Int, radius: Int
) -> Int {
  let minX = max(0, centerX - radius)
  let maxX = min(width - 1, centerX + radius)
  let minY = max(0, centerY - radius)
  let maxY = min(height - 1, centerY + radius)
  guard minX <= maxX, minY <= maxY else { return 0 }
  var best = 0
  for y in minY...maxY {
    for x in minX...maxX {
      best = max(best, luminance(pixels, width: width, x: x, y: y))
    }
  }
  return best
}

private func writePNG(_ image: CGImage, named name: String, to directory: URL) throws {
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let representation = NSBitmapImageRep(cgImage: image)
  let data = try #require(representation.representation(using: .png, properties: [:]))
  try data.write(to: directory.appendingPathComponent("\(name).png"))
}

@MainActor
@Test func setupViewRendersTheVisorOverABlackBackground() throws {
  let face = SyntheticSetup.face()
  let image = SyntheticSetup.image()
  let frameSize = CGSize(width: 1280, height: 720)
  let renderDirectory = ProcessInfo.processInfo.environment["SMART_GAZE_SETUP_RENDER_DIR"]
    .map { URL(fileURLWithPath: $0) }

  let cases: [(String, CalibrationSetupFace?, CalibrationSetupGuidance)] = [
    ("findingFace", face, .findingFace),
    ("moveCloser", face, .moveCloser),
    ("moveBack", face, .moveBack),
    ("centerFace", face, .centerFace(offsetX: 0.2, offsetY: 0.05)),
    ("holdStill", face, .holdStill(progress: 0.5)),
    ("ready", face, .ready),
    ("noFace", nil, .findingFace),
  ]

  for (name, face, guidance) in cases {
    let renderer = ImageRenderer(
      content: CalibrationSetupView(
        face: face, image: image, guidance: guidance, frameSize: frameSize))
    renderer.scale = 1
    renderer.proposedSize = ProposedViewSize(
      width: CGFloat(renderWidth), height: CGFloat(renderHeight))

    let rendered = try #require(renderer.cgImage, "no render for \(name)")
    #expect(rendered.width == renderWidth)
    #expect(rendered.height == renderHeight)

    let pixels = rgbaPixels(rendered)
    #expect(
      !isBlack(pixels, width: renderWidth, x: renderWidth / 2, y: renderHeight / 2),
      "visor centre is black for \(name)")
    #expect(isBlack(pixels, width: renderWidth, x: 20, y: 20), "corner is not black for \(name)")

    if let renderDirectory {
      try writePNG(rendered, named: name, to: renderDirectory)
    }
  }
}

@MainActor
@Test func setupViewUsesTheGuidanceTitleTrackingConstant() {
  #expect(CalibrationSetupView.guidanceTitleTracking == -0.01)
}

@MainActor
@Test func setupViewShadesNearMeshPointsBrighterThanFarOnes() throws {
  var depths = [Double](repeating: 0, count: 468)
  depths[133] = -0.02
  let face = SyntheticSetup.face(meshDepth: depths)
  let band = try #require(face.eyeBand)
  let frameSize = CGSize(width: 1280, height: 720)

  let visorWidth = CGFloat(renderWidth) * CalibrationSetupView.visorWidthRatio
  let visorHeight = visorWidth / CalibrationSetupView.visorAspectRatio
  let visorSize = CGSize(width: visorWidth, height: visorHeight)
  let visorCenterY = CGFloat(renderHeight) * CalibrationSetupView.visorCenterYRatio

  let renderer = ImageRenderer(
    content: CalibrationSetupView(
      face: face, image: nil, guidance: .ready, frameSize: frameSize))
  renderer.scale = 1
  renderer.proposedSize = ProposedViewSize(
    width: CGFloat(renderWidth), height: CGFloat(renderHeight))
  let rendered = try #require(renderer.cgImage)
  let pixels = rgbaPixels(rendered)
  if let renderDirectory = ProcessInfo.processInfo.environment["SMART_GAZE_SETUP_RENDER_DIR"]
    .map({ URL(fileURLWithPath: $0) })
  {
    try writePNG(rendered, named: "depthShading", to: renderDirectory)
  }

  // Nose bridge is mesh 133 at (0.44, 0.56), the cheek is mesh 234 at
  // (0.35, 0.50); the near point (mesh 133) shades brighter. The mesh draws
  // mirrored, so the on-screen x is the visor's width minus the projected x.
  func renderPixel(_ meshIndex: Int) -> (x: Int, y: Int) {
    let local = CalibrationSetupView.project(
      face.mesh[meshIndex], band: band, frameSize: frameSize, visorSize: visorSize)
    return (
      x: Int((CGFloat(renderWidth) / 2 + visorSize.width / 2 - local.x).rounded()),
      y: Int((visorCenterY + (local.y - visorSize.height / 2)).rounded())
    )
  }

  let noseBridge = renderPixel(133)
  let cheek = renderPixel(234)
  let noseBrightness = maxLuminance(
    pixels, width: renderWidth, height: renderHeight, centerX: noseBridge.x,
    centerY: noseBridge.y, radius: 3)
  let cheekBrightness = maxLuminance(
    pixels, width: renderWidth, height: renderHeight, centerX: cheek.x, centerY: cheek.y,
    radius: 3)
  #expect(
    noseBrightness > cheekBrightness,
    "nose \(noseBrightness) at \(noseBridge) is not brighter than cheek \(cheekBrightness) at \(cheek)"
  )
}

@Test func setupViewProjectsTheBandWithAspectFill() {
  let projected = CalibrationSetupView.project(
    CGPoint(x: 0.5, y: 0.5),
    band: CGRect(x: 0.25, y: 0.25, width: 0.25, height: 0.25),
    frameSize: CGSize(width: 1280, height: 720),
    visorSize: CGSize(width: 400, height: 200))
  #expect(projected == CGPoint(x: 400, y: 212.5))
}

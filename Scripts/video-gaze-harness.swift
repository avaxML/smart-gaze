import AVFoundation
import CoreML
import CoreVideo
import Foundation
import GazeKit
import Perception

private func percentile(_ values: [Double], _ fraction: Double) -> Double {
  guard !values.isEmpty else { return 0 }
  let sorted = values.sorted()
  let index = Int((Double(sorted.count - 1) * fraction).rounded())
  return sorted[min(sorted.count - 1, max(0, index))]
}

private func standardDeviation(_ values: [Double]) -> Double {
  guard values.count > 1 else { return 0 }
  let mean = values.reduce(0, +) / Double(values.count)
  let sum = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +)
  return (sum / Double(values.count - 1)).squareRoot()
}

/// The pipeline takes ownership of each frame, and a buffer vended by an asset
/// reader stays owned by its sample, so every frame is copied before it is sent.
private func copiedBGRA(from source: CVPixelBuffer) -> CVPixelBuffer? {
  let width = CVPixelBufferGetWidth(source)
  let height = CVPixelBufferGetHeight(source)
  var created: CVPixelBuffer?
  guard
    CVPixelBufferCreate(
      nil, width, height, CVPixelBufferGetPixelFormatType(source), nil, &created)
      == kCVReturnSuccess, let destination = created
  else { return nil }

  CVPixelBufferLockBaseAddress(source, .readOnly)
  CVPixelBufferLockBaseAddress(destination, [])
  if let from = CVPixelBufferGetBaseAddress(source),
    let into = CVPixelBufferGetBaseAddress(destination)
  {
    let fromStride = CVPixelBufferGetBytesPerRow(source)
    let intoStride = CVPixelBufferGetBytesPerRow(destination)
    for row in 0..<height {
      memcpy(
        into.advanced(by: row * intoStride), from.advanced(by: row * fromStride),
        min(fromStride, intoStride))
    }
  }
  CVPixelBufferUnlockBaseAddress(destination, [])
  CVPixelBufferUnlockBaseAddress(source, .readOnly)
  return destination
}

@main
struct VideoGazeHarness {
  static func main() async throws {
    let arguments = CommandLine.arguments
    guard arguments.count >= 4 else {
      FileHandle.standardError.write(
        "usage: video-gaze-harness <video> <face-mesh.mlmodelc> <blazegaze.mlmodelc> [maxFrames] [iris.mlmodelc]\n"
          .data(using: .utf8)!)
      exit(2)
    }
    let videoURL = URL(fileURLWithPath: arguments[1])
    let maxFrames = arguments.count > 4 ? Int(arguments[4]) ?? 200 : 200
    let irisModelURL: URL? = {
      guard arguments.count > 5 else { return nil }
      let url = URL(fileURLWithPath: arguments[5])
      return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }()

    let pipeline = try GazePipeline(
      faceMeshModelURL: URL(fileURLWithPath: arguments[2]),
      blazeGazeModelURL: URL(fileURLWithPath: arguments[3]),
      irisModelURL: irisModelURL,
      computeUnits: .all)

    let asset = AVURLAsset(url: videoURL)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
      FileHandle.standardError.write("no video track\n".data(using: .utf8)!)
      exit(1)
    }
    let naturalSize = try await track.load(.naturalSize)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(output)
    reader.startReading()

    var frames = 0
    var produced = 0
    var noFace = 0
    var lowPresence = 0
    var otherErrors = 0
    var latencies: [Double] = []
    var xs: [Double] = []
    var ys: [Double] = []
    var times: [Double] = []
    var yaws: [Double] = []
    var trackedCropFrames = 0
    var cropRotations: [Double] = []
    var firstErrors: [String] = []
    var irisFrames = 0
    var leftIrisDiameters: [Double] = []
    var rightIrisDiameters: [Double] = []
    var irisDepths: [Double] = []
    var baselineDepthsOnIrisFrames: [Double] = []
    var impliedInterpupillaryCentimetres: [Double] = []

    while frames < maxFrames, let sample = output.copyNextSampleBuffer() {
      guard let borrowed = CMSampleBufferGetImageBuffer(sample),
        let frame = copiedBGRA(from: borrowed)
      else { continue }
      frames += 1
      let started = CFAbsoluteTimeGetCurrent()
      do {
        let estimate = try await pipeline.gazePoint(from: frame)
        latencies.append((CFAbsoluteTimeGetCurrent() - started) * 1000)
        xs.append(estimate.gaze.x)
        ys.append(estimate.gaze.y)
        yaws.append(abs(estimate.headYawRadians))
        times.append(Double(frames) / 25.0)
        if estimate.usedTrackedCrop { trackedCropFrames += 1 }
        cropRotations.append(abs(estimate.cropRotationRadians))
        if let iris = estimate.iris {
          irisFrames += 1
          leftIrisDiameters.append(iris.imageLeftEye.irisDiameterPixels)
          rightIrisDiameters.append(iris.imageRightEye.irisDiameterPixels)
          irisDepths.append(iris.depthCentimetres)
          baselineDepthsOnIrisFrames.append(estimate.faceDistanceCentimeters)
          if let implied = InterpupillaryFit.impliedCentimetres(
            irisDepthCentimetres: iris.depthCentimetres,
            baselineDepthCentimetres: estimate.faceDistanceCentimeters,
            assumedCentimetres: estimate.assumedInterpupillaryCentimetres)
          {
            impliedInterpupillaryCentimetres.append(implied)
          }
        }
        produced += 1
      } catch let error as GazePipelineError {
        switch error {
        case .noFaceDetected: noFace += 1
        case .facePresenceTooLow: lowPresence += 1
        default:
          otherErrors += 1
          if firstErrors.count < 3 { firstErrors.append("\(error)") }
        }
      } catch {
        otherErrors += 1
        if firstErrors.count < 3 { firstErrors.append("\(error)") }
      }
    }

    print(
      "video \(videoURL.lastPathComponent) \(Int(naturalSize.width))x\(Int(naturalSize.height))")
    print(
      "frames \(frames)  gaze \(produced)  noFace \(noFace)  lowPresence \(lowPresence)  errors \(otherErrors)"
    )
    print("tracked crop frames \(trackedCropFrames)")
    let meanRotationDegrees =
      cropRotations.isEmpty
      ? 0 : cropRotations.reduce(0, +) / Double(cropRotations.count) * 180 / .pi
    print("mean |crop rotation| deg \(String(format: "%.4f", meanRotationDegrees))")
    for message in firstErrors { print("  first error: \(message)") }
    if !latencies.isEmpty {
      print(
        "latency ms  median \(String(format: "%.1f", percentile(latencies, 0.5)))  p95 \(String(format: "%.1f", percentile(latencies, 0.95)))"
      )
    }
    guard xs.count > 1 else { return }
    print(
      "gaze x  mean \(String(format: "%.4f", xs.reduce(0, +) / Double(xs.count)))  sd \(String(format: "%.4f", standardDeviation(xs)))"
    )
    print(
      "gaze y  mean \(String(format: "%.4f", ys.reduce(0, +) / Double(ys.count)))  sd \(String(format: "%.4f", standardDeviation(ys)))"
    )
    var deltas: [Double] = []
    for index in 1..<xs.count {
      deltas.append(abs(xs[index] - xs[index - 1]) + abs(ys[index] - ys[index - 1]))
    }
    print(
      "frame delta  median \(String(format: "%.4f", percentile(deltas, 0.5)))  p95 \(String(format: "%.4f", percentile(deltas, 0.95)))"
    )
    let nonFinite = xs.filter { !$0.isFinite }.count + ys.filter { !$0.isFinite }.count
    print("non-finite \(nonFinite)")
    print(
      "head |yaw| rad  p50 \(percentile(yaws, 0.5))  p90 \(percentile(yaws, 0.9))  p95 \(percentile(yaws, 0.95))  max \(percentile(yaws, 1))  "
        + "frames above 0.40: \(yaws.filter { $0 > 0.40 }.count) of \(yaws.count)")

    print(
      "iris frames \(irisFrames) of \(produced)  median diameter px  left \(String(format: "%.2f", percentile(leftIrisDiameters, 0.5)))  right \(String(format: "%.2f", percentile(rightIrisDiameters, 0.5)))"
    )
    print(
      "median iris depth cm \(String(format: "%.1f", percentile(irisDepths, 0.5)))  median eye-baseline depth cm \(String(format: "%.1f", percentile(baselineDepthsOnIrisFrames, 0.5)))  (\(irisDepths.count) frames)"
    )
    let fittedInterpupillary = InterpupillaryFit.fit(
      impliedCentimetres: impliedInterpupillaryCentimetres)
    let fittedInterpupillaryText =
      fittedInterpupillary.map { String(format: "%.2f", $0) } ?? "nil"
    print(
      "implied IPD cm  median \(String(format: "%.2f", percentile(impliedInterpupillaryCentimetres, 0.5)))  p05 \(String(format: "%.2f", percentile(impliedInterpupillaryCentimetres, 0.05)))  p95 \(String(format: "%.2f", percentile(impliedInterpupillaryCentimetres, 0.95)))  fit \(fittedInterpupillaryText)  (\(impliedInterpupillaryCentimetres.count) frames)"
    )

    // Run the real filter and the real dispersion metric the trigger uses, so the
    // number reported here is comparable to the shipped threshold rather than a
    // differently defined spread.
    let screen = CGSize(
      width: Double(ProcessInfo.processInfo.environment["SMART_GAZE_SCREEN_W"] ?? "1728") ?? 1728,
      height: Double(ProcessInfo.processInfo.environment["SMART_GAZE_SCREEN_H"] ?? "1117") ?? 1117)
    var filter = OneEuroPointFilter()
    var points: [(CGPoint, Double)] = []
    for index in xs.indices {
      let raw = CGPoint(x: xs[index] * screen.width, y: ys[index] * screen.height)
      points.append((filter.apply(raw, at: times[index]), times[index]))
    }

    let window = 1.2
    var dispersions: [Double] = []
    for end in points.indices {
      let cutoff = points[end].1 - window
      let slice = points[...end].filter { $0.1 >= cutoff }
      guard slice.count > 1 else { continue }
      let sx = slice.map { $0.0.x }
      let sy = slice.map { $0.0.y }
      dispersions.append((sx.max()! - sx.min()!) + (sy.max()! - sy.min()!))
    }
    guard !dispersions.isEmpty else { return }
    print(
      """
      windowed dispersion pt (screen \(Int(screen.width))x\(Int(screen.height)), \(window)s window)
        min \(String(format: "%.1f", dispersions.min()!))  p05 \(String(format: "%.1f", percentile(dispersions, 0.05)))  p25 \(String(format: "%.1f", percentile(dispersions, 0.25)))  median \(String(format: "%.1f", percentile(dispersions, 0.5)))  p95 \(String(format: "%.1f", percentile(dispersions, 0.95)))
        windows under 160 pt: \(dispersions.filter { $0 < 160 }.count) of \(dispersions.count)
      """
    )
    if produced < frames || nonFinite > 0 {
      FileHandle.standardError.write(
        "harness failed: not every frame produced a finite gaze point\n".data(using: .utf8)!)
      exit(1)
    }
  }
}

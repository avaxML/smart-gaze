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
        "usage: video-gaze-harness <video> <face-mesh.mlmodelc> <blazegaze.mlmodelc> [maxFrames]\n"
          .data(using: .utf8)!)
      exit(2)
    }
    let videoURL = URL(fileURLWithPath: arguments[1])
    let maxFrames = arguments.count > 4 ? Int(arguments[4]) ?? 200 : 200

    let pipeline = try GazePipeline(
      faceMeshModelURL: URL(fileURLWithPath: arguments[2]),
      blazeGazeModelURL: URL(fileURLWithPath: arguments[3]),
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

    var frames = 0, produced = 0, noFace = 0, lowPresence = 0, otherErrors = 0
    var latencies: [Double] = [], xs: [Double] = [], ys: [Double] = []
    var firstErrors: [String] = []

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

    print("video \(videoURL.lastPathComponent) \(Int(naturalSize.width))x\(Int(naturalSize.height))")
    print(
      "frames \(frames)  gaze \(produced)  noFace \(noFace)  lowPresence \(lowPresence)  errors \(otherErrors)"
    )
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
    if produced < frames || nonFinite > 0 {
      FileHandle.standardError.write(
        "harness failed: not every frame produced a finite gaze point\n".data(using: .utf8)!)
      exit(1)
    }
  }
}

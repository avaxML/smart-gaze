import CoreVideo
import Foundation
import GazeKit
import Testing

@testable import Perception

private func requireModelURLs() throws -> (faceMesh: URL, blazeGaze: URL) {
  let environment = ProcessInfo.processInfo.environment
  guard faceMeshTestsEnabled(environment), modelTestsEnabled(environment) else {
    FileHandle.standardError.write(
      Data(
        "MODEL TEST SKIPPED: GazePipeline integration tests did not run. Set SMART_GAZE_FACE_MESH_TESTS=1, SMART_GAZE_MODEL_TESTS=1, SMART_GAZE_FACE_MESH_MODEL_PATH and SMART_GAZE_MODEL_PATH.\n"
          .utf8))
    try Test.cancel(
      "set SMART_GAZE_FACE_MESH_TESTS=1, SMART_GAZE_MODEL_TESTS=1 and both model path variables to run gaze pipeline integration tests"
    )
  }
  let faceMeshPath =
    environment["SMART_GAZE_FACE_MESH_MODEL_PATH"] ?? "Models/face-mesh/face_mesh.mlmodelc"
  let blazeGazePath = environment["SMART_GAZE_MODEL_PATH"] ?? "Models/blazegaze.mlmodelc"
  return (URL(fileURLWithPath: faceMeshPath), URL(fileURLWithPath: blazeGazePath))
}

private func blackBGRAPixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
  var pixelBuffer: CVPixelBuffer?
  let status = CVPixelBufferCreate(
    kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
  let buffer = try #require(status == kCVReturnSuccess ? pixelBuffer : nil)

  CVPixelBufferLockBaseAddress(buffer, [])
  defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
  let base = try #require(CVPixelBufferGetBaseAddress(buffer))
  memset(base, 0, CVPixelBufferGetBytesPerRow(buffer) * height)
  return buffer
}

@Test func irisDepthsUseTheCropScaleAndFrameWidth() throws {
  let contour = (0..<71).map { _ in SIMD3<Float>(1, 2, 10) }
  let iris = (0..<5).map { _ in SIMD3<Float>(1, 2, 10) }
  let transform = try #require(ProjectiveTransform(matrix: [1, 0, 0, 0, 1, 0, 0, 0, 1]))

  let estimate = try #require(
    makeEyeIrisEstimate(
      contour: contour, iris: iris, transform: transform, flip: false, cropPixelSize: 64,
      scale: 2.5, frameSize: CGSize(width: 1000, height: 1000)))

  #expect(estimate.contourDepth.count == 71)
  #expect(estimate.irisDepth.count == 5)
  #expect(estimate.contourDepth.allSatisfy { $0 == 0.025 })
  #expect(estimate.irisDepth.allSatisfy { $0 == 0.025 })
}

@Test func missingFaceMeshModelPathIsReported() {
  let url = URL(fileURLWithPath: "/nonexistent/face_mesh.mlmodelc")
  #expect(throws: FaceMeshError.modelMissing(url)) {
    try GazePipeline(
      faceMeshModelURL: url,
      blazeGazeModelURL: URL(fileURLWithPath: "/nonexistent/blazegaze.mlmodelc"))
  }
}

@Test func missingBlazeGazeModelPathIsReported() throws {
  let (faceMesh, _) = try requireModelURLs()
  let url = URL(fileURLWithPath: "/nonexistent/blazegaze.mlmodelc")
  #expect(throws: BlazeGazeError.modelMissing(url)) {
    try GazePipeline(faceMeshModelURL: faceMesh, blazeGazeModelURL: url)
  }
}

@Test func aFrameWithNoFaceReturnsNoSampleRatherThanAFabricatedOne() async throws {
  let (faceMesh, blazeGaze) = try requireModelURLs()
  let pipeline = try GazePipeline(
    faceMeshModelURL: faceMesh, blazeGazeModelURL: blazeGaze, computeUnits: .cpuOnly)
  let buffer = try blackBGRAPixelBuffer(width: 640, height: 480)

  do {
    _ = try await pipeline.gazePoint(from: buffer)
    Issue.record("expected GazePipelineError.noFaceDetected")
  } catch let error as GazePipelineError {
    #expect(error == .noFaceDetected)
  }
}

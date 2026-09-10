import CoreML
import Foundation
import GazeKit
import Perception

private let imageShape = [1, 128, 512, 3]
private let imageElementCount = 128 * 512 * 3
private let headVector = SIMD3<Float>(0, 0, -1)
private let faceOriginCentimeters = SIMD3<Float>(0, 0, 50)
private let warmupIterations = 5
private let measuredIterations = 50

private func report(_ message: String) {
  print(message)
}

private func measureProduction(
  _ units: MLComputeUnits,
  modelURL: URL,
  image: [Float]
) async throws -> [Double] {
  let estimator = try BlazeGazeEstimator(modelURL: modelURL, computeUnits: units)

  for _ in 0..<warmupIterations {
    _ = try await estimator.estimate(
      eyeBandRGB: image,
      headVector: headVector,
      faceOriginCentimeters: faceOriginCentimeters)
  }

  var samples = [Double]()
  samples.reserveCapacity(measuredIterations)
  for _ in 0..<measuredIterations {
    let start = DispatchTime.now().uptimeNanoseconds
    _ = try await estimator.estimate(
      eyeBandRGB: image,
      headVector: headVector,
      faceOriginCentimeters: faceOriginCentimeters)
    let end = DispatchTime.now().uptimeNanoseconds
    samples.append(Double(end - start) / 1_000_000.0)
  }
  return samples
}

private func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
  let index = min(sorted.count - 1, Int(Double(sorted.count) * fraction))
  return sorted[index]
}

private func describeLayout(_ model: MLModel) {
  for (name, description) in model.modelDescription.inputDescriptionsByName.sorted(by: {
    $0.key < $1.key
  }) {
    let shape = description.multiArrayConstraint?.shape.map(\.intValue) ?? []
    report("INPUT \(name) shape=\(shape)")
  }
  for (name, description) in model.modelDescription.outputDescriptionsByName.sorted(by: {
    $0.key < $1.key
  }) {
    let shape = description.multiArrayConstraint?.shape.map(\.intValue) ?? []
    report("OUTPUT \(name) shape=\(shape)")
  }
}

private func printDevicePlan(_ modelURL: URL) async throws {
  let configuration = MLModelConfiguration()
  configuration.computeUnits = .all
  let plan = try await MLComputePlan.load(contentsOf: modelURL, configuration: configuration)

  guard case .program(let program) = plan.modelStructure, let main = program.functions["main"]
  else {
    report("DEVICE_PLAN unavailable: model is not an ML Program with a main function")
    return
  }

  var preferred = ["cpu": 0, "gpu": 0, "ane": 0, "undetermined": 0]
  var supported = ["cpu": 0, "gpu": 0, "ane": 0]
  for operation in main.block.operations {
    guard let usage = plan.deviceUsage(for: operation) else {
      preferred["undetermined", default: 0] += 1
      continue
    }
    switch usage.preferred {
    case .cpu: preferred["cpu", default: 0] += 1
    case .gpu: preferred["gpu", default: 0] += 1
    case .neuralEngine: preferred["ane", default: 0] += 1
    @unknown default: preferred["unknown", default: 0] += 1
    }
    for device in usage.supported {
      switch device {
      case .cpu: supported["cpu", default: 0] += 1
      case .gpu: supported["gpu", default: 0] += 1
      case .neuralEngine: supported["ane", default: 0] += 1
      @unknown default: supported["unknown", default: 0] += 1
      }
    }
  }

  report(
    "DEVICE_PLAN_OPERATIONS \(main.block.operations.count) (planned assignments, not profiler-proven execution)"
  )
  report("DEVICE_PLAN_PREFERRED \(preferred.sorted { $0.key < $1.key })")
  report("DEVICE_PLAN_SUPPORTED \(supported.sorted { $0.key < $1.key })")
}

@main struct Benchmark {
  static func main() async throws {
    guard
      let path = CommandLine.arguments.dropFirst().first
        ?? ProcessInfo.processInfo.environment["SMART_GAZE_MODEL_PATH"]
    else {
      fatalError("usage: benchmark-blazegaze.sh [path-to-blazegaze.mlmodelc]")
    }
    let modelURL = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: modelURL.path) else {
      fatalError("model not found at \(path); run Scripts/fetch-blazegaze.sh first")
    }

    report(
      "BENCHMARK_SCOPE production BlazeGazeEstimator.estimate path: input validation, allocation, copy, provider build, and synchronous Core ML prediction, not live gaze accuracy or camera/Vision cost"
    )
    report("BENCHMARK_BUDGET the 33 ms full-pipeline target is not measured here")
    describeLayout(try MLModel(contentsOf: modelURL, configuration: MLModelConfiguration()))

    let image = [Float](repeating: 0.5, count: imageElementCount)

    for (label, units) in [("all", MLComputeUnits.all), ("cpuOnly", MLComputeUnits.cpuOnly)] {
      let samples = try await measureProduction(units, modelURL: modelURL, image: image).sorted()
      let median = percentile(samples, 0.5)
      let p95 = percentile(samples, 0.95)
      report(
        "TIMING \(label) warmup=\(warmupIterations) measured=\(measuredIterations) median_ms=\(median) p95_ms=\(p95)"
      )
    }

    try await printDevicePlan(modelURL)
  }
}

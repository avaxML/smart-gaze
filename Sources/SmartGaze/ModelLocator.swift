import Foundation

/// Resolves the Core ML model files `GazePipeline` needs.
///
/// Model artifacts are fetched by `Scripts/fetch-models.sh` into a gitignored
/// `Models/` directory and are never committed, so there is no bundled
/// default to fall back to yet; packaging them into the app bundle is
/// unresolved and tracked separately. The same environment variables the
/// integration tests use let a developer point at a local checkout.
enum ModelLocator {
  static func faceMeshModelURL() -> URL {
    resolve(
      environmentKey: "SMART_GAZE_FACE_MESH_MODEL_PATH",
      bundleRelativePath: "Models/face-mesh/face_mesh.mlmodelc")
  }

  static func blazeGazeModelURL() -> URL {
    resolve(
      environmentKey: "SMART_GAZE_MODEL_PATH",
      bundleRelativePath: "Models/blazegaze.mlmodelc")
  }

  static func irisModelURL() -> URL {
    resolve(
      environmentKey: "SMART_GAZE_IRIS_MODEL_PATH",
      bundleRelativePath: "Models/iris/iris_landmark_64x64_float32.mlmodelc")
  }

  /// The iris model is optional: its absence turns iris landmarks off for every
  /// frame rather than preventing the gaze pipeline from loading.
  static func irisModelURLIfPresent() -> URL? {
    let url = irisModelURL()
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }

  /// An explicit environment override wins, so a test or a developer can point
  /// at any artifact. Otherwise the copy inside the bundle, which is what makes
  /// a Finder launch work. The bare relative path is the last resort for
  /// `swift run` from the repository root, where there is no bundle.
  private static func resolve(environmentKey: String, bundleRelativePath: String) -> URL {
    if let override = ProcessInfo.processInfo.environment[environmentKey] {
      return URL(fileURLWithPath: override)
    }
    if let resources = Bundle.main.resourceURL {
      let bundled = resources.appendingPathComponent(bundleRelativePath)
      if FileManager.default.fileExists(atPath: bundled.path) {
        return bundled
      }
    }
    return URL(fileURLWithPath: bundleRelativePath)
  }
}

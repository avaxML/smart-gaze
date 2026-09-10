import Foundation

/// Resolves the two Core ML model files `GazePipeline` needs.
///
/// Model artifacts are fetched by `Scripts/fetch-models.sh` into a gitignored
/// `Models/` directory and are never committed, so there is no bundled
/// default to fall back to yet; packaging them into the app bundle is
/// unresolved and tracked separately. The same environment variables the
/// integration tests use let a developer point at a local checkout.
enum ModelLocator {
  static func faceMeshModelURL() -> URL {
    let path =
      ProcessInfo.processInfo.environment["SMART_GAZE_FACE_MESH_MODEL_PATH"]
      ?? "Models/face-mesh/face_mesh.mlmodelc"
    return URL(fileURLWithPath: path)
  }

  static func blazeGazeModelURL() -> URL {
    let path =
      ProcessInfo.processInfo.environment["SMART_GAZE_MODEL_PATH"] ?? "Models/blazegaze.mlmodelc"
    return URL(fileURLWithPath: path)
  }
}

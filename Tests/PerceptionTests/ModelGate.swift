internal func modelTestsEnabled(_ environment: [String: String]) -> Bool {
  environment["SMART_GAZE_MODEL_TESTS"] == "1"
}

internal func faceMeshTestsEnabled(_ environment: [String: String]) -> Bool {
  environment["SMART_GAZE_FACE_MESH_TESTS"] == "1"
}

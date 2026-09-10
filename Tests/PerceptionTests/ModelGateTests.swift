import Testing

@Suite struct ModelGateTests {
  @Test func modelGateIsDisabledWhenVariableIsAbsent() {
    #expect(modelTestsEnabled([:]) == false)
  }

  @Test func modelGateIsDisabledWhenVariableIsZero() {
    #expect(modelTestsEnabled(["SMART_GAZE_MODEL_TESTS": "0"]) == false)
  }

  @Test func modelGateIsDisabledWhenVariableIsTrueText() {
    #expect(modelTestsEnabled(["SMART_GAZE_MODEL_TESTS": "true"]) == false)
  }

  @Test func modelGateIsEnabledOnlyByOne() {
    #expect(modelTestsEnabled(["SMART_GAZE_MODEL_TESTS": "1"]) == true)
  }

  @Test func faceMeshGateIsDisabledWhenVariableIsAbsent() {
    #expect(faceMeshTestsEnabled([:]) == false)
  }

  @Test func faceMeshGateIsDisabledWhenVariableIsZero() {
    #expect(faceMeshTestsEnabled(["SMART_GAZE_FACE_MESH_TESTS": "0"]) == false)
  }

  @Test func faceMeshGateIsDisabledWhenVariableIsTrueText() {
    #expect(faceMeshTestsEnabled(["SMART_GAZE_FACE_MESH_TESTS": "true"]) == false)
  }

  @Test func faceMeshGateIsEnabledOnlyByOne() {
    #expect(faceMeshTestsEnabled(["SMART_GAZE_FACE_MESH_TESTS": "1"]) == true)
  }
}

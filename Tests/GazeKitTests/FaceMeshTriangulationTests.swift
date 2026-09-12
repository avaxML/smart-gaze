import Testing

@testable import GazeKit

@Test func triangulationHasThePinnedTriangleCount() {
  #expect(FaceMeshTriangulation.triangleCount == 898)
  #expect(FaceMeshTriangulation.triangles.count == 898)
}

@Test func everyTriangleVertexIsInRangeAndDistinct() {
  let triangles = FaceMeshTriangulation.triangles
  let outOfRange = triangles.filter {
    Swift.min($0.x, $0.y, $0.z) < 0 || Swift.max($0.x, $0.y, $0.z) >= 468
  }
  #expect(outOfRange.isEmpty)

  let degenerate = triangles.filter { $0.x == $0.y || $0.y == $0.z || $0.x == $0.z }
  #expect(degenerate.isEmpty)
}

@Test func deduplicatedEdgeCountMatchesTheMeshTopology() {
  var edges: Set<[Int]> = []
  for triangle in FaceMeshTriangulation.triangles {
    let indices = [Int(triangle.x), Int(triangle.y), Int(triangle.z)]
    for (first, second) in [(0, 1), (1, 2), (2, 0)] {
      let a = Swift.min(indices[first], indices[second])
      let b = Swift.max(indices[first], indices[second])
      edges.insert([a, b])
    }
  }
  #expect(edges.count == 1365)
}

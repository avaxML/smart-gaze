import Foundation
import Testing

private struct Edge: Hashable, Comparable, CustomStringConvertible {
  let from: String
  let to: String

  var description: String { "\(from) -> \(to)" }

  static func < (lhs: Edge, rhs: Edge) -> Bool {
    (lhs.from, lhs.to) < (rhs.from, rhs.to)
  }
}

private enum TargetDependency: Decodable {
  case target(String)
  case product(String)

  private enum CodingKeys: String, CodingKey {
    case byName
    case target
    case product
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let name = try Self.firstName(in: container, forKey: .byName) {
      self = .target(name)
    } else if let name = try Self.firstName(in: container, forKey: .target) {
      self = .target(name)
    } else if let name = try Self.firstName(in: container, forKey: .product) {
      self = .product(name)
    } else {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(
          codingPath: container.codingPath,
          debugDescription: "target dependency had no byName, target or product entry"
        )
      )
    }
  }

  private static func firstName(
    in container: KeyedDecodingContainer<CodingKeys>,
    forKey key: CodingKeys
  ) throws -> String? {
    guard container.contains(key) else { return nil }
    var nested = try container.nestedUnkeyedContainer(forKey: key)
    return try nested.decode(String.self)
  }

  var targetName: String? {
    switch self {
    case .target(let name): name
    case .product: nil
    }
  }
}

private struct DumpedTarget: Decodable {
  let name: String
  let dependencies: [TargetDependency]
}

private struct DumpedPackage: Decodable {
  let targets: [DumpedTarget]
}

private enum RepoLayout {
  static func root(from filePath: String) -> URL? {
    var directory = URL(fileURLWithPath: filePath).deletingLastPathComponent()
    while directory.path != "/" {
      if FileManager.default.fileExists(atPath: directory.appending(path: "Package.swift").path) {
        return directory
      }
      directory = directory.deletingLastPathComponent()
    }
    return nil
  }
}

private struct CommandResult {
  let standardOutput: Data
  let standardError: String
  let exitCode: Int32
}

private func runSwiftPackageDump(packagePath: URL, scratchPath: URL) throws -> CommandResult {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments = [
    "swift", "package",
    "--package-path", packagePath.path,
    "--scratch-path", scratchPath.path,
    "dump-package",
  ]
  var environment = ProcessInfo.processInfo.environment
  for key in environment.keys where key.hasPrefix("SWIFTPM_") || key.hasPrefix("LLBUILD_") {
    environment.removeValue(forKey: key)
  }
  process.environment = environment

  let outputPipe = Pipe()
  let errorPipe = Pipe()
  process.standardOutput = outputPipe
  process.standardError = errorPipe
  try process.run()

  let output = try outputPipe.fileHandleForReading.readToEnd() ?? Data()
  let errorData = try errorPipe.fileHandleForReading.readToEnd() ?? Data()
  process.waitUntilExit()

  return CommandResult(
    standardOutput: output,
    standardError: String(decoding: errorData, as: UTF8.self),
    exitCode: process.terminationStatus
  )
}

@Test func dependencyGraphMatchesTheArchitecture() throws {
  let root = try #require(
    RepoLayout.root(from: #filePath),
    "no directory containing Package.swift above \(#filePath)"
  )

  let scratch = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: scratch) }

  let result = try runSwiftPackageDump(packagePath: root, scratchPath: scratch)
  try #require(
    result.exitCode == 0,
    "swift package dump-package exited \(result.exitCode): \(result.standardError)"
  )
  try #require(
    !result.standardOutput.isEmpty,
    "swift package dump-package produced no output: \(result.standardError)"
  )

  let dumped = try JSONDecoder().decode(DumpedPackage.self, from: result.standardOutput)

  let actualNames = Set(dumped.targets.map(\.name))
  let expectedNames: Set<String> = [
    "GazeKit", "Perception", "ScreenCapture", "Providers", "OverlayUI", "SmartGaze", "GazeKitTests",
    "PerceptionTests", "ScreenCaptureTests", "ProvidersTests", "OverlayUITests", "SmartGazeTests",
  ]
  #expect(
    actualNames == expectedNames,
    """
    unexpected targets: \(actualNames.subtracting(expectedNames).sorted().joined(separator: ", "))
    missing targets: \(expectedNames.subtracting(actualNames).sorted().joined(separator: ", "))
    """
  )

  let actualEdges = Set(
    dumped.targets.flatMap { target in
      target.dependencies.compactMap(\.targetName).map { Edge(from: target.name, to: $0) }
    }
  )
  let expectedEdges: Set<Edge> = [
    Edge(from: "Perception", to: "GazeKit"),
    Edge(from: "ScreenCapture", to: "GazeKit"),
    Edge(from: "Providers", to: "GazeKit"),
    Edge(from: "OverlayUI", to: "GazeKit"),
    Edge(from: "SmartGaze", to: "GazeKit"),
    Edge(from: "SmartGaze", to: "Perception"),
    Edge(from: "SmartGaze", to: "ScreenCapture"),
    Edge(from: "SmartGaze", to: "Providers"),
    Edge(from: "SmartGaze", to: "OverlayUI"),
    Edge(from: "GazeKitTests", to: "GazeKit"),
    Edge(from: "PerceptionTests", to: "Perception"),
    Edge(from: "ScreenCaptureTests", to: "ScreenCapture"),
    Edge(from: "ProvidersTests", to: "Providers"),
    Edge(from: "OverlayUITests", to: "OverlayUI"),
    Edge(from: "SmartGazeTests", to: "SmartGaze"),
    Edge(from: "SmartGazeTests", to: "GazeKit"),
    Edge(from: "SmartGazeTests", to: "Perception"),
    Edge(from: "SmartGazeTests", to: "Providers"),
  ]

  let unexpected = actualEdges.subtracting(expectedEdges).sorted()
  let missing = expectedEdges.subtracting(actualEdges).sorted()
  #expect(
    actualEdges == expectedEdges,
    """
    unexpected edges: \(unexpected.map(\.description).joined(separator: ", "))
    missing edges: \(missing.map(\.description).joined(separator: ", "))
    """
  )
}

private let importKindKeywords: Set<String> = [
  "typealias", "struct", "class", "enum", "protocol", "let", "var", "func",
]

private func importedModules(inSwiftSource source: String) -> Set<String> {
  var modules: Set<String> = []
  for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("import ") || trimmed.hasPrefix("@") else { continue }
    let tokens = trimmed.split(separator: " ").map(String.init)
    guard let importIndex = tokens.firstIndex(of: "import") else { continue }
    var nameIndex = importIndex + 1
    guard nameIndex < tokens.count else { continue }
    if importKindKeywords.contains(tokens[nameIndex]) {
      nameIndex += 1
      guard nameIndex < tokens.count else { continue }
    }
    guard let module = tokens[nameIndex].split(separator: ".").first else { continue }
    modules.insert(String(module))
  }
  return modules
}

@Test func gazeKitImportsOnlyPermittedModules() throws {
  let root = try #require(
    RepoLayout.root(from: #filePath),
    "no directory containing Package.swift above \(#filePath)"
  )
  let sources = root.appending(path: "Sources/GazeKit")

  let enumerator = try #require(
    FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil),
    "could not enumerate \(sources.path)"
  )

  var scannedFiles: [String] = []
  var imported: Set<String> = []
  for case let url as URL in enumerator where url.pathExtension == "swift" {
    let source = try String(contentsOf: url, encoding: .utf8)
    scannedFiles.append(url.lastPathComponent)
    imported.formUnion(importedModules(inSwiftSource: source))
  }

  try #require(
    !scannedFiles.isEmpty,
    "found no .swift files under \(sources.path)"
  )

  let permitted: Set<String> = ["Foundation", "CoreGraphics", "Accelerate"]
  let forbidden = imported.subtracting(permitted).sorted()
  #expect(
    forbidden.isEmpty,
    """
    GazeKit imports modules outside the permitted set: \(forbidden.joined(separator: ", "))
    scanned files: \(scannedFiles.sorted().joined(separator: ", "))
    """
  )
}

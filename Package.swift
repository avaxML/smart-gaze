// swift-tools-version: 6.1

import PackageDescription

let strictConcurrency: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
  name: "smart-gaze",
  platforms: [.macOS("26.0")],
  products: [
    .executable(name: "SmartGaze", targets: ["SmartGaze"])
  ],
  targets: [
    .target(name: "GazeKit", swiftSettings: strictConcurrency),
    .target(
      name: "Perception",
      dependencies: ["GazeKit"],
      swiftSettings: strictConcurrency
    ),
    .target(
      name: "ScreenCapture",
      dependencies: ["GazeKit"],
      swiftSettings: strictConcurrency
    ),
    .target(
      name: "Providers",
      dependencies: ["GazeKit"],
      swiftSettings: strictConcurrency
    ),
    .target(
      name: "OverlayUI",
      dependencies: ["GazeKit"],
      swiftSettings: strictConcurrency
    ),
    .executableTarget(
      name: "SmartGaze",
      dependencies: ["GazeKit", "Perception", "ScreenCapture", "Providers", "OverlayUI"],
      swiftSettings: strictConcurrency
    ),
    .testTarget(
      name: "GazeKitTests",
      dependencies: ["GazeKit"],
      swiftSettings: strictConcurrency
    ),
  ]
)

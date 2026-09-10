import GazeKit
import OverlayUI
import Perception
import Providers
import ScreenCapture

@main
struct SmartGazeApp {
  static func main() {
    let modules = [
      GazeKit.moduleName,
      Perception.moduleName,
      ScreenCapture.moduleName,
      Providers.moduleName,
      OverlayUI.moduleName,
    ]
    print("smart-gaze linked modules: \(modules.joined(separator: ", "))")
  }
}

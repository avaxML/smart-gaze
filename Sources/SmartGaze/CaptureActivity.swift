import Foundation

@MainActor
final class CaptureActivity {
  private(set) var captureCount = 0
  private(set) var isBusy = false
  var onChange: (() -> Void)?

  func captureDidBegin() {
    guard !isBusy else { return }
    isBusy = true
    onChange?()
  }

  func captureDidEnd() {
    guard isBusy else { return }
    isBusy = false
    onChange?()
  }

  func captureDidSucceed() {
    captureCount += 1
    isBusy = false
    onChange?()
  }
}

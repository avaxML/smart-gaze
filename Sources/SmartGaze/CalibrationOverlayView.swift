import GazeKit
import SwiftUI

/// The full-screen content for one display during a calibration run. The
/// window controller places one of these per active `NSScreen`; only the
/// screen holding the current target shows a reticle, the rest show the
/// status text so a multi-display setup reads as one connected run.
struct CalibrationOverlayView: View {
  var coordinator: CalibrationCoordinator
  var localTargetPoint: (CGPoint) -> CGPoint?

  var body: some View {
    ZStack {
      Color.black.opacity(0.001).ignoresSafeArea()

      if let target = currentTarget, let local = localTargetPoint(target) {
        reticle.position(local)
      }

      VStack {
        Spacer()
        statusLabel
          .padding(.bottom, 48)
      }
    }
  }

  private var currentTarget: CGPoint? {
    switch coordinator.phase {
    case .settling(let target), .collecting(let target), .retrying(let target):
      return target
    default:
      return nil
    }
  }

  @ViewBuilder
  private var reticle: some View {
    switch coordinator.phase {
    case .collecting:
      Circle().fill(.white).frame(width: 18, height: 18)
        .overlay(Circle().strokeBorder(.blue, lineWidth: 3))
    default:
      Circle().stroke(.white, style: StrokeStyle(lineWidth: 2, dash: [4, 4])).frame(width: 30)
        .overlay(Circle().fill(.white).frame(width: 8, height: 8))
    }
  }

  @ViewBuilder
  private var statusLabel: some View {
    switch coordinator.phase {
    case .preparing:
      Text("Preparing calibration…").foregroundStyle(.white)
    case .unavailable(let message):
      Text(message).foregroundStyle(.white)
    case .settling:
      Text("Look at the dot. Press Escape to cancel.").foregroundStyle(.white)
    case .collecting:
      Text("Hold your gaze…").foregroundStyle(.white)
    case .retrying:
      Text("That reading was too scattered. Trying that point again.")
        .foregroundStyle(.yellow)
    case .completed, .failed, .aborted:
      EmptyView()
    }
  }
}

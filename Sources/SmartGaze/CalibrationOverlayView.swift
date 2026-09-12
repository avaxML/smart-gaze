import GazeKit
import SwiftUI

/// The full-screen content for one display during a calibration run.
///
/// Everything here obeys one rule: while a target is live, nothing else on
/// screen may compete for the eye. The sample being collected is wherever the
/// user is looking, so text at the bottom of the screen does not merely
/// distract, it corrupts the measurement. Instructions appear once, before the
/// first target, and every later cue is drawn around the dot itself.
struct CalibrationOverlayView: View {
  var coordinator: CalibrationCoordinator
  var localTargetPoint: (CGPoint) -> CGPoint?
  var showsSetup: Bool

  var body: some View {
    ZStack {
      Color.black.opacity(0.94).ignoresSafeArea()

      if let target = currentTarget, let local = localTargetPoint(target) {
        CalibrationTargetView(
          phase: targetPhase,
          settleDuration: coordinator.settleDuration,
          burstDuration: coordinator.burstDuration
        )
        .position(local)
      }

      introduction

      if showsSetup, case .setup(let guidance) = coordinator.phase {
        CalibrationSetupView(
          face: coordinator.setupFace,
          image: coordinator.setupImage,
          guidance: guidance,
          frameSize: coordinator.frameSize
        )
        .transition(.opacity)
      }
    }
  }

  private var currentTarget: CGPoint? {
    switch coordinator.phase {
    case .settling(let target), .collecting(let target), .retrying(let target),
      .sweeping(let target, _):
      return target
    default:
      return nil
    }
  }

  private var targetPhase: CalibrationTargetView.Phase {
    switch coordinator.phase {
    case .collecting: .collecting
    case .retrying: .retrying
    case .sweeping:
      .sweeping(yaw: coordinator.sweepYawCoverage, pitch: coordinator.sweepPitchCoverage)
    default: .settling
    }
  }

  /// The only text in the run, shown before the first target and never beside
  /// a live one.
  @ViewBuilder
  private var introduction: some View {
    switch coordinator.phase {
    case .preparing:
      VStack(spacing: 12) {
        Text("Look at each dot until the ring closes.")
          .font(.title2.weight(.medium))
        Text("Keep your head still. Press Escape to cancel.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      .foregroundStyle(.white)
      .transition(.opacity)
    case .unavailable(let message), .failed(let message):
      Text(message)
        .font(.callout)
        .foregroundStyle(.white)
    default:
      EmptyView()
    }
  }
}

/// One calibration target: a dot with a ring that fills over the burst window.
///
/// Settling breathes so the eye finds and holds it. Collecting fills the ring
/// clockwise over exactly the coordinator's burst duration, so a closed ring
/// means the burst is done. A retry flashes the ring amber and resets it, in
/// place, because the eye must stay on the dot for the retry to work.
struct CalibrationTargetView: View {
  enum Phase: Equatable {
    case settling, collecting, retrying
    case sweeping(yaw: Double, pitch: Double)
  }

  var phase: Phase
  var settleDuration: Duration
  var burstDuration: Duration

  @State private var fill: CGFloat = 0
  @State private var breathe = false
  @State private var retryFlash = false

  private let ringDiameter: CGFloat = 64
  private let dotDiameter: CGFloat = 14

  var body: some View {
    ZStack {
      ring

      Circle()
        .fill(.white)
        .frame(width: dotDiameter, height: dotDiameter)
        .scaleEffect(breathe ? 1.25 : 1.0)
    }
    .onAppear { apply(phase, animated: false) }
    .onChange(of: phase) { _, next in apply(next, animated: true) }
  }

  /// The still ring on a held target, or the four arcs that fill with the
  /// sweep's yaw and pitch coverage. Left and right fill with yaw, top and
  /// bottom with pitch, so the user sees which way still needs a turn without
  /// any text.
  @ViewBuilder
  private var ring: some View {
    switch phase {
    case .sweeping(let yaw, let pitch):
      ZStack {
        arc(fill: yaw, startingAtDegrees: -45)
        arc(fill: yaw, startingAtDegrees: 135)
        arc(fill: pitch, startingAtDegrees: 45)
        arc(fill: pitch, startingAtDegrees: 225)
      }
      .frame(width: ringDiameter, height: ringDiameter)
    case .settling, .collecting, .retrying:
      ZStack {
        Circle()
          .stroke(.white.opacity(0.18), lineWidth: 4)

        Circle()
          .trim(from: 0, to: fill)
          .stroke(
            retryFlash ? Color.orange : Color.white,
            style: StrokeStyle(lineWidth: 4, lineCap: .round)
          )
          .rotationEffect(.degrees(-90))
      }
      .frame(width: ringDiameter, height: ringDiameter)
    }
  }

  private func arc(fill: Double, startingAtDegrees degrees: Double) -> some View {
    Circle()
      .trim(from: 0, to: 0.25 * min(1, max(0, fill)))
      .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
      .rotationEffect(.degrees(degrees))
      .frame(width: ringDiameter, height: ringDiameter)
  }

  private func apply(_ next: Phase, animated: Bool) {
    switch next {
    case .settling:
      retryFlash = false
      withAnimation(animated ? .easeOut(duration: 0.2) : nil) { fill = 0 }
      withAnimation(
        .easeInOut(duration: seconds(settleDuration) / 2).repeatForever(autoreverses: true)
      ) {
        breathe = true
      }
    case .collecting:
      breathe = false
      retryFlash = false
      fill = 0
      withAnimation(.linear(duration: seconds(burstDuration))) { fill = 1 }
    case .retrying:
      breathe = false
      withAnimation(.easeOut(duration: 0.15)) { retryFlash = true }
      withAnimation(.easeOut(duration: 0.25).delay(0.15)) { fill = 0 }
      withAnimation(.easeOut(duration: 0.2).delay(0.4)) { retryFlash = false }
    case .sweeping:
      retryFlash = false
      withAnimation(animated ? .easeOut(duration: 0.2) : nil) { fill = 0 }
      if !breathe {
        withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
          breathe = true
        }
      }
    }
  }

  private func seconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
  }
}

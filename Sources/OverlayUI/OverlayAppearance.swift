import AppKit
import SwiftUI

public struct OverlayAppearance {
  public var colorScheme: ColorScheme?
  public var reduceTransparency: Bool
  public var increaseContrast: Bool
  public var reduceMotion: Bool

  public init(
    colorScheme: ColorScheme? = nil,
    reduceTransparency: Bool = false,
    increaseContrast: Bool = false,
    reduceMotion: Bool = false
  ) {
    self.colorScheme = colorScheme
    self.reduceTransparency = reduceTransparency
    self.increaseContrast = increaseContrast
    self.reduceMotion = reduceMotion
  }

  var panelAppearance: NSAppearance? {
    switch colorScheme {
    case .dark?: return NSAppearance(named: .darkAqua)
    case .light?: return NSAppearance(named: .aqua)
    default: return nil
    }
  }
}

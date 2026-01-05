import AppKit
import SwiftUI

/// Helper for handling provider icon theme adaptation (dark/light mode)
/// Now delegates to ProviderIconResource for unified icon management
enum ProviderIconThemeHelper {
  /// Icon names that require color inversion in dark mode
  /// @deprecated: Use ProviderIconResource.darkModeInvertIcons instead
  static var darkModeInvertIcons: Set<String> {
    ProviderIconResource.darkModeInvertIcons
  }

  /// Check if an icon name requires inversion in dark mode
  /// @deprecated: Use ProviderIconResource.requiresDarkModeInversion instead
  static func shouldInvertInDarkMode(_ iconName: String) -> Bool {
    ProviderIconResource.requiresDarkModeInversion(iconName)
  }

  /// Check if current appearance is dark mode (for AppKit contexts)
  static func isDarkMode() -> Bool {
    if let appearance = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) {
      return appearance == .darkAqua
    }
    return false
  }

  /// Process an NSImage for menu display, applying dark mode inversion if needed
  /// Now uses ProviderIconResource for unified processing
  static func menuImage(named iconName: String, size: NSSize = NSSize(width: 14, height: 14)) -> NSImage? {
    ProviderIconResource.processedImage(
      named: iconName,
      size: size,
      isDarkMode: isDarkMode()
    )
  }
}

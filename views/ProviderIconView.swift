import AppKit
import SwiftUI

struct ProviderIconView: View {
  let provider: UsageProviderKind
  var size: CGFloat = 12
  var cornerRadius: CGFloat = 2
  var saturation: Double = 1.0
  var opacity: Double = 1.0

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Group {
      if let name = iconName(for: provider),
         let image = ProviderIconResource.processedImage(
           named: name,
           size: NSSize(width: size, height: size),
           isDarkMode: colorScheme == .dark
         ) {
        Image(nsImage: image)
          .resizable()
          .interpolation(.high)
          .aspectRatio(contentMode: .fit)
          .frame(width: size, height: size)
          .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
          .saturation(saturation)
          .opacity(opacity)
      } else {
        Circle()
          .fill(accent(for: provider))
          .frame(width: dotSize, height: dotSize)
          .saturation(saturation)
          .opacity(opacity)
      }
    }
    .frame(width: size, height: size, alignment: .center)
    .id(colorScheme)
  }

  private var dotSize: CGFloat {
    max(6, size * 0.75)
  }

  private func iconName(for provider: UsageProviderKind) -> String? {
    switch provider {
    case .codex: return "ChatGPTIcon"
    case .claude: return "ClaudeIcon"
    case .gemini: return "GeminiIcon"
    }
  }

  private func accent(for provider: UsageProviderKind) -> Color {
    switch provider {
    case .codex: return Color.accentColor
    case .claude: return Color(nsColor: .systemPurple)
    case .gemini: return Color(nsColor: .systemTeal)
    }
  }
}

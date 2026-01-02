import SwiftUI
import AppKit

struct APIKeyProviderIconView: View {
  let provider: ProvidersRegistryService.Provider
  var size: CGFloat = 16
  var cornerRadius: CGFloat = 4
  var isSelected: Bool = false

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Group {
      if let image = nsImage(for: provider) {
        Image(nsImage: image)
          .resizable()
          .interpolation(.high)
          .aspectRatio(contentMode: .fit)
          .frame(width: size, height: size)
          .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
          .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
              .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
          )
      } else {
        Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
          .foregroundStyle(Color.accentColor)
          .frame(width: size, height: size)
      }
    }
    .frame(width: size, height: size, alignment: .center)
  }

  private func nsImage(for provider: ProvidersRegistryService.Provider) -> NSImage? {
    // Match by provider ID first
    let iconName = iconNameForProvider(provider)
    guard let name = iconName else { return nil }
    return NSImage(named: name)
  }

  private func iconNameForProvider(_ provider: ProvidersRegistryService.Provider) -> String? {
    let id = provider.id.lowercased()
    let name = (provider.name ?? "").lowercased()
    
    // Match by ID
    switch id {
    case "deepseek", "deep-seek":
      return "DeepSeekIcon"
    case "minimax", "mini-max":
      return "MiniMaxIcon"
    case "openrouter", "open-router":
      return "OpenRouterIcon"
    case "zai", "z.ai", "glm":
      return "ZaiIcon"
    case "k2", "kimi":
      return "KimiIcon"
    case "openai":
      return "ChatGPTIcon"
    case "anthropic":
      return "ClaudeIcon"
    default:
      break
    }
    
    // Match by name
    switch name {
    case let n where n.contains("deepseek") || n.contains("deep-seek"):
      return "DeepSeekIcon"
    case let n where n.contains("minimax") || n.contains("mini-max"):
      return "MiniMaxIcon"
    case let n where n.contains("openrouter") || n.contains("open-router"):
      return "OpenRouterIcon"
    case let n where n.contains("zai") || n.contains("z.ai") || n.contains("glm"):
      return "ZaiIcon"
    case let n where n.contains("kimi") || n.contains("k2"):
      return "KimiIcon"
    case let n where n.contains("openai"):
      return "ChatGPTIcon"
    case let n where n.contains("anthropic") || n.contains("claude"):
      return "ClaudeIcon"
    default:
      break
    }
    
    // Match by baseURL
    let codexBaseURL = provider.connectors[ProvidersRegistryService.Consumer.codex.rawValue]?.baseURL?.lowercased() ?? ""
    let claudeBaseURL = provider.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue]?.baseURL?.lowercased() ?? ""
    let baseURL = codexBaseURL.isEmpty ? claudeBaseURL : codexBaseURL
    
    if baseURL.contains("deepseek.com") {
      return "DeepSeekIcon"
    } else if baseURL.contains("minimaxi.com") || baseURL.contains("minimax.com") {
      return "MiniMaxIcon"
    } else if baseURL.contains("openrouter.ai") {
      return "OpenRouterIcon"
    } else if baseURL.contains("zai.com") || baseURL.contains("z.ai") || baseURL.contains("bigmodel.cn") {
      return "ZaiIcon"
    } else if baseURL.contains("moonshot.cn") || baseURL.contains("kimi") {
      return "KimiIcon"
    } else if baseURL.contains("openai.com") {
      return "ChatGPTIcon"
    } else if baseURL.contains("anthropic.com") {
      return "ClaudeIcon"
    }
    
    return nil
  }
}

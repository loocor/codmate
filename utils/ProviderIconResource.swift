import AppKit
import CoreImage
import SwiftUI

/// Unified provider icon resource library
/// Manages all provider icons with centralized theme adaptation
enum ProviderIconResource {
  /// Icon metadata including theme adaptation requirements
  struct IconMetadata {
    let name: String
    let requiresDarkModeInversion: Bool
    let aliases: [String]  // Alternative names/IDs that map to this icon
  }
  
  /// Registry of all provider icons with their metadata
  static let iconRegistry: [IconMetadata] = [
    // OAuth providers
    IconMetadata(name: "ChatGPTIcon", requiresDarkModeInversion: true, aliases: ["codex", "openai"]),
    IconMetadata(name: "ClaudeIcon", requiresDarkModeInversion: false, aliases: ["claude", "anthropic"]),
    IconMetadata(name: "GeminiIcon", requiresDarkModeInversion: false, aliases: ["gemini", "google"]),
    IconMetadata(name: "AntigravityIcon", requiresDarkModeInversion: false, aliases: ["antigravity"]),
    IconMetadata(name: "QwenIcon", requiresDarkModeInversion: false, aliases: ["qwen"]),
    
    // API key providers
    IconMetadata(name: "DeepSeekIcon", requiresDarkModeInversion: false, aliases: ["deepseek", "deep-seek"]),
    IconMetadata(name: "MiniMaxIcon", requiresDarkModeInversion: true, aliases: ["minimax", "mini-max"]),
    IconMetadata(name: "OpenRouterIcon", requiresDarkModeInversion: true, aliases: ["openrouter", "open-router"]),
    IconMetadata(name: "ZaiIcon", requiresDarkModeInversion: true, aliases: ["zai", "z.ai", "glm"]),
    IconMetadata(name: "KimiIcon", requiresDarkModeInversion: true, aliases: ["kimi", "k2", "moonshot"]),
  ]
  
  /// Lookup map: alias -> icon name
  private static let aliasMap: [String: String] = {
    var map: [String: String] = [:]
    for icon in iconRegistry {
      map[icon.name.lowercased()] = icon.name
      for alias in icon.aliases {
        map[alias.lowercased()] = icon.name
      }
    }
    return map
  }()
  
  /// Lookup map: icon name -> metadata
  private static let metadataMap: [String: IconMetadata] = {
    Dictionary(uniqueKeysWithValues: iconRegistry.map { ($0.name, $0) })
  }()
  
  /// Find icon name by alias (ID, name, or baseURL)
  static func iconName(for alias: String) -> String? {
    aliasMap[alias.lowercased()]
  }
  
  /// Find icon name by provider ID, name, or baseURL
  static func iconName(forProviderId id: String?, name: String?, baseURL: String?) -> String? {
    // Try ID first
    if let id = id, let iconName = iconName(for: id) {
      return iconName
    }
    
    // Try name
    if let name = name, let iconName = iconName(for: name) {
      return iconName
    }
    
    // Try baseURL
    if let baseURL = baseURL?.lowercased() {
      // Check for domain matches
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
    }
    
    return nil
  }
  
  /// Get metadata for an icon name
  static func metadata(for iconName: String) -> IconMetadata? {
    metadataMap[iconName]
  }
  
  /// Check if an icon requires dark mode inversion
  static func requiresDarkModeInversion(_ iconName: String) -> Bool {
    metadata(for: iconName)?.requiresDarkModeInversion ?? false
  }
  
  /// Process NSImage for display with theme adaptation
  /// - Parameters:
  ///   - iconName: The icon asset name
  ///   - size: Target size for the icon
  ///   - isDarkMode: Whether dark mode is active
  /// - Returns: Processed NSImage ready for display
  static func processedImage(
    named iconName: String,
    size: NSSize,
    isDarkMode: Bool
  ) -> NSImage? {
    guard let originalImage = NSImage(named: iconName) else { return nil }
    
    // Resize to target size
    let resized = NSImage(size: size)
    resized.lockFocus()
    originalImage.draw(
      in: NSRect(origin: .zero, size: size),
      from: NSRect(origin: .zero, size: originalImage.size),
      operation: .copy,
      fraction: 1.0
    )
    resized.unlockFocus()
    
    // Apply inversion if needed
    if requiresDarkModeInversion(iconName) && isDarkMode {
      return invertedImage(resized) ?? resized
    }
    
    return resized
  }
  
  /// Invert an NSImage using Core Image filter
  private static func invertedImage(_ image: NSImage) -> NSImage? {
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      return nil
    }
    
    let ciImage = CIImage(cgImage: cgImage)
    guard let filter = CIFilter(name: "CIColorInvert") else { return nil }
    filter.setValue(ciImage, forKey: kCIInputImageKey)
    guard let outputImage = filter.outputImage else { return nil }
    
    let rep = NSCIImageRep(ciImage: outputImage)
    let newImage = NSImage(size: image.size)
    newImage.addRepresentation(rep)
    return newImage
  }
  
  /// Get all registered icon names
  static var allIconNames: [String] {
    iconRegistry.map { $0.name }
  }
  
  /// Get icons that require dark mode inversion
  static var darkModeInvertIcons: Set<String> {
    Set(iconRegistry.filter { $0.requiresDarkModeInversion }.map { $0.name })
  }
}

/// SwiftUI ViewModifier for applying dark mode inversion to provider icons
struct ProviderIconDarkModeModifier: ViewModifier {
  let iconName: String
  @Environment(\.colorScheme) private var colorScheme
  
  func body(content: Content) -> some View {
    if ProviderIconResource.requiresDarkModeInversion(iconName) && colorScheme == .dark {
      content.colorInvert()
    } else {
      content
    }
  }
}

extension View {
  /// Apply dark mode inversion to provider icons if needed
  func providerIconTheme(iconName: String) -> some View {
    modifier(ProviderIconDarkModeModifier(iconName: iconName))
  }
}

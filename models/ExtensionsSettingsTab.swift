import Foundation

enum ExtensionsSettingsTab: String, CaseIterable, Identifiable {
  case mcp
  case skills
  case commands
  case hooks

  var id: String { rawValue }
}

import Foundation

enum ExtensionsSettingsTab: String, CaseIterable, Identifiable {
  case mcp
  case skills
  case commands

  var id: String { rawValue }
}

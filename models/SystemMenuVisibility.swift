import Foundation

enum SystemMenuVisibility: String, CaseIterable, Identifiable, Sendable {
  case hidden
  case visible
  case menuOnly

  var id: String { rawValue }

  var title: String {
    switch self {
    case .hidden: return "Hidden"
    case .visible: return "Shown"
    case .menuOnly: return "Menu Bar Only"
    }
  }
}

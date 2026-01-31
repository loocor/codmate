import Foundation

extension SessionSource.Kind: CaseIterable {
  static var allCases: [SessionSource.Kind] { [.codex, .claude, .gemini] }
}

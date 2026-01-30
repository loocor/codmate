import Foundation

struct HookSyncWarning: Identifiable, Equatable {
  let id = UUID()
  let provider: HookTarget
  let message: String
}


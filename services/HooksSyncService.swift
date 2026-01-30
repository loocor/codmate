import Foundation

actor HooksSyncService {
  func syncGlobal(rules: [HookRule]) async -> [HookSyncWarning] {
    var warnings: [HookSyncWarning] = []

    if SessionPreferencesStore.isCLIEnabled(.codex) {
      let service = CodexConfigService()
      do {
        warnings.append(contentsOf: try await service.applyHooksFromCodMate(rules))
      } catch {
        warnings.append(HookSyncWarning(provider: .codex, message: "Failed to apply hooks: \(error.localizedDescription)"))
      }
    }

    if SessionPreferencesStore.isCLIEnabled(.claude) {
      let service = ClaudeSettingsService()
      do {
        warnings.append(contentsOf: try await service.applyHooksFromCodMate(rules))
      } catch {
        warnings.append(HookSyncWarning(provider: .claude, message: "Failed to apply hooks: \(error.localizedDescription)"))
      }
    }

    if SessionPreferencesStore.isCLIEnabled(.gemini) {
      let service = GeminiSettingsService()
      do {
        warnings.append(contentsOf: try await service.applyHooksFromCodMate(rules))
      } catch {
        warnings.append(HookSyncWarning(provider: .gemini, message: "Failed to apply hooks: \(error.localizedDescription)"))
      }
    }

    return warnings
  }
}

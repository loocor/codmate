import Foundation

@MainActor
final class HooksViewModel: ObservableObject {
  @Published var rules: [HookRule] = []
  @Published var selectedRuleId: String? = nil
  @Published var searchText: String = ""
  @Published var showAddSheet = false
  @Published var editingRule: HookRule? = nil
  @Published var syncWarnings: [HookSyncWarning] = []
  @Published var errorMessage: String? = nil
  @Published var isLoading = false
  @Published var showImportSheet = false
  @Published var importCandidates: [HookImportCandidate] = []
  @Published var isImporting = false
  @Published var importStatusMessage: String? = nil

  private let store = HooksStore()
  private let syncService = HooksSyncService()

  var selectedRule: HookRule? {
    guard let id = selectedRuleId else { return nil }
    return rules.first(where: { $0.id == id })
  }

  var filteredRules: [HookRule] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    if query.isEmpty { return rules }
    return rules.filter { rule in
      rule.name.localizedCaseInsensitiveContains(query) ||
      rule.event.localizedCaseInsensitiveContains(query) ||
      (rule.matcher?.localizedCaseInsensitiveContains(query) ?? false) ||
      rule.commands.contains(where: { $0.command.localizedCaseInsensitiveContains(query) })
    }
  }

  func load() async {
    isLoading = true
    defer { isLoading = false }
    rules = await store.list()
  }

  // MARK: - CRUD

  func addRule(_ rule: HookRule) async {
    do {
      try await store.upsert(rule)
      await load()
      selectedRuleId = rule.id
      await applyToProviders()
    } catch {
      errorMessage = "Failed to save hook"
    }
  }

  func updateRule(_ rule: HookRule) async {
    do {
      try await store.upsert(rule)
      await load()
      await applyToProviders()
    } catch {
      errorMessage = "Failed to save hook"
    }
  }

  func deleteRule(id: String) async {
    do {
      try await store.delete(id: id)
      if selectedRuleId == id { selectedRuleId = nil }
      await load()
      await applyToProviders()
    } catch {
      errorMessage = "Failed to delete hook"
    }
  }

  func updateRuleEnabled(id: String, value: Bool) {
    updateLocalRule(id: id) { $0.enabled = value }
    Task {
      do {
        try await store.update(id: id) { rule in
          rule.enabled = value
          rule.updatedAt = Date()
        }
        await applyToProviders()
      } catch {
        errorMessage = "Failed to update hook"
      }
    }
  }

  func updateRuleTarget(id: String, target: HookTarget, value: Bool) {
    updateLocalRule(id: id) { rule in
      var targets = rule.targets ?? HookTargets()
      targets.setEnabled(value, for: target)
      rule.targets = targets.allEnabled ? nil : targets
    }
    Task {
      do {
        try await store.update(id: id) { rule in
          var targets = rule.targets ?? HookTargets()
          targets.setEnabled(value, for: target)
          rule.targets = targets.allEnabled ? nil : targets
          rule.updatedAt = Date()
        }
        await applyToProviders()
      } catch {
        errorMessage = "Failed to update hook"
      }
    }
  }

  private func updateLocalRule(id: String, mutate: (inout HookRule) -> Void) {
    guard let idx = rules.firstIndex(where: { $0.id == id }) else { return }
    mutate(&rules[idx])
  }

  // MARK: - Import

  func beginImportFromHome() {
    showImportSheet = true
    Task { await loadImportCandidatesFromHome() }
  }

  func loadImportCandidatesFromHome() async {
    isImporting = true
    importStatusMessage = "Scanning…"

    if SecurityScopedBookmarks.shared.isSandboxed {
      let home = SessionPreferencesStore.getRealUserHomeURL()
      AuthorizationHub.shared.ensureDirectoryAccessOrPrompt(
        directory: home,
        purpose: .generalAccess,
        message: "Authorize your Home folder to import hooks"
      )
    }

    let existing = await store.list()
    let existingSignatures = Set(existing.map { HooksImportService.hookSignature($0) })

    let scanned = await Task.detached(priority: .userInitiated) {
      await HooksImportService.scan(scope: .home)
    }.value

    var candidates = scanned
    for idx in candidates.indices {
      let signature = candidates[idx].signature
      candidates[idx].hasConflict = existingSignatures.contains(signature)
      candidates[idx].resolution = candidates[idx].hasConflict ? .skip : .overwrite
      candidates[idx].renameName = candidates[idx].rule.name
    }

    await MainActor.run {
      self.importCandidates = candidates
      self.isImporting = false
      self.importStatusMessage = candidates.isEmpty ? "No hooks found." : nil
    }
  }

  func cancelImport() {
    showImportSheet = false
    importCandidates = []
    importStatusMessage = nil
  }

  func importSelectedHooks() async {
    let selected = importCandidates.filter { $0.isSelected }
    guard !selected.isEmpty else {
      importStatusMessage = "No hooks selected."
      return
    }

    let existing = await store.list()
    let existingBySignature = Dictionary(grouping: existing, by: { HooksImportService.hookSignature($0) })

    var importedCount = 0
    var importedCandidateIds: Set<UUID> = []

    for item in selected {
      switch item.resolution {
      case .skip:
        continue
      case .overwrite:
        if let existingRule = existingBySignature[item.signature]?.first {
          var updated = item.rule
          updated.id = existingRule.id
          updated.createdAt = existingRule.createdAt
          updated.updatedAt = Date()
          do { try await store.upsert(updated) } catch { continue }
        } else {
          var fresh = item.rule
          fresh.id = UUID().uuidString
          fresh.createdAt = Date()
          fresh.updatedAt = Date()
          do { try await store.upsert(fresh) } catch { continue }
        }
        importedCount += 1
        importedCandidateIds.insert(item.id)
      case .rename:
        let newName = item.renameName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else { continue }
        var fresh = item.rule
        fresh.id = UUID().uuidString
        fresh.name = newName
        fresh.createdAt = Date()
        fresh.updatedAt = Date()
        do { try await store.upsert(fresh) } catch { continue }
        importedCount += 1
        importedCandidateIds.insert(item.id)
      }
    }

    await load()
    await applyToProviders()
    importStatusMessage = "Imported \(importedCount) hook(s)."
    if !importedCandidateIds.isEmpty {
      importCandidates.removeAll { importedCandidateIds.contains($0.id) }
    }
    if importCandidates.isEmpty {
      closeImportSheetAfterDelay()
    }
  }

  private func closeImportSheetAfterDelay(_ delay: TimeInterval = 0.6) {
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      self.showImportSheet = false
      self.importStatusMessage = nil
    }
  }

  // MARK: - Apply

  func applyToProviders() async {
    if SecurityScopedBookmarks.shared.isSandboxed {
      let home = SessionPreferencesStore.getRealUserHomeURL()
      AuthorizationHub.shared.ensureDirectoryAccessOrPrompt(
        directory: home,
        purpose: .generalAccess,
        message: "Authorize your Home folder to apply hooks"
      )
    }

    let warnings = await syncService.syncGlobal(rules: rules)
    syncWarnings = warnings

    if !warnings.isEmpty {
      errorMessage = "Applied with \(warnings.count) warning(s)"
    } else {
      errorMessage = nil
    }
  }
}


import Foundation
import SwiftUI

@MainActor
class CommandsViewModel: ObservableObject {
  @Published var commands: [CommandRecord] = []
  @Published var selectedCommandId: String? = nil
  @Published var searchText: String = ""
  @Published var showAddSheet = false
  @Published var editingCommand: CommandRecord? = nil
  @Published var syncWarnings: [CommandSyncWarning] = []
  @Published var errorMessage: String? = nil
  @Published var isLoading = false

  private let store = CommandsStore()
  private let syncService = CommandsSyncService()

  init() {
    Task { await load() }
  }

  var selectedCommand: CommandRecord? {
    guard let id = selectedCommandId else { return nil }
    return commands.first(where: { $0.id == id })
  }

  var filteredCommands: [CommandRecord] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    if query.isEmpty {
      return commands
    }
    return commands.filter { command in
      command.name.localizedCaseInsensitiveContains(query) ||
      command.description.localizedCaseInsensitiveContains(query) ||
      command.prompt.localizedCaseInsensitiveContains(query)
    }
  }

  // MARK: - Load
  func load() async {
    isLoading = true
    defer { isLoading = false }

    let records = await store.listWithBuiltIns()
    commands = records
  }

  // MARK: - CRUD Operations
  func addCommand(_ command: CommandRecord) async {
    await store.upsert(command)
    await load()
    selectedCommandId = command.id
    await syncToProviders()
  }

  func updateCommand(_ command: CommandRecord) async {
    await store.upsert(command)
    await load()
    await syncToProviders()
  }

  func deleteCommand(id: String) async {
    await store.delete(id: id)
    if selectedCommandId == id {
      selectedCommandId = nil
    }
    await load()
    await syncToProviders()
  }

  func updateCommandEnabled(id: String, value: Bool) {
    Task {
      await store.update(id: id) { record in
        record.isEnabled = value
      }
      await load()
      await syncToProviders()
    }
  }

  func updateCommandTarget(id: String, target: CommandTarget, value: Bool) {
    Task {
      await store.update(id: id) { record in
        switch target {
        case .codex:
          record.targets.codex = value
        case .claude:
          record.targets.claude = value
        case .gemini:
          record.targets.gemini = value
        }
      }
      await load()
      await syncToProviders()
    }
  }

  // MARK: - Sync
  func syncToProviders() async {
    let warnings = await syncService.syncGlobal(commands: commands)
    syncWarnings = warnings

    if !warnings.isEmpty {
      errorMessage = "Sync completed with \(warnings.count) warning(s)"
    }
  }

  func manualSync() async {
    isLoading = true
    defer { isLoading = false }

    await syncToProviders()

    if syncWarnings.isEmpty {
      errorMessage = "Successfully synced \(commands.filter { $0.isEnabled }.count) commands"
    }
  }

  // MARK: - Import/Export
  func importFromJSON(url: URL) async {
    do {
      let data = try Data(contentsOf: url)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let imported = try decoder.decode([CommandRecord].self, from: data)

      for command in imported {
        await store.upsert(command)
      }

      await load()
      await syncToProviders()

      errorMessage = "Successfully imported \(imported.count) commands"
    } catch {
      errorMessage = "Import failed: \(error.localizedDescription)"
    }
  }

  func exportToJSON(url: URL) async {
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
      encoder.dateEncodingStrategy = .iso8601

      let data = try encoder.encode(commands)
      try data.write(to: url, options: .atomic)

      errorMessage = "Successfully exported \(commands.count) commands"
    } catch {
      errorMessage = "Export failed: \(error.localizedDescription)"
    }
  }

  // MARK: - Helpers
  func canDelete(id: String) -> Bool {
    // All commands can be deleted
    return commands.first(where: { $0.id == id }) != nil
  }

  func enabledCount(for target: CommandTarget) -> Int {
    commands.filter { $0.isEnabled && $0.targets.isEnabled(for: target) }.count
  }

  func isCommandTargetEnabled(id: String, target: CommandTarget) -> Bool {
    guard let command = commands.first(where: { $0.id == id }) else { return false }
    return command.targets.isEnabled(for: target)
  }

  var totalEnabledCount: Int {
    commands.filter { $0.isEnabled }.count
  }
}

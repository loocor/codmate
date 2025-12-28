import Foundation

/// Service for syncing commands from the unified store to provider-specific formats
/// Follows the same pattern as SkillsSyncService and MCPServersStore export functions
actor CommandsSyncService {
  private let fm: FileManager

  init(fileManager: FileManager = .default) {
    self.fm = fileManager
  }

  // MARK: - Sync to All Providers
  func syncGlobal(commands: [CommandRecord]) -> [CommandSyncWarning] {
    let home = SessionPreferencesStore.getRealUserHomeURL()
    let codexDir = home.appendingPathComponent(".codex", isDirectory: true)
      .appendingPathComponent("prompts", isDirectory: true)
    let claudeDir = home.appendingPathComponent(".claude", isDirectory: true)
      .appendingPathComponent("commands", isDirectory: true)
    let geminiDir = home.appendingPathComponent(".gemini", isDirectory: true)
      .appendingPathComponent("commands", isDirectory: true)

    var warnings: [CommandSyncWarning] = []
    warnings.append(contentsOf: syncCommands(commands: commands, target: .codex, destination: codexDir))
    warnings.append(contentsOf: syncCommands(commands: commands, target: .claude, destination: claudeDir))
    warnings.append(contentsOf: syncCommands(commands: commands, target: .gemini, destination: geminiDir))
    return warnings
  }

  // MARK: - Private Sync Logic
  private func syncCommands(
    commands: [CommandRecord],
    target: CommandTarget,
    destination: URL
  ) -> [CommandSyncWarning] {
    let selected = commands.filter { $0.isEnabled && $0.targets.isEnabled(for: target) }

    if selected.isEmpty {
      removeManagedCommands(at: destination)
      return []
    }

    try? fm.createDirectory(at: destination, withIntermediateDirectories: true)

    var warnings: [CommandSyncWarning] = []
    for command in selected {
      do {
        try writeCommand(command, to: destination, target: target)
      } catch {
        warnings.append(CommandSyncWarning(
          message: "\(command.id) could not sync to \(destination.path): \(error.localizedDescription)"
        ))
      }
    }

    removeManagedCommands(at: destination, keeping: Set(selected.map { $0.id }))
    return warnings
  }

  // MARK: - Format Writers
  private func writeCommand(_ command: CommandRecord, to directory: URL, target: CommandTarget) throws {
    let fileURL: URL
    let content: String

    switch target {
    case .codex, .claude:
      // Both use Markdown + YAML frontmatter
      fileURL = directory.appendingPathComponent("\(command.id).md", isDirectory: false)
      content = generateMarkdownFormat(command, for: target)

    case .gemini:
      // Gemini uses TOML
      fileURL = directory.appendingPathComponent("\(command.id).toml", isDirectory: false)
      content = generateTOMLFormat(command)
    }

    // Write content
    try content.write(to: fileURL, atomically: true, encoding: .utf8)

    // Write marker file for CodMate management
    try writeMarker(to: directory, id: command.id, target: target)
  }

  // MARK: - Markdown Format (Claude Code & Codex CLI)
  private func generateMarkdownFormat(_ command: CommandRecord, for target: CommandTarget) -> String {
    var frontmatter: [String] = []

    // Description (required)
    frontmatter.append("description: \"\(escapeYAML(command.description))\"")

    // Argument hint (optional)
    if let hint = command.metadata.argumentHint, !hint.isEmpty {
      frontmatter.append("argument-hint: \(hint)")
    }

    // Model (Claude Code only)
    if target == .claude, let model = command.metadata.model, !model.isEmpty {
      frontmatter.append("model: \(model)")
    }

    // Allowed tools (Claude Code only)
    if target == .claude, let tools = command.metadata.allowedTools, !tools.isEmpty {
      frontmatter.append("allowed-tools: \(tools.joined(separator: ", "))")
    }

    // Build final markdown
    var lines: [String] = ["---"]
    lines.append(contentsOf: frontmatter)
    lines.append("---")
    lines.append("")
    lines.append(command.prompt)
    lines.append("")

    return lines.joined(separator: "\n")
  }

  // MARK: - TOML Format (Gemini CLI)
  private func generateTOMLFormat(_ command: CommandRecord) -> String {
    var lines: [String] = []

    // Multi-line prompt
    lines.append("prompt = \"\"\"")
    lines.append(command.prompt)
    lines.append("\"\"\"")

    // Description
    lines.append("description = \"\(escapeTOML(command.description))\"")

    return lines.joined(separator: "\n") + "\n"
  }

  // MARK: - Marker Management
  private func writeMarker(to directory: URL, id: String, target: CommandTarget) throws {
    let markerFile: URL
    switch target {
    case .codex, .claude:
      markerFile = directory.appendingPathComponent(".\(id).codmate", isDirectory: false)
    case .gemini:
      markerFile = directory.appendingPathComponent(".\(id).codmate", isDirectory: false)
    }

    let marker: [String: Any] = [
      "managedByCodMate": true,
      "id": id,
      "syncedAt": ISO8601DateFormatter().string(from: Date())
    ]

    let data = try JSONSerialization.data(withJSONObject: marker, options: [.prettyPrinted])
    try data.write(to: markerFile, options: .atomic)
  }

  private func removeManagedCommands(at directory: URL, keeping ids: Set<String> = []) {
    guard fm.fileExists(atPath: directory.path) else { return }
    guard let entries = try? fm.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) else { return }

    for entry in entries {
      let basename = entry.deletingPathExtension().lastPathComponent
      guard !ids.contains(basename) else { continue }

      // Check if there's a marker file
      let markerFile = directory.appendingPathComponent(".\(basename).codmate", isDirectory: false)
      if fm.fileExists(atPath: markerFile.path) {
        // Remove both the command file and marker
        try? fm.removeItem(at: entry)
        try? fm.removeItem(at: markerFile)
      }
    }
  }

  // MARK: - Utility Functions
  private func escapeYAML(_ string: String) -> String {
    string
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n")
  }

  private func escapeTOML(_ string: String) -> String {
    string
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
  }
}

// MARK: - Warning
struct CommandSyncWarning {
  var message: String
}

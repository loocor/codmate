import Foundation

/// Unified commands store for managing slash commands across AI CLI providers
/// Follows the same pattern as SkillsStore - uses Markdown files with YAML frontmatter
actor CommandsStore {
  struct Paths {
    let root: URL
    let libraryDir: URL
    let indexURL: URL

    static func `default`(fileManager: FileManager = .default) -> Paths {
      let home = SessionPreferencesStore.getRealUserHomeURL()
      let root = home.appendingPathComponent(".codmate", isDirectory: true)
        .appendingPathComponent("commands", isDirectory: true)
      return Paths(
        root: root,
        libraryDir: root.appendingPathComponent("library", isDirectory: true),
        indexURL: root.appendingPathComponent("index.json", isDirectory: false)
      )
    }
  }

  private let paths: Paths
  private let fm: FileManager

  init(paths: Paths = .default(), fileManager: FileManager = .default) {
    self.paths = paths
    self.fm = fileManager
  }

  // MARK: - Load/Save
  func list() -> [CommandRecord] {
    load()
  }

  func record(id: String) -> CommandRecord? {
    load().first(where: { $0.id == id })
  }

  func saveAll(_ records: [CommandRecord]) {
    save(records)
  }

  func upsert(_ record: CommandRecord) {
    var records = load()
    let updatedRecord: CommandRecord

    if let idx = records.firstIndex(where: { $0.id == record.id }) {
      // Update existing: preserve path if not provided
      let existingPath = records[idx].path
      updatedRecord = CommandRecord(
        id: record.id,
        name: record.name,
        description: record.description,
        prompt: record.prompt,
        metadata: record.metadata,
        targets: record.targets,
        isEnabled: record.isEnabled,
        source: record.source,
        path: record.path.isEmpty ? existingPath : record.path,
        installedAt: record.installedAt
      )
      records[idx] = updatedRecord
    } else {
      // New command: create path if empty
      let commandPath = record.path.isEmpty
        ? paths.libraryDir.appendingPathComponent("\(record.id).md").path
        : record.path
      updatedRecord = CommandRecord(
        id: record.id,
        name: record.name,
        description: record.description,
        prompt: record.prompt,
        metadata: record.metadata,
        targets: record.targets,
        isEnabled: record.isEnabled,
        source: record.source,
        path: commandPath,
        installedAt: record.installedAt
      )
      records.append(updatedRecord)
    }

    // Write Markdown file
    writeMarkdownFile(for: updatedRecord)
    save(records)
  }

  func update(id: String, mutate: (inout CommandRecord) -> Void) {
    var records = load()
    guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
    mutate(&records[idx])
    save(records)
  }

  func delete(id: String) {
    var records = load()
    guard let record = records.first(where: { $0.id == id }) else { return }

    // Delete Markdown file
    let url = URL(fileURLWithPath: record.path)
    try? fm.removeItem(at: url)

    records.removeAll(where: { $0.id == id })
    save(records)
  }

  // MARK: - Payload Commands
  /// Load default commands from the bundled payload directory
  private static func loadPayloadCommands(fm: FileManager = .default) -> [CommandRecord] {
    let bundle = Bundle.main
    var commands: [CommandRecord] = []

    // Try loading index.json from bundle
    var indexURL: URL?
    if let url = bundle.url(forResource: "commands/index", withExtension: "json") {
      indexURL = url
    }
    if indexURL == nil, let url = bundle.url(forResource: "index", withExtension: "json", subdirectory: "payload/commands") {
      indexURL = url
    }

    guard let indexURL = indexURL,
          let data = try? Data(contentsOf: indexURL) else {
      return []
    }

    // Parse lightweight index
    struct IndexEntry: Codable {
      let id: String
      let path: String
      let source: String
      let isEnabled: Bool
      let installedAt: String
    }

    let decoder = JSONDecoder()
    guard let indexEntries = try? decoder.decode([IndexEntry].self, from: data) else {
      return []
    }

    let indexDir = indexURL.deletingLastPathComponent()

    // Load each Markdown file
    for entry in indexEntries {
      let mdURL = indexDir.appendingPathComponent(entry.path)
      guard let content = try? String(contentsOf: mdURL, encoding: .utf8) else { continue }
      guard let record = parseMarkdownContent(content, id: entry.id, source: entry.source, isEnabled: entry.isEnabled, installedAt: entry.installedAt, path: mdURL.path) else { continue }
      commands.append(record)
    }

    return commands
  }

  /// Parse Markdown content with YAML frontmatter
  private static func parseMarkdownContent(_ content: String, id: String, source: String, isEnabled: Bool, installedAt: String, path: String) -> CommandRecord? {
    let lines = content.components(separatedBy: .newlines)
    guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }

    var frontmatter: [String] = []
    var promptLines: [String] = []
    var inFrontmatter = false
    var foundSecondDash = false

    for (index, line) in lines.enumerated() {
      if index == 0 {
        inFrontmatter = true
        continue
      }
      if line.trimmingCharacters(in: .whitespaces) == "---" && inFrontmatter {
        foundSecondDash = true
        inFrontmatter = false
        continue
      }
      if inFrontmatter {
        frontmatter.append(line)
      } else if foundSecondDash {
        promptLines.append(line)
      }
    }

    // Parse YAML frontmatter
    var name = id
    var description = ""
    var argumentHint: String?
    var model: String?
    var allowedTools: [String]?
    var tags: [String] = []
    var codex = true
    var claude = true
    var gemini = false

    for line in frontmatter {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("name:") {
        name = trimmed.replacingOccurrences(of: "name:", with: "").trimmingCharacters(in: .whitespaces)
      } else if trimmed.hasPrefix("description:") {
        description = trimmed.replacingOccurrences(of: "description:", with: "").trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
      } else if trimmed.hasPrefix("argument-hint:") {
        argumentHint = trimmed.replacingOccurrences(of: "argument-hint:", with: "").trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
      } else if trimmed.hasPrefix("model:") {
        let value = trimmed.replacingOccurrences(of: "model:", with: "").trimmingCharacters(in: .whitespaces)
        if value != "null" && !value.isEmpty {
          model = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
      } else if trimmed.hasPrefix("allowed-tools:") {
        // Simple array parsing
        let arrayStr = trimmed.replacingOccurrences(of: "allowed-tools:", with: "").trimmingCharacters(in: .whitespaces)
        if arrayStr.hasPrefix("[") {
          let cleaned = arrayStr.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
          allowedTools = cleaned.components(separatedBy: ",").map {
            $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
          }.filter { !$0.isEmpty }
        }
      } else if trimmed.hasPrefix("tags:") {
        // Simple array parsing
        let arrayStr = trimmed.replacingOccurrences(of: "tags:", with: "").trimmingCharacters(in: .whitespaces)
        if arrayStr.hasPrefix("[") {
          let cleaned = arrayStr.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
          tags = cleaned.components(separatedBy: ",").map {
            $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
          }.filter { !$0.isEmpty }
        }
      } else if trimmed == "targets:" {
        // Next lines will be target values
      } else if trimmed.hasPrefix("codex:") {
        codex = trimmed.replacingOccurrences(of: "codex:", with: "").trimmingCharacters(in: .whitespaces) == "true"
      } else if trimmed.hasPrefix("claude:") {
        claude = trimmed.replacingOccurrences(of: "claude:", with: "").trimmingCharacters(in: .whitespaces) == "true"
      } else if trimmed.hasPrefix("gemini:") {
        gemini = trimmed.replacingOccurrences(of: "gemini:", with: "").trimmingCharacters(in: .whitespaces) == "true"
      } else if trimmed.hasPrefix("-") && frontmatter.last?.contains("tags") == true {
        // Handle YAML array items
        let item = trimmed.replacingOccurrences(of: "-", with: "").trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        if !item.isEmpty {
          tags.append(item)
        }
      } else if trimmed.hasPrefix("-") && frontmatter.last?.contains("allowed-tools") == true {
        // Handle YAML array items
        let item = trimmed.replacingOccurrences(of: "-", with: "").trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        if !item.isEmpty {
          if allowedTools == nil { allowedTools = [] }
          allowedTools?.append(item)
        }
      }
    }

    let prompt = promptLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    let dateFormatter = ISO8601DateFormatter()
    let date = dateFormatter.date(from: installedAt) ?? Date()

    return CommandRecord(
      id: id,
      name: name,
      description: description,
      prompt: prompt,
      metadata: CommandMetadata(
        argumentHint: argumentHint,
        model: model,
        allowedTools: allowedTools,
        tags: tags
      ),
      targets: CommandTargets(codex: codex, claude: claude, gemini: gemini),
      isEnabled: isEnabled,
      source: source,
      path: path,
      installedAt: date
    )
  }

  /// List all commands, initializing from payload if needed
  func listWithBuiltIns() -> [CommandRecord] {
    // Initialize from payload on first run
    initializeFromPayloadIfNeeded()

    // Load from user directory
    let userCommands = load()

    // Load command content from Markdown files
    var fullCommands: [CommandRecord] = []
    for record in userCommands {
      if let loaded = loadCommandFromMarkdown(record) {
        fullCommands.append(loaded)
      }
    }

    return fullCommands.sorted { $0.name < $1.name }
  }

  /// Initialize commands from payload (one-time only)
  private func initializeFromPayloadIfNeeded() {
    // Check if already initialized
    if fm.fileExists(atPath: paths.indexURL.path) {
      return
    }

    // Load payload commands
    let payloadCommands = Self.loadPayloadCommands(fm: fm)
    guard !payloadCommands.isEmpty else { return }

    // Create library directory
    try? fm.createDirectory(at: paths.libraryDir, withIntermediateDirectories: true)

    // Copy commands to user library with source: "library"
    var userCommands: [CommandRecord] = []
    for payloadCmd in payloadCommands {
      let userPath = paths.libraryDir.appendingPathComponent("\(payloadCmd.id).md").path
      let userCmd = CommandRecord(
        id: payloadCmd.id,
        name: payloadCmd.name,
        description: payloadCmd.description,
        prompt: payloadCmd.prompt,
        metadata: payloadCmd.metadata,
        targets: payloadCmd.targets,
        isEnabled: payloadCmd.isEnabled,
        source: "library",  // Mark as library, not payload
        path: userPath,
        installedAt: payloadCmd.installedAt
      )

      // Write Markdown file
      writeMarkdownFile(for: userCmd)
      userCommands.append(userCmd)
    }

    // Save index
    save(userCommands)
  }

  // MARK: - Private Helpers

  /// Load command details from Markdown file
  private func loadCommandFromMarkdown(_ indexRecord: CommandRecord) -> CommandRecord? {
    let path = indexRecord.path
    guard !path.isEmpty else { return indexRecord }
    let url = URL(fileURLWithPath: path)
    guard let content = try? String(contentsOf: url, encoding: .utf8) else { return indexRecord }

    let dateFormatter = ISO8601DateFormatter()
    let installedAtStr = dateFormatter.string(from: indexRecord.installedAt)

    return Self.parseMarkdownContent(content, id: indexRecord.id, source: indexRecord.source, isEnabled: indexRecord.isEnabled, installedAt: installedAtStr, path: path)
  }

  /// Write command to Markdown file
  private func writeMarkdownFile(for record: CommandRecord) {
    let url = URL(fileURLWithPath: record.path)
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

    var content = "---\n"
    content += "id: \(record.id)\n"
    content += "name: \(record.name)\n"
    content += "description: \"\(record.description)\"\n"

    if let hint = record.metadata.argumentHint {
      content += "argument-hint: \"\(hint)\"\n"
    }
    if let model = record.metadata.model {
      content += "model: \"\(model)\"\n"
    }
    if let tools = record.metadata.allowedTools, !tools.isEmpty {
      content += "allowed-tools: [\"\(tools.joined(separator: "\", \""))\"]\n"
    }
    if !record.metadata.tags.isEmpty {
      content += "tags: [\"\(record.metadata.tags.joined(separator: "\", \""))\"]\n"
    }

    content += "targets:\n"
    content += "  codex: \(record.targets.codex)\n"
    content += "  claude: \(record.targets.claude)\n"
    content += "  gemini: \(record.targets.gemini)\n"
    content += "---\n\n"
    content += record.prompt

    try? content.write(to: url, atomically: true, encoding: .utf8)
  }

  /// Load index (lightweight metadata only)
  private func load() -> [CommandRecord] {
    guard fm.fileExists(atPath: paths.indexURL.path) else { return [] }
    guard let data = try? Data(contentsOf: paths.indexURL) else { return [] }

    struct IndexEntry: Codable {
      let id: String
      let path: String
      let source: String
      let isEnabled: Bool
      let installedAt: Date
    }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let entries = try? decoder.decode([IndexEntry].self, from: data) else { return [] }

    return entries.map { entry in
      CommandRecord(
        id: entry.id,
        name: entry.id,
        description: "",
        prompt: "",
        isEnabled: entry.isEnabled,
        source: entry.source,
        path: entry.path,
        installedAt: entry.installedAt
      )
    }
  }

  /// Save index (lightweight metadata only)
  private func save(_ records: [CommandRecord]) {
    struct IndexEntry: Codable {
      let id: String
      let path: String
      let source: String
      let isEnabled: Bool
      let installedAt: Date
    }

    let entries = records.map { record in
      IndexEntry(
        id: record.id,
        path: record.path,
        source: record.source,
        isEnabled: record.isEnabled,
        installedAt: record.installedAt
      )
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(entries) else { return }
    try? fm.createDirectory(at: paths.root, withIntermediateDirectories: true)
    try? data.write(to: paths.indexURL, options: .atomic)
  }
}

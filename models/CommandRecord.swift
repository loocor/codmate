import Foundation

// MARK: - Command Record
/// Represents a unified slash command that can be synced to multiple AI CLI providers
struct CommandRecord: Codable, Identifiable, Hashable {
  var id: String
  var name: String
  var description: String
  var prompt: String
  var metadata: CommandMetadata
  var targets: CommandTargets
  var isEnabled: Bool
  var source: String
  var path: String  // Path to the Markdown file
  var installedAt: Date

  init(
    id: String,
    name: String,
    description: String,
    prompt: String,
    metadata: CommandMetadata = CommandMetadata(),
    targets: CommandTargets = CommandTargets(),
    isEnabled: Bool = true,
    source: String = "user",
    path: String = "",
    installedAt: Date = Date()
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.prompt = prompt
    self.metadata = metadata
    self.targets = targets
    self.isEnabled = isEnabled
    self.source = source
    self.path = path
    self.installedAt = installedAt
  }
}

// MARK: - Command Metadata
struct CommandMetadata: Codable, Hashable {
  var argumentHint: String?
  var model: String?
  var allowedTools: [String]?
  var tags: [String]

  init(
    argumentHint: String? = nil,
    model: String? = nil,
    allowedTools: [String]? = nil,
    tags: [String] = []
  ) {
    self.argumentHint = argumentHint
    self.model = model
    self.allowedTools = allowedTools
    self.tags = tags
  }
}

// MARK: - Command Targets
struct CommandTargets: Codable, Hashable {
  var codex: Bool
  var claude: Bool
  var gemini: Bool

  init(codex: Bool = true, claude: Bool = true, gemini: Bool = false) {
    self.codex = codex
    self.claude = claude
    self.gemini = gemini
  }

  func isEnabled(for target: CommandTarget) -> Bool {
    switch target {
    case .codex: return codex
    case .claude: return claude
    case .gemini: return gemini
    }
  }
}

// MARK: - Command Target
enum CommandTarget: String, CaseIterable {
  case codex
  case claude
  case gemini

  var displayName: String {
    switch self {
    case .codex: return "Codex CLI"
    case .claude: return "Claude Code"
    case .gemini: return "Gemini CLI"
    }
  }

  var directoryName: String {
    switch self {
    case .codex: return ".codex"
    case .claude: return ".claude"
    case .gemini: return ".gemini"
    }
  }

  var commandsSubpath: String {
    switch self {
    case .codex: return "prompts"  // Codex uses ~/.codex/prompts/
    case .claude: return "commands" // Claude uses ~/.claude/commands/
    case .gemini: return "commands" // Gemini uses ~/.gemini/commands/
    }
  }
}

// MARK: - Command Extensions
extension Array where Element == CommandRecord {
  func enabledCommands(for target: CommandTarget) -> [CommandRecord] {
    filter { $0.isEnabled && $0.targets.isEnabled(for: target) }
  }
}

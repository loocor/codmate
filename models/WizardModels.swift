import Foundation

enum WizardFeature: String, Codable, CaseIterable, Sendable {
  case hooks
  case commands
  case mcp
  case skills

  var displayName: String {
    switch self {
    case .hooks: return "Hooks"
    case .commands: return "Commands"
    case .mcp: return "MCP Servers"
    case .skills: return "Skills"
    }
  }
}

enum WizardRole: String, Codable, Sendable {
  case system
  case user
  case assistant
}

struct WizardMessage: Identifiable, Codable, Hashable, Sendable {
  var id: UUID
  var role: WizardRole
  var text: String
  var createdAt: Date
  var draftJSON: String?

  init(
    id: UUID = UUID(),
    role: WizardRole,
    text: String,
    createdAt: Date = Date(),
    draftJSON: String? = nil
  ) {
    self.id = id
    self.role = role
    self.text = text
    self.createdAt = createdAt
    self.draftJSON = draftJSON
  }
}

enum WizardOutputMode: String, Codable, Sendable {
  case question
  case draft
}

struct WizardDraftEnvelope<Draft: Codable & Sendable>: Codable, Sendable {
  var mode: WizardOutputMode
  var questions: [String]?
  var draft: Draft?
  var warnings: [String]?
  var notes: [String]?
}

struct HookWizardDraft: Codable, Hashable, Sendable {
  var name: String?
  var description: String?
  var event: String
  var matcher: String?
  var targets: HookTargets?
  var commands: [HookCommand]
  var warnings: [String]?
  var notes: [String]?
}

struct CommandWizardDraft: Codable, Hashable, Sendable {
  var name: String
  var description: String
  var prompt: String
  var argumentHint: String?
  var model: String?
  var allowedTools: [String]?
  var tags: [String]
  var targets: CommandTargets?
  var warnings: [String]?
  var notes: [String]?
}

struct MCPWizardDraft: Codable, Hashable, Sendable {
  var name: String
  var kind: MCPServerKind
  var command: String?
  var args: [String]?
  var env: [String: String]?
  var url: String?
  var headers: [String: String]?
  var description: String?
  var targets: MCPServerTargets?
  var warnings: [String]?
  var notes: [String]?

  private enum CodingKeys: String, CodingKey {
    case name
    case kind
    case command
    case args
    case env
    case url
    case headers
    case description
    case targets
    case warnings
    case notes
  }

  private struct KeyValuePair: Codable, Hashable {
    var key: String
    var value: String
  }

  init(
    name: String,
    kind: MCPServerKind,
    command: String? = nil,
    args: [String]? = nil,
    env: [String: String]? = nil,
    url: String? = nil,
    headers: [String: String]? = nil,
    description: String? = nil,
    targets: MCPServerTargets? = nil,
    warnings: [String]? = nil,
    notes: [String]? = nil
  ) {
    self.name = name
    self.kind = kind
    self.command = command
    self.args = args
    self.env = env
    self.url = url
    self.headers = headers
    self.description = description
    self.targets = targets
    self.warnings = warnings
    self.notes = notes
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decode(String.self, forKey: .name)
    kind = try container.decode(MCPServerKind.self, forKey: .kind)
    command = try container.decodeIfPresent(String.self, forKey: .command)
    args = try container.decodeIfPresent([String].self, forKey: .args)
    url = try container.decodeIfPresent(String.self, forKey: .url)
    description = try container.decodeIfPresent(String.self, forKey: .description)
    targets = try container.decodeIfPresent(MCPServerTargets.self, forKey: .targets)
    warnings = try container.decodeIfPresent([String].self, forKey: .warnings)
    notes = try container.decodeIfPresent([String].self, forKey: .notes)

    if let dict = try? container.decodeIfPresent([String: String].self, forKey: .env) {
      env = dict
    } else if let pairs = try? container.decodeIfPresent([KeyValuePair].self, forKey: .env) {
      env = Dictionary(uniqueKeysWithValues: pairs.map { ($0.key, $0.value) })
    } else {
      env = nil
    }

    if let dict = try? container.decodeIfPresent([String: String].self, forKey: .headers) {
      headers = dict
    } else if let pairs = try? container.decodeIfPresent([KeyValuePair].self, forKey: .headers) {
      headers = Dictionary(uniqueKeysWithValues: pairs.map { ($0.key, $0.value) })
    } else {
      headers = nil
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(name, forKey: .name)
    try container.encode(kind, forKey: .kind)
    try container.encodeIfPresent(command, forKey: .command)
    try container.encodeIfPresent(args, forKey: .args)
    try container.encodeIfPresent(env, forKey: .env)
    try container.encodeIfPresent(url, forKey: .url)
    try container.encodeIfPresent(headers, forKey: .headers)
    try container.encodeIfPresent(description, forKey: .description)
    try container.encodeIfPresent(targets, forKey: .targets)
    try container.encodeIfPresent(warnings, forKey: .warnings)
    try container.encodeIfPresent(notes, forKey: .notes)
  }
}

struct SkillWizardExample: Codable, Hashable, Sendable {
  var title: String
  var user: String
  var assistant: String
}

struct SkillWizardDraft: Codable, Hashable, Sendable {
  var id: String
  var name: String
  var description: String
  var summary: String?
  var tags: [String]
  var overview: String
  var instructions: [String]
  var examples: [SkillWizardExample]
  var notes: [String]
  var targets: MCPServerTargets?
  var warnings: [String]?
}

struct WizardRunEvent: Identifiable, Hashable, Sendable {
  enum Kind: String, Codable, Sendable {
    case status
    case stdout
    case stderr
  }

  var id: UUID = UUID()
  var message: String
  var kind: Kind = .status
  var timestamp: Date = Date()
}

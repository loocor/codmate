import Foundation

enum HookTarget: String, Codable, CaseIterable, Sendable {
  case codex
  case claude
  case gemini

  var displayName: String {
    switch self {
    case .codex: return "Codex"
    case .claude: return "Claude"
    case .gemini: return "Gemini"
    }
  }

  var usageProvider: UsageProviderKind {
    switch self {
    case .codex: return .codex
    case .claude: return .claude
    case .gemini: return .gemini
    }
  }

  var baseKind: SessionSource.Kind { usageProvider.baseKind }
}

struct HookTargets: Codable, Equatable, Hashable, Sendable {
  var codex: Bool
  var claude: Bool
  var gemini: Bool

  init(codex: Bool = true, claude: Bool = true, gemini: Bool = true) {
    self.codex = codex
    self.claude = claude
    self.gemini = gemini
  }

  func isEnabled(for target: HookTarget) -> Bool {
    switch target {
    case .codex: return codex
    case .claude: return claude
    case .gemini: return gemini
    }
  }

  mutating func setEnabled(_ value: Bool, for target: HookTarget) {
    switch target {
    case .codex: codex = value
    case .claude: claude = value
    case .gemini: gemini = value
    }
  }

  var allEnabled: Bool { codex && claude && gemini }
}

struct HookCommand: Codable, Equatable, Hashable, Sendable {
  var command: String
  var args: [String]?
  var env: [String: String]?
  var timeoutMs: Int?

  init(command: String, args: [String]? = nil, env: [String: String]? = nil, timeoutMs: Int? = nil) {
    self.command = command
    self.args = args
    self.env = env
    self.timeoutMs = timeoutMs
  }
}

struct HookRule: Codable, Identifiable, Equatable, Hashable, Sendable {
  var id: String
  var name: String
  var description: String?
  var event: String
  var matcher: String?
  var commands: [HookCommand]
  var enabled: Bool
  /// nil means enabled for all targets (default).
  var targets: HookTargets?
  var source: String
  var createdAt: Date
  var updatedAt: Date

  init(
    id: String = UUID().uuidString,
    name: String,
    description: String? = nil,
    event: String,
    matcher: String? = nil,
    commands: [HookCommand],
    enabled: Bool = true,
    targets: HookTargets? = nil,
    source: String = "user",
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.event = event
    self.matcher = matcher
    self.commands = commands
    self.enabled = enabled
    self.targets = targets
    self.source = source
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  func isEnabled(for target: HookTarget) -> Bool {
    guard enabled else { return false }
    return (targets?.isEnabled(for: target) ?? true)
  }
}

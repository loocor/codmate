import Foundation

enum HookVariableKind: String, CaseIterable, Sendable, Codable {
  case env
  case stdin

  var displayName: String {
    switch self {
    case .env: return "Environment"
    case .stdin: return "Stdin JSON"
    }
  }

  var shortLabel: String {
    switch self {
    case .env: return "ENV"
    case .stdin: return "STDIN"
    }
  }
}

enum HookVariableProvider: String, CaseIterable, Sendable, Codable {
  case codex
  case claude
  case gemini

  var displayName: String {
    switch self {
    case .codex: return "Codex"
    case .claude: return "Claude Code"
    case .gemini: return "Gemini CLI"
    }
  }
}

struct HookVariableDescriptor: Identifiable, Hashable, Sendable {
  let name: String
  let kind: HookVariableKind
  let description: String
  let providers: Set<HookVariableProvider>
  let note: String?

  var id: String { "\(kind.rawValue):\(name)" }
}

enum HookCommandVariableCatalog {
  static let all: [HookVariableDescriptor] = {
    let bundled = loadBundledVariables() ?? fallbackVariables
    return merge(bundled)
  }()

  static func variables(kind: HookVariableKind) -> [HookVariableDescriptor] {
    all.filter { $0.kind == kind }
  }

  private static func merge(_ vars: [HookVariableDescriptor]) -> [HookVariableDescriptor] {
    var map: [String: HookVariableDescriptor] = [:]
    for variable in vars {
      if let existing = map[variable.id] {
        let providers = existing.providers.union(variable.providers)
        let description = existing.description.count >= variable.description.count ? existing.description : variable.description
        let note = mergeNotes(existing.note, variable.note)
        map[variable.id] = HookVariableDescriptor(
          name: existing.name,
          kind: existing.kind,
          description: description,
          providers: providers,
          note: note
        )
      } else {
        map[variable.id] = variable
      }
    }
    return map.values.sorted {
      if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
      return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  private static func mergeNotes(_ a: String?, _ b: String?) -> String? {
    let left = a?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let right = b?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if left.isEmpty { return right.isEmpty ? nil : right }
    if right.isEmpty { return left }
    if left == right { return left }
    return "\(left) · \(right)"
  }

  private struct HookVariableFile: Codable {
    let variables: [HookVariableRecord]
  }

  private struct HookVariableRecord: Codable {
    let name: String
    let kind: HookVariableKind
    let description: String
    let providers: [HookVariableProvider]
    let note: String?

    func toDescriptor() -> HookVariableDescriptor {
      HookVariableDescriptor(
        name: name,
        kind: kind,
        description: description,
        providers: Set(providers),
        note: note
      )
    }
  }

  private static func loadBundledVariables() -> [HookVariableDescriptor]? {
    let bundle = Bundle.main
    var urls: [URL] = []
    if let url = bundle.url(forResource: "hook-variables", withExtension: "json") {
      urls.append(url)
    }
    if let url = bundle.url(
      forResource: "hook-variables",
      withExtension: "json",
      subdirectory: "payload"
    ) {
      urls.append(url)
    }
    for url in urls {
      guard let data = try? Data(contentsOf: url) else { continue }
      let decoder = JSONDecoder()
      if let file = try? decoder.decode(HookVariableFile.self, from: data) {
        return file.variables.map { $0.toDescriptor() }
      }
      if let list = try? decoder.decode([HookVariableRecord].self, from: data) {
        return list.map { $0.toDescriptor() }
      }
    }
    return nil
  }

  private static let fallbackVariables: [HookVariableDescriptor] = claudeVariables + geminiVariables

  private static let claudeVariables: [HookVariableDescriptor] = [
    HookVariableDescriptor(
      name: "CLAUDE_PROJECT_DIR",
      kind: .env,
      description: "Project root directory",
      providers: [.claude],
      note: nil
    ),
    HookVariableDescriptor(
      name: "CLAUDE_ENV_FILE",
      kind: .env,
      description: "Path to environment file",
      providers: [.claude],
      note: "SessionStart/Setup"
    ),
    HookVariableDescriptor(
      name: "session_id",
      kind: .stdin,
      description: "Session identifier",
      providers: [.claude],
      note: nil
    ),
    HookVariableDescriptor(
      name: "transcript_path",
      kind: .stdin,
      description: "Transcript JSON path",
      providers: [.claude],
      note: nil
    ),
    HookVariableDescriptor(
      name: "cwd",
      kind: .stdin,
      description: "Current working directory",
      providers: [.claude],
      note: nil
    ),
    HookVariableDescriptor(
      name: "permission_mode",
      kind: .stdin,
      description: "Permission mode",
      providers: [.claude],
      note: nil
    ),
    HookVariableDescriptor(
      name: "hook_event_name",
      kind: .stdin,
      description: "Hook event name",
      providers: [.claude],
      note: nil
    ),
    HookVariableDescriptor(
      name: "tool_name",
      kind: .stdin,
      description: "Tool name",
      providers: [.claude],
      note: "PreToolUse/PermissionRequest/PostToolUse/PostToolUseFailure"
    ),
    HookVariableDescriptor(
      name: "tool_input",
      kind: .stdin,
      description: "Tool input JSON",
      providers: [.claude],
      note: "PreToolUse/PermissionRequest/PostToolUse/PostToolUseFailure"
    ),
    HookVariableDescriptor(
      name: "tool_use_id",
      kind: .stdin,
      description: "Tool use identifier",
      providers: [.claude],
      note: "PreToolUse/PermissionRequest/PostToolUse/PostToolUseFailure"
    ),
    HookVariableDescriptor(
      name: "tool_response",
      kind: .stdin,
      description: "Tool response JSON",
      providers: [.claude],
      note: "PostToolUse/PostToolUseFailure"
    ),
    HookVariableDescriptor(
      name: "message",
      kind: .stdin,
      description: "Notification message",
      providers: [.claude],
      note: "Notification"
    ),
    HookVariableDescriptor(
      name: "notification_type",
      kind: .stdin,
      description: "Notification type",
      providers: [.claude],
      note: "Notification"
    ),
    HookVariableDescriptor(
      name: "prompt",
      kind: .stdin,
      description: "User prompt",
      providers: [.claude],
      note: "UserPromptSubmit"
    ),
    HookVariableDescriptor(
      name: "stop_hook_active",
      kind: .stdin,
      description: "Stop hook state",
      providers: [.claude],
      note: "Stop/SubagentStop"
    ),
    HookVariableDescriptor(
      name: "agent_id",
      kind: .stdin,
      description: "Subagent identifier",
      providers: [.claude],
      note: "SubagentStart/SubagentStop"
    ),
    HookVariableDescriptor(
      name: "agent_transcript_path",
      kind: .stdin,
      description: "Subagent transcript JSON path",
      providers: [.claude],
      note: "SubagentStop"
    ),
    HookVariableDescriptor(
      name: "trigger",
      kind: .stdin,
      description: "Compaction trigger",
      providers: [.claude],
      note: "PreCompact/Setup"
    ),
    HookVariableDescriptor(
      name: "custom_instructions",
      kind: .stdin,
      description: "Custom instructions",
      providers: [.claude],
      note: "PreCompact"
    ),
    HookVariableDescriptor(
      name: "source",
      kind: .stdin,
      description: "Session start source",
      providers: [.claude],
      note: "SessionStart"
    ),
    HookVariableDescriptor(
      name: "model",
      kind: .stdin,
      description: "Model name",
      providers: [.claude],
      note: "SessionStart"
    ),
    HookVariableDescriptor(
      name: "agent_type",
      kind: .stdin,
      description: "Agent type",
      providers: [.claude],
      note: "SessionStart/SubagentStart"
    ),
    HookVariableDescriptor(
      name: "reason",
      kind: .stdin,
      description: "Session end reason",
      providers: [.claude],
      note: "SessionEnd"
    ),
  ]

  private static let geminiVariables: [HookVariableDescriptor] = [
    HookVariableDescriptor(
      name: "GEMINI_PROJECT_DIR",
      kind: .env,
      description: "Project root directory",
      providers: [.gemini],
      note: nil
    ),
    HookVariableDescriptor(
      name: "GEMINI_SESSION_ID",
      kind: .env,
      description: "Session identifier",
      providers: [.gemini],
      note: nil
    ),
    HookVariableDescriptor(
      name: "GEMINI_CWD",
      kind: .env,
      description: "Current working directory",
      providers: [.gemini],
      note: nil
    ),
    HookVariableDescriptor(
      name: "CLAUDE_PROJECT_DIR",
      kind: .env,
      description: "Alias for GEMINI_PROJECT_DIR",
      providers: [.gemini],
      note: "Gemini alias"
    ),
    HookVariableDescriptor(
      name: "session_id",
      kind: .stdin,
      description: "Session identifier",
      providers: [.gemini],
      note: nil
    ),
    HookVariableDescriptor(
      name: "transcript_path",
      kind: .stdin,
      description: "Transcript JSON path",
      providers: [.gemini],
      note: nil
    ),
    HookVariableDescriptor(
      name: "cwd",
      kind: .stdin,
      description: "Current working directory",
      providers: [.gemini],
      note: nil
    ),
    HookVariableDescriptor(
      name: "hook_event_name",
      kind: .stdin,
      description: "Hook event name",
      providers: [.gemini],
      note: nil
    ),
    HookVariableDescriptor(
      name: "timestamp",
      kind: .stdin,
      description: "Event timestamp",
      providers: [.gemini],
      note: nil
    ),
    HookVariableDescriptor(
      name: "tool_name",
      kind: .stdin,
      description: "Tool name",
      providers: [.gemini],
      note: "BeforeTool/AfterTool"
    ),
    HookVariableDescriptor(
      name: "tool_input",
      kind: .stdin,
      description: "Tool input JSON",
      providers: [.gemini],
      note: "BeforeTool/AfterTool"
    ),
    HookVariableDescriptor(
      name: "tool_response",
      kind: .stdin,
      description: "Tool response JSON",
      providers: [.gemini],
      note: "AfterTool"
    ),
    HookVariableDescriptor(
      name: "mcp_context",
      kind: .stdin,
      description: "MCP context JSON",
      providers: [.gemini],
      note: "BeforeTool/AfterTool"
    ),
    HookVariableDescriptor(
      name: "prompt",
      kind: .stdin,
      description: "User prompt",
      providers: [.gemini],
      note: "BeforeAgent/AfterAgent"
    ),
    HookVariableDescriptor(
      name: "prompt_response",
      kind: .stdin,
      description: "Agent response",
      providers: [.gemini],
      note: "AfterAgent"
    ),
    HookVariableDescriptor(
      name: "stop_hook_active",
      kind: .stdin,
      description: "Stop hook state",
      providers: [.gemini],
      note: "AfterAgent"
    ),
    HookVariableDescriptor(
      name: "llm_request",
      kind: .stdin,
      description: "Model request JSON",
      providers: [.gemini],
      note: "BeforeModel/BeforeToolSelection/AfterModel"
    ),
    HookVariableDescriptor(
      name: "llm_response",
      kind: .stdin,
      description: "Model response JSON",
      providers: [.gemini],
      note: "AfterModel"
    ),
    HookVariableDescriptor(
      name: "source",
      kind: .stdin,
      description: "Session start source",
      providers: [.gemini],
      note: "SessionStart"
    ),
    HookVariableDescriptor(
      name: "reason",
      kind: .stdin,
      description: "Session end reason",
      providers: [.gemini],
      note: "SessionEnd"
    ),
    HookVariableDescriptor(
      name: "notification_type",
      kind: .stdin,
      description: "Notification type",
      providers: [.gemini],
      note: "Notification"
    ),
    HookVariableDescriptor(
      name: "message",
      kind: .stdin,
      description: "Notification message",
      providers: [.gemini],
      note: "Notification"
    ),
    HookVariableDescriptor(
      name: "details",
      kind: .stdin,
      description: "Notification details JSON",
      providers: [.gemini],
      note: "Notification"
    ),
    HookVariableDescriptor(
      name: "trigger",
      kind: .stdin,
      description: "Compression trigger",
      providers: [.gemini],
      note: "PreCompress"
    ),
  ]
}

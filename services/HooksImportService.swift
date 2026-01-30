import Foundation

enum HooksImportService {
  static func scan(scope: ExtensionsImportScope) async -> [HookImportCandidate] {
    switch scope {
    case .home:
      return await scanHome()
    case .project:
      return []
    }
  }

  private static func scanHome() async -> [HookImportCandidate] {
    var aggregated: [String: HookImportCandidate] = [:]

    // Codex notify -> Stop
    if SessionPreferencesStore.isCLIEnabled(.codex) {
      let codex = CodexConfigService()
      let notify = await codex.getNotifyArray()
      if let program = notify.first,
         !program.isEmpty,
         !program.contains("codmate-notify")
      {
        let args = Array(notify.dropFirst())
        let rule = HookRule(
          name: HookEventCatalog.defaultName(
            event: "Stop",
            matcher: nil,
            command: HookCommand(command: program, args: args.isEmpty ? nil : args)
          ),
          event: "Stop",
          commands: [HookCommand(command: program, args: args.isEmpty ? nil : args)],
          enabled: true,
          targets: HookTargets(codex: true, claude: false, gemini: false),
          source: "import"
        )
        upsertCandidate(
          into: &aggregated,
          rule: rule,
          provider: "Codex",
          sourcePath: CodexConfigService.Paths.default().configURL.path
        )
      }
    }

    // Claude hooks
    if SessionPreferencesStore.isCLIEnabled(.claude) {
      let claude = ClaudeSettingsService()
      let rules = await claude.importHooksAsCodMateRules()
      for rule in rules {
        upsertCandidate(
          into: &aggregated,
          rule: rule,
          provider: "Claude",
          sourcePath: ClaudeSettingsService.Paths.default().file.path
        )
      }
    }

    // Gemini hooks
    if SessionPreferencesStore.isCLIEnabled(.gemini) {
      let gemini = GeminiSettingsService()
      let rules = await gemini.importHooksAsCodMateRules()
      for rule in rules {
        upsertCandidate(
          into: &aggregated,
          rule: rule,
          provider: "Gemini",
          sourcePath: gemini.settingsFileURL.path
        )
      }
    }

    var candidates = Array(aggregated.values)
    // Detect name collisions within import list.
    let nameCounts = Dictionary(grouping: candidates, by: { $0.rule.name.lowercased() })
      .mapValues { $0.count }
    for idx in candidates.indices {
      let key = candidates[idx].rule.name.lowercased()
      candidates[idx].hasNameCollision = (nameCounts[key] ?? 0) > 1
    }

    return candidates.sorted { a, b in
      a.rule.name.localizedCaseInsensitiveCompare(b.rule.name) == .orderedAscending
    }
  }

  private static func upsertCandidate(
    into aggregated: inout [String: HookImportCandidate],
    rule: HookRule,
    provider: String,
    sourcePath: String
  ) {
    let signature = hookSignature(rule)
    let normalizedRule = normalizedImportRule(rule, provider: provider)
    if var existing = aggregated[signature] {
      // Merge sources and targets.
      if !existing.sources.contains(provider) {
        existing.sources.append(provider)
      }
      existing.sourcePaths[provider] = sourcePath
      existing.rule.targets = mergeTargets(existing.rule.targets, normalizedRule.targets)
      aggregated[signature] = existing
    } else {
      let candidate = HookImportCandidate(
        id: UUID(),
        rule: normalizedRule,
        sources: [provider],
        sourcePaths: [provider: sourcePath],
        isSelected: true,
        hasConflict: false,
        hasNameCollision: false,
        resolution: .skip,
        renameName: normalizedRule.name,
        signature: signature
      )
      aggregated[signature] = candidate
    }
  }

  private static func normalizedImportRule(_ rule: HookRule, provider: String) -> HookRule {
    var normalized = rule
    normalized.id = UUID().uuidString
    normalized.source = "import"
    normalized.createdAt = Date()
    normalized.updatedAt = Date()
    if normalized.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      normalized.name = HookEventCatalog.defaultName(
        event: normalized.event,
        matcher: normalized.matcher,
        command: normalized.commands.first
      )
    }
    switch provider {
    case "Codex":
      normalized.targets = HookTargets(codex: true, claude: false, gemini: false)
    case "Claude":
      normalized.targets = HookTargets(codex: false, claude: true, gemini: false)
    case "Gemini":
      normalized.targets = HookTargets(codex: false, claude: false, gemini: true)
    default:
      break
    }
    return normalized
  }

  private static func mergeTargets(_ lhs: HookTargets?, _ rhs: HookTargets?) -> HookTargets? {
    let a = lhs ?? HookTargets()
    let b = rhs ?? HookTargets()
    let merged = HookTargets(
      codex: a.codex || b.codex,
      claude: a.claude || b.claude,
      gemini: a.gemini || b.gemini
    )
    return merged.allEnabled ? nil : merged
  }

  static func hookSignature(_ rule: HookRule) -> String {
    let event = rule.event.trimmingCharacters(in: .whitespacesAndNewlines)
    let matcher = rule.matcher?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    let commands = rule.commands.map { cmd in
      let command = cmd.command.trimmingCharacters(in: .whitespacesAndNewlines)
      let args = (cmd.args ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\u{1f}")
      let envPairs = (cmd.env ?? [:]).sorted(by: { $0.key < $1.key })
        .map { "\($0.key)=\($0.value)" }
        .joined(separator: "\u{1f}")
      let timeout = cmd.timeoutMs.map(String.init) ?? ""
      return [command, args, envPairs, timeout].joined(separator: "\u{1e}")
    }
    return ([event, matcher] + commands).joined(separator: "\u{1d}")
  }
}


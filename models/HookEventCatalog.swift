import Foundation

struct HookEventMatcher: Identifiable, Hashable, Sendable {
  let value: String
  let description: String?
  let providers: Set<HookVariableProvider>?

  var id: String { value }
}

struct HookEventDescriptor: Identifiable, Hashable, Sendable {
  let name: String
  let description: String
  let providers: Set<HookVariableProvider>
  let aliases: [HookVariableProvider: String]
  let supportsMatcher: Bool
  let matchers: [HookEventMatcher]
  let note: String?

  var id: String { name }
}

struct HookEventProviderResolution: Sendable {
  let name: String
  let canonicalName: String
  let isKnown: Bool
  let isSupported: Bool
}

enum HookEventCatalog {
  static let all: [HookEventDescriptor] = {
    let bundled = loadBundledEvents() ?? fallbackEvents
    return merge(bundled)
  }()

  static var canonicalEvents: [String] { all.map(\.name) }

  static func descriptor(for eventName: String) -> HookEventDescriptor? {
    let trimmed = eventName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let match = all.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
      return match
    }
    return all.first(where: { descriptor in
      descriptor.aliases.values.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
    })
  }

  static func description(for eventName: String) -> String {
    guard let descriptor = descriptor(for: eventName) else {
      return "Custom event. Ensure the selected CLIs support this event name."
    }
    return descriptor.description
  }

  static func detailText(for eventName: String) -> String {
    guard let descriptor = descriptor(for: eventName) else {
      return "Custom event. Ensure the selected CLIs support this event name."
    }
    let parts = [descriptor.description, descriptor.note].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
    return parts.filter { !$0.isEmpty }.joined(separator: " ")
  }

  static func supportsMatcher(_ eventName: String) -> Bool {
    guard let descriptor = descriptor(for: eventName) else {
      return true
    }
    return descriptor.supportsMatcher
  }

  static func supportsMatcher(_ eventName: String, provider: HookVariableProvider) -> Bool {
    guard let descriptor = descriptor(for: eventName) else {
      return true
    }
    guard descriptor.supportsMatcher, descriptor.providers.contains(provider) else {
      return false
    }
    return matcherSupport(descriptor, provider: provider)
  }

  static func supportsMatcher(_ eventName: String, targets: HookTargets) -> Bool {
    let enabled = targets.enabledProviders()
    return enabled.contains { supportsMatcher(eventName, provider: $0) }
  }

  static func matchers(for eventName: String, targets: HookTargets? = nil) -> [HookEventMatcher] {
    guard let descriptor = descriptor(for: eventName) else { return [] }
    let base = descriptor.matchers
    guard let targets else { return base }
    let enabled = targets.enabledProviders()
    return base.filter { matcher in
      guard let providers = matcher.providers, !providers.isEmpty else { return true }
      return !providers.isDisjoint(with: enabled)
    }
  }

  static func matcherDescription(for eventName: String, matcher: String) -> String? {
    let trimmed = matcher.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return matchers(for: eventName).first(where: {
      $0.value.caseInsensitiveCompare(trimmed) == .orderedSame
    })?.description
  }

  static func resolveProviderEvent(_ eventName: String, for provider: HookVariableProvider) -> HookEventProviderResolution {
    let trimmed = eventName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return HookEventProviderResolution(
        name: trimmed,
        canonicalName: trimmed,
        isKnown: false,
        isSupported: false
      )
    }
    if let descriptor = descriptor(for: trimmed) {
      let supported = descriptor.providers.contains(provider)
      let name = descriptor.aliases[provider] ?? descriptor.name
      return HookEventProviderResolution(
        name: name,
        canonicalName: descriptor.name,
        isKnown: true,
        isSupported: supported
      )
    }
    return HookEventProviderResolution(
      name: trimmed,
      canonicalName: trimmed,
      isKnown: false,
      isSupported: true
    )
  }

  static func canonicalName(for eventName: String, provider: HookVariableProvider) -> String {
    resolveProviderEvent(eventName, for: provider).canonicalName
  }

  static func defaultName(event: String, matcher: String?, command: HookCommand?) -> String {
    let e = event.trimmingCharacters(in: .whitespacesAndNewlines)
    let m = matcher?.trimmingCharacters(in: .whitespacesAndNewlines)
    let base = e.isEmpty ? "Hook" : e
    let cmd = command?.command.trimmingCharacters(in: .whitespacesAndNewlines)
    let cmdShort: String? = {
      guard let cmd, !cmd.isEmpty else { return nil }
      return URL(fileURLWithPath: cmd).lastPathComponent
    }()
    let parts = [base, (m?.isEmpty == false ? m : nil), cmdShort].compactMap { $0 }
    return parts.joined(separator: " · ")
  }

  private struct HookEventFile: Codable {
    let events: [HookEventRecord]
  }

  private struct HookEventRecord: Codable {
    let name: String
    let description: String
    let providers: [HookVariableProvider]
    let aliases: [String: String]?
    let supportsMatcher: Bool?
    let matchers: [HookEventMatcherRecord]?
    let note: String?

    func toDescriptor() -> HookEventDescriptor {
      let aliasMap: [HookVariableProvider: String] = (aliases ?? [:]).reduce(into: [:]) { out, pair in
        if let provider = HookVariableProvider(rawValue: pair.key) {
          out[provider] = pair.value
        }
      }
      let matcherList = (matchers ?? []).map { $0.toMatcher() }
      let matcherSupport = supportsMatcher ?? !matcherList.isEmpty
      return HookEventDescriptor(
        name: name,
        description: description,
        providers: Set(providers),
        aliases: aliasMap,
        supportsMatcher: matcherSupport,
        matchers: matcherList,
        note: note
      )
    }
  }

  private struct HookEventMatcherRecord: Codable {
    let value: String
    let description: String?
    let providers: [HookVariableProvider]?

    func toMatcher() -> HookEventMatcher {
      HookEventMatcher(
        value: value,
        description: description,
        providers: providers.map(Set.init)
      )
    }
  }

  private static func loadBundledEvents() -> [HookEventDescriptor]? {
    let bundle = Bundle.main
    var urls: [URL] = []
    if let url = bundle.url(forResource: "hook-events", withExtension: "json") {
      urls.append(url)
    }
    if let url = bundle.url(
      forResource: "hook-events",
      withExtension: "json",
      subdirectory: "payload"
    ) {
      urls.append(url)
    }
    for url in urls {
      guard let data = try? Data(contentsOf: url) else { continue }
      let decoder = JSONDecoder()
      if let file = try? decoder.decode(HookEventFile.self, from: data) {
        return file.events.map { $0.toDescriptor() }
      }
      if let list = try? decoder.decode([HookEventRecord].self, from: data) {
        return list.map { $0.toDescriptor() }
      }
    }
    return nil
  }

  private static func merge(_ events: [HookEventDescriptor]) -> [HookEventDescriptor] {
    var map: [String: HookEventDescriptor] = [:]
    var order: [String] = []
    for event in events {
      let key = event.name.lowercased()
      if map[key] == nil {
        order.append(key)
      }
      if let existing = map[key] {
        let providers = existing.providers.union(event.providers)
        let description = existing.description.count >= event.description.count ? existing.description : event.description
        var aliases = existing.aliases
        for (provider, alias) in event.aliases where aliases[provider] == nil {
          aliases[provider] = alias
        }
        let supportsMatcher = existing.supportsMatcher || event.supportsMatcher
        let matchers = mergeMatchers(existing.matchers, event.matchers)
        let note = mergeNotes(existing.note, event.note)
        map[key] = HookEventDescriptor(
          name: existing.name,
          description: description,
          providers: providers,
          aliases: aliases,
          supportsMatcher: supportsMatcher,
          matchers: matchers,
          note: note
        )
      } else {
        map[key] = event
      }
    }
    return order.compactMap { map[$0] }
  }

  private static func mergeMatchers(_ lhs: [HookEventMatcher], _ rhs: [HookEventMatcher]) -> [HookEventMatcher] {
    var map: [String: HookEventMatcher] = [:]
    for matcher in lhs + rhs {
      let key = matcher.value
      if let existing = map[key] {
        let providers = mergeProviderSets(existing.providers, matcher.providers)
        let description = existing.description ?? matcher.description
        map[key] = HookEventMatcher(value: key, description: description, providers: providers)
      } else {
        map[key] = matcher
      }
    }
    return map.values.sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }
  }

  private static func matcherSupport(_ descriptor: HookEventDescriptor, provider: HookVariableProvider) -> Bool {
    let matchers = descriptor.matchers
    guard !matchers.isEmpty else { return true }
    return matchers.contains { matcher in
      guard let providers = matcher.providers, !providers.isEmpty else { return true }
      return providers.contains(provider)
    }
  }

  private static func mergeProviderSets(
    _ lhs: Set<HookVariableProvider>?,
    _ rhs: Set<HookVariableProvider>?
  ) -> Set<HookVariableProvider>? {
    if lhs == nil { return rhs }
    if rhs == nil { return lhs }
    return lhs!.union(rhs!)
  }

  private static func mergeNotes(_ a: String?, _ b: String?) -> String? {
    let left = a?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let right = b?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if left.isEmpty { return right.isEmpty ? nil : right }
    if right.isEmpty { return left }
    if left == right { return left }
    return "\(left) · \(right)"
  }

  private static let fallbackEvents: [HookEventDescriptor] = [
    HookEventDescriptor(
      name: "Setup",
      description: "Load context and configure the environment during repository initialization or maintenance.",
      providers: [.claude],
      aliases: [:],
      supportsMatcher: false,
      matchers: [],
      note: nil
    ),
    HookEventDescriptor(
      name: "SessionStart",
      description: "Runs when a session starts.",
      providers: [.claude, .gemini],
      aliases: [:],
      supportsMatcher: true,
      matchers: [
        HookEventMatcher(value: "startup", description: "Session starts fresh.", providers: [.gemini]),
        HookEventMatcher(value: "resume", description: "Session resumes from history.", providers: [.gemini]),
        HookEventMatcher(value: "clear", description: "Session is cleared and restarted.", providers: [.gemini])
      ],
      note: nil
    ),
    HookEventDescriptor(
      name: "UserPromptSubmit",
      description: "Runs when the user submits a prompt.",
      providers: [.claude, .gemini],
      aliases: [.gemini: "BeforeAgent"],
      supportsMatcher: true,
      matchers: [
        HookEventMatcher(value: "*", description: "Wildcard matcher.", providers: [.gemini])
      ],
      note: nil
    ),
    HookEventDescriptor(
      name: "PreToolUse",
      description: "Runs before a tool is called.",
      providers: [.claude, .gemini],
      aliases: [.gemini: "BeforeTool"],
      supportsMatcher: true,
      matchers: [
        HookEventMatcher(value: "Bash", description: "Tool name.", providers: [.claude]),
        HookEventMatcher(value: "Write", description: "Tool name.", providers: [.claude]),
        HookEventMatcher(value: "Edit", description: "Tool name.", providers: [.claude]),
        HookEventMatcher(value: "Read", description: "Tool name.", providers: [.claude]),
        HookEventMatcher(value: "Write|Edit", description: "Regex example.", providers: [.claude]),
        HookEventMatcher(value: "Notebook.*", description: "Regex example.", providers: [.claude]),
        HookEventMatcher(value: "*", description: "Wildcard matcher.", providers: [.gemini]),
        HookEventMatcher(value: "write_.*", description: "Regex example.", providers: [.gemini])
      ],
      note: nil
    ),
    HookEventDescriptor(
      name: "PermissionRequest",
      description: "Runs when a tool permission is requested.",
      providers: [.claude],
      aliases: [:],
      supportsMatcher: true,
      matchers: [
        HookEventMatcher(value: "Bash", description: "Tool name.", providers: [.claude]),
        HookEventMatcher(value: "Write", description: "Tool name.", providers: [.claude]),
        HookEventMatcher(value: "Edit", description: "Tool name.", providers: [.claude]),
        HookEventMatcher(value: "Read", description: "Tool name.", providers: [.claude]),
        HookEventMatcher(value: "Write|Edit", description: "Regex example.", providers: [.claude]),
        HookEventMatcher(value: "Notebook.*", description: "Regex example.", providers: [.claude])
      ],
      note: nil
    ),
    HookEventDescriptor(
      name: "PostToolUse",
      description: "Runs after a tool call succeeds.",
      providers: [.claude, .gemini],
      aliases: [.gemini: "AfterTool"],
      supportsMatcher: true,
      matchers: [
        HookEventMatcher(value: "Bash", description: "Tool name.", providers: [.claude]),
        HookEventMatcher(value: "Write", description: "Tool name.", providers: [.claude]),
        HookEventMatcher(value: "Edit", description: "Tool name.", providers: [.claude]),
        HookEventMatcher(value: "Read", description: "Tool name.", providers: [.claude]),
        HookEventMatcher(value: "Write|Edit", description: "Regex example.", providers: [.claude]),
        HookEventMatcher(value: "Notebook.*", description: "Regex example.", providers: [.claude]),
        HookEventMatcher(value: "*", description: "Wildcard matcher.", providers: [.gemini]),
        HookEventMatcher(value: "write_.*", description: "Regex example.", providers: [.gemini])
      ],
      note: nil
    ),
    HookEventDescriptor(
      name: "PostToolUseFailure",
      description: "Runs after a tool call fails.",
      providers: [.claude],
      aliases: [:],
      supportsMatcher: false,
      matchers: [],
      note: nil
    ),
    HookEventDescriptor(
      name: "SubagentStart",
      description: "Runs when a subagent (Task tool call) starts.",
      providers: [.claude],
      aliases: [:],
      supportsMatcher: false,
      matchers: [],
      note: nil
    ),
    HookEventDescriptor(
      name: "SubagentStop",
      description: "Runs when a subagent (Task tool call) finishes.",
      providers: [.claude],
      aliases: [:],
      supportsMatcher: false,
      matchers: [],
      note: "Prompt-based hooks are supported for this event."
    ),
    HookEventDescriptor(
      name: "Stop",
      description: "Runs when the assistant finishes responding.",
      providers: [.claude, .gemini, .codex],
      aliases: [.gemini: "AfterAgent"],
      supportsMatcher: true,
      matchers: [
        HookEventMatcher(value: "*", description: "Wildcard matcher.", providers: [.gemini])
      ],
      note: "Prompt-based hooks are supported for this event."
    ),
    HookEventDescriptor(
      name: "PreCompact",
      description: "Runs before context compaction.",
      providers: [.claude, .gemini],
      aliases: [.gemini: "PreCompress"],
      supportsMatcher: true,
      matchers: [
        HookEventMatcher(value: "*", description: "Wildcard matcher.", providers: [.gemini])
      ],
      note: nil
    ),
    HookEventDescriptor(
      name: "SessionEnd",
      description: "Runs when a session ends.",
      providers: [.claude, .gemini],
      aliases: [:],
      supportsMatcher: true,
      matchers: [
        HookEventMatcher(value: "exit", description: "Session exits.", providers: [.gemini]),
        HookEventMatcher(value: "clear", description: "Session is cleared.", providers: [.gemini])
      ],
      note: nil
    ),
    HookEventDescriptor(
      name: "Notification",
      description: "Runs when the CLI raises a notification.",
      providers: [.claude, .gemini],
      aliases: [:],
      supportsMatcher: true,
      matchers: [
        HookEventMatcher(value: "*", description: "Wildcard matcher.", providers: [.gemini])
      ],
      note: nil
    ),
    HookEventDescriptor(
      name: "BeforeModel",
      description: "Runs before a request is sent to the model.",
      providers: [.gemini],
      aliases: [:],
      supportsMatcher: true,
      matchers: [],
      note: nil
    ),
    HookEventDescriptor(
      name: "AfterModel",
      description: "Runs after the model responds, before tool selection.",
      providers: [.gemini],
      aliases: [:],
      supportsMatcher: true,
      matchers: [],
      note: nil
    ),
    HookEventDescriptor(
      name: "BeforeToolSelection",
      description: "Runs before tool selection.",
      providers: [.gemini],
      aliases: [:],
      supportsMatcher: true,
      matchers: [],
      note: nil
    ),
  ]
}

private extension HookTargets {
  func enabledProviders() -> Set<HookVariableProvider> {
    var providers: Set<HookVariableProvider> = []
    if codex { providers.insert(.codex) }
    if claude { providers.insert(.claude) }
    if gemini { providers.insert(.gemini) }
    return providers
  }
}

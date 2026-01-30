import Foundation

actor GeminiSettingsService {
  struct Paths {
    let directory: URL
    let file: URL

    static func `default`() -> Paths {
      let home = SessionPreferencesStore.getRealUserHomeURL()
      let dir = home.appendingPathComponent(".gemini", isDirectory: true)
      return Paths(directory: dir, file: dir.appendingPathComponent("settings.json", isDirectory: false))
    }
  }

  struct Snapshot: Sendable {
    var previewFeatures: Bool?
    var vimMode: Bool?
    var disableAutoUpdate: Bool?
    var enablePromptCompletion: Bool?
    var sessionRetentionEnabled: Bool?
    var modelName: String?
    var maxSessionTurns: Int?
    var compressionThreshold: Double?
    var skipNextSpeakerCheck: Bool?
  }

  struct NotificationHooksStatus: Sendable {
    var hookInstalled: Bool
    var hooksEnabled: Bool
  }

  private typealias JSONObject = [String: Any]
  private let codMateHookURLPrefix = "codmate://notify?source=gemini&event="
  private let codMateManagedHookNamePrefix = "codmate-hook:"

  private enum HookEvent: String {
    case permission
  }

  private struct HookPayload {
    var title: String
    var body: String
  }

  private let paths: Paths
  private let fm: FileManager

  init(paths: Paths = .default(), fileManager: FileManager = .default) {
    self.paths = paths
    self.fm = fileManager
  }

  nonisolated var settingsFileURL: URL { paths.file }

  // MARK: - Public API

  func loadSnapshot() -> Snapshot {
    let object = loadJSONObject()
    return Snapshot(
      previewFeatures: boolValue(in: object, path: ["general", "previewFeatures"]),
      vimMode: boolValue(in: object, path: ["general", "vimMode"]),
      disableAutoUpdate: boolValue(in: object, path: ["general", "disableAutoUpdate"]),
      enablePromptCompletion: boolValue(in: object, path: ["general", "enablePromptCompletion"]),
      sessionRetentionEnabled: boolValue(in: object, path: ["general", "sessionRetention", "enabled"]),
      modelName: stringValue(in: object, path: ["model", "name"]),
      maxSessionTurns: intValue(in: object, path: ["model", "maxSessionTurns"]),
      compressionThreshold: doubleValue(in: object, path: ["model", "compressionThreshold"]),
      skipNextSpeakerCheck: boolValue(in: object, path: ["model", "skipNextSpeakerCheck"])
    )
  }

  func loadRawText() -> String {
    (try? String(contentsOf: paths.file, encoding: .utf8)) ?? ""
  }

  func setBool(_ value: Bool, at path: [String]) throws {
    try setValue(value, at: path)
  }

  func setOptionalBool(_ value: Bool?, at path: [String]) throws {
    try setValue(value, at: path)
  }

  func setInt(_ value: Int, at path: [String]) throws {
    try setValue(value, at: path)
  }

  func setDouble(_ value: Double, at path: [String]) throws {
    try setValue(value, at: path)
  }

  func setOptionalString(_ value: String?, at path: [String]) throws {
    try setValue(value, at: path)
  }

  // MARK: - Notification hooks

  func codMateNotificationHooksStatus() -> NotificationHooksStatus {
    let object = loadJSONObject()
    let hooksEnabled = boolValue(in: object, path: ["tools", "enableHooks"]) ?? false
    guard let hooks = object["hooks"] as? JSONObject else {
      return NotificationHooksStatus(hookInstalled: false, hooksEnabled: hooksEnabled)
    }
    let installed = containsCodMateHook(in: hooks)
    return NotificationHooksStatus(hookInstalled: installed, hooksEnabled: hooksEnabled)
  }

  func setCodMateNotificationHooks(enabled: Bool) throws {
    var object = loadJSONObject()
    var hooks = object["hooks"] as? JSONObject ?? [:]
    hooks = updateNotificationHooksContainer(hooks, enabled: enabled)
    if hooks.isEmpty {
      object.removeValue(forKey: "hooks")
    } else {
      object["hooks"] = hooks
    }
    if enabled {
      update(&object, path: ["tools", "enableMessageBusIntegration"], value: true)
      update(&object, path: ["tools", "enableHooks"], value: true)
    }
    try writeJSONObject(object)
  }

  // MARK: - User hooks (CodMate Extensions)
  func applyHooksFromCodMate(_ rules: [HookRule]) throws -> [HookSyncWarning] {
    var warnings: [HookSyncWarning] = []
    var object = loadJSONObject()
    var hooks = object["hooks"] as? JSONObject ?? [:]

    hooks = pruneCodMateManagedHooks(hooks)

    let filtered = rules.filter { $0.isEnabled(for: .gemini) }
    for rule in filtered {
      let rawEvent = rule.event.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !rawEvent.isEmpty else { continue }
      let resolution = HookEventCatalog.resolveProviderEvent(rawEvent, for: .gemini)
      if resolution.isKnown, !resolution.isSupported {
        warnings.append(HookSyncWarning(
          provider: .gemini,
          message: "Gemini CLI does not support hook event \"\(rawEvent)\"; skipping \"\(rule.name)\"."
        ))
        continue
      }
      let event = resolution.name

      let supportsMatcher = HookEventCatalog.supportsMatcher(resolution.canonicalName, provider: .gemini)
      let matcherText = rule.matcher?.trimmingCharacters(in: .whitespacesAndNewlines)
      let matcher: String = {
        if supportsMatcher {
          return (matcherText?.isEmpty == false ? matcherText! : "*")
        }
        if matcherText?.isEmpty == false {
          warnings.append(HookSyncWarning(
            provider: .gemini,
            message: "Gemini hook event \"\(event)\" does not support matcher; ignoring matcher for \"\(rule.name)\"."
          ))
        }
        return "*"
      }()

      var hookObjects: [JSONObject] = []
      for (index, cmd) in rule.commands.enumerated() {
        let program = cmd.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !program.isEmpty else { continue }
        var hook: JSONObject = [
          "name": "\(codMateManagedHookNamePrefix)\(rule.id):\(index)",
          "type": "command",
          "command": program,
        ]
        if let args = cmd.args, !args.isEmpty { hook["args"] = args }
        if let timeout = cmd.timeoutMs { hook["timeout"] = timeout }
        if let env = cmd.env, !env.isEmpty {
          warnings.append(HookSyncWarning(
            provider: .gemini,
            message: "Gemini CLI hook commands do not support env in settings.json; ignoring env for \"\(rule.name)\"."
          ))
        }
        hookObjects.append(hook)
      }
      guard !hookObjects.isEmpty else { continue }

      var entries = (hooks[event] as? [JSONObject]) ?? []
      if let idx = entries.firstIndex(where: { entry in
        let existing = (entry["matcher"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (existing?.isEmpty == false ? existing : "*") == matcher
      }) {
        var entry = entries[idx]
        var nested = (entry["hooks"] as? [JSONObject]) ?? []
        nested.append(contentsOf: hookObjects)
        entry["hooks"] = nested
        entry["matcher"] = matcher
        entries[idx] = entry
      } else {
        entries.append([
          "matcher": matcher,
          "hooks": hookObjects
        ])
      }
      hooks[event] = entries
    }

    if hooks.isEmpty {
      object.removeValue(forKey: "hooks")
    } else {
      object["hooks"] = hooks
    }

    if !filtered.isEmpty {
      update(&object, path: ["tools", "enableMessageBusIntegration"], value: true)
      update(&object, path: ["tools", "enableHooks"], value: true)
    }

    try writeJSONObject(object)
    return warnings
  }

  func importHooksAsCodMateRules() -> [HookRule] {
    let object = loadJSONObject()
    guard let hooks = object["hooks"] as? JSONObject else { return [] }
    var rules: [HookRule] = []
    for (event, value) in hooks {
      guard let entries = value as? [JSONObject] else { continue }
      let canonicalEvent = HookEventCatalog.canonicalName(for: event, provider: .gemini)
      for entry in entries {
        let matcher = (entry["matcher"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let hookList = entry["hooks"] as? [JSONObject] else { continue }

        var commands: [HookCommand] = []
        for hook in hookList {
          guard (hook["type"] as? String) == "command" else { continue }
          guard let command = hook["command"] as? String else { continue }
          if command.contains(codMateHookURLPrefix) { continue } // managed by Notifications UI
          if (hook["name"] as? String) == "codmate-notify" { continue }
          let args = hook["args"] as? [String]
          let timeout = (hook["timeout"] as? Int) ?? (hook["timeout"] as? NSNumber)?.intValue
          commands.append(HookCommand(command: command, args: args, env: nil, timeoutMs: timeout))
        }

        guard !commands.isEmpty else { continue }
        let name = HookEventCatalog.defaultName(event: canonicalEvent, matcher: matcher, command: commands.first)
        let targets = HookTargets(codex: false, claude: false, gemini: true)
        rules.append(HookRule(
          name: name,
          event: canonicalEvent,
          matcher: (matcher?.isEmpty == false ? matcher : nil),
          commands: commands,
          enabled: true,
          targets: targets,
          source: "import"
        ))
      }
    }
    return rules
  }

  // MARK: - MCP Servers

  func applyMCPServers(_ servers: [MCPServer]) throws {
    if !SessionPreferencesStore.isCLIEnabled(.gemini) { return }
    var object = loadJSONObject()
    let enabled = servers.enabledServers(for: .gemini)
    
    if enabled.isEmpty {
      object.removeValue(forKey: "mcpServers")
    } else {
      var mcpServers: JSONObject = [:]
      for server in enabled {
        var config: JSONObject = [:]
        if let command = server.command {
          config["command"] = command
        }
        if let args = server.args, !args.isEmpty {
          config["args"] = args
        }
        if let env = server.env, !env.isEmpty {
          config["env"] = env
        }
        if let url = server.url {
          config["url"] = url
        }
        if let headers = server.headers, !headers.isEmpty {
          config["headers"] = headers
        }
        mcpServers[server.name] = config
      }
      object["mcpServers"] = mcpServers
    }
    
    try writeJSONObject(object)
  }

  // MARK: - Internal helpers

  private func loadJSONObject() -> JSONObject {
    guard fm.fileExists(atPath: paths.file.path) else { return [:] }
    guard let text = try? String(contentsOf: paths.file, encoding: .utf8) else { return [:] }
    if let object = parseJSONObject(from: text) {
      return object
    }
    return [:]
  }

  private func parseJSONObject(from text: String) -> JSONObject? {
    if let data = text.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data, options: []),
      let dict = json as? JSONObject
    {
      return dict
    }
    let stripped = stripComments(from: text)
    guard let data = stripped.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data, options: []),
      let dict = json as? JSONObject
    else {
      return nil
    }
    return dict
  }

  private func writeJSONObject(_ object: JSONObject) throws {
    try fm.createDirectory(at: paths.directory, withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: paths.file, options: .atomic)
  }

  private func setValue(_ value: Any?, at path: [String]) throws {
    var object = loadJSONObject()
    update(&object, path: path, value: value)
    try writeJSONObject(object)
  }

  private func update(_ object: inout JSONObject, path: [String], value: Any?) {
    guard let first = path.first else { return }
    if path.count == 1 {
      if let value {
        object[first] = value
      } else {
        object.removeValue(forKey: first)
      }
      return
    }
    var child = object[first] as? JSONObject ?? JSONObject()
    update(&child, path: Array(path.dropFirst()), value: value)
    if child.isEmpty {
      object.removeValue(forKey: first)
    } else {
      object[first] = child
    }
  }

  private func value(in object: JSONObject, path: [String]) -> Any? {
    var current: Any? = object
    for component in path {
      guard let dict = current as? JSONObject else { return nil }
      current = dict[component]
    }
    return current
  }

  private func boolValue(in object: JSONObject, path: [String]) -> Bool? {
    if let v = value(in: object, path: path) as? Bool {
      return v
    }
    if let str = value(in: object, path: path) as? String {
      return (str as NSString).boolValue
    }
    return nil
  }

  private func stringValue(in object: JSONObject, path: [String]) -> String? {
    value(in: object, path: path) as? String
  }

  private func intValue(in object: JSONObject, path: [String]) -> Int? {
    if let v = value(in: object, path: path) as? Int { return v }
    if let number = value(in: object, path: path) as? NSNumber { return number.intValue }
    if let str = value(in: object, path: path) as? String { return Int(str) }
    return nil
  }

  private func doubleValue(in object: JSONObject, path: [String]) -> Double? {
    if let v = value(in: object, path: path) as? Double { return v }
    if let number = value(in: object, path: path) as? NSNumber { return number.doubleValue }
    if let str = value(in: object, path: path) as? String { return Double(str) }
    return nil
  }

  private func containsCodMateHook(in hooks: JSONObject) -> Bool {
    guard let entries = hooks["Notification"] as? [JSONObject] else { return false }
    let marker = "\(codMateHookURLPrefix)\(HookEvent.permission.rawValue)"
    for entry in entries {
      guard let nested = entry["hooks"] as? [JSONObject] else { continue }
      if nested.contains(where: { ($0["command"] as? String)?.contains(marker) == true }) {
        return true
      }
    }
    return false
  }

  private func pruneCodMateManagedHooks(_ hooks: JSONObject) -> JSONObject {
    var out: JSONObject = [:]
    for (event, value) in hooks {
      guard let entries = value as? [JSONObject] else {
        out[event] = value
        continue
      }

      var newEntries: [JSONObject] = []
      for var entry in entries {
        guard var nested = entry["hooks"] as? [JSONObject] else {
          newEntries.append(entry)
          continue
        }
        nested.removeAll { hook in
          guard let name = hook["name"] as? String else { return false }
          return name.hasPrefix(codMateManagedHookNamePrefix)
        }
        guard !nested.isEmpty else { continue }
        entry["hooks"] = nested
        newEntries.append(entry)
      }
      if !newEntries.isEmpty {
        out[event] = newEntries
      }
    }
    return out
  }

  private func updateNotificationHooksContainer(_ hooks: JSONObject, enabled: Bool) -> JSONObject {
    var container = hooks
    var entries = (container["Notification"] as? [JSONObject]) ?? []
    let marker = "\(codMateHookURLPrefix)\(HookEvent.permission.rawValue)"
    entries.removeAll { entry in
      guard let nested = entry["hooks"] as? [JSONObject] else { return false }
      return nested.contains { ($0["command"] as? String)?.contains(marker) == true }
    }
    if enabled, let urlString = hookURL(for: .permission) {
      let command = "/usr/bin/open -j \"\(urlString)\""
      entries.append([
        "matcher": "*",
        "hooks": [[
          "name": "codmate-notify",
          "type": "command",
          "command": command
        ]]
      ])
    }
    if entries.isEmpty {
      container.removeValue(forKey: "Notification")
    } else {
      container["Notification"] = entries
    }
    return container
  }

  private func hookURL(for event: HookEvent) -> String? {
    let payload = hookPayload(for: event)
    var comps = URLComponents()
    comps.scheme = "codmate"
    comps.host = "notify"
    var query: [URLQueryItem] = [
      URLQueryItem(name: "source", value: "gemini"),
      URLQueryItem(name: "event", value: event.rawValue)
    ]
    if let titleData = payload.title.data(using: .utf8) {
      query.append(URLQueryItem(name: "title64", value: titleData.base64EncodedString()))
    }
    if let bodyData = payload.body.data(using: .utf8) {
      query.append(URLQueryItem(name: "body64", value: bodyData.base64EncodedString()))
    }
    comps.queryItems = query
    return comps.url?.absoluteString
  }

  private func hookPayload(for event: HookEvent) -> HookPayload {
    switch event {
    case .permission:
      return HookPayload(
        title: "Gemini CLI",
        body: "Gemini requires approval. Return to the Gemini window to respond."
      )
    }
  }

  private func stripComments(from text: String) -> String {
    let scalars = Array(text.unicodeScalars)
    var result: [UnicodeScalar] = []
    var index = 0
    var inString = false
    var escapeNext = false
    let quote: UnicodeScalar = "\""
    let slash: UnicodeScalar = "/"
    let newlineScalar = "\n".unicodeScalars.first!

    while index < scalars.count {
      let scalar = scalars[index]

      if inString {
        result.append(scalar)
        if escapeNext {
          escapeNext = false
        } else if scalar == "\\" {
          escapeNext = true
        } else if scalar == quote {
          inString = false
        }
        index += 1
        continue
      }

      if scalar == quote {
        inString = true
        result.append(scalar)
        index += 1
        continue
      }

      if scalar == slash && index + 1 < scalars.count {
        let next = scalars[index + 1]
        if next == slash {
          index += 2
          while index < scalars.count, scalars[index] != newlineScalar {
            index += 1
          }
          if index < scalars.count {
            result.append(scalars[index])
            index += 1
          }
          continue
        } else if next == "*" {
          index += 2
          while index + 1 < scalars.count {
            if scalars[index] == "*" && scalars[index + 1] == slash {
              index += 2
              break
            }
            index += 1
          }
          continue
        }
      }

      result.append(scalar)
      index += 1
    }

    return String(String.UnicodeScalarView(result))
  }
}

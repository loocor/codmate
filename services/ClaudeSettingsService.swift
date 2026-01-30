import Foundation

// MARK: - Claude Code user settings writer (~/.claude/settings.json)

actor ClaudeSettingsService {
    struct Paths {
        let dir: URL
        let file: URL
        static func `default`() -> Paths {
            let home = SessionPreferencesStore.getRealUserHomeURL()
            let dir = home.appendingPathComponent(".claude", isDirectory: true)
            return Paths(dir: dir, file: dir.appendingPathComponent("settings.json", isDirectory: false))
        }
    }

    // MARK: - Runtime composite
    struct Runtime: Sendable {
        var permissionMode: String? // default/acceptEdits/bypassPermissions/plan
        var skipPermissions: Bool
        var allowSkipPermissions: Bool
        var debug: Bool
        var debugFilter: String?
        var verbose: Bool
        var ide: Bool
        var strictMCP: Bool
        var fallbackModel: String?
        var allowedTools: String?
        var disallowedTools: String?
        var addDirs: [String]?
    }

    struct NotificationHooksStatus: Sendable {
        var permissionHookInstalled: Bool
        var completionHookInstalled: Bool
    }

    private enum HookEvent: String {
        case permission
        case complete
    }

    private struct HookPayload {
        var title: String
        var body: String
    }

    private let codMateHookURLPrefix = "codmate://notify?source=claude&event="
    private let claudeNotificationKey = "Notification"
    private let claudeStopKey = "Stop"
    private let codMateManagedHookNamePrefix = "codmate-hook:"

    func applyRuntime(_ r: Runtime) throws {
        var obj = loadObject()
        func setOrRemove(_ key: String, _ value: Any?) {
            if let v = value {
                obj[key] = v
            } else {
                obj.removeValue(forKey: key)
            }
        }
        // permissionMode: omit when default
        let pm = (r.permissionMode == nil || r.permissionMode == "default") ? nil : r.permissionMode
        setOrRemove("permissionMode", pm)
        // booleans: only store when true to keep file light
        setOrRemove("skipPermissions", r.skipPermissions ? true : nil)
        setOrRemove("allowSkipPermissions", r.allowSkipPermissions ? true : nil)
        setOrRemove("debug", r.debug ? true : nil)
        let df = (r.debugFilter?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? r.debugFilter : nil
        setOrRemove("debugFilter", df)
        setOrRemove("verbose", r.verbose ? true : nil)
        setOrRemove("ide", r.ide ? true : nil)
        setOrRemove("strictMCP", r.strictMCP ? true : nil)
        let fb = (r.fallbackModel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? r.fallbackModel : nil
        setOrRemove("fallbackModel", fb)
        let at = (r.allowedTools?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? r.allowedTools : nil
        let dt = (r.disallowedTools?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? r.disallowedTools : nil
        setOrRemove("allowedTools", at)
        setOrRemove("disallowedTools", dt)
        let dirs = (r.addDirs?.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        setOrRemove("addDirs", (dirs?.isEmpty == false) ? dirs : nil)
        try writeObject(obj)
    }

    // MARK: - Notification hooks (CodMate-managed)
    func codMateNotificationHooksStatus() -> NotificationHooksStatus {
        let obj = loadObject()
        guard let hooks = obj["hooks"] as? [String: Any] else {
            return NotificationHooksStatus(permissionHookInstalled: false, completionHookInstalled: false)
        }
        return NotificationHooksStatus(
            permissionHookInstalled: containsCodMateHook(in: hooks, key: claudeNotificationKey, event: .permission),
            completionHookInstalled: containsCodMateHook(in: hooks, key: claudeStopKey, event: .complete)
        )
    }

    func setCodMateNotificationHooks(enabled: Bool) throws {
        var obj = loadObject()
        var hooks = obj["hooks"] as? [String: Any] ?? [:]
        hooks = updateHooksContainer(
            hooks,
            key: claudeNotificationKey,
            event: .permission,
            enabled: enabled
        )
        hooks = updateHooksContainer(
            hooks,
            key: claudeStopKey,
            event: .complete,
            enabled: enabled
        )
        if hooks.isEmpty {
            obj.removeValue(forKey: "hooks")
        } else {
            obj["hooks"] = hooks
        }
        try writeObject(obj)
    }

    // MARK: - User hooks (CodMate Extensions)
    func applyHooksFromCodMate(_ rules: [HookRule]) throws -> [HookSyncWarning] {
        var obj = loadObject()
        if (obj["allowManagedHooksOnly"] as? Bool) == true {
            return [
                HookSyncWarning(
                    provider: .claude,
                    message: "Claude Code settings has allowManagedHooksOnly=true; skipping hooks apply."
                )
            ]
        }

        var warnings: [HookSyncWarning] = []
        var hooks = obj["hooks"] as? [String: Any] ?? [:]

        // Remove previously applied CodMate-managed hooks (by name prefix).
        hooks = pruneCodMateManagedHooks(hooks)

        let filtered = rules.filter { $0.isEnabled(for: .claude) }
        for rule in filtered {
            let rawEvent = rule.event.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawEvent.isEmpty else { continue }
            let resolution = HookEventCatalog.resolveProviderEvent(rawEvent, for: .claude)
            if resolution.isKnown, !resolution.isSupported {
                warnings.append(HookSyncWarning(
                    provider: .claude,
                    message: "Claude Code does not support hook event \"\(rawEvent)\"; skipping \"\(rule.name)\"."
                ))
                continue
            }
            let event = resolution.name

            let supportsMatcher = HookEventCatalog.supportsMatcher(resolution.canonicalName, provider: .claude)
            let matcherText = rule.matcher?.trimmingCharacters(in: .whitespacesAndNewlines)
            let matcher = supportsMatcher ? (matcherText?.isEmpty == false ? matcherText : nil) : nil
            if !supportsMatcher, matcherText?.isEmpty == false {
                warnings.append(HookSyncWarning(
                    provider: .claude,
                    message: "Claude hook event \"\(event)\" does not support matcher; ignoring matcher for \"\(rule.name)\"."
                ))
            }

            var hookObjects: [[String: Any]] = []
            for (index, cmd) in rule.commands.enumerated() {
                let program = cmd.command.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !program.isEmpty else { continue }
                var hook: [String: Any] = [
                    "type": "command",
                    "command": program,
                    "name": "\(codMateManagedHookNamePrefix)\(rule.id):\(index)"
                ]
                if let args = cmd.args, !args.isEmpty { hook["args"] = args }
                if let timeout = cmd.timeoutMs { hook["timeout"] = timeout }
                if let env = cmd.env, !env.isEmpty {
                    warnings.append(HookSyncWarning(
                        provider: .claude,
                        message: "Claude Code hook commands do not support env in settings.json; ignoring env for \"\(rule.name)\"."
                    ))
                }
                hookObjects.append(hook)
            }
            guard !hookObjects.isEmpty else { continue }

            var entries = (hooks[event] as? [[String: Any]]) ?? []
            let matcherKey: String? = matcher

            if let idx = entries.firstIndex(where: { entry in
                let existing = (entry["matcher"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let existingKey = (existing?.isEmpty == false) ? existing : nil
                return existingKey == matcherKey
            }) {
                var entry = entries[idx]
                var nested = (entry["hooks"] as? [[String: Any]]) ?? []
                nested.append(contentsOf: hookObjects)
                entry["hooks"] = nested
                entries[idx] = entry
            } else {
                var entry: [String: Any] = ["hooks": hookObjects]
                if let matcherKey { entry["matcher"] = matcherKey }
                entries.append(entry)
            }

            hooks[event] = entries
        }

        if hooks.isEmpty {
            obj.removeValue(forKey: "hooks")
        } else {
            obj["hooks"] = hooks
        }
        try writeObject(obj)
        return warnings
    }

    func importHooksAsCodMateRules() -> [HookRule] {
        let obj = loadObject()
        guard let hooks = obj["hooks"] as? [String: Any] else { return [] }
        var rules: [HookRule] = []

        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            let canonicalEvent = HookEventCatalog.canonicalName(for: event, provider: .claude)
            for entry in entries {
                let matcher = (entry["matcher"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let hookList = entry["hooks"] as? [[String: Any]] else { continue }

                var commands: [HookCommand] = []
                for hook in hookList {
                    guard (hook["type"] as? String) == "command" else { continue }
                    guard let command = hook["command"] as? String else { continue }
                    if command.contains(codMateHookURLPrefix) { continue } // managed by Notifications UI
                    let args = hook["args"] as? [String]
                    let timeout = (hook["timeout"] as? Int) ?? (hook["timeout"] as? NSNumber)?.intValue
                    commands.append(HookCommand(command: command, args: args, env: nil, timeoutMs: timeout))
                }
                guard !commands.isEmpty else { continue }
                let name = HookEventCatalog.defaultName(event: canonicalEvent, matcher: matcher, command: commands.first)
                let targets = HookTargets(codex: false, claude: true, gemini: false)
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

    private func pruneCodMateManagedHooks(_ hooks: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else {
                out[event] = value
                continue
            }
            var newEntries: [[String: Any]] = []
            for var entry in entries {
                guard var nested = entry["hooks"] as? [[String: Any]] else {
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

    private func containsCodMateHook(in hooks: [String: Any], key: String, event: HookEvent) -> Bool {
        guard let entries = hooks[key] as? [[String: Any]] else { return false }
        let marker = "\(codMateHookURLPrefix)\(event.rawValue)"
        for entry in entries {
            guard let nested = entry["hooks"] as? [[String: Any]] else { continue }
            if nested.contains(where: { ($0["command"] as? String)?.contains(marker) == true }) {
                return true
            }
        }
        return false
    }

    private func updateHooksContainer(
        _ hooks: [String: Any],
        key: String,
        event: HookEvent,
        enabled: Bool
    ) -> [String: Any] {
        var container = hooks
        var entries = (container[key] as? [[String: Any]]) ?? []
        let marker = "\(codMateHookURLPrefix)\(event.rawValue)"
        entries.removeAll { entry in
            guard let nested = entry["hooks"] as? [[String: Any]] else { return false }
            return nested.contains { ($0["command"] as? String)?.contains(marker) == true }
        }
        if enabled {
            if let urlString = hookURL(for: event) {
                // 使用 -j (隐藏启动) 而不是 -g (后台启动) 来防止 SwiftUI WindowGroup 自动创建新窗口
                let command = "/usr/bin/open -j \"\(urlString)\""
                entries.append(["hooks": [["type": "command", "command": command]]])
            }
        }
        if entries.isEmpty {
            container.removeValue(forKey: key)
        } else {
            container[key] = entries
        }
        return container
    }

    private func hookURL(for event: HookEvent) -> String? {
        let payload = hookPayload(for: event)
        var comps = URLComponents()
        comps.scheme = "codmate"
        comps.host = "notify"
        var query: [URLQueryItem] = [
            URLQueryItem(name: "source", value: "claude"),
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
                title: "Claude Code",
                body: "Claude Code requires approval. Return to the Claude window to respond."
            )
        case .complete:
            return HookPayload(
                title: "Claude Code",
                body: "Claude Code finished its current task."
            )
        }
    }

    private let fm: FileManager
    private let paths: Paths

    init(fileManager: FileManager = .default, paths: Paths = .default()) {
        self.fm = fileManager
        self.paths = paths
    }

    // Load existing JSON dict or empty
    private func loadObject() -> [String: Any] {
        guard let data = try? Data(contentsOf: paths.file) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // Atomic write with backup
    private func writeObject(_ obj: [String: Any]) throws {
        try fm.createDirectory(at: paths.dir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: paths.file) {
            let backup = paths.file.appendingPathExtension("backup")
            try? data.write(to: backup, options: .atomic)
        }
        let out = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try out.write(to: paths.file, options: .atomic)
    }

    // MARK: - Public upserts
    func setModel(_ modelId: String?) throws {
        var obj = loadObject()
        if let m = modelId?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty {
            obj["model"] = m
        } else {
            obj.removeValue(forKey: "model")
        }
        try writeObject(obj)
    }

    func setForceLoginMethod(_ method: String?) throws {
        var obj = loadObject()
        if let m = method?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty {
            obj["forceLoginMethod"] = m
        } else {
            obj.removeValue(forKey: "forceLoginMethod")
        }
        try writeObject(obj)
    }

    func setEnvBaseURL(_ baseURL: String?) throws {
        var obj = loadObject()
        var env = (obj["env"] as? [String: Any]) ?? [:]
        if let url = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
            env["ANTHROPIC_BASE_URL"] = url
        } else {
            env.removeValue(forKey: "ANTHROPIC_BASE_URL")
        }
        if env.isEmpty { obj.removeValue(forKey: "env") } else { obj["env"] = env }
        try writeObject(obj)
    }

    func setEnvToken(_ token: String?) throws {
        var obj = loadObject()
        var env = (obj["env"] as? [String: Any]) ?? [:]
        if let t = token?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            env["ANTHROPIC_AUTH_TOKEN"] = t
        } else {
            env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
        }
        if env.isEmpty { obj.removeValue(forKey: "env") } else { obj["env"] = env }
        try writeObject(obj)
    }

    func setEnvValues(_ entries: [String: String?]) throws {
        guard !entries.isEmpty else { return }
        var obj = loadObject()
        var env = (obj["env"] as? [String: Any]) ?? [:]
        for (key, value) in entries {
            if let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                env[key] = v
            } else {
                env.removeValue(forKey: key)
            }
        }
        if env.isEmpty { obj.removeValue(forKey: "env") } else { obj["env"] = env }
        try writeObject(obj)
    }

    func currentModel() -> String? {
        let obj = loadObject()
        return obj["model"] as? String
    }

    func envSnapshot() -> [String: String] {
        let obj = loadObject()
        guard let env = obj["env"] as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in env {
            if let str = value as? String, !str.isEmpty {
                out[key] = str
            }
        }
        return out
    }
}

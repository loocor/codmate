import Foundation

// MARK: - Persistent MCP Servers Store

actor MCPServersStore {
    struct Paths { let home: URL; let fileURL: URL }

    static func defaultPaths(fileManager: FileManager = .default) -> Paths {
        // Persist MCP servers under the real user home (~/.codmate), not sandbox container
        let home = SessionPreferencesStore.getRealUserHomeURL()
            .appendingPathComponent(".codmate", isDirectory: true)
        return Paths(home: home, fileURL: home.appendingPathComponent("mcp-servers.json"))
    }

    private let fm: FileManager
    private let paths: Paths
    private var cache: [MCPServer]? = nil

    init(paths: Paths = MCPServersStore.defaultPaths(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fm = fileManager
    }

    // MARK: Load/Save
    func load() -> [MCPServer] {
        if let cache { return cache }
        let url = paths.fileURL
        guard let data = try? Data(contentsOf: url) else { cache = []; return [] }
        if let list = try? JSONDecoder().decode([MCPServer].self, from: data) {
            cache = list
            return list
        }
        cache = []
        return []
    }

    private func save(_ list: [MCPServer]) throws {
        try fm.createDirectory(at: paths.home, withIntermediateDirectories: true)
        let tmp = paths.fileURL.appendingPathExtension("tmp")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let data = try enc.encode(list)
        try data.write(to: tmp, options: .atomic)
        if fm.fileExists(atPath: paths.fileURL.path) { try fm.removeItem(at: paths.fileURL) }
        try fm.moveItem(at: tmp, to: paths.fileURL)
        cache = list
    }

    // MARK: Public API
    func list() -> [MCPServer] { load() }

    func upsert(_ server: MCPServer) throws {
        var list = load()
        if let idx = list.firstIndex(where: { $0.name == server.name }) {
            list[idx] = server
        } else {
            list.append(server)
        }
        try save(list)
    }

    func upsertMany(_ servers: [MCPServer]) throws {
        var map: [String: MCPServer] = [:]
        for s in load() { map[s.name] = s }
        for s in servers { map[s.name] = s }
        let sorted = map.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        try save(sorted)
    }

    // Export enabled servers to Claude Code user settings (~/.claude/settings.json)
    // Per official docs, settings.json is the canonical configuration entry point.
    //
    // Safety strategy:
    // - Only modifies the "mcpServers" field
    // - Preserves all other existing configuration
    // - Creates backup before writing
    // - Uses atomic write to prevent partial corruption
    func exportEnabledForClaudeConfig(servers: [MCPServer]? = nil) throws {
        let list: [MCPServer]
        if let servers {
            list = servers.enabledServers(for: .claude)
        } else {
            list = load().enabledServers(for: .claude)
        }
        let realHome = SessionPreferencesStore.getRealUserHomeURL()
        // User settings file under ~/.claude/settings.json (preferred)
        let claudeDir = realHome.appendingPathComponent(".claude", isDirectory: true)
        let claudeSettingsPath = claudeDir.appendingPathComponent("settings.json")
        let codmateDir = realHome.appendingPathComponent(".codmate", isDirectory: true)
        let helperPath = codmateDir.appendingPathComponent("mcp-enabled-claude.json")

        // Step 1: Load existing settings or create empty object
        var existingConfig: [String: Any] = [:]
        var existingData: Data? = nil
        if fm.fileExists(atPath: claudeSettingsPath.path) {
            existingData = try? Data(contentsOf: claudeSettingsPath)
            if let data = existingData,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                existingConfig = json
            }
        }

        // Step 2: Build mcpServers object
        var serversObj: [String: Any] = [:]
        for s in list {
            var entry: [String: Any] = [:]
            if let url = s.url { entry["url"] = url }
            if let cmd = s.command { entry["command"] = cmd }
            if let args = s.args { entry["args"] = args }
            if let env = s.env { entry["env"] = env }
            if let headers = s.headers { entry["headers"] = headers }
            serversObj[s.name] = entry
        }

        // Step 3: Update or remove mcpServers key
        if serversObj.isEmpty {
            existingConfig.removeValue(forKey: "mcpServers")
        } else {
            existingConfig["mcpServers"] = serversObj
        }

        // Step 4: Write atomically to ~/.claude/settings.json (with backup)
        try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        if let backupData = existingData {
            let backupPath = claudeSettingsPath.appendingPathExtension("backup")
            try? backupData.write(to: backupPath, options: .atomic)
        }
        let settingsData = try JSONSerialization.data(withJSONObject: existingConfig, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try settingsData.write(to: claudeSettingsPath, options: .atomic)

        // Step 6: Also write a CodMate-managed helper file that contains only the mcpServers object
        // This is useful for launching Claude with --mcp-config explicitly from copied command examples.
        // Ensure ~/.codmate exists first.
        try fm.createDirectory(at: codmateDir, withIntermediateDirectories: true)
        var helperObj: [String: Any] = [:]
        if let servers = existingConfig["mcpServers"] {
            helperObj["mcpServers"] = servers
        }
        let helperData = try JSONSerialization.data(withJSONObject: helperObj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try helperData.write(to: helperPath, options: .atomic)
    }

    func delete(name: String) throws {
        var list = load()
        list.removeAll { $0.name == name }
        try save(list)
    }

    func setEnabled(name: String, enabled: Bool) throws {
        var list = load()
        guard let idx = list.firstIndex(where: { $0.name == name }) else { return }
        list[idx].enabled = enabled
        try save(list)
    }

    func setCapabilityEnabled(name: String, capability: String, enabled: Bool) throws {
        var list = load()
        guard let idx = list.firstIndex(where: { $0.name == name }) else { return }
        var caps = list[idx].capabilities
        if let cidx = caps.firstIndex(where: { $0.name == capability }) {
            caps[cidx].enabled = enabled
        } else {
            caps.append(MCPCapability(name: capability, enabled: enabled))
        }
        list[idx].capabilities = caps
        try save(list)
    }
}

import Foundation

actor ProjectExtensionsApplier {
  private let fm: FileManager
  private let skillsSyncer = SkillsSyncService()

  init(fileManager: FileManager = .default) {
    self.fm = fileManager
  }

  func apply(
    projectDirectory: URL,
    mcpSelections: [ProjectMCPSelection],
    skillRecords: [SkillRecord],
    skillSelections: [SkillsSyncService.SkillSelection]
  ) async {
    await applyMCP(projectDirectory: projectDirectory, selections: mcpSelections)
    _ = await skillsSyncer.syncProject(
      skills: skillRecords,
      selections: skillSelections,
      projectDirectory: projectDirectory
    )
  }

  private func applyMCP(projectDirectory: URL, selections: [ProjectMCPSelection]) async {
    let selected = selections.filter { $0.isSelected }
    let codexServers = selected.filter { $0.targets.codex }.map { $0.server }
    let claudeServers = selected.filter { $0.targets.claude }.map { $0.server }
    let geminiServers = selected.filter { $0.targets.gemini }.map { $0.server }

    let codexDir = projectDirectory.appendingPathComponent(".codex", isDirectory: true)
    let configURL = codexDir.appendingPathComponent("config.toml", isDirectory: false)
    if !codexServers.isEmpty || fm.fileExists(atPath: configURL.path) {
      let ensured = ensureCodexConfig(projectDirectory: projectDirectory)
      ensureCodexAuthSymlink(projectDirectory: ensured.deletingLastPathComponent())
      let service = CodexConfigService(paths: .init(home: codexDir, configURL: ensured))
      try? await service.applyMCPServers(codexServers)
    }

    // Claude Code official path: project_root/.mcp.json
    let claudeRootFile = projectDirectory.appendingPathComponent(".mcp.json", isDirectory: false)
    // CodMate legacy path: project_root/.claude/.mcp.json (for backward compatibility)
    let claudeLegacyDir = projectDirectory.appendingPathComponent(".claude", isDirectory: true)
    let claudeLegacyFile = claudeLegacyDir.appendingPathComponent(".mcp.json", isDirectory: false)

    if !claudeServers.isEmpty {
      // Write to Claude Code official path (project root)
      writeClaudeMCPFile(servers: claudeServers, file: claudeRootFile)
      // Remove legacy file if it exists to avoid conflicts
      if fm.fileExists(atPath: claudeLegacyFile.path) {
        try? fm.removeItem(at: claudeLegacyFile)
      }
    } else {
      // Remove both files when clearing
      if fm.fileExists(atPath: claudeRootFile.path) {
        try? fm.removeItem(at: claudeRootFile)
      }
      if fm.fileExists(atPath: claudeLegacyFile.path) {
        try? fm.removeItem(at: claudeLegacyFile)
      }
    }

    let geminiDir = projectDirectory.appendingPathComponent(".gemini", isDirectory: true)
    let geminiSettings = geminiDir.appendingPathComponent("settings.json", isDirectory: false)
    if !geminiServers.isEmpty || fm.fileExists(atPath: geminiSettings.path) {
      let service = GeminiSettingsService(paths: .init(directory: geminiDir, file: geminiSettings))
      try? await service.applyMCPServers(geminiServers)
    }
  }

  private func ensureCodexConfig(projectDirectory: URL) -> URL {
    let codexDir = projectDirectory.appendingPathComponent(".codex", isDirectory: true)
    let configURL = codexDir.appendingPathComponent("config.toml", isDirectory: false)
    if !fm.fileExists(atPath: configURL.path) {
      try? fm.createDirectory(at: codexDir, withIntermediateDirectories: true)
      let global = SessionPreferencesStore.getRealUserHomeURL()
        .appendingPathComponent(".codex", isDirectory: true)
        .appendingPathComponent("config.toml", isDirectory: false)
      if fm.fileExists(atPath: global.path) {
        try? fm.copyItem(at: global, to: configURL)
      } else {
        try? "".write(to: configURL, atomically: true, encoding: .utf8)
      }
    }
    return configURL
  }

  private func ensureCodexAuthSymlink(projectDirectory: URL) {
    let auth = projectDirectory.appendingPathComponent("auth.json", isDirectory: false)
    guard !fm.fileExists(atPath: auth.path) else { return }
    let global = SessionPreferencesStore.getRealUserHomeURL()
      .appendingPathComponent(".codex", isDirectory: true)
      .appendingPathComponent("auth.json", isDirectory: false)
    guard fm.fileExists(atPath: global.path) else { return }
    try? fm.createSymbolicLink(at: auth, withDestinationURL: global)
  }

  private func writeClaudeMCPFile(servers: [MCPServer], file: URL) {
    var obj: [String: Any] = [:]
    var mcpServers: [String: Any] = [:]
    for server in servers {
      var config: [String: Any] = [:]
      if let command = server.command { config["command"] = command }
      if let args = server.args, !args.isEmpty { config["args"] = args }
      if let env = server.env, !env.isEmpty { config["env"] = env }
      if let url = server.url { config["url"] = url }
      if let headers = server.headers, !headers.isEmpty { config["headers"] = headers }
      mcpServers[server.name] = config
    }
    obj["mcpServers"] = mcpServers
    if let data = try? JSONSerialization.data(
      withJSONObject: obj, options: [.prettyPrinted, .withoutEscapingSlashes])
    {
      try? data.write(to: file, options: .atomic)
    }
  }
}

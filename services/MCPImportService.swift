import Foundation

enum MCPImportService {
  struct SourceDescriptor {
    let label: String
    let url: URL
    let loader: () -> String?
  }

  private static let codmateBegin = "# codmate-mcp begin"
  private static let codmateEnd = "# codmate-mcp end"

  static func scan(scope: ExtensionsImportScope, fileManager: FileManager = .default)
    -> [MCPImportCandidate]
  {
    let sources: [SourceDescriptor]
    switch scope {
    case .home:
      let home = SessionPreferencesStore.getRealUserHomeURL()
      sources = [
        SourceDescriptor(
          label: "Codex",
          url: home.appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("config.toml", isDirectory: false),
          loader: {
            let url = home.appendingPathComponent(".codex", isDirectory: true)
              .appendingPathComponent("config.toml", isDirectory: false)
            return readText(url: url, fileManager: fileManager).map(stripCodMateManagedBlock)
          }),
        SourceDescriptor(
          label: "Claude",
          url: home.appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false),
          loader: {
            let url = home.appendingPathComponent(".claude", isDirectory: true)
              .appendingPathComponent("settings.json", isDirectory: false)
            return readMCPServersJSON(url: url, fileManager: fileManager)
          }),
        SourceDescriptor(
          label: "Gemini",
          url: home.appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false),
          loader: {
            let url = home.appendingPathComponent(".gemini", isDirectory: true)
              .appendingPathComponent("settings.json", isDirectory: false)
            return readMCPServersJSON(url: url, fileManager: fileManager)
          }),
      ]
    case .project(let directory):
      sources = [
        SourceDescriptor(
          label: "Codex",
          url: directory.appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("config.toml", isDirectory: false),
          loader: {
            let url = directory.appendingPathComponent(".codex", isDirectory: true)
              .appendingPathComponent("config.toml", isDirectory: false)
            return readText(url: url, fileManager: fileManager).map(stripCodMateManagedBlock)
          }),
        // Claude Code official path: project_root/.mcp.json
        SourceDescriptor(
          label: "Claude",
          url: directory.appendingPathComponent(".mcp.json", isDirectory: false),
          loader: {
            let url = directory.appendingPathComponent(".mcp.json", isDirectory: false)
            return readMCPServersJSON(url: url, fileManager: fileManager)
          }),
        // CodMate legacy path: project_root/.claude/.mcp.json (for backward compatibility)
        SourceDescriptor(
          label: "Claude",
          url: directory.appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent(".mcp.json", isDirectory: false),
          loader: {
            let url = directory.appendingPathComponent(".claude", isDirectory: true)
              .appendingPathComponent(".mcp.json", isDirectory: false)
            return readMCPServersJSON(url: url, fileManager: fileManager)
          }),
        SourceDescriptor(
          label: "Gemini",
          url: directory.appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false),
          loader: {
            let url = directory.appendingPathComponent(".gemini", isDirectory: true)
              .appendingPathComponent("settings.json", isDirectory: false)
            return readMCPServersJSON(url: url, fileManager: fileManager)
          }),
      ]
    }
    return scan(sources: sources)
  }

  private static func scan(sources: [SourceDescriptor]) -> [MCPImportCandidate] {
    var map: [String: MCPImportCandidate] = [:]
    var byName: [String: [String]] = [:]

    for source in sources {
      guard let text = source.loader(), !text.isEmpty else { continue }
      guard let drafts = try? UniImportMCPNormalizer.parseText(text) else { continue }

      for draft in drafts {
        let name = (draft.name ?? "imported-server").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { continue }

        let signature = normalizeSignature(
          name: name, kind: draft.kind, command: draft.command, url: draft.url, args: draft.args)
        if var existing = map[signature] {
          if !existing.sources.contains(source.label) {
            existing.sources.append(source.label)
          }
          existing.sourcePaths[source.label] = source.url.path
          map[signature] = existing
        } else {
          map[signature] = MCPImportCandidate(
            id: UUID(),
            name: name,
            kind: draft.kind,
            command: draft.command,
            args: draft.args,
            env: draft.env,
            url: draft.url,
            headers: draft.headers,
            description: draft.meta?.description,
            sources: [source.label],
            sourcePaths: [source.label: source.url.path],
            isSelected: true,
            hasConflict: false,
            hasNameCollision: false,
            resolution: .overwrite,
            renameName: name,
            signature: signature
          )
        }
      }
    }

    for candidate in map.values {
      byName[candidate.name, default: []].append(candidate.signature)
    }

    var out = map.values.sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
    for idx in out.indices {
      if let signatures = byName[out[idx].name], signatures.count > 1 {
        out[idx].hasNameCollision = true
      }
    }

    return out
  }

  static func signature(for server: MCPServer) -> String {
    normalizeSignature(
      name: server.name,
      kind: server.kind,
      command: server.command,
      url: server.url,
      args: server.args
    )
  }

  static func filterManagedCandidates(
    _ candidates: [MCPImportCandidate],
    managedSignatures: Set<String>
  ) -> [MCPImportCandidate] {
    candidates.filter { !managedSignatures.contains($0.signature) }
  }

  private static func normalizeSignature(
    name: String,
    kind: MCPServerKind,
    command: String?,
    url: String?,
    args: [String]?
  ) -> String {
    let normName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let normCommand = (command ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let normURL = (url ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let normArgs = (args ?? []).map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }.sorted().joined(separator: "|")
    return "\(normName)|\(kind.rawValue)|\(normCommand)|\(normURL)|\(normArgs)"
  }

  private static func readText(url: URL, fileManager: FileManager) -> String? {
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    return try? String(contentsOf: url, encoding: .utf8)
  }

  private static func readMCPServersJSON(url: URL, fileManager: FileManager) -> String? {
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    guard let data = try? Data(contentsOf: url) else { return nil }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    guard let mcpServers = json["mcpServers"] as? [String: Any] else { return nil }
    let payload: [String: Any] = ["mcpServers": mcpServers]
    guard
      let out = try? JSONSerialization.data(
        withJSONObject: payload, options: [.prettyPrinted, .withoutEscapingSlashes])
    else { return nil }
    return String(data: out, encoding: .utf8)
  }

  private static func stripCodMateManagedBlock(_ text: String) -> String {
    guard let begin = text.range(of: codmateBegin), let end = text.range(of: codmateEnd) else {
      return text
    }
    var updated = text
    updated.removeSubrange(begin.lowerBound..<end.upperBound)
    return updated
  }
}

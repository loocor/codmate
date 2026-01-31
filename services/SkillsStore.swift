import Foundation

enum SkillCreationError: LocalizedError {
  case invalidName(String)
  case nameConflict(existing: String, suggested: String)

  var errorDescription: String? {
    switch self {
    case .invalidName(let message):
      return message
    case .nameConflict(let existing, let suggested):
      return "A skill named '\(existing)' already exists. Suggested name: '\(suggested)'"
    }
  }
}

actor SkillsStore {
  struct Paths {
    let root: URL
    let libraryDir: URL
    let indexURL: URL

    static func `default`(fileManager: FileManager = .default) -> Paths {
      let home = SessionPreferencesStore.getRealUserHomeURL()
      let root = home.appendingPathComponent(".codmate", isDirectory: true)
        .appendingPathComponent("skills", isDirectory: true)
      return Paths(
        root: root,
        libraryDir: root.appendingPathComponent("library", isDirectory: true),
        indexURL: root.appendingPathComponent("index.json", isDirectory: false)
      )
    }
  }

  private let paths: Paths
  private let fm: FileManager

  init(paths: Paths = .default(), fileManager: FileManager = .default) {
    self.paths = paths
    self.fm = fileManager
  }

  func list() -> [SkillRecord] {
    load()
  }

  func record(id: String) -> SkillRecord? {
    load().first(where: { $0.id == id })
  }

  func saveAll(_ records: [SkillRecord]) {
    save(records)
  }

  func uninstall(id: String) {
    var records = load()
    guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
    let record = records.remove(at: idx)
    save(records)
    let path = record.path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else { return }
    let url = URL(fileURLWithPath: path, isDirectory: true)
    if fm.fileExists(atPath: url.path) {
      if isCodMateManagedSkill(at: url) || url.standardizedFileURL.path.hasPrefix(paths.libraryDir.standardizedFileURL.path) {
        try? fm.removeItem(at: url)
      }
    }
  }

  func refreshMetadata(id: String) -> SkillRecord? {
    var records = load()
    guard let idx = records.firstIndex(where: { $0.id == id }) else { return nil }
    let record = records[idx]
    let path = record.path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else { return nil }
    let url = URL(fileURLWithPath: path, isDirectory: true)
    guard fm.fileExists(atPath: url.path) else { return nil }
    let metadata = (try? parseSkillMetadata(at: url, sourceLabel: record.source)) ?? ParsedMetadata(
      name: record.name,
      description: record.description,
      summary: record.summary,
      tags: record.tags,
      source: record.source
    )
    records[idx].name = metadata.name
    records[idx].description = metadata.description
    records[idx].summary = metadata.summary
    records[idx].tags = metadata.tags
    save(records)
    return records[idx]
  }

  func update(id: String, mutate: (inout SkillRecord) -> Void) {
    var records = load()
    guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
    mutate(&records[idx])
    save(records)
  }

  func upsert(_ record: SkillRecord) {
    var records = load()
    if let idx = records.firstIndex(where: { $0.id == record.id }) {
      records[idx] = record
    } else {
      records.append(record)
    }
    save(records)
  }

  func createFromTemplate(name: String, description: String) async throws -> SkillRecord {
    let skillId = try validateAndNormalizeSkillName(name)

    try fm.createDirectory(at: paths.libraryDir, withIntermediateDirectories: true)
    let destination = paths.libraryDir.appendingPathComponent(skillId, isDirectory: true)

    if fm.fileExists(atPath: destination.path) {
      let suggested = suggestNewId(basedOn: skillId)
      throw SkillCreationError.nameConflict(existing: skillId, suggested: suggested)
    }

    try fm.createDirectory(at: destination, withIntermediateDirectories: true)

    let skillMarkdown = generateDefaultSkillMarkdown(name: skillId, description: description)
    let skillFile = destination.appendingPathComponent("SKILL.md", isDirectory: false)
    try skillMarkdown.write(to: skillFile, atomically: true, encoding: .utf8)

    try writeMarker(to: destination, id: skillId, sourceType: "template")

    let record = SkillRecord(
      id: skillId,
      name: skillId,
      description: description,
      summary: description,
      tags: [],
      source: "Template",
      path: destination.path,
      isEnabled: true,
      targets: MCPServerTargets(codex: true, claude: true, gemini: false),
      installedAt: Date()
    )

    upsert(record)
    return record
  }

  func createFromWizard(draft: SkillWizardDraft, enabled: Bool = false) async throws -> SkillRecord {
    let proposed = draft.id.isEmpty ? draft.name : draft.id
    let skillId = try validateAndNormalizeSkillName(proposed)

    try fm.createDirectory(at: paths.libraryDir, withIntermediateDirectories: true)
    let destination = paths.libraryDir.appendingPathComponent(skillId, isDirectory: true)

    if fm.fileExists(atPath: destination.path) {
      let suggested = suggestNewId(basedOn: skillId)
      throw SkillCreationError.nameConflict(existing: skillId, suggested: suggested)
    }

    try fm.createDirectory(at: destination, withIntermediateDirectories: true)

    let skillMarkdown = generateSkillMarkdownFromDraft(draft, id: skillId)
    let skillFile = destination.appendingPathComponent("SKILL.md", isDirectory: false)
    try skillMarkdown.write(to: skillFile, atomically: true, encoding: .utf8)

    try writeMarker(to: destination, id: skillId, sourceType: "wizard")

    let summary = draft.summary?.isEmpty == false ? draft.summary! : draft.description
    let record = SkillRecord(
      id: skillId,
      name: draft.name,
      description: draft.description,
      summary: summary,
      tags: draft.tags,
      source: "Wizard",
      path: destination.path,
      isEnabled: enabled,
      targets: draft.targets ?? MCPServerTargets(codex: true, claude: true, gemini: false),
      installedAt: Date()
    )

    upsert(record)
    return record
  }

  private func validateAndNormalizeSkillName(_ name: String) throws -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw SkillCreationError.invalidName("Skill name cannot be empty")
    }

    let normalized = trimmed
      .lowercased()
      .replacingOccurrences(of: " ", with: "-")
      .replacingOccurrences(of: "_", with: "-")

    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
    let filtered = normalized.unicodeScalars.filter { allowed.contains($0) }
    let result = String(String.UnicodeScalarView(filtered))

    guard !result.isEmpty else {
      throw SkillCreationError.invalidName("Skill name must contain at least one alphanumeric character")
    }

    guard result.count <= 64 else {
      throw SkillCreationError.invalidName("Skill name must be 64 characters or less")
    }

    return result
  }

  private func generateDefaultSkillMarkdown(name: String, description: String) -> String {
    let displayName = name.split(separator: "-")
      .map { $0.prefix(1).uppercased() + $0.dropFirst() }
      .joined(separator: " ")

    return """
---
name: \(name)
description: \(description.isEmpty ? "Custom skill for specific tasks" : description)
---

# \(displayName)

## Overview

This is a custom skill created from a template. Describe what this skill does and when Claude or Codex should use it.

## Instructions

Provide clear, step-by-step guidance for the AI assistant:

1. First step or action to take
2. Second step or action
3. Additional steps as needed

## Examples

Show concrete usage examples to help the AI understand how to apply this skill:

**Example 1: Basic Usage**
```
User: [Example user request]
Assistant: [Expected behavior or response]
```

**Example 2: Advanced Usage**
```
User: [Another example]
Assistant: [Expected behavior]
```

## Notes

- Add any special considerations or limitations
- Document required tools or dependencies
- Include best practices or tips

"""
  }

  nonisolated func generateSkillMarkdownFromDraft(_ draft: SkillWizardDraft, id: String) -> String {
    let title = draft.name.isEmpty ? id : draft.name
    let summary = draft.summary?.isEmpty == false ? draft.summary! : draft.description
    let tagsBlock: String = {
      if draft.tags.isEmpty { return "" }
      let lines = draft.tags.map { "  - \($0)" }.joined(separator: "\n")
      return "tags:\n\(lines)\n"
    }()

    let instructions: String = {
      if draft.instructions.isEmpty { return "" }
      return draft.instructions.enumerated().map { index, step in
        "\(index + 1). \(step)"
      }.joined(separator: "\n")
    }()

    let examples: String = {
      if draft.examples.isEmpty { return "" }
      return draft.examples.enumerated().map { index, example in
        let title = example.title.isEmpty ? "Example \(index + 1)" : example.title
        return """
**\(title)**
```
User: \(example.user)
Assistant: \(example.assistant)
```
"""
      }.joined(separator: "\n\n")
    }()

    let notes: String = {
      if draft.notes.isEmpty { return "" }
      return draft.notes.map { "- \($0)" }.joined(separator: "\n")
    }()

    return """
---
name: \(id)
description: \(draft.description)
metadata:
  short-description: \(summary)
\(tagsBlock)---

# \(title)

## Overview

\(draft.overview)

## Instructions

\(instructions)

## Examples

\(examples)

## Notes

\(notes)

"""
  }

  func install(
    request: SkillInstallRequest,
    resolution: SkillConflictResolution? = nil
  ) async -> SkillInstallOutcome {
    do {
      let result = try await performInstall(request: request, resolution: resolution)
      return result
    } catch {
      return .skipped
    }
  }

  func validate(request: SkillInstallRequest) async -> Bool {
    do {
      let tempRoot = fm.temporaryDirectory
        .appendingPathComponent("codmate-skill-validate-\(UUID().uuidString)", isDirectory: true)
      try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
      defer { try? fm.removeItem(at: tempRoot) }

      guard let sourceURL = try await resolveSourceURL(request: request, tempRoot: tempRoot) else {
        return false
      }
      _ = try locateSkillRoot(from: sourceURL, request: request, tempRoot: tempRoot)
      return true
    } catch {
      return false
    }
  }

  private func performInstall(
    request: SkillInstallRequest,
    resolution: SkillConflictResolution? = nil
  ) async throws -> SkillInstallOutcome {
    let tempRoot = fm.temporaryDirectory
      .appendingPathComponent("codmate-skill-install-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tempRoot) }

    guard let sourceURL = try await resolveSourceURL(request: request, tempRoot: tempRoot) else {
      return .skipped
    }

    let skillRoot = try locateSkillRoot(from: sourceURL, request: request, tempRoot: tempRoot)
    let proposedId = skillRoot.lastPathComponent
    let targetId: String
    switch resolution {
    case .rename(let newId):
      targetId = newId
    default:
      targetId = proposedId
    }

    try fm.createDirectory(at: paths.libraryDir, withIntermediateDirectories: true)
    let destination = paths.libraryDir.appendingPathComponent(targetId, isDirectory: true)

    if fm.fileExists(atPath: destination.path) {
      if resolution == .skip { return .skipped }
      let managed = isCodMateManagedSkill(at: destination)
      if managed || resolution == .overwrite {
        try? fm.removeItem(at: destination)
      } else {
        let suggested = suggestNewId(basedOn: targetId)
        let conflict = SkillInstallConflict(
          proposedId: targetId,
          destination: destination,
          existingIsManaged: managed,
          suggestedId: suggested
        )
        return .conflict(conflict)
      }
    }

    try fm.copyItem(at: skillRoot, to: destination)
    try writeMarker(to: destination, id: targetId)

    let sourceLabel = sourceDescription(request: request, fallback: destination.lastPathComponent)
    let metadata = try parseSkillMetadata(at: destination, sourceLabel: sourceLabel)
    let existing = load().first(where: { $0.id == targetId })
    let record = SkillRecord(
      id: targetId,
      name: metadata.name,
      description: metadata.description,
      summary: metadata.summary,
      tags: metadata.tags,
      source: metadata.source,
      path: destination.path,
      isEnabled: existing?.isEnabled ?? true,
      targets: existing?.targets ?? MCPServerTargets(codex: true, claude: true, gemini: false),
      installedAt: Date()
    )
    upsert(record)
    return .installed(record)
  }

  struct ParsedMetadata {
    var name: String
    var description: String
    var summary: String
    var tags: [String]
    var source: String
  }

  func parseSkillMetadata(at root: URL, sourceLabel: String) throws -> ParsedMetadata {
    let skillFile = root.appendingPathComponent("SKILL.md", isDirectory: false)
    let text = (try? String(contentsOf: skillFile, encoding: .utf8)) ?? ""
    let front = parseFrontMatter(text)
    let name = front.name.isEmpty ? root.lastPathComponent : front.name
    let description = front.description.isEmpty ? name : front.description
    let summary = front.shortDescription.isEmpty ? description : front.shortDescription
    let tags = front.tags
    return ParsedMetadata(
      name: name,
      description: description,
      summary: summary,
      tags: tags,
      source: sourceLabel
    )
  }

  private func load() -> [SkillRecord] {
    guard fm.fileExists(atPath: paths.indexURL.path) else { return [] }
    guard let data = try? Data(contentsOf: paths.indexURL) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return (try? decoder.decode([SkillRecord].self, from: data)) ?? []
  }

  private func save(_ records: [SkillRecord]) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(records) else { return }
    try? fm.createDirectory(at: paths.root, withIntermediateDirectories: true)
    try? data.write(to: paths.indexURL, options: .atomic)
  }

  private func resolveSourceURL(request: SkillInstallRequest, tempRoot: URL) async throws -> URL? {
    switch request.mode {
    case .folder:
      guard let url = request.url else { return nil }
      return url
    case .zip:
      guard let url = request.url else { return nil }
      return try extractZip(at: url, to: tempRoot)
    case .url:
      guard let text = request.text?.trimmingCharacters(in: .whitespacesAndNewlines),
            let url = URL(string: text)
      else { return nil }
      let downloaded = try await downloadURL(url, to: tempRoot)
      if downloaded.pathExtension.lowercased() == "zip" {
        return try extractZip(at: downloaded, to: tempRoot)
      }
      return downloaded
    }
  }

  private func locateSkillRoot(from source: URL, request: SkillInstallRequest, tempRoot: URL) throws -> URL {
    let fm = FileManager.default
    let isDirectory = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    if isDirectory {
      if hasSkillFile(in: source) { return source }
      let candidates = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
      if let nested = candidates.first(where: { hasSkillFile(in: $0) }) { return nested }
    } else if hasSkillFile(in: source.deletingLastPathComponent()) {
      return source.deletingLastPathComponent()
    }

    let candidates = try fm.contentsOfDirectory(at: tempRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
      .filter { $0.lastPathComponent != "__MACOSX" }
    if candidates.count == 1 {
      let single = candidates[0]
      if hasSkillFile(in: single) { return single }
      let nested = try fm.contentsOfDirectory(at: single, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
      if let hit = nested.first(where: { hasSkillFile(in: $0) }) { return hit }
    }
    if hasSkillFile(in: tempRoot) { return tempRoot }
    throw NSError(domain: "CodMate", code: -1, userInfo: [NSLocalizedDescriptionKey: "SKILL.md not found"])
  }

  private func hasSkillFile(in dir: URL) -> Bool {
    fm.fileExists(atPath: dir.appendingPathComponent("SKILL.md", isDirectory: false).path)
  }

  private func downloadURL(_ url: URL, to tempRoot: URL) async throws -> URL {
    let (data, _) = try await URLSession.shared.data(from: url)
    let ext = url.pathExtension.isEmpty ? "download" : url.pathExtension
    let target = tempRoot.appendingPathComponent("skill.\(ext)", isDirectory: false)
    try data.write(to: target, options: .atomic)
    return target
  }

  private func extractZip(at url: URL, to tempRoot: URL) throws -> URL {
    let ditto = Process()
    ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    ditto.arguments = ["-x", "-k", url.path, tempRoot.path]
    let pipe = Pipe()
    ditto.standardOutput = pipe
    ditto.standardError = pipe
    try ditto.run()
    ditto.waitUntilExit()
    if ditto.terminationStatus != 0 {
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      let output = String(data: data, encoding: .utf8) ?? ""
      throw NSError(domain: "CodMate", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to extract zip: \(output)"])
    }
    return tempRoot
  }

  func suggestNewId(basedOn id: String) -> String {
    let base = id.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !base.isEmpty else { return "skill" }
    var i = 2
    var candidate = "\(base)-\(i)"
    while fm.fileExists(atPath: paths.libraryDir.appendingPathComponent(candidate).path) {
      i += 1
      candidate = "\(base)-\(i)"
    }
    return candidate
  }

  private func sourceDescription(request: SkillInstallRequest, fallback: String) -> String {
    switch request.mode {
    case .folder:
      return request.url?.path ?? fallback
    case .zip:
      return request.url?.path ?? fallback
    case .url:
      return request.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? fallback
    }
  }

  func writeMarker(to dir: URL, id: String, sourceType: String = "installed") throws {
    let marker = dir.appendingPathComponent(".codmate.json", isDirectory: false)
    let obj: [String: Any] = [
      "managedByCodMate": true,
      "id": id,
      "sourceType": sourceType
    ]
    let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
    try data.write(to: marker, options: .atomic)
  }

  func isCodMateManagedSkill(at dir: URL) -> Bool {
    let marker = dir.appendingPathComponent(".codmate.json", isDirectory: false)
    guard fm.fileExists(atPath: marker.path),
          let data = try? Data(contentsOf: marker),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return false }
    return (obj["managedByCodMate"] as? Bool) == true
  }

  func getSourceType(at dir: URL) -> String? {
    let marker = dir.appendingPathComponent(".codmate.json", isDirectory: false)
    guard fm.fileExists(atPath: marker.path),
          let data = try? Data(contentsOf: marker),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return obj["sourceType"] as? String
  }

  func conflictInfo(forProposedId id: String) -> SkillInstallConflict? {
    let dest = paths.libraryDir.appendingPathComponent(id, isDirectory: true)
    guard fm.fileExists(atPath: dest.path) else { return nil }
    let managed = isCodMateManagedSkill(at: dest)
    let suggested = suggestNewId(basedOn: id)
    return SkillInstallConflict(
      proposedId: id,
      destination: dest,
      existingIsManaged: managed,
      suggestedId: suggested
    )
  }

  func markImported(id: String) {
    var records = load()
    guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
    records[idx].source = "Import"
    save(records)
    let dir = URL(fileURLWithPath: records[idx].path, isDirectory: true)
    try? writeMarker(to: dir, id: id, sourceType: "import")
  }

  private struct FrontMatter {
    var name: String = ""
    var description: String = ""
    var shortDescription: String = ""
    var tags: [String] = []
  }

  private func parseFrontMatter(_ text: String) -> FrontMatter {
    var result = FrontMatter()
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return result }
    var idx = 1
    var inMetadata = false
    var inTagsList = false
    while idx < lines.count {
      let raw = String(lines[idx])
      let trimmed = raw.trimmingCharacters(in: .whitespaces)
      if trimmed == "---" { break }
      if trimmed.isEmpty || trimmed.hasPrefix("#") {
        idx += 1
        continue
      }
      let indent = raw.prefix { $0 == " " || $0 == "\t" }.count
      if indent == 0 {
        inMetadata = false
        inTagsList = false
        if let colon = trimmed.firstIndex(of: ":") {
          let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
          let value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
          if key == "metadata" {
            inMetadata = true
          } else if key == "tags" {
            if value.hasPrefix("[") {
              result.tags = parseInlineArray(value)
            } else if !value.isEmpty {
              result.tags = [unquote(value)]
            } else {
              inTagsList = true
            }
          } else if key == "name" {
            result.name = unquote(value)
          } else if key == "description" {
            result.description = unquote(value)
          }
        }
      } else if inMetadata {
        let line = trimmed
        if let colon = line.firstIndex(of: ":") {
          let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
          let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
          if key == "short-description" {
            result.shortDescription = unquote(value)
          }
        }
      } else if inTagsList {
        if trimmed.hasPrefix("-") {
          let tag = trimmed.replacingOccurrences(of: "-", with: "", options: .anchored)
            .trimmingCharacters(in: .whitespaces)
          if !tag.isEmpty { result.tags.append(unquote(tag)) }
        }
      }
      idx += 1
    }
    return result
  }

  private func parseInlineArray(_ value: String) -> [String] {
    var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("[") { trimmed.removeFirst() }
    if trimmed.hasSuffix("]") { trimmed.removeLast() }
    return trimmed.split(separator: ",").map { unquote(String($0).trimmingCharacters(in: .whitespaces)) }
  }

  private func unquote(_ value: String) -> String {
    var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) || (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
      trimmed.removeFirst()
      trimmed.removeLast()
    }
    return trimmed
  }
}

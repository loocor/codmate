import Foundation

actor InternalSkillsRegistry {
  private struct IndexedSkill: Hashable {
    let definition: InternalSkillDefinition
    let rootURL: URL
  }

  private let fileManager = FileManager.default
  private var cached: [WizardFeature: [IndexedSkill]] = [:]

  func skill(for feature: WizardFeature) -> InternalSkillAsset? {
    let list = loadSkills(for: feature)
    return list.first.map { materialize($0) }
  }

  func skills(for feature: WizardFeature) -> [InternalSkillAsset] {
    loadSkills(for: feature).map { materialize($0) }
  }

  // MARK: - Load

  private func loadSkills(for feature: WizardFeature) -> [IndexedSkill] {
    if let cached = cached[feature] { return cached }
    let bundled = loadIndex(from: bundledIndexURL(), baseURL: bundledRootURL())
    let overrides = loadIndex(from: overrideIndexURL(), baseURL: overrideRootURL())

    var map: [String: IndexedSkill] = [:]
    for item in bundled { map[item.definition.id] = item }
    for item in overrides { map[item.definition.id] = item }

    let merged = map.values.filter { $0.definition.feature == feature }
      .sorted { $0.definition.id < $1.definition.id }
    cached[feature] = merged
    return merged
  }

  private func loadIndex(from indexURL: URL?, baseURL: URL?) -> [IndexedSkill] {
    guard let indexURL, let baseURL else { return [] }
    guard let data = try? Data(contentsOf: indexURL) else { return [] }
    let decoder = JSONDecoder()
    let index = (try? decoder.decode(InternalSkillsIndex.self, from: data))?.skills ?? []
    return index.map { def in
      let root = baseURL.appendingPathComponent(def.id, isDirectory: true)
      return IndexedSkill(definition: def, rootURL: root)
    }
  }

  private func bundledIndexURL() -> URL? {
    if let url = Bundle.main.url(forResource: "index", withExtension: "json", subdirectory: "payload/internal-skills") {
      return url
    }
    return devPayloadRootURL()?
      .appendingPathComponent("internal-skills", isDirectory: true)
      .appendingPathComponent("index.json", isDirectory: false)
  }

  private func bundledRootURL() -> URL? {
    if let url = Bundle.main.url(forResource: "internal-skills", withExtension: nil, subdirectory: "payload") {
      return url
    }
    return devPayloadRootURL()?
      .appendingPathComponent("internal-skills", isDirectory: true)
  }

  private func devPayloadRootURL() -> URL? {
    let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
    if let found = findPayloadRoot(startingAt: cwd) {
      return found
    }
    if let execURL = Bundle.main.executableURL {
      let execDir = execURL.deletingLastPathComponent()
      if let found = findPayloadRoot(startingAt: execDir) {
        return found
      }
    }
    return nil
  }

  private func findPayloadRoot(startingAt start: URL) -> URL? {
    var current = start
    for _ in 0..<6 {
      let candidate = current
        .appendingPathComponent("payload", isDirectory: true)
        .appendingPathComponent("internal-skills", isDirectory: true)
        .appendingPathComponent("index.json", isDirectory: false)
      if fileManager.fileExists(atPath: candidate.path) {
        return current.appendingPathComponent("payload", isDirectory: true)
      }
      current = current.deletingLastPathComponent()
    }
    return nil
  }

  private func overrideRootURL() -> URL? {
    let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    return base?.appendingPathComponent("CodMate", isDirectory: true)
      .appendingPathComponent("internal-skills", isDirectory: true)
  }

  private func overrideIndexURL() -> URL? {
    overrideRootURL()?.appendingPathComponent("index.json", isDirectory: false)
  }

  // MARK: - Materialize

  private func materialize(_ skill: IndexedSkill) -> InternalSkillAsset {
    let def = skill.definition
    let assets = def.assets ?? InternalSkillAssetPaths()
    let skillPath = assets.skill ?? "SKILL.md"
    let promptPath = assets.prompt ?? "prompt.md"
    let schemaPath = assets.schema ?? "schema.json"
    let docsPath = assets.docs ?? "docs.json"

    let skillMarkdown = readText(skill.rootURL.appendingPathComponent(skillPath))
    let prompt = readText(skill.rootURL.appendingPathComponent(promptPath))
    let schema = readText(skill.rootURL.appendingPathComponent(schemaPath))
    let fileOverrides = loadDocsOverrides(skill.rootURL.appendingPathComponent(docsPath))
    let docsOverrides = (def.docsSources ?? []) + fileOverrides

    return InternalSkillAsset(
      definition: def,
      rootURL: skill.rootURL,
      skillMarkdown: skillMarkdown,
      prompt: prompt,
      schema: schema,
      docsOverrides: docsOverrides
    )
  }

  private func readText(_ url: URL) -> String? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    let text = String(data: data, encoding: .utf8) ?? ""
    return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
  }

  private func loadDocsOverrides(_ url: URL) -> [WizardDocSource] {
    guard let data = try? Data(contentsOf: url) else { return [] }
    let decoder = JSONDecoder()
    let list = (try? decoder.decode([WizardDocSource].self, from: data)) ?? []
    return list
  }
}

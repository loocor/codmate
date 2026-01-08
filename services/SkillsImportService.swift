import Foundation

enum SkillsImportService {
  struct SourceDescriptor {
    let label: String
    let directory: URL
  }

  static func scan(scope: ExtensionsImportScope, fileManager: FileManager = .default) async -> [SkillImportCandidate] {
    let sources: [SourceDescriptor]
    switch scope {
    case .home:
      let home = SessionPreferencesStore.getRealUserHomeURL()
      sources = [
        SourceDescriptor(
          label: "Codex",
          directory: home.appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
        ),
        SourceDescriptor(
          label: "Claude",
          directory: home.appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
        ),
        SourceDescriptor(
          label: "Gemini",
          directory: home.appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
        ),
      ]
    case .project(let directory):
      sources = [
        SourceDescriptor(
          label: "Codex",
          directory: directory.appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
        ),
        SourceDescriptor(
          label: "Claude",
          directory: directory.appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
        ),
        SourceDescriptor(
          label: "Gemini",
          directory: directory.appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
        ),
      ]
    }
    return await scan(sources: sources, fileManager: fileManager)
  }

  private static func scan(sources: [SourceDescriptor], fileManager: FileManager) async -> [SkillImportCandidate] {
    let store = SkillsStore()
    var merged: [String: SkillImportCandidate] = [:]

    for source in sources {
      guard fileManager.fileExists(atPath: source.directory.path) else { continue }
      guard let entries = try? fileManager.contentsOfDirectory(
        at: source.directory,
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles]
      ) else { continue }

      for entry in entries {
        guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
        let skillFile = entry.appendingPathComponent("SKILL.md", isDirectory: false)
        guard fileManager.fileExists(atPath: skillFile.path) else { continue }
        if await store.isCodMateManagedSkill(at: entry) { continue }

        let proposedId = entry.lastPathComponent
        let metadata = try? await store.parseSkillMetadata(at: entry, sourceLabel: "import")
        let name = metadata?.name.isEmpty == false ? metadata?.name ?? proposedId : proposedId
        let summary = metadata?.summary ?? (metadata?.description ?? "")

        if var existing = merged[proposedId] {
          if !existing.sources.contains(source.label) {
            existing.sources.append(source.label)
          }
          existing.sourcePaths[source.label] = skillFile.path
          merged[proposedId] = existing
        } else {
          merged[proposedId] = SkillImportCandidate(
            id: proposedId,
            name: name,
            summary: summary,
            sourcePath: entry.path,
            sources: [source.label],
            sourcePaths: [source.label: skillFile.path],
            isSelected: true,
            hasConflict: false,
            conflictDetail: nil,
            resolution: .overwrite,
            renameId: proposedId,
            suggestedId: proposedId
          )
        }
      }
    }

    return merged.values.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
  }
}

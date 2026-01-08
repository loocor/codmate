import Foundation

actor SkillsSyncService {
  private let fm: FileManager
  private let libraryDir: URL

  init(fileManager: FileManager = .default, libraryDir: URL? = nil) {
    self.fm = fileManager
    self.libraryDir = libraryDir ?? SkillsStore.Paths.default().libraryDir
  }

  func syncGlobal(skills: [SkillRecord]) -> [SkillSyncWarning] {
    let home = SessionPreferencesStore.getRealUserHomeURL()
    let codexDir = home.appendingPathComponent(".codex", isDirectory: true).appendingPathComponent("skills", isDirectory: true)
    let claudeDir = home.appendingPathComponent(".claude", isDirectory: true).appendingPathComponent("skills", isDirectory: true)
    let geminiDir = home.appendingPathComponent(".gemini", isDirectory: true).appendingPathComponent("skills", isDirectory: true)

    var warnings: [SkillSyncWarning] = []
    warnings.append(contentsOf: syncSkills(skills: skills, target: .codex, destination: codexDir))
    warnings.append(contentsOf: syncSkills(skills: skills, target: .claude, destination: claudeDir))
    warnings.append(contentsOf: syncSkills(skills: skills, target: .gemini, destination: geminiDir))
    return warnings
  }

  func syncProject(skills: [SkillRecord], selections: [SkillSelection], projectDirectory: URL) -> [SkillSyncWarning] {
    let codexDir = projectDirectory.appendingPathComponent(".codex", isDirectory: true)
      .appendingPathComponent("skills", isDirectory: true)
    let claudeDir = projectDirectory.appendingPathComponent(".claude", isDirectory: true)
      .appendingPathComponent("skills", isDirectory: true)
    let geminiDir = projectDirectory.appendingPathComponent(".gemini", isDirectory: true)
      .appendingPathComponent("skills", isDirectory: true)

    var warnings: [SkillSyncWarning] = []
    let selectedSkills = selections.reduce(into: [String: SkillSelection]()) { $0[$1.id] = $1 }
    let chosen = skills.filter { selectedSkills[$0.id]?.isSelected == true }

    warnings.append(contentsOf: syncSkills(
      skills: chosen,
      target: .codex,
      destination: codexDir,
      selectionOverride: selectedSkills
    ))
    warnings.append(contentsOf: syncSkills(
      skills: chosen,
      target: .claude,
      destination: claudeDir,
      selectionOverride: selectedSkills
    ))
    warnings.append(contentsOf: syncSkills(
      skills: chosen,
      target: .gemini,
      destination: geminiDir,
      selectionOverride: selectedSkills
    ))
    return warnings
  }

  struct SkillSelection: Hashable {
    var id: String
    var isSelected: Bool
    var targets: MCPServerTargets
  }

  private func syncSkills(
    skills: [SkillRecord],
    target: MCPServerTarget,
    destination: URL,
    selectionOverride: [String: SkillSelection]? = nil
  ) -> [SkillSyncWarning] {
    let selected = skills.filter { record in
      if let override = selectionOverride?[record.id] {
        return override.isSelected && override.targets.isEnabled(for: target)
      }
      return record.isEnabled && record.targets.isEnabled(for: target)
    }

    if selected.isEmpty {
      removeManagedEntries(keeping: [], at: destination)
      return []
    }

    try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
    let wanted = Set(selected.map { $0.id })

    var warnings: [SkillSyncWarning] = []
    for record in selected {
      if record.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        warnings.append(SkillSyncWarning(message: "\(record.id) has no install path." ))
        continue
      }
      let dest = destination.appendingPathComponent(record.id, isDirectory: true)
      let src = URL(fileURLWithPath: record.path, isDirectory: true)
      do {
        // Codex CLI skips symlinks when loading skills, so we must use copy for codex target
        // Gemini CLI also supports symlinks, so we can use symlinks for both claude and gemini
        let forceCopy = (target == .codex)
        try ensureSkillLinked(from: src, to: dest, id: record.id, forceCopy: forceCopy)
      } catch {
        warnings.append(SkillSyncWarning(message: "\(record.id) could not sync to \(destination.path)"))
      }
    }

    removeManagedEntries(keeping: wanted, at: destination)
    return warnings
  }

  private func removeManagedEntries(keeping ids: Set<String>, at destination: URL) {
    guard let entries = try? fm.contentsOfDirectory(at: destination, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
    for entry in entries {
      let name = entry.lastPathComponent
      guard !ids.contains(name) else { continue }
      if isCodMateManagedSkill(at: entry) {
        try? fm.removeItem(at: entry)
      }
    }
  }

  private func ensureSkillLinked(from source: URL, to dest: URL, id: String, forceCopy: Bool = false) throws {
    if fm.fileExists(atPath: dest.path) {
      if isSymbolicLink(dest) {
        let link = try? fm.destinationOfSymbolicLink(atPath: dest.path)
        if let link, URL(fileURLWithPath: link).standardizedFileURL == source.standardizedFileURL {
          // If forceCopy is true but we have a symlink, remove it and copy
          if forceCopy {
            try fm.removeItem(at: dest)
          } else {
            return
          }
        } else {
          try fm.removeItem(at: dest)
        }
      } else if isCodMateManagedSkill(at: dest) {
        // Check if it's already a copy pointing to the same source
        let marker = dest.appendingPathComponent(".codmate.json", isDirectory: false)
        if fm.fileExists(atPath: marker.path),
           let data = try? Data(contentsOf: marker),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           (obj["id"] as? String) == id {
          return  // Already synced
        }
        try fm.removeItem(at: dest)
      } else {
        throw NSError(domain: "CodMate", code: -1, userInfo: [NSLocalizedDescriptionKey: "Skill conflict at \(dest.path)"])
      }
    }

    if forceCopy {
      // Force copy instead of symlink (needed for Codex CLI which skips symlinks)
      try fm.copyItem(at: source, to: dest)
      try writeMarker(to: dest, id: id)
    } else {
      do {
        try fm.createSymbolicLink(at: dest, withDestinationURL: source)
      } catch {
        try fm.copyItem(at: source, to: dest)
        try writeMarker(to: dest, id: id)
      }
    }
  }

  private func isSymbolicLink(_ url: URL) -> Bool {
    let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
    return values?.isSymbolicLink ?? false
  }

  private func writeMarker(to dir: URL, id: String) throws {
    let marker = dir.appendingPathComponent(".codmate.json", isDirectory: false)
    let obj: [String: Any] = [
      "managedByCodMate": true,
      "id": id
    ]
    let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
    try data.write(to: marker, options: .atomic)
  }

  private func isCodMateManagedSkill(at dir: URL) -> Bool {
    if isSymbolicLink(dir) {
      if let target = try? fm.destinationOfSymbolicLink(atPath: dir.path) {
        let resolved = URL(fileURLWithPath: target).standardizedFileURL
        return resolved.path.hasPrefix(libraryDir.standardizedFileURL.path)
      }
      return false
    }
    let marker = dir.appendingPathComponent(".codmate.json", isDirectory: false)
    guard fm.fileExists(atPath: marker.path),
          let data = try? Data(contentsOf: marker),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return false }
    return (obj["managedByCodMate"] as? Bool) == true
  }
}

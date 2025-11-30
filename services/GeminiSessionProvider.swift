import CryptoKit
import Foundation

actor GeminiSessionProvider {
  private let parser = GeminiSessionParser()
  private var projectsStore: ProjectsStore
  private let fileManager: FileManager
  private let tmpRoot: URL?

  private var hashToPath: [String: String] = [:]
  private var canonicalURLById: [String: URL] = [:]

  init(projectsStore: ProjectsStore, fileManager: FileManager = .default) {
    self.projectsStore = projectsStore
    self.fileManager = fileManager
    let home = SessionPreferencesStore.getRealUserHomeURL()
    let root = home.appendingPathComponent(".gemini", isDirectory: true)
      .appendingPathComponent("tmp", isDirectory: true)
    var isDir: ObjCBool = false
    if fileManager.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue {
      self.tmpRoot = root
    } else {
      self.tmpRoot = nil
    }
  }

  func sessions(scope: SessionLoadScope) async -> [SessionSummary] {
    guard let tmpRoot else { return [] }
    guard let hashes = try? fileManager.contentsOfDirectory(
      at: tmpRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
    else { return [] }

    var summaries: [SessionSummary] = []

    for hashURL in hashes {
      guard hashURL.hasDirectoryPath else { continue }
      let hash = hashURL.lastPathComponent
      guard hash.count == 64,
        hash.range(of: "^[0-9a-f]+$", options: .regularExpression) != nil
      else { continue }
      let chatsDir = hashURL.appendingPathComponent("chats", isDirectory: true)
      var isDir: ObjCBool = false
      guard fileManager.fileExists(atPath: chatsDir.path, isDirectory: &isDir), isDir.boolValue else {
        continue
      }
      guard let files = try? fileManager.contentsOfDirectory(
        at: chatsDir,
        includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
        options: [.skipsHiddenFiles])
      else { continue }

      let resolvedPath = await resolveProjectPath(forHash: hash)
      for file in files where file.pathExtension.lowercased() == "json" {
        if let parsed = parser.parse(at: file, projectHash: hash, resolvedProjectPath: resolvedPath) {
          if matches(scope: scope, summary: parsed.summary) {
            summaries.append(parsed.summary)
            canonicalURLById[parsed.summary.id] = file
          }
        }
      }
    }

    return summaries.sorted {
      let lhs = $0.lastUpdatedAt ?? $0.startedAt
      let rhs = $1.lastUpdatedAt ?? $1.startedAt
      return lhs > rhs
    }
  }

  func collectCWDCounts() async -> [String: Int] {
    guard let tmpRoot else { return [:] }
    var counts: [String: Int] = [:]
    guard let hashes = try? fileManager.contentsOfDirectory(
      at: tmpRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
    else { return [:] }

    for hashURL in hashes {
      guard hashURL.hasDirectoryPath else { continue }
      let hash = hashURL.lastPathComponent
      guard hash.count == 64,
        hash.range(of: "^[0-9a-f]+$", options: .regularExpression) != nil else { continue }
      let chats = hashURL.appendingPathComponent("chats", isDirectory: true)
      var isDir: ObjCBool = false
      guard fileManager.fileExists(atPath: chats.path, isDirectory: &isDir), isDir.boolValue else {
        continue
      }
      guard let files = try? fileManager.contentsOfDirectory(
        at: chats,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles])
      else { continue }

      let resolved = await resolveProjectPath(forHash: hash)
      for file in files where file.pathExtension.lowercased() == "json" {
        if let parsed = parser.parse(at: file, projectHash: hash, resolvedProjectPath: resolved) {
          counts[parsed.summary.cwd, default: 0] += 1
        }
      }
    }
    return counts
  }

  func countAllSessions() async -> Int {
    guard let tmpRoot else { return 0 }
    guard let hashes = try? fileManager.contentsOfDirectory(
      at: tmpRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
    else { return 0 }
    var total = 0
    for hashURL in hashes {
      guard hashURL.hasDirectoryPath else { continue }
      let chats = hashURL.appendingPathComponent("chats", isDirectory: true)
      var isDir: ObjCBool = false
      guard fileManager.fileExists(atPath: chats.path, isDirectory: &isDir), isDir.boolValue else {
        continue
      }
      if let files = try? fileManager.contentsOfDirectory(
        at: chats, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
      {
        total += files.filter { $0.pathExtension.lowercased() == "json" }.count
      }
    }
    return total
  }

  func timeline(for summary: SessionSummary) async -> [ConversationTurn]? {
    guard let url = canonicalURL(for: summary) else { return nil }
    guard
      let hash = projectHash(for: url),
      let parsed = parser.parse(
        at: url,
        projectHash: hash,
        resolvedProjectPath: await resolveProjectPath(forHash: hash))
    else { return nil }
    let loader = SessionTimelineLoader()
    return loader.turns(from: parsed.rows)
  }

  func enrich(summary: SessionSummary) async -> SessionSummary? {
    guard let url = canonicalURL(for: summary) else { return summary }
    guard
      let hash = projectHash(for: url),
      let parsed = parser.parse(
        at: url,
        projectHash: hash,
        resolvedProjectPath: await resolveProjectPath(forHash: hash))
    else { return summary }
    let loader = SessionTimelineLoader()
    let turns = loader.turns(from: parsed.rows)
    let activeDuration = computeActiveDuration(turns: turns)
    return SessionSummary(
      id: parsed.summary.id,
      fileURL: parsed.summary.fileURL,
      fileSizeBytes: parsed.summary.fileSizeBytes,
      startedAt: parsed.summary.startedAt,
      endedAt: parsed.summary.endedAt,
      activeDuration: activeDuration,
      cliVersion: parsed.summary.cliVersion,
      cwd: parsed.summary.cwd,
      originator: parsed.summary.originator,
      instructions: parsed.summary.instructions,
      model: parsed.summary.model,
      approvalPolicy: parsed.summary.approvalPolicy,
      userMessageCount: parsed.summary.userMessageCount,
      assistantMessageCount: parsed.summary.assistantMessageCount,
      toolInvocationCount: parsed.summary.toolInvocationCount,
      responseCounts: parsed.summary.responseCounts,
      turnContextCount: parsed.summary.turnContextCount,
      eventCount: parsed.summary.eventCount,
      lineCount: parsed.summary.lineCount,
      lastUpdatedAt: parsed.summary.lastUpdatedAt,
      source: .geminiLocal,
      remotePath: parsed.summary.remotePath,
      userTitle: parsed.summary.userTitle,
      userComment: parsed.summary.userComment,
      taskId: parsed.summary.taskId
    )
  }

  func sessions(inProjectDirectory directory: String) async -> [SessionSummary] {
    guard let hash = directoryHash(for: directory) else { return [] }
    guard let tmpRoot = tmpRoot else { return [] }
    let hashURL = tmpRoot.appendingPathComponent(hash, isDirectory: true)
    let chats = hashURL.appendingPathComponent("chats", isDirectory: true)
    var isDir: ObjCBool = false
    guard fileManager.fileExists(atPath: chats.path, isDirectory: &isDir), isDir.boolValue else {
      return []
    }
    guard let files = try? fileManager.contentsOfDirectory(
      at: chats,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles])
    else { return [] }
    var summaries: [SessionSummary] = []
    for file in files where file.pathExtension.lowercased() == "json" {
      if let parsed = parser.parse(at: file, projectHash: hash, resolvedProjectPath: directory) {
        summaries.append(parsed.summary)
        canonicalURLById[parsed.summary.id] = file
      }
    }
    return summaries
  }

  // MARK: - Helpers

  private func matches(scope: SessionLoadScope, summary: SessionSummary) -> Bool {
    let calendar = Calendar.current
    let referenceDates = [summary.startedAt, summary.lastUpdatedAt ?? summary.startedAt]
    switch scope {
    case .all:
      return true
    case .today:
      return referenceDates.contains { calendar.isDateInToday($0) }
    case .day(let day):
      return referenceDates.contains { calendar.isDate($0, inSameDayAs: day) }
    case .month(let date):
      return referenceDates.contains {
        calendar.isDate($0, equalTo: date, toGranularity: .month)
      }
    }
  }

  private func canonicalURL(for summary: SessionSummary) -> URL? {
    if let url = canonicalURLById[summary.id] { return url }
    return summary.fileURL
  }

  private func projectHash(for url: URL) -> String? {
    let components = url.pathComponents
    guard let chatsIndex = components.lastIndex(of: "chats"), chatsIndex > 0 else { return nil }
    return components[chatsIndex - 1]
  }

  private func resolveProjectPath(forHash hash: String) async -> String? {
    if let cached = hashToPath[hash] { return cached }
    let projects = await projectsStore.listProjects()
    let directories = projects.compactMap { $0.directory }
    for directory in directories {
      guard let digest = directoryHash(for: directory), digest == hash else { continue }
      hashToPath[hash] = normalized(directory)
      return hashToPath[hash]
    }
    return nil
  }

  private func directoryHash(for directory: String) -> String? {
    let expanded = (directory as NSString).expandingTildeInPath
    guard let data = expanded.data(using: .utf8) else { return nil }
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  private func normalized(_ directory: String) -> String {
    let expanded = (directory as NSString).expandingTildeInPath
    return URL(fileURLWithPath: expanded).standardizedFileURL.path
  }

  func invalidateProjectMappings() {
    hashToPath.removeAll()
  }

  func updateProjectsStore(_ store: ProjectsStore) {
    projectsStore = store
    hashToPath.removeAll()
  }

  private func computeActiveDuration(turns: [ConversationTurn]) -> TimeInterval? {
    guard !turns.isEmpty else { return nil }
    let filtered = turns.removingEnvironmentContext()
    guard !filtered.isEmpty else { return nil }
    var total: TimeInterval = 0
    for turn in filtered {
      let start = turn.userMessage?.timestamp ?? turn.outputs.first?.timestamp
      guard let s = start, let end = turn.outputs.last?.timestamp else { continue }
      let delta = end.timeIntervalSince(s)
      if delta > 0 { total += delta }
    }
    return total
  }
}

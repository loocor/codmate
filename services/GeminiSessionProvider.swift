import CryptoKit
import Foundation

actor GeminiSessionProvider {
  enum SessionProviderCacheError: Error {
    case cacheUnavailable
  }

  private struct AggregatedSession {
    let summary: SessionSummary
    let rows: [SessionRow]
    let primaryFileURL: URL
  }

  private struct GeminiLogEntry: Decodable {
    let sessionId: String
    let messageId: Int
    let type: String
    let message: String
    let timestamp: String
  }

  private struct GeminiSessionValidationRecord: Decodable {
    struct Message: Decodable {
      let type: String?
    }
    let messages: [Message]?
  }

  private let parser = GeminiSessionParser()
  private var projectsStore: ProjectsStore
  private let fileManager: FileManager
  private let tmpRoot: URL?
  private let cacheStore: SessionIndexSQLiteStore?

  private var hashToPath: [String: String] = [:]
  private var canonicalURLById: [String: URL] = [:]
  private var rowsCacheBySessionId: [String: [SessionRow]] = [:]
  private var logCacheByHash: [String: [String: [GeminiLogEntry]]] = [:]
  private var aggregatedCacheByHash: [String: AggregatedCacheEntry] = [:]
  private let logDateFormatter: ISO8601DateFormatter
  private let fallbackLogFormatter: ISO8601DateFormatter
  private static func hash(for path: String) -> String? {
    let canonical = (path as NSString).expandingTildeInPath
    guard let data = canonical.data(using: .utf8) else { return nil }
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  private struct AggregatedCacheEntry {
    let signature: HashSignature
    let sessions: [AggregatedSession]
  }

  private struct HashSignature: Equatable {
    let fileCount: Int
    let chatsTotalSize: UInt64
    let latestChatMtime: Date?
    let logSize: UInt64
    let logMtime: Date?
  }

  private struct CachedSummariesResult {
    let summaries: [SessionSummary]
    let isComplete: Bool
  }

  private func cachedSummaries(
    forHash hash: String,
    files: [ChatFileInfo],
    signature: HashSignature
  ) async throws -> CachedSummariesResult {
    guard let cacheStore else { throw SessionProviderCacheError.cacheUnavailable }
    guard let latest = signature.latestChatMtime else {
      return CachedSummariesResult(summaries: [], isComplete: true)
    }
    var bestById: [String: SessionSummary] = [:]
    var isComplete = true
    for file in files {
      let validity = sessionValidity(for: file.url)
      if validity == .invalid { continue }
      guard let cached = try await cacheStore.fetch(
        path: file.url.path,
        modificationDate: latest,
        fileSize: signature.chatsTotalSize
      ) else {
        isComplete = false
        continue
      }
      let summary = cached.overridingSource(.geminiLocal)
      canonicalURLById[summary.id] = file.url
      if let existing = bestById[summary.id] {
        bestById[summary.id] = prefer(lhs: existing, rhs: summary)
      } else {
        bestById[summary.id] = summary
      }
    }
    return CachedSummariesResult(summaries: Array(bestById.values), isComplete: isComplete)
  }

  private enum GeminiSessionValidity {
    case valid
    case invalid
    case unknown
  }

  private func sessionValidity(for url: URL) -> GeminiSessionValidity {
    guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return .unknown }
    guard let record = try? JSONDecoder().decode(GeminiSessionValidationRecord.self, from: data) else {
      return .unknown
    }
    guard let messages = record.messages, !messages.isEmpty else { return .invalid }
    for message in messages {
      let kind = message.type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if kind == "user" || kind == "gemini" { return .valid }
    }
    return .invalid
  }

  private func persist(summary: SessionSummary, modificationDate: Date?, fileSize: UInt64?) {
    guard let cacheStore else { return }
    Task.detached { [cacheStore] in
      try? await cacheStore.upsert(
        summary: summary,
        project: nil,
        fileModificationTime: modificationDate,
        fileSize: fileSize,
        tokenBreakdown: summary.tokenBreakdown,
        parseError: nil
      )
    }
  }

  init(
    projectsStore: ProjectsStore,
    fileManager: FileManager = .default,
    cacheStore: SessionIndexSQLiteStore? = nil
  ) {
    self.projectsStore = projectsStore
    self.fileManager = fileManager
    self.cacheStore = cacheStore
    let home = SessionPreferencesStore.getRealUserHomeURL()
    let root = home.appendingPathComponent(".gemini", isDirectory: true)
      .appendingPathComponent("tmp", isDirectory: true)
    var isDir: ObjCBool = false
    if fileManager.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue {
      self.tmpRoot = root
    } else {
      self.tmpRoot = nil
    }
    self.logDateFormatter = ISO8601DateFormatter()
    self.logDateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    self.fallbackLogFormatter = ISO8601DateFormatter()
    self.fallbackLogFormatter.formatOptions = [.withInternetDateTime]
  }

  func sessions(scope: SessionLoadScope, allowedProjectDirectories: [String]? = nil, ignoredPaths: [String] = []) async throws -> [SessionSummary] {
    guard cacheStore != nil else { throw SessionProviderCacheError.cacheUnavailable }
    let preferFullInitialParse = ((try? await cacheStore?.fetchMeta().sessionCount) ?? 0) == 0
    guard let tmpRoot else { return [] }
    guard let hashes = try? fileManager.contentsOfDirectory(
      at: tmpRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
    else { return [] }
    let allowedHashes: Set<String>? = {
      guard let allowed = allowedProjectDirectories, !allowed.isEmpty else { return nil }
      var hashes: Set<String> = []
      for path in allowed {
        if let hash = Self.hash(for: path) { hashes.insert(hash) }
      }
      return hashes.isEmpty ? nil : hashes
    }()

    rowsCacheBySessionId.removeAll()
    var summaries: [SessionSummary] = []

    for hashURL in hashes {
      guard hashURL.hasDirectoryPath else { continue }
      // Apply ignore rules
      if shouldIgnorePath(hashURL.path, ignoredPaths: ignoredPaths) {
        continue
      }
      let hash = hashURL.lastPathComponent
      guard hash.count == 64,
        hash.range(of: "^[0-9a-f]+$", options: .regularExpression) != nil
      else { continue }
      if let allowedHashes, !allowedHashes.contains(hash) { continue }
      let resolvedPath = await resolveProjectPath(forHash: hash)
      if !preferFullInitialParse, let fileInfo = chatFilesAndSignature(forHash: hash, hashURL: hashURL) {
        let cached = try await cachedSummaries(
          forHash: hash,
          files: fileInfo.files,
          signature: fileInfo.signature
        )
        if cached.isComplete {
          if !cached.summaries.isEmpty {
            for summary in cached.summaries where matches(scope: scope, summary: summary) {
              summaries.append(summary)
            }
          }
          continue
        }
      }

      let aggregated = aggregatedSessions(
        forHash: hash,
        hashURL: hashURL,
        resolvedProjectPath: resolvedPath,
        cacheResults: true)
      for session in aggregated where matches(scope: scope, summary: session.summary) {
        // Check ignore rules against cwd
        // Note: Cache is preserved - we filter out ignored sessions but don't delete cache entries.
        // This allows sessions to reappear if ignore rules are removed later.
        // (aggregatedSessions already cached with cacheResults: true)
        if shouldIgnoreSummary(session.summary, ignoredPaths: ignoredPaths) {
          continue
        }
        summaries.append(session.summary)
        rowsCacheBySessionId[session.summary.id] = session.rows
        canonicalURLById[session.summary.id] = session.primaryFileURL
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
    guard let hashes = try? fileManager.contentsOfDirectory(
      at: tmpRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
    else { return [:] }

    var counts: [String: Int] = [:]
    for hashURL in hashes {
      guard hashURL.hasDirectoryPath else { continue }
      let hash = hashURL.lastPathComponent
      guard hash.count == 64,
        hash.range(of: "^[0-9a-f]+$", options: .regularExpression) != nil
      else { continue }
      let resolved = await resolveProjectPath(forHash: hash)
      let aggregated = aggregatedSessions(
        forHash: hash,
        hashURL: hashURL,
        resolvedProjectPath: resolved,
        cacheResults: false)
      for session in aggregated {
        counts[session.summary.cwd, default: 0] += 1
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
      let hash = hashURL.lastPathComponent
      guard hash.count == 64,
        hash.range(of: "^[0-9a-f]+$", options: .regularExpression) != nil
      else { continue }
      let resolved = await resolveProjectPath(forHash: hash)
      let aggregated = aggregatedSessions(
        forHash: hash,
        hashURL: hashURL,
        resolvedProjectPath: resolved,
        cacheResults: false)
      total += aggregated.count
    }
    return total
  }

  func timeline(for summary: SessionSummary) async -> [ConversationTurn]? {
    guard let rows = await rowsForSession(summary: summary) else { return nil }
    let loader = SessionTimelineLoader()
    return loader.turns(from: rows)
  }

  func environmentContext(for summary: SessionSummary) async -> EnvironmentContextInfo? {
    guard let rows = await rowsForSession(summary: summary) else { return nil }
    let loader = SessionTimelineLoader()
    return loader.loadEnvironmentContext(from: rows)
  }

  func enrich(summary: SessionSummary) async -> SessionSummary? {
    guard let rows = await rowsForSession(summary: summary) else { return summary }
    let loader = SessionTimelineLoader()
    let turns = loader.turns(from: rows)
    let activeDuration = computeActiveDuration(turns: turns)
    return SessionSummary(
      id: summary.id,
      fileURL: summary.fileURL,
      fileSizeBytes: summary.fileSizeBytes,
      startedAt: summary.startedAt,
      endedAt: summary.endedAt,
      activeDuration: activeDuration,
      cliVersion: summary.cliVersion,
      cwd: summary.cwd,
      originator: summary.originator,
      instructions: summary.instructions,
      model: summary.model,
      approvalPolicy: summary.approvalPolicy,
      userMessageCount: summary.userMessageCount,
      assistantMessageCount: summary.assistantMessageCount,
      toolInvocationCount: summary.toolInvocationCount,
      responseCounts: summary.responseCounts,
      turnContextCount: summary.turnContextCount,
      totalTokens: summary.totalTokens,
      tokenBreakdown: summary.tokenBreakdown,
      eventCount: summary.eventCount,
      lineCount: summary.lineCount,
      lastUpdatedAt: summary.lastUpdatedAt,
      source: .geminiLocal,
      remotePath: summary.remotePath,
      userTitle: summary.userTitle,
      userComment: summary.userComment,
      taskId: summary.taskId
    )
  }

  func sessions(inProjectDirectory directory: String) async -> [SessionSummary] {
    guard let hash = directoryHash(for: directory) else { return [] }
    guard let tmpRoot else { return [] }
    let hashURL = tmpRoot.appendingPathComponent(hash, isDirectory: true)
    let aggregated = aggregatedSessions(
      forHash: hash,
      hashURL: hashURL,
      resolvedProjectPath: directory,
      cacheResults: true)
    for session in aggregated {
      rowsCacheBySessionId[session.summary.id] = session.rows
      canonicalURLById[session.summary.id] = session.primaryFileURL
    }
    return aggregated.map { $0.summary }
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
    canonicalURLById[summary.id] ?? summary.fileURL
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

  private func rowsForSession(summary: SessionSummary) async -> [SessionRow]? {
    if let rows = rowsCacheBySessionId[summary.id] { return rows }
    guard let url = canonicalURL(for: summary),
      let hash = projectHash(for: url),
      let tmpRoot
    else { return nil }
    let hashURL = tmpRoot.appendingPathComponent(hash, isDirectory: true)
    let resolved = await resolveProjectPath(forHash: hash)
    let aggregated = aggregatedSessions(
      forHash: hash,
      hashURL: hashURL,
      resolvedProjectPath: resolved,
      cacheResults: true)
    for session in aggregated {
      rowsCacheBySessionId[session.summary.id] = session.rows
      canonicalURLById[session.summary.id] = session.primaryFileURL
    }
    return rowsCacheBySessionId[summary.id]
  }

  private func aggregatedSessions(
    forHash hash: String,
    hashURL: URL,
    resolvedProjectPath: String?,
    cacheResults: Bool
  ) -> [AggregatedSession] {
    guard let fileInfo = chatFilesAndSignature(forHash: hash, hashURL: hashURL) else { return [] }
    if let cached = aggregatedCacheByHash[hash], cached.signature == fileInfo.signature {
      if cacheResults {
        for session in cached.sessions {
          rowsCacheBySessionId[session.summary.id] = session.rows
          canonicalURLById[session.summary.id] = session.primaryFileURL
        }
      }
      return cached.sessions
    }

    var segmentsBySession: [String: [GeminiParsedLog]] = [:]
    for info in fileInfo.files where info.url.pathExtension.lowercased() == "json" {
      // Note: ignore rules are applied at hash directory level, not individual files
      guard let parsed = parser.parse(
        at: info.url, projectHash: hash, resolvedProjectPath: resolvedProjectPath)
      else { continue }
      segmentsBySession[parsed.summary.id, default: []].append(parsed)
    }
    guard !segmentsBySession.isEmpty else { return [] }

    if cacheResults {
      logCacheByHash.removeValue(forKey: hash)
    }
    let logEntries = logEntriesBySession(forHash: hash)
    var results: [AggregatedSession] = []
    for (sessionId, segments) in segmentsBySession {
      guard let aggregated = aggregate(
        segments: segments,
        extraLogEntries: logEntries[sessionId])
      else { continue }
      results.append(aggregated)
      if cacheResults {
        rowsCacheBySessionId[aggregated.summary.id] = aggregated.rows
        canonicalURLById[aggregated.summary.id] = aggregated.primaryFileURL
        persist(summary: aggregated.summary, modificationDate: fileInfo.signature.latestChatMtime, fileSize: fileInfo.signature.chatsTotalSize)
      }
    }

    if cacheResults {
      aggregatedCacheByHash[hash] = AggregatedCacheEntry(signature: fileInfo.signature, sessions: results)
    }
    return results
  }

  private func aggregate(
    segments: [GeminiParsedLog],
    extraLogEntries: [GeminiLogEntry]?
  ) -> AggregatedSession? {
    guard !segments.isEmpty else { return nil }
    var rows: [SessionRow] = []
    let orderedSegments = segments.sorted { lhs, rhs in
      lhs.summary.startedAt < rhs.summary.startedAt
    }
    for segment in orderedSegments { rows.append(contentsOf: segment.rows) }
    if let extras = extraLogEntries {
      rows.append(contentsOf: rowsFromLogs(extras))
    }
    let normalized = normalize(rows: rows)
    guard !normalized.isEmpty else { return nil }
    let timelineLoader = SessionTimelineLoader()
    let turns = timelineLoader.turns(from: normalized)
    let conversationCount = turns.count
    let assistantMessages = turns.reduce(into: 0) { partialResult, turn in
      partialResult += turn.outputs.filter { $0.actor == .assistant }.count
    }

    var builder = SessionSummaryBuilder()
    builder.setSource(.geminiLocal)
    let totalSize = segments.compactMap { $0.summary.fileSizeBytes }.reduce(0, +)
    if totalSize > 0 { builder.setFileSize(totalSize) }
    for row in normalized { builder.observe(row) }
    if let lastTimestamp = normalized.last?.timestamp {
      builder.seedLastUpdated(lastTimestamp)
    }
    guard let representative = segments.max(by: { ($0.summary.lastUpdatedAt ?? $0.summary.startedAt) < ($1.summary.lastUpdatedAt ?? $1.summary.startedAt) })
    else { return nil }
    guard var summary = builder.build(for: representative.summary.fileURL) else { return nil }
    summary = summary
      .overridingSource(.geminiLocal)
      .overridingCounts(userMessages: conversationCount, assistantMessages: assistantMessages)

    // Aggregate token usage across all Gemini segments using the raw chat JSON.
    var totalInput = 0
    var totalOutput = 0
    var totalCached = 0
    var totalThoughts = 0
    var totalTool = 0

    for segment in segments {
      guard let tokens = segment.tokens else { continue }
      if tokens.input > 0 { totalInput &+= tokens.input }
      if tokens.output > 0 { totalOutput &+= tokens.output }
      if tokens.cached > 0 { totalCached &+= tokens.cached }
      if tokens.thoughts > 0 { totalThoughts &+= tokens.thoughts }
      if tokens.tool > 0 { totalTool &+= tokens.tool }
    }

    if totalInput != 0 || totalOutput != 0 || totalCached != 0 || totalThoughts != 0 || totalTool != 0 {
      // Treat Gemini output as the sum of output, thoughts, and tool tokens.
      let aggregatedOutput = totalOutput &+ totalThoughts &+ totalTool
      let aggregatedInput = totalInput
      let aggregatedCacheRead = totalCached
      let aggregatedCacheCreation = 0

      let breakdown = SessionTokenBreakdown(
        input: max(aggregatedInput, 0),
        output: max(aggregatedOutput, 0),
        cacheRead: max(aggregatedCacheRead, 0),
        cacheCreation: max(aggregatedCacheCreation, 0)
      )

      // Session-wide total tokens = sum of per-message totals (input + output + thoughts + tool).
      let totalTokens = breakdown.total
      summary = summary.overridingTokens(
        totalTokens: totalTokens,
        tokenBreakdown: breakdown
      )
    }

    return AggregatedSession(summary: summary, rows: normalized, primaryFileURL: representative.summary.fileURL)
  }

  private struct ChatFileInfo {
    let url: URL
    let modificationDate: Date?
    let size: UInt64
  }

  private func chatFilesAndSignature(
    forHash hash: String,
    hashURL: URL
  ) -> (files: [ChatFileInfo], signature: HashSignature)? {
    let chatsDir = hashURL.appendingPathComponent("chats", isDirectory: true)
    var isDir: ObjCBool = false
    guard fileManager.fileExists(atPath: chatsDir.path, isDirectory: &isDir), isDir.boolValue else {
      return nil
    }
    guard let files = try? fileManager.contentsOfDirectory(
      at: chatsDir,
      includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
      options: [.skipsHiddenFiles])
    else { return nil }

    var infos: [ChatFileInfo] = []
    var totalSize: UInt64 = 0
    var latestMtime: Date?
    var fileCount = 0

    for file in files where file.pathExtension.lowercased() == "json" {
      guard let values = try? file.resourceValues(
        forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
        values.isRegularFile == true
      else { continue }
      fileCount += 1
      let size = UInt64(values.fileSize ?? 0)
      totalSize += size
      if let m = values.contentModificationDate {
        if latestMtime == nil || m > latestMtime! { latestMtime = m }
      }
      infos.append(ChatFileInfo(url: file, modificationDate: values.contentModificationDate, size: size))
    }

    let logURL = hashURL.appendingPathComponent("logs.json", isDirectory: false)
    let logValues = try? logURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    let logSize = UInt64(logValues?.fileSize ?? 0)
    let logMtime = logValues?.contentModificationDate
    if let logMtime, latestMtime == nil || logMtime > latestMtime! {
      latestMtime = logMtime
    }

    let signature = HashSignature(
      fileCount: fileCount,
      chatsTotalSize: totalSize,
      latestChatMtime: latestMtime,
      logSize: logSize,
      logMtime: logMtime)
    return (infos, signature)
  }

  private func rowsFromLogs(_ logEntries: [GeminiLogEntry]) -> [SessionRow] {
    logEntries.compactMap { entry in
      guard entry.type.lowercased() == "user" else { return nil }
      guard let timestamp = parseLogDate(entry.timestamp) else { return nil }
      let text = entry.message.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty, !GeminiSessionParser.isControlCommand(text) else { return nil }
      let payload = EventMessagePayload(
        type: "user_message",
        message: text,
        kind: nil,
        text: text,
        reason: nil,
        info: nil,
        rateLimits: nil
      )
      return SessionRow(timestamp: timestamp, kind: .eventMessage(payload))
    }
  }

  private func normalize(rows: [SessionRow]) -> [SessionRow] {
    guard !rows.isEmpty else { return [] }
    let ordered = rows.enumerated().sorted { lhs, rhs in
      if lhs.element.timestamp == rhs.element.timestamp { return lhs.offset < rhs.offset }
      return lhs.element.timestamp < rhs.element.timestamp
    }

    var deduped: [SessionRow] = []
    var repeatCountByIndex: [Int: Int] = [:]
    var userEntryByText: [String: (index: Int, timestamp: Date)] = [:]
    let duplicateWindow: TimeInterval = 5.0

    for (_, row) in ordered {
      var shouldAppend = true
      if case let .eventMessage(payload) = row.kind,
        payload.type.lowercased() == "user_message"
      {
        let normalizedText = (payload.message ?? payload.text ?? "")
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = userEntryByText[normalizedText],
          abs(row.timestamp.timeIntervalSince(existing.timestamp)) < duplicateWindow
        {
          repeatCountByIndex[existing.index, default: 1] += 1
          userEntryByText[normalizedText] = (existing.index, row.timestamp)
          shouldAppend = false
        } else {
          let index = deduped.count
          userEntryByText[normalizedText] = (index, row.timestamp)
          repeatCountByIndex[index] = 1
        }
      }

      if shouldAppend {
        deduped.append(row)
      }
    }

    if !repeatCountByIndex.isEmpty {
      for (index, count) in repeatCountByIndex where count > 1 {
        guard index < deduped.count else { continue }
        deduped[index] = injectRepeatCount(into: deduped[index], count: count)
      }
    }

    return deduped
  }

  private func injectRepeatCount(into row: SessionRow, count: Int) -> SessionRow {
    guard count > 1 else { return row }
    guard case let .eventMessage(payload) = row.kind else { return row }
    var metadata: [String: JSONValue] = [:]
    if case let .object(existing) = payload.info {
      metadata = existing
    }
    metadata["repeat_count"] = .number(Double(count))
    let updatedPayload = EventMessagePayload(
      type: payload.type,
      message: payload.message,
      kind: payload.kind,
      text: payload.text,
      reason: payload.reason,
      info: metadata.isEmpty ? nil : .object(metadata),
      rateLimits: payload.rateLimits
    )
    return SessionRow(timestamp: row.timestamp, kind: .eventMessage(updatedPayload))
  }

  private func prefer(lhs: SessionSummary, rhs: SessionSummary) -> SessionSummary {
    if lhs.id != rhs.id { return lhs }
    let lt = lhs.lastUpdatedAt ?? lhs.startedAt
    let rt = rhs.lastUpdatedAt ?? rhs.startedAt
    if lt != rt { return lt > rt ? lhs : rhs }
    let ls = lhs.fileSizeBytes ?? 0
    let rs = rhs.fileSizeBytes ?? 0
    if ls != rs { return ls > rs ? lhs : rhs }
    return lhs.fileURL.lastPathComponent < rhs.fileURL.lastPathComponent ? lhs : rhs
  }

  private func logEntriesBySession(forHash hash: String) -> [String: [GeminiLogEntry]] {
    if let cached = logCacheByHash[hash] { return cached }
    guard let tmpRoot else {
      logCacheByHash[hash] = [:]
      return [:]
    }
    let logURL = tmpRoot
      .appendingPathComponent(hash, isDirectory: true)
      .appendingPathComponent("logs.json", isDirectory: false)
    guard let data = try? Data(contentsOf: logURL) else {
      logCacheByHash[hash] = [:]
      return [:]
    }
    guard let entries = try? JSONDecoder().decode([GeminiLogEntry].self, from: data) else {
      logCacheByHash[hash] = [:]
      return [:]
    }
    var grouped: [String: [GeminiLogEntry]] = [:]
    for entry in entries {
      grouped[entry.sessionId, default: []].append(entry)
    }
    for key in grouped.keys {
      grouped[key]?.sort(by: { $0.messageId < $1.messageId })
    }
    logCacheByHash[hash] = grouped
    return grouped
  }

  private func parseLogDate(_ value: String) -> Date? {
    if let date = logDateFormatter.date(from: value) { return date }
    return fallbackLogFormatter.date(from: value)
  }
}

// MARK: - SessionProvider

extension GeminiSessionProvider: SessionProvider {
  nonisolated var kind: SessionSource.Kind { .gemini }
  nonisolated var identifier: String { "gemini-local" }
  nonisolated var label: String { "Gemini (local)" }

  func load(context: SessionProviderContext) async throws -> SessionProviderResult {
    switch context.cachePolicy {
    case .cacheOnly:
      if let cacheStore {
        let dateColumn = context.dateDimension == .updated ? "COALESCE(last_updated_at, started_at)" : "started_at"
        let range = context.dateRange ?? Self.dateRange(for: context.scope)
        var cached = try await cacheStore.fetchSummaries(
          kinds: [.gemini],
          includeRemote: false,
          dateColumn: dateColumn,
          dateRange: range,
          projectIds: context.projectIds
        )
        // Apply ignore rules to cached results
        let originalCount = cached.count
        if !context.ignoredPaths.isEmpty {
          cached = cached.filter { !shouldIgnoreSummary($0, ignoredPaths: context.ignoredPaths) }
          print("GeminiSessionProvider: filtered \(originalCount - cached.count) sessions by ignore rules (\(cached.count) remain)")
        }
        if !cached.isEmpty {
          let filtered = cached.filter { sessionValidity(for: $0.fileURL) != .invalid }
          return SessionProviderResult(summaries: filtered, coverage: nil, cacheHit: true)
        }
      }
      return SessionProviderResult(summaries: [], coverage: nil, cacheHit: true)
    case .refresh:
      guard cacheStore != nil else { throw SessionProviderCacheError.cacheUnavailable }
      let summaries = try await sessions(
        scope: context.scope,
        allowedProjectDirectories: context.projectDirectories,
        ignoredPaths: context.ignoredPaths
      )
      return SessionProviderResult(summaries: summaries, coverage: nil, cacheHit: false)
    }
  }

  private static func dateRange(for scope: SessionLoadScope) -> (Date, Date)? {
    let cal = Calendar.current
    switch scope {
    case .all:
      return nil
    case .today:
      let start = cal.startOfDay(for: Date())
      guard let end = cal.date(byAdding: .day, value: 1, to: start)?.addingTimeInterval(-1) else { return nil }
      return (start, end)
    case .day(let day):
      let start = cal.startOfDay(for: day)
      guard let end = cal.date(byAdding: .day, value: 1, to: start)?.addingTimeInterval(-1) else { return nil }
      return (start, end)
    case .month(let date):
      guard
        let start = cal.date(from: cal.dateComponents([.year, .month], from: date)),
        let end = cal.date(byAdding: DateComponents(month: 1, second: -1), to: start)
      else { return nil }
      return (start, end)
    }
  }
  
  // MARK: - Ignore Rules
  
  private func shouldIgnorePath(_ absolutePath: String, ignoredPaths: [String]) -> Bool {
    SessionPathFilter.shouldIgnorePath(absolutePath, ignoredPaths: ignoredPaths)
  }
  
  private func shouldIgnoreSummary(_ summary: SessionSummary, ignoredPaths: [String]) -> Bool {
    SessionPathFilter.shouldIgnoreSummary(summary, ignoredPaths: ignoredPaths)
  }
}

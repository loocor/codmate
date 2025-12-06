import Foundation
import OSLog
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Token 分项，用于长期保留 input/output/cache 细粒度统计。
struct TokenBreakdown: Sendable, Equatable {
  let input: Int
  let output: Int
  let cacheRead: Int
  let cacheCreation: Int

  var total: Int { input + output + cacheRead + cacheCreation }
}

/// 持久化缓存的一条记录，包含 SessionSummary 以及文件元数据。
struct SessionIndexRecord: Sendable {
  let summary: SessionSummary
  let filePath: String
  let fileModificationTime: Date?
  let fileSize: UInt64?
  let project: String?
  let schemaVersion: Int
  let parseError: String?
  let tokenBreakdown: TokenBreakdown?
  let parseLevel: String?  // "metadata" | "full" | "enriched"
  let parsedAt: Date?       // When this parse was done
}

struct SessionIndexMeta: Sendable {
  let lastFullIndexAt: Date?
  let sessionCount: Int
}

enum SessionIndexSQLiteStoreError: Error {
  case openFailed(String)
  case stepFailed(String)
  case bindFailed(String)
  case decodeFailed(String)
}

/// SQLite 持久化缓存，负责 sessions 汇总数据的存储与读取。
  actor SessionIndexSQLiteStore {
    static let schemaVersion = 1

    private let logger = Logger(subsystem: "io.umate.codmate", category: "SessionIndexSQLiteStore")
    private let dbURL: URL
    private var db: OpaquePointer?
    private var missingDbLogged = false

  init(baseDirectory: URL? = nil, fileManager: FileManager = .default) {
    let directory: URL
    if let baseDirectory {
      directory = baseDirectory
    } else {
      directory = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codmate", isDirectory: true)
    }
    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    dbURL = directory.appendingPathComponent("sessionIndex-v2.db")
  }

  // MARK: - Public API

  func reset() throws {
    closeDatabase()
    try? FileManager.default.removeItem(at: dbURL)
  }

  /// 更新全量索引完成时间和记录数。
  func setMeta(lastFullIndexAt: Date, sessionCount: Int) throws {
    try openIfNeeded()
    let sql =
      "INSERT INTO meta (key, last_full_index_at, session_count) VALUES ('global', ?1, ?2) ON CONFLICT(key) DO UPDATE SET last_full_index_at=excluded.last_full_index_at, session_count=excluded.session_count"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
      throw SessionIndexSQLiteStoreError.stepFailed(errorMessage)
    }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_double(stmt, 1, lastFullIndexAt.timeIntervalSince1970)
    sqlite3_bind_int(stmt, 2, Int32(sessionCount))
    guard sqlite3_step(stmt) == SQLITE_DONE else {
      throw SessionIndexSQLiteStoreError.stepFailed(errorMessage)
    }
  }

  func fetchMeta() throws -> SessionIndexMeta {
    try openIfNeeded()
    let sql = "SELECT last_full_index_at, session_count FROM meta WHERE key = 'global' LIMIT 1"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
      throw SessionIndexSQLiteStoreError.stepFailed(errorMessage)
    }
    defer { sqlite3_finalize(stmt) }
    if sqlite3_step(stmt) == SQLITE_ROW {
      let ts = sqlite3_column_double(stmt, 0)
      let count = Int(sqlite3_column_int(stmt, 1))
      let date = ts == 0 ? nil : Date(timeIntervalSince1970: ts)
      return SessionIndexMeta(lastFullIndexAt: date, sessionCount: count)
    }
    return SessionIndexMeta(lastFullIndexAt: nil, sessionCount: 0)
  }

  /// 按文件路径 + mtime（可选 fileSize 校验）命中缓存，用于索引快速路径。
  func fetch(path: String, modificationDate: Date?, fileSize: UInt64?) throws -> SessionSummary? {
    guard let modificationDate else { return nil }
    try openIfNeeded()
    let sql =
      "SELECT payload, file_size FROM sessions WHERE file_path = ?1 AND file_mtime = ?2 LIMIT 1"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
      throw SessionIndexSQLiteStoreError.stepFailed(errorMessage)
    }
    defer { sqlite3_finalize(stmt) }

    sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)
    sqlite3_bind_double(stmt, 2, modificationDate.timeIntervalSince1970)

    if sqlite3_step(stmt) == SQLITE_ROW {
      let storedSize = columnInt64(stmt, index: 1).flatMap { UInt64($0) }
      if let fileSize, let storedSize, fileSize != storedSize {
        logger.info("cache miss (size mismatch) for path=\(path, privacy: .public)")
        return nil
      }
      guard let payload = columnData(stmt, index: 0) else { return nil }
      let summary = try JSONDecoder().decode(SessionSummary.self, from: payload)
      logger.info("cache hit (path+mtime) kind=\(summary.source.baseKind.rawValue, privacy: .public) path=\(path, privacy: .public)")
      return summary
    }
    logger.info("cache miss (path+mtime) path=\(path, privacy: .public)")
    return nil
  }

  func fetch(sessionId: String) throws -> SessionIndexRecord? {
    try openIfNeeded()
    let sql = "SELECT payload, file_path, file_mtime, file_size, project, schema_version, parse_error, tokens_input, tokens_output, tokens_cache_read, tokens_cache_creation, parse_level, parsed_at FROM sessions WHERE session_id = ?1" // swiftlint:disable:this line_length
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
      throw SessionIndexSQLiteStoreError.stepFailed(errorMessage)
    }
    defer { sqlite3_finalize(stmt) }

    sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT)

    if sqlite3_step(stmt) == SQLITE_ROW {
      guard let payload = columnData(stmt, index: 0) else {
        throw SessionIndexSQLiteStoreError.decodeFailed("Missing payload for session_id=\(sessionId)")
      }
      let summary = try JSONDecoder().decode(SessionSummary.self, from: payload)
      let filePath = columnText(stmt, index: 1) ?? summary.fileURL.path
      let fileMtime = columnDate(stmt, index: 2)
      let fileSize = columnInt64(stmt, index: 3).flatMap { UInt64($0) }
      let project = columnText(stmt, index: 4)
      let schemaVersion = Int(sqlite3_column_int(stmt, 5))
      let parseError = columnText(stmt, index: 6)
      let tokenBreakdown = tokenBreakdownFromColumns(stmt, startIndex: 7)
      let parseLevel = columnText(stmt, index: 11)
      let parsedAt = columnDate(stmt, index: 12)
      return SessionIndexRecord(
        summary: summary,
        filePath: filePath,
        fileModificationTime: fileMtime,
        fileSize: fileSize,
        project: project,
        schemaVersion: schemaVersion,
        parseError: parseError,
        tokenBreakdown: tokenBreakdown,
        parseLevel: parseLevel,
        parsedAt: parsedAt
      )
    }
    return nil
  }

  func fetchAll(limit: Int? = nil) throws -> [SessionIndexRecord] {
    try openIfNeeded()
    var sql = "SELECT payload, file_path, file_mtime, file_size, project, schema_version, parse_error, tokens_input, tokens_output, tokens_cache_read, tokens_cache_creation, parse_level, parsed_at FROM sessions"
    if let limit { sql += " LIMIT \(limit)" }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
      throw SessionIndexSQLiteStoreError.stepFailed(errorMessage)
    }
    defer { sqlite3_finalize(stmt) }

    var result: [SessionIndexRecord] = []
    let decoder = JSONDecoder()
    while sqlite3_step(stmt) == SQLITE_ROW {
      guard let payload = columnData(stmt, index: 0) else { continue }
      guard let summary = try? decoder.decode(SessionSummary.self, from: payload) else { continue }
      let filePath = columnText(stmt, index: 1) ?? summary.fileURL.path
      let fileMtime = columnDate(stmt, index: 2)
      let fileSize = columnInt64(stmt, index: 3).flatMap { UInt64($0) }
      let project = columnText(stmt, index: 4)
      let schemaVersion = Int(sqlite3_column_int(stmt, 5))
      let parseError = columnText(stmt, index: 6)
      let tokenBreakdown = tokenBreakdownFromColumns(stmt, startIndex: 7)
      let parseLevel = columnText(stmt, index: 11)
      let parsedAt = columnDate(stmt, index: 12)
      result.append(
        SessionIndexRecord(
          summary: summary,
          filePath: filePath,
          fileModificationTime: fileMtime,
          fileSize: fileSize,
          project: project,
          schemaVersion: schemaVersion,
          parseError: parseError,
          tokenBreakdown: tokenBreakdown,
          parseLevel: parseLevel,
          parsedAt: parsedAt
        )
      )
    }
    return result
  }

  /// 聚合 Overview 统计（全部来源，使用缓存数据）。
  func fetchOverviewAggregate(scope: OverviewAggregateScope? = nil) throws -> OverviewAggregate {
    let started = Date()
    try openIfNeeded()
    let totals = try fetchTotals(scope: scope)
    let sources = try fetchSourceAggregates(scope: scope)
    let daily = try fetchDailyAggregates(scope: scope)
    let elapsed = Date().timeIntervalSince(started)
    logger.log("fetchOverviewAggregate totals.sessions=\(totals.sessions, privacy: .public) sources=\(sources.count, privacy: .public) daily=\(daily.count, privacy: .public) in \(elapsed, format: .fixed(precision: 3))s")
    return OverviewAggregate(
      totalSessions: totals.sessions,
      totalTokens: totals.tokens,
      totalDuration: totals.duration,
      userMessages: totals.userMessages,
      assistantMessages: totals.assistantMessages,
      toolInvocations: totals.toolInvocations,
      sources: sources,
      daily: daily,
      generatedAt: Date()
    )
  }

  /// 缓存覆盖范围（命中源、记录数、全量完成时间）。
  func fetchCoverage() throws -> SessionIndexCoverage {
    let started = Date()
    try openIfNeeded()
    let meta = try fetchMeta()
    let sources = try distinctSources()
    let sessionCount = try countSessions()
    let elapsed = Date().timeIntervalSince(started)
    logger.log("fetchCoverage sessions=\(sessionCount, privacy: .public) sources=\(sources, privacy: .public) metaTs=\(meta.lastFullIndexAt?.timeIntervalSince1970 ?? 0, privacy: .public) in \(elapsed, format: .fixed(precision: 3))s")
    return SessionIndexCoverage(
      sessionCount: sessionCount,
      lastFullIndexAt: meta.lastFullIndexAt,
      sources: sources
    )
  }

  func upsert(
    summary: SessionSummary,
    project: String?,
    fileModificationTime: Date?,
    fileSize: UInt64?,
    tokenBreakdown: TokenBreakdown?,
    parseError: String? = nil,
    parseLevel: String = "full"  // "metadata" | "full" | "enriched"
  ) throws {
    try openIfNeeded()

    // Downgrade protection:
    // If we already have a record for this session, check if the new data would overwrite
    // a high-quality parse (full/enriched) with a low-quality one (metadata) when the file hasn't changed.
    if let oldRecord = try? fetch(sessionId: summary.id) {
      // Check if file is effectively unchanged
      let mtimeChanged = (fileModificationTime != nil && oldRecord.fileModificationTime != nil) &&
                         (abs(fileModificationTime!.timeIntervalSince1970 - oldRecord.fileModificationTime!.timeIntervalSince1970) > 0.001)
      let sizeChanged = (fileSize != nil && oldRecord.fileSize != nil) && (fileSize != oldRecord.fileSize)
      let fileUnchanged = !mtimeChanged && !sizeChanged

      if fileUnchanged {
        let oldRank = parseLevelRank(oldRecord.parseLevel)
        let newRank = parseLevelRank(parseLevel)

        // If trying to overwrite higher rank with lower rank (e.g. Full -> Metadata),
        // we SKIP the update for all content fields to preserve the better data.
        // However, we might want to update last_updated_at if the new one is fresher
        // (though usually full parse has better timestamp too).
        // For safety, we just abort the upsert entirely if we are downgrading on same file.
        if newRank < oldRank {
          // logger.debug("Skipping upsert for \(summary.id): preventing downgrade from \(oldRecord.parseLevel ?? "nil") to \(parseLevel)")
          return
        }
      }
    }

    let sql = """
    INSERT INTO sessions (
      session_id, file_path, file_mtime, file_size, schema_version, parse_error,
      project, source, source_host, started_at, ended_at, last_updated_at,
      active_duration, cli_version, cwd, originator, instructions, model,
      approval_policy, user_message_count, assistant_message_count,
      tool_invocation_count, reasoning_count, response_counts_json,
      turn_context_count, tokens_input, tokens_output, tokens_cache_read,
      tokens_cache_creation, tokens_total, event_count, line_count, remote_path,
      user_title, user_comment, task_id, has_terminal, has_review, payload,
      parse_level, parsed_at
    ) VALUES (
      ?1, ?2, ?3, ?4, ?5, ?6,
      ?7, ?8, ?9, ?10, ?11, ?12,
      ?13, ?14, ?15, ?16, ?17, ?18,
      ?19, ?20, ?21, ?22, ?23, ?24,
      ?25, ?26, ?27, ?28, ?29, ?30,
      ?31, ?32, ?33, ?34, ?35, ?36, ?37, ?38, ?39,
      ?40, ?41
    )
    ON CONFLICT(session_id) DO UPDATE SET
      file_path=excluded.file_path,
      file_mtime=excluded.file_mtime,
      file_size=excluded.file_size,
      schema_version=excluded.schema_version,
      parse_error=excluded.parse_error,
      project=excluded.project,
      source=excluded.source,
      source_host=excluded.source_host,
      started_at=excluded.started_at,
      ended_at=excluded.ended_at,
      last_updated_at=excluded.last_updated_at,
      active_duration=excluded.active_duration,
      cli_version=excluded.cli_version,
      cwd=excluded.cwd,
      originator=excluded.originator,
      instructions=excluded.instructions,
      model=excluded.model,
      approval_policy=excluded.approval_policy,
      user_message_count=excluded.user_message_count,
      assistant_message_count=excluded.assistant_message_count,
      tool_invocation_count=excluded.tool_invocation_count,
      reasoning_count=excluded.reasoning_count,
      response_counts_json=excluded.response_counts_json,
      turn_context_count=excluded.turn_context_count,
      tokens_input=excluded.tokens_input,
      tokens_output=excluded.tokens_output,
      tokens_cache_read=excluded.tokens_cache_read,
      tokens_cache_creation=excluded.tokens_cache_creation,
      tokens_total=excluded.tokens_total,
      event_count=excluded.event_count,
      line_count=excluded.line_count,
      remote_path=excluded.remote_path,
      user_title=excluded.user_title,
      user_comment=excluded.user_comment,
      task_id=excluded.task_id,
      has_terminal=excluded.has_terminal,
      has_review=excluded.has_review,
      payload=excluded.payload,
      parse_level=excluded.parse_level,
      parsed_at=excluded.parsed_at
    """

    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
      throw SessionIndexSQLiteStoreError.stepFailed(errorMessage)
    }
    defer { sqlite3_finalize(stmt) }

    let responseCountsJSON = (try? JSONEncoder().encode(summary.responseCounts)).flatMap {
      String(data: $0, encoding: .utf8)
    }
    let summaryData = try JSONEncoder().encode(summary)

    bindText(stmt, index: 1, value: summary.id)
    bindText(stmt, index: 2, value: summary.fileURL.path)
    bindDate(stmt, index: 3, value: fileModificationTime)
    bindInt64(stmt, index: 4, value: fileSize.map(Int64.init))
    sqlite3_bind_int(stmt, 5, Int32(Self.schemaVersion))
    bindText(stmt, index: 6, value: parseError)
    bindText(stmt, index: 7, value: project)
    let sourceEncoding = encode(source: summary.source)
    bindText(stmt, index: 8, value: sourceEncoding.kind)
    bindText(stmt, index: 9, value: sourceEncoding.host)
    bindDate(stmt, index: 10, value: summary.startedAt)
    bindDate(stmt, index: 11, value: summary.endedAt)
    bindDate(stmt, index: 12, value: summary.lastUpdatedAt)
    bindDouble(stmt, index: 13, value: summary.activeDuration)
    bindText(stmt, index: 14, value: summary.cliVersion)
    bindText(stmt, index: 15, value: summary.cwd)
    bindText(stmt, index: 16, value: summary.originator)
    bindText(stmt, index: 17, value: summary.instructions)
    bindText(stmt, index: 18, value: summary.model)
    bindText(stmt, index: 19, value: summary.approvalPolicy)
    sqlite3_bind_int(stmt, 20, Int32(summary.userMessageCount))
    sqlite3_bind_int(stmt, 21, Int32(summary.assistantMessageCount))
    sqlite3_bind_int(stmt, 22, Int32(summary.toolInvocationCount))
    sqlite3_bind_int(stmt, 23, Int32(summary.responseCounts["reasoning"] ?? 0))
    bindText(stmt, index: 24, value: responseCountsJSON)
    sqlite3_bind_int(stmt, 25, Int32(summary.turnContextCount))
    bindInt(stmt, index: 26, value: tokenBreakdown?.input)
    bindInt(stmt, index: 27, value: tokenBreakdown?.output)
    bindInt(stmt, index: 28, value: tokenBreakdown?.cacheRead)
    bindInt(stmt, index: 29, value: tokenBreakdown?.cacheCreation)
    bindInt(stmt, index: 30, value: summary.totalTokens)
    sqlite3_bind_int(stmt, 31, Int32(summary.eventCount))
    sqlite3_bind_int(stmt, 32, Int32(summary.lineCount))
    bindText(stmt, index: 33, value: summary.remotePath)
    bindText(stmt, index: 34, value: summary.userTitle)
    bindText(stmt, index: 35, value: summary.userComment)
    bindText(stmt, index: 36, value: summary.taskId?.uuidString)
    sqlite3_bind_int(stmt, 37, 0) // has_terminal (placeholder)
    sqlite3_bind_int(stmt, 38, 0) // has_review (placeholder)
    bindData(stmt, index: 39, data: summaryData)
    bindText(stmt, index: 40, value: parseLevel)
    bindDate(stmt, index: 41, value: Date()) // parsed_at = now

    let stepResult = sqlite3_step(stmt)
    guard stepResult == SQLITE_DONE else {
      throw SessionIndexSQLiteStoreError.stepFailed(errorMessage)
    }
  }

  /// Update project assignment for a session without touching other fields.
  func updateProject(sessionId: String, project: String?) throws {
    try openIfNeeded()
    let sql = "UPDATE sessions SET project = ?1 WHERE session_id = ?2"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
      throw SessionIndexSQLiteStoreError.stepFailed(errorMessage)
    }
    defer { sqlite3_finalize(stmt) }
    bindText(stmt, index: 1, value: project)
    sqlite3_bind_text(stmt, 2, sessionId, -1, SQLITE_TRANSIENT)
    guard sqlite3_step(stmt) == SQLITE_DONE else {
      throw SessionIndexSQLiteStoreError.stepFailed(errorMessage)
    }
  }

  func delete(sessionId: String) throws {
    try openIfNeeded()
    let sql = "DELETE FROM sessions WHERE session_id = ?1"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
      throw SessionIndexSQLiteStoreError.stepFailed(errorMessage)
    }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT)
    guard sqlite3_step(stmt) == SQLITE_DONE else {
      throw SessionIndexSQLiteStoreError.stepFailed(errorMessage)
    }
  }

  /// 批量 upsert，使用单个事务降低开销。
  func upsertBatch(summaries: [SessionSummary]) throws {
    guard !summaries.isEmpty else { return }
    try openIfNeeded()
    try exec("BEGIN IMMEDIATE TRANSACTION;")
    do {
      for summary in summaries {
        try upsert(
          summary: summary,
          project: nil,
          fileModificationTime: nil,
          fileSize: summary.fileSizeBytes,
          tokenBreakdown: nil,
          parseError: nil
        )
      }
      try exec("COMMIT;")
    } catch {
      let _ = try? exec("ROLLBACK;")
      throw error
    }
  }

  // MARK: - Private

  private func openIfNeeded() throws {
    if db != nil {
      if !FileManager.default.fileExists(atPath: dbURL.path) {
        if !missingDbLogged {
          logger.error("Database file missing while connection open; recreating new store.")
          missingDbLogged = true
        }
        closeDatabase()
      } else {
        return
      }
    }

    if !FileManager.default.fileExists(atPath: dbURL.path) {
      if !missingDbLogged {
        logger.error("Database file missing; auto-creating a fresh cache store.")
        missingDbLogged = true
      }
      let directory = dbURL.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
    if sqlite3_open_v2(dbURL.path, &db, flags, nil) != SQLITE_OK {
      throw SessionIndexSQLiteStoreError.openFailed(errorMessage)
    }
    missingDbLogged = false
    try applyPragmas()
    try migrateIfNeeded()
  }

  private func closeDatabase() {
    if let db {
      sqlite3_close(db)
    }
    db = nil
  }

  private func applyPragmas() throws {
    try exec("PRAGMA journal_mode=WAL;")
    try exec("PRAGMA synchronous=NORMAL;")
    try exec("PRAGMA foreign_keys=ON;")
    try exec("PRAGMA temp_store=MEMORY;")
    try exec("PRAGMA cache_size=-2000;") // ~2MB page cache
    try exec("PRAGMA busy_timeout=5000;")
  }

  private func predicate(
    for scope: OverviewAggregateScope?
  ) -> (clause: String, binder: (OpaquePointer?, Int32) -> Int32) {
    guard let scope else {
      return ("", { _, idx in idx })
    }
    let dateColumn: String
    switch scope.dateDimension {
    case .created:
      dateColumn = "started_at"
    case .updated:
      dateColumn = "COALESCE(last_updated_at, started_at)"
    }

    var components: [String] = []
    components.append("\(dateColumn) >= ?")
    components.append("\(dateColumn) <= ?")

    let projects = Array(scope.projectIds ?? [])
    if !projects.isEmpty {
      let placeholders = Array(repeating: "?", count: projects.count).joined(separator: ",")
      components.append("project IN (\(placeholders))")
    }

    let clause = components.joined(separator: " AND ")
    let start = scope.start.timeIntervalSince1970
    let end = scope.end.timeIntervalSince1970

    let binder: (OpaquePointer?, Int32) -> Int32 = { stmt, startIndex in
      var idx = startIndex
      sqlite3_bind_double(stmt, idx, start)
      idx += 1
      sqlite3_bind_double(stmt, idx, end)
      idx += 1
      if !projects.isEmpty {
        for project in projects {
          sqlite3_bind_text(stmt, idx, project, -1, SQLITE_TRANSIENT)
          idx += 1
        }
      }
      return idx
    }
    return (clause, binder)
  }

  private func migrateIfNeeded() throws {
    let createSQL = """
    CREATE TABLE IF NOT EXISTS meta (
      key TEXT PRIMARY KEY,
      last_full_index_at REAL,
      session_count INTEGER
    );
    CREATE TABLE IF NOT EXISTS sessions (
      session_id TEXT PRIMARY KEY,
      file_path TEXT NOT NULL,
      file_mtime REAL,
      file_size INTEGER,
      schema_version INTEGER NOT NULL,
      parse_error TEXT,
      project TEXT,
      source TEXT NOT NULL,
      source_host TEXT,
      started_at REAL NOT NULL,
      ended_at REAL,
      last_updated_at REAL,
      active_duration REAL,
      cli_version TEXT NOT NULL,
      cwd TEXT NOT NULL,
      originator TEXT NOT NULL,
      instructions TEXT,
      model TEXT,
      approval_policy TEXT,
      user_message_count INTEGER NOT NULL,
      assistant_message_count INTEGER NOT NULL,
      tool_invocation_count INTEGER NOT NULL,
      reasoning_count INTEGER NOT NULL,
      response_counts_json TEXT,
      turn_context_count INTEGER NOT NULL,
      tokens_input INTEGER,
      tokens_output INTEGER,
      tokens_cache_read INTEGER,
      tokens_cache_creation INTEGER,
      tokens_total INTEGER,
      event_count INTEGER NOT NULL,
      line_count INTEGER NOT NULL,
      remote_path TEXT,
      user_title TEXT,
      user_comment TEXT,
      task_id TEXT,
      has_terminal INTEGER,
      has_review INTEGER,
      payload BLOB NOT NULL
    );
    """
    try exec(createSQL)
    try exec("CREATE INDEX IF NOT EXISTS idx_sessions_project ON sessions(project);")
    try exec("CREATE INDEX IF NOT EXISTS idx_sessions_updated ON sessions(last_updated_at);")
    try exec("CREATE INDEX IF NOT EXISTS idx_sessions_started ON sessions(started_at);")
    try exec("CREATE INDEX IF NOT EXISTS idx_sessions_source ON sessions(source);")

    // Composite indexes for project + date queries (Tasks mode optimization)
    // TEMPORARILY DISABLED FOR PERFORMANCE TESTING
    // try exec("CREATE INDEX IF NOT EXISTS idx_sessions_project_updated ON sessions(project, last_updated_at DESC);")
    // try exec("CREATE INDEX IF NOT EXISTS idx_sessions_project_started ON sessions(project, started_at DESC);")

    // Add parse_level and parsed_at columns if they don't exist (schema migration)
    try? exec("ALTER TABLE sessions ADD COLUMN parse_level TEXT DEFAULT 'metadata';")
    try? exec("ALTER TABLE sessions ADD COLUMN parsed_at REAL;")
    try? exec("CREATE INDEX IF NOT EXISTS idx_sessions_parse_level ON sessions(parse_level);")

    // Data migration: Fix incorrectly marked parse_level='full' records
    // Before this fix, refreshSessions used buildSummaryFast but marked records as 'full'
    // Heuristic: if lineCount < 100 and parse_level='full', it's likely from fast parse → downgrade to 'metadata'
    try? exec("UPDATE sessions SET parse_level = 'metadata' WHERE parse_level = 'full' AND line_count < 100;")
    // Also reset all existing 'full' records to 'metadata' to force re-parsing with correct labels
    // This is a one-time migration to clean up the database after the bug fix
    try? exec("UPDATE sessions SET parse_level = 'metadata' WHERE parse_level = 'full' AND parsed_at IS NULL;")

    // Timeline previews table for fast initial rendering
    // TEMPORARILY DISABLED FOR PERFORMANCE TESTING
    /*
    let createPreviewsSQL = """
    CREATE TABLE IF NOT EXISTS timeline_previews (
      session_id TEXT NOT NULL,
      turn_id TEXT NOT NULL,
      turn_index INTEGER NOT NULL,
      timestamp REAL NOT NULL,
      user_preview TEXT,
      outputs_preview TEXT,
      output_count INTEGER NOT NULL DEFAULT 0,
      has_tool_calls INTEGER NOT NULL DEFAULT 0,
      has_thinking INTEGER NOT NULL DEFAULT 0,
      file_mtime REAL NOT NULL,
      file_size INTEGER,
      created_at REAL NOT NULL DEFAULT (strftime('%s', 'now')),
      PRIMARY KEY (session_id, turn_id),
      FOREIGN KEY (session_id) REFERENCES sessions(session_id) ON DELETE CASCADE
    );
    """
    try exec(createPreviewsSQL)
    try exec("CREATE INDEX IF NOT EXISTS idx_timeline_previews_session ON timeline_previews(session_id, turn_index);")
    try exec("CREATE INDEX IF NOT EXISTS idx_timeline_previews_mtime ON timeline_previews(file_mtime);")
    */
  }

  @discardableResult
  private func exec(_ sql: String) throws -> Int32 {
    var errorMessagePointer: UnsafeMutablePointer<Int8>?
    let code = sqlite3_exec(db, sql, nil, nil, &errorMessagePointer)
    if let errorMessagePointer {
      let message = String(cString: errorMessagePointer)
      sqlite3_free(errorMessagePointer)
      if code != SQLITE_OK {
        throw SessionIndexSQLiteStoreError.stepFailed(message)
      }
    } else if code != SQLITE_OK {
      throw SessionIndexSQLiteStoreError.stepFailed("Unknown SQLite error")
    }
    return code
  }

  private var errorMessage: String {
    if let cString = sqlite3_errmsg(db) {
      return String(cString: cString)
    }
    return "Unknown SQLite error"
  }

  // MARK: - Binding helpers

  private func bindText(_ stmt: OpaquePointer?, index: Int32, value: String?) {
    if let value {
      sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
    } else {
      sqlite3_bind_null(stmt, index)
    }
  }

  private func bindInt(_ stmt: OpaquePointer?, index: Int32, value: Int?) {
    if let value {
      sqlite3_bind_int(stmt, index, Int32(value))
    } else {
      sqlite3_bind_null(stmt, index)
    }
  }

  private func bindInt64(_ stmt: OpaquePointer?, index: Int32, value: Int64?) {
    if let value {
      sqlite3_bind_int64(stmt, index, value)
    } else {
      sqlite3_bind_null(stmt, index)
    }
  }

  private func bindDouble(_ stmt: OpaquePointer?, index: Int32, value: TimeInterval?) {
    if let value {
      sqlite3_bind_double(stmt, index, value)
    } else {
      sqlite3_bind_null(stmt, index)
    }
  }

  private func bindDate(_ stmt: OpaquePointer?, index: Int32, value: Date?) {
    if let value {
      sqlite3_bind_double(stmt, index, value.timeIntervalSince1970)
    } else {
      sqlite3_bind_null(stmt, index)
    }
  }

  private func bindData(_ stmt: OpaquePointer?, index: Int32, data: Data) {
    _ = data.withUnsafeBytes { ptr in
      sqlite3_bind_blob(stmt, index, ptr.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
    }
  }

  // MARK: - Column helpers

  private func columnText(_ stmt: OpaquePointer?, index: Int32) -> String? {
    guard let cString = sqlite3_column_text(stmt, index) else { return nil }
    return String(cString: cString)
  }

  private func columnData(_ stmt: OpaquePointer?, index: Int32) -> Data? {
    guard let bytes = sqlite3_column_blob(stmt, index) else { return nil }
    let length = Int(sqlite3_column_bytes(stmt, index))
    return Data(bytes: bytes, count: length)
  }

  private func columnDate(_ stmt: OpaquePointer?, index: Int32) -> Date? {
    let value = sqlite3_column_double(stmt, index)
    if value == 0 { return nil }
    return Date(timeIntervalSince1970: value)
  }

  private func columnInt64(_ stmt: OpaquePointer?, index: Int32) -> Int64? {
    let value = sqlite3_column_int64(stmt, index)
    if sqlite3_column_type(stmt, index) == SQLITE_NULL { return nil }
    return value
  }

  private func tokenBreakdownFromColumns(_ stmt: OpaquePointer?, startIndex: Int32) -> TokenBreakdown? {
    let input = columnInt64(stmt, index: startIndex).map(Int.init)
    let output = columnInt64(stmt, index: startIndex + 1).map(Int.init)
    let cacheRead = columnInt64(stmt, index: startIndex + 2).map(Int.init)
    let cacheCreation = columnInt64(stmt, index: startIndex + 3).map(Int.init)
    guard let input, let output, let cacheRead, let cacheCreation else { return nil }
    return TokenBreakdown(input: input, output: output, cacheRead: cacheRead, cacheCreation: cacheCreation)
  }

  // MARK: - Source encoding helpers

  private func encode(source: SessionSource) -> (kind: String, host: String?) {
    switch source {
    case .codexLocal:
      return ("codexLocal", nil)
    case .claudeLocal:
      return ("claudeLocal", nil)
    case .geminiLocal:
      return ("geminiLocal", nil)
    case .codexRemote(let host):
      return ("codexRemote", host)
    case .claudeRemote(let host):
      return ("claudeRemote", host)
    case .geminiRemote(let host):
      return ("geminiRemote", host)
    }
  }

  private func decodeKind(_ value: String) -> SessionSource.Kind? {
    switch value {
    case "codexLocal", "codexRemote":
      return .codex
    case "claudeLocal", "claudeRemote":
      return .claude
    case "geminiLocal", "geminiRemote":
      return .gemini
    default:
      return nil
    }
  }

  private func distinctSources() throws -> [SessionSource.Kind] {
    let sql = "SELECT DISTINCT source FROM sessions"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
      throw SessionIndexSQLiteStoreError.stepFailed(errorMessage)
    }
    defer { sqlite3_finalize(stmt) }
    var kinds: [SessionSource.Kind] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      if let text = columnText(stmt, index: 0), let kind = decodeKind(text) {
        kinds.append(kind)
      }
    }
    return Array(Set(kinds)).sorted { $0.rawValue < $1.rawValue }
  }

  private func fetchTotals(scope: OverviewAggregateScope?) throws -> (sessions: Int, tokens: Int, duration: TimeInterval, userMessages: Int, assistantMessages: Int, toolInvocations: Int) {
    let predicate = predicate(for: scope)
    let whereClause = predicate.clause.isEmpty ? "" : "WHERE \(predicate.clause)"
    let sql = """
    SELECT
      COUNT(*) AS c,
      SUM(COALESCE(tokens_total, 0)) AS tokens,
      SUM(
        COALESCE(
          active_duration,
          CASE
            WHEN ended_at IS NOT NULL THEN MAX(0, ended_at - started_at)
            WHEN last_updated_at IS NOT NULL THEN MAX(0, last_updated_at - started_at)
            ELSE 0
          END
        )
      ) AS duration,
      SUM(user_message_count) AS user_messages,
      SUM(assistant_message_count) AS assistant_messages,
      SUM(tool_invocation_count) AS tool_invocations
    FROM sessions
    \(whereClause)
    """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
      throw SessionIndexSQLiteStoreError.stepFailed(errorMessage)
    }
    defer { sqlite3_finalize(stmt) }
    _ = predicate.binder(stmt, 1)
    guard sqlite3_step(stmt) == SQLITE_ROW else {
      throw SessionIndexSQLiteStoreError.decodeFailed("Failed to read totals")
    }
    let sessions = Int(sqlite3_column_int(stmt, 0))
    let tokens = Int(sqlite3_column_int64(stmt, 1))
    let duration = sqlite3_column_double(stmt, 2)
    let userMessages = Int(sqlite3_column_int64(stmt, 3))
    let assistantMessages = Int(sqlite3_column_int64(stmt, 4))
    let toolInvocations = Int(sqlite3_column_int64(stmt, 5))
    return (sessions, tokens, duration, userMessages, assistantMessages, toolInvocations)
  }

  private func fetchSourceAggregates(scope: OverviewAggregateScope?) throws -> [OverviewSourceAggregate] {
    let predicate = predicate(for: scope)
    let whereClause = predicate.clause.isEmpty ? "" : "WHERE \(predicate.clause)"
    let sql = """
    SELECT
      source,
      COUNT(*) AS c,
      SUM(COALESCE(tokens_total, 0)) AS tokens,
      SUM(
        COALESCE(
          active_duration,
          CASE
            WHEN ended_at IS NOT NULL THEN MAX(0, ended_at - started_at)
            WHEN last_updated_at IS NOT NULL THEN MAX(0, last_updated_at - started_at)
            ELSE 0
          END
        )
      ) AS duration,
      SUM(user_message_count) AS user_messages,
      SUM(assistant_message_count) AS assistant_messages,
      SUM(tool_invocation_count) AS tool_invocations
    FROM sessions
    \(whereClause)
    GROUP BY source
    """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
      throw SessionIndexSQLiteStoreError.stepFailed(errorMessage)
    }
    defer { sqlite3_finalize(stmt) }
    _ = predicate.binder(stmt, 1)
    var results: [OverviewSourceAggregate] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      guard
        let kindText = columnText(stmt, index: 0),
        let kind = decodeKind(kindText)
      else { continue }
      let count = Int(sqlite3_column_int64(stmt, 1))
      let tokens = Int(sqlite3_column_int64(stmt, 2))
      let duration = sqlite3_column_double(stmt, 3)
      let userMessages = Int(sqlite3_column_int64(stmt, 4))
      let assistantMessages = Int(sqlite3_column_int64(stmt, 5))
      let toolInvocations = Int(sqlite3_column_int64(stmt, 6))
      results.append(
        OverviewSourceAggregate(
          kind: kind,
          sessionCount: count,
          totalTokens: tokens,
          totalDuration: duration,
          userMessages: userMessages,
          assistantMessages: assistantMessages,
          toolInvocations: toolInvocations
        )
      )
    }
    return results
  }

  private func fetchDailyAggregates(scope: OverviewAggregateScope?) throws -> [OverviewDailyPoint] {
    let predicate = predicate(for: scope)
    let dateColumn = scope?.dateDimension == .updated ? "COALESCE(last_updated_at, started_at)" : "started_at"
    let whereClause = predicate.clause.isEmpty ? "" : "WHERE \(predicate.clause)"
    let sql = """
    SELECT
      strftime('%Y-%m-%d', \(dateColumn), 'unixepoch', 'localtime') AS day,
      source,
      COUNT(*) AS c,
      SUM(COALESCE(tokens_total, 0)) AS tokens,
      SUM(
        COALESCE(
          active_duration,
          CASE
            WHEN ended_at IS NOT NULL THEN MAX(0, ended_at - started_at)
            WHEN last_updated_at IS NOT NULL THEN MAX(0, last_updated_at - started_at)
            ELSE 0
          END
        )
      ) AS duration
    FROM sessions
    \(whereClause)
    GROUP BY day, source
    ORDER BY day ASC
    """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
      throw SessionIndexSQLiteStoreError.stepFailed(errorMessage)
    }
    defer { sqlite3_finalize(stmt) }
    _ = predicate.binder(stmt, 1)

    var results: [OverviewDailyPoint] = []
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd"
    df.locale = Locale(identifier: "en_US_POSIX")

    while sqlite3_step(stmt) == SQLITE_ROW {
      guard
        let dayText = columnText(stmt, index: 0),
        let dayDate = df.date(from: dayText),
        let kindText = columnText(stmt, index: 1),
        let kind = decodeKind(kindText)
      else { continue }
      let count = Int(sqlite3_column_int64(stmt, 2))
      let tokens = Int(sqlite3_column_int64(stmt, 3))
      let duration = sqlite3_column_double(stmt, 4)
      results.append(
        OverviewDailyPoint(
          day: dayDate,
          kind: kind,
          sessionCount: count,
          totalTokens: tokens,
          totalDuration: duration
        )
      )
    }
    return results
  }

  private func countSessions() throws -> Int {
    let sql = "SELECT COUNT(*) FROM sessions"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
      throw SessionIndexSQLiteStoreError.stepFailed(errorMessage)
    }
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_step(stmt) == SQLITE_ROW else {
      throw SessionIndexSQLiteStoreError.decodeFailed("Failed to read session count")
    }
    return Int(sqlite3_column_int64(stmt, 0))
  }

  private func parseLevelRank(_ level: String?) -> Int {
    switch level {
    case "enriched": return 3
    case "full": return 2
    case "metadata": return 1
    default: return 0
    }
  }
}

// MARK: - Cached summaries by source

extension SessionIndexSQLiteStore {
  /// Fetch cached summaries for given source kinds without touching the filesystem.
  func fetchSummaries(
    kinds: [SessionSource.Kind],
    includeRemote: Bool,
    dateColumn: String?,
    dateRange: (Date, Date)?,
    projectIds: Set<String>?
  ) throws -> [SessionSummary] {
    try openIfNeeded()
    let sources = sourceStrings(for: kinds, includeRemote: includeRemote)
    guard !sources.isEmpty else { return [] }
    let placeholders = sources.map { _ in "?" }.joined(separator: ",")
    var whereParts: [String] = ["source IN (\(placeholders))"]
    if let dateColumn, dateRange != nil {
      whereParts.append("\(dateColumn) >= ?")
      whereParts.append("\(dateColumn) <= ?")
    }
    if let projectIds, !projectIds.isEmpty {
      let projectPlaceholders = projectIds.map { _ in "?" }.joined(separator: ",")
      whereParts.append("project IN (\(projectPlaceholders))")
    }
    let whereClause = whereParts.joined(separator: " AND ")
    let sql = "SELECT payload FROM sessions WHERE \(whereClause)"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
      throw SessionIndexSQLiteStoreError.stepFailed(errorMessage)
    }
    defer { sqlite3_finalize(stmt) }
    var idx: Int32 = 1
    for source in sources {
      sqlite3_bind_text(stmt, idx, source, -1, SQLITE_TRANSIENT)
      idx += 1
    }
    if let dateRange {
      sqlite3_bind_double(stmt, idx, dateRange.0.timeIntervalSince1970)
      idx += 1
      sqlite3_bind_double(stmt, idx, dateRange.1.timeIntervalSince1970)
      idx += 1
    }
    if let projectIds {
      for pid in projectIds {
        sqlite3_bind_text(stmt, idx, pid, -1, SQLITE_TRANSIENT)
        idx += 1
      }
    }
    var result: [SessionSummary] = []
    let decoder = JSONDecoder()
    while sqlite3_step(stmt) == SQLITE_ROW {
      guard let payload = columnData(stmt, index: 0) else { continue }
      if let summary = try? decoder.decode(SessionSummary.self, from: payload) {
        result.append(summary)
      }
    }
    let withLevels = result
    let kindLabel = kinds.map { "\($0)" }.joined(separator: ",")
    logger.info("fetchSummaries cache kind=\(kindLabel, privacy: .public) count=\(withLevels.count, privacy: .public) includeRemote=\(includeRemote, privacy: .public)")
    return withLevels
  }

  /// Fetch cached records (payload + metadata) for given source kinds to build scoped caches.
  func fetchRecords(
    kinds: [SessionSource.Kind],
    includeRemote: Bool,
    dateColumn: String?,
    dateRange: (Date, Date)?,
    projectIds: Set<String>?
  ) throws -> [SessionIndexRecord] {
    try openIfNeeded()
    let sources = sourceStrings(for: kinds, includeRemote: includeRemote)
    guard !sources.isEmpty else { return [] }
    let placeholders = sources.map { _ in "?" }.joined(separator: ",")
    var whereParts: [String] = ["source IN (\(placeholders))"]
    if let dateColumn, dateRange != nil {
      whereParts.append("\(dateColumn) >= ?")
      whereParts.append("\(dateColumn) <= ?")
    }
    if let projectIds, !projectIds.isEmpty {
      let projectPlaceholders = projectIds.map { _ in "?" }.joined(separator: ",")
      whereParts.append("project IN (\(projectPlaceholders))")
    }
    let whereClause = whereParts.joined(separator: " AND ")
    let sql = """
    SELECT payload, file_path, file_mtime, file_size, project, schema_version, parse_error, tokens_input, tokens_output, tokens_cache_read, tokens_cache_creation, parse_level, parsed_at
    FROM sessions
    WHERE \(whereClause)
    """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
      throw SessionIndexSQLiteStoreError.stepFailed(errorMessage)
    }
    defer { sqlite3_finalize(stmt) }
    var idx: Int32 = 1
    for source in sources {
      sqlite3_bind_text(stmt, idx, source, -1, SQLITE_TRANSIENT)
      idx += 1
    }
    if let dateRange {
      sqlite3_bind_double(stmt, idx, dateRange.0.timeIntervalSince1970)
      idx += 1
      sqlite3_bind_double(stmt, idx, dateRange.1.timeIntervalSince1970)
      idx += 1
    }
    if let projectIds {
      for pid in projectIds {
        sqlite3_bind_text(stmt, idx, pid, -1, SQLITE_TRANSIENT)
        idx += 1
      }
    }

    var records: [SessionIndexRecord] = []
    let decoder = JSONDecoder()
    while sqlite3_step(stmt) == SQLITE_ROW {
      guard let payload = columnData(stmt, index: 0) else { continue }
      guard let summary = try? decoder.decode(SessionSummary.self, from: payload) else { continue }
      let filePath = columnText(stmt, index: 1) ?? summary.fileURL.path
      let fileMtime = columnDate(stmt, index: 2)
      let fileSize = columnInt64(stmt, index: 3).flatMap { UInt64($0) }
      let project = columnText(stmt, index: 4)
      let schemaVersion = Int(sqlite3_column_int(stmt, 5))
      let parseError = columnText(stmt, index: 6)
      let tokenBreakdown = tokenBreakdownFromColumns(stmt, startIndex: 7)
      let parseLevel = columnText(stmt, index: 11)
      let parsedAt = columnDate(stmt, index: 12)
      records.append(
        SessionIndexRecord(
          summary: summary,
          filePath: filePath,
          fileModificationTime: fileMtime,
          fileSize: fileSize,
          project: project,
          schemaVersion: schemaVersion,
          parseError: parseError,
          tokenBreakdown: tokenBreakdown,
          parseLevel: parseLevel,
          parsedAt: parsedAt
        )
      )
    }
    return records
  }

  /// Fetch file paths for a specific date without loading full payloads (optimized for single-day queries).
  /// Returns [(filePath, lastUpdatedAt, fileModificationTime, fileSize)].
  func fetchFilePathsForDate(
    kinds: [SessionSource.Kind],
    includeRemote: Bool,
    dateColumn: String,
    targetDate: Date
  ) throws -> [(filePath: String, lastUpdatedAt: Date?, fileMtime: Date?, fileSize: UInt64?)] {
    try openIfNeeded()
    let sources = sourceStrings(for: kinds, includeRemote: includeRemote)
    guard !sources.isEmpty else { return [] }
    let placeholders = sources.map { _ in "?" }.joined(separator: ",")

    // Use SQLite date() function to filter by calendar day in UTC
    let sql = """
    SELECT file_path, last_updated_at, file_mtime, file_size
    FROM sessions
    WHERE source IN (\(placeholders))
      AND date(\(dateColumn), 'unixepoch') = date(?1, 'unixepoch')
    """

    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
      throw SessionIndexSQLiteStoreError.stepFailed(errorMessage)
    }
    defer { sqlite3_finalize(stmt) }

    var idx: Int32 = 1
    for source in sources {
      sqlite3_bind_text(stmt, idx, source, -1, SQLITE_TRANSIENT)
      idx += 1
    }
    sqlite3_bind_double(stmt, idx, targetDate.timeIntervalSince1970)

    var result: [(String, Date?, Date?, UInt64?)] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      let filePath = columnText(stmt, index: 0) ?? ""
      let lastUpdated = columnDate(stmt, index: 1)
      let fileMtime = columnDate(stmt, index: 2)
      let fileSize = columnInt64(stmt, index: 3).map { UInt64($0) }
      result.append((filePath, lastUpdated, fileMtime, fileSize))
    }
    return result
  }

  /// Fetch cached records for a specific set of session IDs.
  func fetchRecords(sessionIds: Set<String>) throws -> [SessionIndexRecord] {
    try openIfNeeded()
    guard !sessionIds.isEmpty else { return [] }
    let placeholders = sessionIds.map { _ in "?" }.joined(separator: ",")
    let sql = """
    SELECT payload, file_path, file_mtime, file_size, project, schema_version, parse_error, tokens_input, tokens_output, tokens_cache_read, tokens_cache_creation
    FROM sessions
    WHERE session_id IN (\(placeholders))
    """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
      throw SessionIndexSQLiteStoreError.stepFailed(errorMessage)
    }
    defer { sqlite3_finalize(stmt) }
    var idx: Int32 = 1
    for id in sessionIds {
      sqlite3_bind_text(stmt, idx, id, -1, SQLITE_TRANSIENT)
      idx += 1
    }

    var records: [SessionIndexRecord] = []
    let decoder = JSONDecoder()
    while sqlite3_step(stmt) == SQLITE_ROW {
      guard let payload = columnData(stmt, index: 0) else { continue }
      guard let summary = try? decoder.decode(SessionSummary.self, from: payload) else { continue }
      let filePath = columnText(stmt, index: 1) ?? summary.fileURL.path
      let fileMtime = columnDate(stmt, index: 2)
      let fileSize = columnInt64(stmt, index: 3).flatMap { UInt64($0) }
      let project = columnText(stmt, index: 4)
      let schemaVersion = Int(sqlite3_column_int(stmt, 5))
      let parseError = columnText(stmt, index: 6)
      let tokenBreakdown = tokenBreakdownFromColumns(stmt, startIndex: 7)
      let parseLevel = columnText(stmt, index: 11)
      let parsedAt = columnDate(stmt, index: 12)
      records.append(
        SessionIndexRecord(
          summary: summary,
          filePath: filePath,
          fileModificationTime: fileMtime,
          fileSize: fileSize,
          project: project,
          schemaVersion: schemaVersion,
          parseError: parseError,
          tokenBreakdown: tokenBreakdown,
          parseLevel: parseLevel,
          parsedAt: parsedAt
        )
      )
    }
    return records
  }

  private func sourceStrings(for kinds: [SessionSource.Kind], includeRemote: Bool) -> [String] {
    var sources: [String] = []
    for kind in kinds {
      switch kind {
      case .codex:
        sources.append("codexLocal")
        if includeRemote { sources.append("codexRemote") }
      case .claude:
        sources.append("claudeLocal")
        if includeRemote { sources.append("claudeRemote") }
      case .gemini:
        sources.append("geminiLocal")
        if includeRemote { sources.append("geminiRemote") }
      }
    }
    return sources
  }

  // MARK: - Timeline Previews

  /// Fetch timeline previews for a session. Returns nil if cache is invalid (mtime mismatch).
  func fetchTimelinePreviews(
    sessionId: String,
    fileModificationTime: Date?,
    fileSize: UInt64?
  ) throws -> [ConversationTurnPreview]? {
    try openIfNeeded()

    // First check if we have any previews for this session
    let countSQL = "SELECT COUNT(*), MIN(file_mtime) FROM timeline_previews WHERE session_id = ?1"
    var countStmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, countSQL, -1, &countStmt, nil) == SQLITE_OK else {
      throw SessionIndexSQLiteStoreError.stepFailed(errorMessage)
    }
    defer { sqlite3_finalize(countStmt) }

    sqlite3_bind_text(countStmt, 1, sessionId, -1, SQLITE_TRANSIENT)

    guard sqlite3_step(countStmt) == SQLITE_ROW else {
      return nil
    }

    let count = Int(sqlite3_column_int(countStmt, 0))
    if count == 0 {
      return nil  // No previews cached
    }

    // Check mtime validity
    if let fileModificationTime {
      let cachedMtime = sqlite3_column_double(countStmt, 1)
      let mtimeInterval = fileModificationTime.timeIntervalSince1970
      if abs(cachedMtime - mtimeInterval) > 1.0 {
        // Cache is stale, return nil to trigger re-caching
        return nil
      }
    }

    // Fetch all previews for this session
    let fetchSQL = """
      SELECT turn_id, turn_index, timestamp, user_preview, outputs_preview,
             output_count, has_tool_calls, has_thinking
      FROM timeline_previews
      WHERE session_id = ?1
      ORDER BY turn_index ASC
    """

    var fetchStmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, fetchSQL, -1, &fetchStmt, nil) == SQLITE_OK else {
      throw SessionIndexSQLiteStoreError.stepFailed(errorMessage)
    }
    defer { sqlite3_finalize(fetchStmt) }

    sqlite3_bind_text(fetchStmt, 1, sessionId, -1, SQLITE_TRANSIENT)

    var previews: [ConversationTurnPreview] = []
    while sqlite3_step(fetchStmt) == SQLITE_ROW {
      guard let turnId = columnText(fetchStmt, index: 0) else { continue }

      let turnIndex = Int(sqlite3_column_int(fetchStmt, 1))
      let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(fetchStmt, 2))
      let userPreview = columnText(fetchStmt, index: 3)
      let outputsPreview = columnText(fetchStmt, index: 4)
      let outputCount = Int(sqlite3_column_int(fetchStmt, 5))
      let hasToolCalls = sqlite3_column_int(fetchStmt, 6) != 0
      let hasThinking = sqlite3_column_int(fetchStmt, 7) != 0

      let preview = ConversationTurnPreview(
        id: turnId,
        sessionId: sessionId,
        turnIndex: turnIndex,
        timestamp: timestamp,
        userPreview: userPreview,
        outputsPreview: outputsPreview,
        outputCount: outputCount,
        hasToolCalls: hasToolCalls,
        hasThinking: hasThinking
      )
      previews.append(preview)
    }

    return previews
  }

  /// Upsert timeline previews for a session. Replaces all existing previews for the session.
  func upsertTimelinePreviews(
    _ previews: [ConversationTurnPreview],
    sessionId: String,
    fileModificationTime: Date,
    fileSize: UInt64?
  ) throws {
    try openIfNeeded()

    // Delete existing previews for this session
    let deleteSQL = "DELETE FROM timeline_previews WHERE session_id = ?1"
    var deleteStmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, deleteSQL, -1, &deleteStmt, nil) == SQLITE_OK else {
      throw SessionIndexSQLiteStoreError.stepFailed(errorMessage)
    }
    defer { sqlite3_finalize(deleteStmt) }

    sqlite3_bind_text(deleteStmt, 1, sessionId, -1, SQLITE_TRANSIENT)
    guard sqlite3_step(deleteStmt) == SQLITE_DONE else {
      throw SessionIndexSQLiteStoreError.stepFailed(errorMessage)
    }

    // Insert new previews
    let insertSQL = """
      INSERT INTO timeline_previews (
        session_id, turn_id, turn_index, timestamp, user_preview, outputs_preview,
        output_count, has_tool_calls, has_thinking, file_mtime, file_size
      ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
    """

    var insertStmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, insertSQL, -1, &insertStmt, nil) == SQLITE_OK else {
      throw SessionIndexSQLiteStoreError.stepFailed(errorMessage)
    }
    defer { sqlite3_finalize(insertStmt) }

    for preview in previews {
      sqlite3_bind_text(insertStmt, 1, sessionId, -1, SQLITE_TRANSIENT)
      sqlite3_bind_text(insertStmt, 2, preview.id, -1, SQLITE_TRANSIENT)
      bindInt(insertStmt, index: 3, value: preview.turnIndex)
      bindDate(insertStmt, index: 4, value: preview.timestamp)
      bindText(insertStmt, index: 5, value: preview.userPreview)
      bindText(insertStmt, index: 6, value: preview.outputsPreview)
      bindInt(insertStmt, index: 7, value: preview.outputCount)
      sqlite3_bind_int(insertStmt, 8, preview.hasToolCalls ? 1 : 0)
      sqlite3_bind_int(insertStmt, 9, preview.hasThinking ? 1 : 0)
      bindDate(insertStmt, index: 10, value: fileModificationTime)
      bindInt64(insertStmt, index: 11, value: fileSize.map { Int64($0) })

      guard sqlite3_step(insertStmt) == SQLITE_DONE else {
        throw SessionIndexSQLiteStoreError.stepFailed(errorMessage)
      }

      sqlite3_reset(insertStmt)
    }
  }

  /// Delete timeline previews for a session (e.g., when file is deleted or modified)
  func deleteTimelinePreviews(sessionId: String) throws {
    try openIfNeeded()

    let sql = "DELETE FROM timeline_previews WHERE session_id = ?1"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
      throw SessionIndexSQLiteStoreError.stepFailed(errorMessage)
    }
    defer { sqlite3_finalize(stmt) }

    sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT)
    guard sqlite3_step(stmt) == SQLITE_DONE else {
      throw SessionIndexSQLiteStoreError.stepFailed(errorMessage)
    }
  }
}

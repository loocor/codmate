import Foundation
import OSLog

actor SessionIndexer {
  private let fileManager: FileManager
  private let decoder: JSONDecoder
  private let cache = NSCache<NSURL, CacheEntry>()
  private let sqliteStore: SessionIndexSQLiteStore
  private let logger = Logger(subsystem: "io.umate.codmate", category: "SessionIndexer")
  /// Prevent concurrent refresh loops (scope-level gate)
  private var isRefreshing = false
  /// Tracks files whose token total is confirmed zero for a given mtime to avoid repeated rescans.
  private var zeroTokenStable: [String: TimeInterval?] = [:]
  /// Avoid global mutable, non-Sendable formatter; create locally when needed
  nonisolated private static func makeTailTimestampFormatter() -> ISO8601DateFormatter {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }

  private final class CacheEntry {
    let modificationDate: Date?
    let summary: SessionSummary

    init(modificationDate: Date?, summary: SessionSummary) {
      self.modificationDate = modificationDate
      self.summary = summary
    }
  }

  init(
    fileManager: FileManager = .default,
    sqliteStore: SessionIndexSQLiteStore = SessionIndexSQLiteStore()
  ) {
    self.fileManager = fileManager
    self.sqliteStore = sqliteStore
    decoder = FlexibleDecoders.iso8601Flexible()
  }

  func refreshSessions(
    root: URL,
    scope: SessionLoadScope,
    dateRange: (Date, Date)? = nil,
    projectIds: Set<String>? = nil,
    projectDirectories: [String]? = nil,
    dateDimension: DateDimension = .updated
  ) async throws -> [SessionSummary] {
    // First, try cached meta fast path so repeated .all refreshes don't re-enumerate
    if case .all = scope, let cached = await cachedAllSummariesFromMeta() {
      return cached
    }

    guard !isRefreshing else {
      logger.debug("Refresh skipped: already in progress for scope=\(String(describing: scope), privacy: .public)")
      // When a refresh is already running, still try to surface cached data for ALL scope
      if case .all = scope, let cached = await cachedAllSummariesFromMeta() {
        return cached
      }
      return []
    }
    isRefreshing = true
    defer { isRefreshing = false }

    // Layer 0.5: Single-day fast path using SQLite date query (optimized for Updated dimension)
    // Directly query files by date without loading all cached records into memory
    let dateColumn = dateDimension == .updated ? "COALESCE(last_updated_at, started_at)" : "started_at"
    var cachedRecords: [String: SessionIndexRecord] = [:]

    if dateDimension == .updated, case .day(let targetDate) = scope {
      // Use optimized single-day query to get candidate file paths directly from SQLite
      if let dateCandidates = try? await sqliteStore.fetchFilePathsForDate(
        kinds: [.codex],
        includeRemote: false,
        dateColumn: dateColumn,
        targetDate: targetDate
      ), !dateCandidates.isEmpty {
        logger.info("Single-day fast path: found \(dateCandidates.count, privacy: .public) candidates for date")
        // Build minimal cachedRecords from file paths for change detection
        for _ in dateCandidates {
          // Fetch full record only if file still exists and needs processing
          if let fullRecords = try? await sqliteStore.fetchRecords(
            kinds: [.codex],
            includeRemote: false,
            dateColumn: dateColumn,
            dateRange: (targetDate.addingTimeInterval(-86400), targetDate.addingTimeInterval(86400)),
            projectIds: projectIds
          ) {
            cachedRecords = Dictionary(uniqueKeysWithValues: fullRecords.map { ($0.filePath, $0) })
            break
          }
        }
      }
    }

    // Layer 1: scoped cached records to skip SQLite fetch per file (fallback or non-single-day queries)
    if cachedRecords.isEmpty {
      let initialRecords = try? await sqliteStore.fetchRecords(
        kinds: [.codex],
        includeRemote: false,
        dateColumn: dateRange != nil ? dateColumn : nil,
        dateRange: dateRange,
        projectIds: projectIds
      )
      if let initialRecords, !initialRecords.isEmpty {
        cachedRecords = Dictionary(uniqueKeysWithValues: initialRecords.map { ($0.filePath, $0) })
      } else if cachedRecords.isEmpty {
        // Layer 1 baseline: fallback to all cached records for change detection to avoid reparsing unchanged files.
        if let allRecords = try? await sqliteStore.fetchRecords(
          kinds: [.codex],
          includeRemote: false,
          dateColumn: nil,
          dateRange: nil,
          projectIds: nil
        ) {
          cachedRecords = Dictionary(uniqueKeysWithValues: allRecords.map { ($0.filePath, $0) })
        }
      }
    }

    let scopedDirectories = scopedDirectoriesForRefresh(
      root: root,
      scope: scope,
      dateRange: dateRange,
      dateDimension: dateDimension,
      cachedRecords: cachedRecords,
      projectIds: projectIds,
      projectDirectories: projectDirectories
    )
    let sessionFiles = try sessionFileURLs(
      at: root,
      scope: scope,
      dateRange: dateRange,
      dateDimension: dateDimension,
      directories: scopedDirectories,
      cachedRecords: cachedRecords
    )
    logger.info(
      "Refreshing sessions under \(root.path, privacy: .public) scope=\(String(describing: scope), privacy: .public) count=\(sessionFiles.count)"
    )
    guard !sessionFiles.isEmpty else { return [] }

    // Fast path: if all files have up-to-date summaries in cache/SQLite, return immediately
    var summaries: [SessionSummary] = []
    summaries.reserveCapacity(sessionFiles.count)
    var pending: [(url: URL, modificationDate: Date?, fileSize: Int?)] = []

    // Layer 1.5: if all files are covered by cachedRecords with matching mtime/size, short-circuit.
    if !cachedRecords.isEmpty {
      var allCovered = true
      for url in sessionFiles {
        let values = try url.resourceValues(
          forKeys: Set<URLResourceKey>([.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
        )
        guard values.isRegularFile == true else { continue }
        let mdate = values.contentModificationDate
        let fsize = values.fileSize
        guard let record = cachedRecords[url.path],
              let m = record.fileModificationTime,
              mdate == m,
              (record.fileSize == nil || fsize == nil || record.fileSize == fsize.map { UInt64($0) })
        else {
          allCovered = false
          break
        }
      }
      if allCovered {
        let fastSummaries = Array(cachedRecords.values.map(\.summary))
        logger.info("SessionIndexer fast path: all files covered by scoped cache count=\(fastSummaries.count, privacy: .public)")
        if case .all = scope {
          try? await sqliteStore.setMeta(lastFullIndexAt: Date(), sessionCount: sessionFiles.count)
        }
        return fastSummaries
      }
    }

    for url in sessionFiles {
      let values = try url.resourceValues(
        forKeys: Set<URLResourceKey>([.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
      )
      guard values.isRegularFile == true else { continue }
      let mdate = values.contentModificationDate
      let fsize = values.fileSize

      if let record = cachedRecords[url.path],
         let m = record.fileModificationTime,
         mdate == m,
         (record.fileSize == nil || fsize == nil || record.fileSize == fsize.map { UInt64($0) })
      {
        let summary = record.summary
        store(summary: summary, for: url as NSURL, modificationDate: mdate)
        summaries.append(summary)
        continue
      }

      if let cached = cachedSummary(for: url as NSURL, modificationDate: mdate) {
        if shouldRecomputeTokens(for: url.path, modificationDate: mdate, summary: cached) {
          pending.append((url, mdate, fsize))
        } else {
          summaries.append(cached)
        }
        continue
      }
      if cachedRecords.isEmpty {
        if
          let disk = try? await sqliteStore.fetch(
            path: url.path,
            modificationDate: mdate,
            fileSize: fsize.flatMap { UInt64($0) })
        {
          if shouldRecomputeTokens(for: url.path, modificationDate: mdate, summary: disk) {
            pending.append((url, mdate, fsize))
          } else {
            store(summary: disk, for: url as NSURL, modificationDate: mdate)
            summaries.append(disk)
          }
          continue
        }
      }
      pending.append((url, mdate, fsize))
    }

    // If everything hit cache, short-circuit
    if pending.isEmpty {
      if case .all = scope {
        do {
          try await sqliteStore.setMeta(lastFullIndexAt: Date(), sessionCount: sessionFiles.count)
          logger.info("SessionIndexer meta updated from cache-only path count=\(sessionFiles.count, privacy: .public)")
        } catch {
          logger.error("Failed to set meta: \(error.localizedDescription, privacy: .public)")
        }
      }
      return summaries
    }

    logger.info(
      "Change detection: pending=\(pending.count, privacy: .public) cacheHits=\(summaries.count, privacy: .public) total=\(sessionFiles.count, privacy: .public)"
    )

    let cpuCount = ProcessInfo.processInfo.processorCount
    let workerCount = max(2, cpuCount / 2)
    var firstError: Error?
    summaries.reserveCapacity(sessionFiles.count)

    await withTaskGroup(of: Result<SessionSummary?, Error>.self) { group in
      var iterator = pending.makeIterator()

      func addNextTasks(_ n: Int) {
        for _ in 0..<n {
              guard let url = iterator.next() else { return }
          group.addTask { [weak self] in
            guard let self else { return .success(nil) }
            do {
              let (url, modificationDate, fileSize) = url

              var builder = SessionSummaryBuilder()
              if let size = fileSize { builder.setFileSize(UInt64(size)) }
              // Seed updatedAt by fs metadata to avoid full scan for recency
              if let lastUpdated = self.lastUpdatedTimestamp(
                for: url, modificationDate: modificationDate)
              {
                builder.seedLastUpdated(lastUpdated)
              }
              guard
                let summary = try await self.buildSummaryFast(
                  for: url, builder: &builder)
              else { return .success(nil) }
              // Track zero-token stability to avoid re-scans next time if still zero
              await self.updateZeroTokenStable(
                path: url.path, modificationDate: modificationDate, tokens: summary.actualTotalTokens)
              // Persist to SQLite (best-effort)
              do {
                try await self.sqliteStore.upsert(
                  summary: summary,
                  project: nil,
                  fileModificationTime: modificationDate,
                  fileSize: fileSize.flatMap { UInt64($0) },
                  tokenBreakdown: nil,
                  parseError: nil)
              } catch {
                self.logger.error(
                  "Failed to persist session summary: \(error.localizedDescription, privacy: .public) path=\(url.path, privacy: .public)"
                )
              }
              await self.store(
                summary: summary, for: url as NSURL,
                modificationDate: modificationDate)
              return .success(summary)
            } catch {
              return .failure(error)
            }
          }
        }
      }

      addNextTasks(workerCount)

      while let result = await group.next() {
        switch result {
        case .success(let maybe):
          if let s = maybe { summaries.append(s) }
        case .failure(let error):
          if firstError == nil { firstError = error }
          self.logger.error(
            "Failed to build session summary: \(error.localizedDescription, privacy: .public)"
          )
        }
        addNextTasks(1)
      }
    }

    // Layer 0: meta update only when full scope refreshed
    if case .all = scope {
      do {
        try await sqliteStore.setMeta(lastFullIndexAt: Date(), sessionCount: sessionFiles.count)
        logger.info(
          "SessionIndexer refresh complete. summaries=\(summaries.count, privacy: .public) files=\(sessionFiles.count, privacy: .public)"
        )
      } catch {
        logger.error("Failed to set meta after refresh: \(error.localizedDescription, privacy: .public)")
      }
    } else {
      logger.info(
        "SessionIndexer refresh complete (partial scope). summaries=\(summaries.count, privacy: .public) pending=0"
      )
    }

    // Remove SQLite entries no longer present in scoped refresh
    if let cached = try? await sqliteStore.fetchRecords(
      kinds: [.codex],
      includeRemote: false,
      dateColumn: dateColumn,
      dateRange: dateRange,
      projectIds: projectIds
    ) {
      let alivePaths = Set(sessionFiles.map { $0.path })
      let staleIds = cached.filter { !alivePaths.contains($0.filePath) }.map { $0.summary.id }
      for id in staleIds {
        do { try await sqliteStore.delete(sessionId: id) }
        catch {
          logger.error("Failed to delete stale cache id=\(id, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
      }
    }

    if summaries.isEmpty, let error = firstError {
      throw error
    }
    return summaries
  }

  func invalidate(url: URL) {
    cache.removeObject(forKey: url as NSURL)
  }

  func invalidateAll() {
    cache.removeAllObjects()
  }

  /// Remove cached entries (memory + SQLite) for deleted sessions.
  func deleteSessions(ids: [String]) async {
    guard !ids.isEmpty else { return }
    for id in ids {
      cache.removeAllObjects()
      do {
        try await sqliteStore.delete(sessionId: id)
      } catch {
        logger.error("Failed to delete session from cache id=\(id, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
      }
    }
  }

  /// Clear both in-memory and on-disk session index caches.
  func resetAllCaches() async {
    cache.removeAllObjects()
    try? await sqliteStore.reset()
  }

  /// Fetch aggregated overview metrics from SQLite cache (all sources).
  func fetchOverviewAggregate() async -> OverviewAggregate? {
    return try? await sqliteStore.fetchOverviewAggregate()
  }

  /// Fetch scoped aggregated overview metrics (project/date).
  func fetchOverviewAggregate(scope: OverviewAggregateScope?) async -> OverviewAggregate? {
    return try? await sqliteStore.fetchOverviewAggregate(scope: scope)
  }

  /// Current cache coverage (sources present + meta).
  func currentCoverage() async -> SessionIndexCoverage? {
    return try? await sqliteStore.fetchCoverage()
  }

  /// Cache externally provided session summaries (e.g., Claude/Gemini providers) into SQLite.
  func cacheExternalSummaries(_ summaries: [SessionSummary]) async {
    guard !summaries.isEmpty else { return }
    for summary in summaries {
      do {
        try await sqliteStore.upsert(
          summary: summary,
          project: nil,
          fileModificationTime: nil,
          fileSize: summary.fileSizeBytes,
          tokenBreakdown: nil,
          parseError: nil
        )
      } catch {
        logger.error("Failed to cache external summary \(summary.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
      }
    }
    logger.info("Cached external summaries count=\(summaries.count, privacy: .public)")
  }

  // MARK: - Private

  private func cachedSummary(for key: NSURL, modificationDate: Date?) -> SessionSummary? {
    guard let entry = cache.object(forKey: key) else {
      return nil
    }
    if entry.modificationDate == modificationDate {
      return entry.summary
    }
    return nil
  }

  private func shouldRecomputeTokens(
    for path: String, modificationDate: Date?, summary: SessionSummary
  ) -> Bool {
    if summary.actualTotalTokens > 0 { return false }
    switch summary.source.baseKind {
    case .codex, .gemini:
      let key = path
      let mt = modificationDate?.timeIntervalSince1970
      if let stable = zeroTokenStable[key], stable == mt {
        return false
      }
      return true
    case .claude:
      return false
    }
  }

  private func updateZeroTokenStable(path: String, modificationDate: Date?, tokens: Int) {
    if tokens > 0 {
      zeroTokenStable.removeValue(forKey: path)
    } else {
      zeroTokenStable[path] = modificationDate?.timeIntervalSince1970
    }
  }

  private func store(summary: SessionSummary, for key: NSURL, modificationDate: Date?) {
    let entry = CacheEntry(modificationDate: modificationDate, summary: summary)
    cache.setObject(entry, forKey: key)
  }

  nonisolated private func lastUpdatedTimestamp(for url: URL, modificationDate: Date?) -> Date? {
    // Updated timestamp is derived from JSONL content only; ignore file
    // modification times to avoid treating non-session edits as activity.
    return readTailTimestamp(url: url)
  }

  /// Cached fast path: return all summaries from SQLite meta without touching the filesystem.
  private func cachedAllSummariesFromMeta() async -> [SessionSummary]? {
    guard let meta = try? await sqliteStore.fetchMeta(), meta.sessionCount > 0 else {
      return nil
    }
    let records = (try? await sqliteStore.fetchAll()) ?? []
    if records.isEmpty {
      return nil
    }
    logger.info("SessionIndexer meta hit: sessions=\(records.count, privacy: .public)")
    return records.map(\.summary)
  }

  /// Fast tail scan to retrieve latest token_count for Codex/Gemini sessions.
  private func sessionFileURLs(
    at root: URL,
    scope: SessionLoadScope,
    dateRange: (Date, Date)?,
    dateDimension: DateDimension,
    directories: [URL]? = nil,
    cachedRecords: [String: SessionIndexRecord]? = nil
  ) throws -> [URL] {
    var urls: [URL] = []
    let targets: [URL]
    if let directories, !directories.isEmpty {
      targets = directories
    } else if let base = scopeBaseURL(root: root, scope: scope) {
      targets = [base]
    } else {
      logger.warning(
        "No enumerator URL for scope=\(String(describing: scope), privacy: .public) root=\(root.path, privacy: .public)"
      )
      return []
    }

    // Updated single-day fast path: if cached records cover the day, avoid wide enumeration
    if let cachedRecords,
       let dateRange,
       dateDimension == .updated,
       Calendar.current.isDate(dateRange.0, inSameDayAs: dateRange.1)
    {
      let start = dateRange.0
      let end = dateRange.1
      var candidates: [URL] = []
      for record in cachedRecords.values {
        let updated = record.summary.lastUpdatedAt ?? record.summary.endedAt ?? record.summary.startedAt
        if updated < start || updated > end { continue }
        let url = URL(fileURLWithPath: record.filePath)
        if fileManager.fileExists(atPath: url.path) {
          candidates.append(url)
        } else {
          // Keep directory for fallback enumeration below
          if let dir = directoryIfExists(url.deletingLastPathComponent()) {
            urls.append(dir)
          }
        }
      }
      if !candidates.isEmpty {
        logger.info("Updated-day fast path: returning \(candidates.count, privacy: .public) cached files without enumeration")
        return candidates
      }
    }

    var seen = Set<URL>()

    for enumeratorURL in targets {
      guard
        let enumerator = fileManager.enumerator(
          at: enumeratorURL,
          includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey] as [URLResourceKey],
          options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
      else {
        logger.warning("Enumerator could not open \(enumeratorURL.path, privacy: .public)")
        continue
      }

      while let obj = enumerator.nextObject() {
        guard let fileURL = obj as? URL else { continue }
        if fileURL.pathExtension.lowercased() == "jsonl" {
          if let dateRange, dateDimension == .updated {
            let values = try? fileURL.resourceValues(forKeys: Set<URLResourceKey>([.contentModificationDateKey]))
            if let mdate = values?.contentModificationDate {
              if mdate < dateRange.0 || mdate > dateRange.1 { continue }
            }
          }
          if seen.insert(fileURL).inserted {
            urls.append(fileURL)
          }
        }
      }
    }
    logger.info("Enumerated \(urls.count) files under scoped targets count=\(targets.count, privacy: .public)")
    return urls
  }

  /// Build a narrowed set of directories for enumeration when a project or date range is active.
  private func scopedDirectoriesForRefresh(
    root: URL,
    scope: SessionLoadScope,
    dateRange: (Date, Date)? = nil,
    dateDimension: DateDimension,
    cachedRecords: [String: SessionIndexRecord],
    projectIds: Set<String>?,
    projectDirectories: [String]?
  ) -> [URL]? {
    var directories: Set<URL> = []
    // Use cached records to re-scan only directories that previously contained matching sessions
    if let projectIds, !projectIds.isEmpty {
      for record in cachedRecords.values {
        if let project = record.project, projectIds.contains(project) {
          let url = URL(fileURLWithPath: record.filePath)
            .deletingLastPathComponent()
          directories.insert(url)
        }
      }
    }

    if !cachedRecords.isEmpty {
      for record in cachedRecords.values {
        let url = URL(fileURLWithPath: record.filePath)
          .deletingLastPathComponent()
        directories.insert(url)
      }
    }

    if let projectDirectories, !projectDirectories.isEmpty {
      for path in projectDirectories {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        if let dir = directoryIfExists(url) {
          directories.insert(dir)
        }
      }
    }

    // If created dimension with explicit date range, add day directories to cover new files
    if let dateRange, dateDimension == .created {
      let cal = Calendar.current
      var cursor = cal.startOfDay(for: dateRange.0)
      let end = cal.startOfDay(for: dateRange.1)
      while cursor <= end {
        if let dayDir = dayDirectory(root: root, date: cursor) {
          directories.insert(dayDir)
        }
        guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
        cursor = next
      }
    }

    // When no narrowing information exists, fall back to default scope directory
    if directories.isEmpty { return nil }
    return Array(directories)
  }

  private func mappedDataIfAvailable(at url: URL) throws -> Data? {
    do {
      return try Data(contentsOf: url, options: [.mappedIfSafe])
    } catch let error as NSError {
      if error.domain == NSCocoaErrorDomain &&
        (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError)
      {
        logger.debug("File disappeared before reading \(url.path, privacy: .public); skipping.")
        return nil
      }
      throw error
    }
  }

  // Sidebar: month daily counts without parsing content (fast)
  func computeCalendarCounts(root: URL, monthStart: Date, dimension: DateDimension) async -> [Int:
    Int]
  {
    var counts: [Int: Int] = [:]
    let cal = Calendar.current
    let comps = cal.dateComponents([.year, .month], from: monthStart)
    guard let year = comps.year, let month = comps.month else { return [:] }

    // For the Updated dimension we must scan all files, since cross-month updates can land in any month folder
    let scanURL: URL
    if dimension == .updated {
      scanURL = root
    } else {
      guard let monthURL = monthDirectory(root: root, year: year, month: month) else {
        return [:]
      }
      scanURL = monthURL
    }

    guard
      let enumerator = fileManager.enumerator(
        at: scanURL,
        includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants])
    else { return [:] }

    // Collect URLs synchronously first to avoid Swift 6 async/iterator issues
    let urls = enumerator.compactMap { $0 as? URL }

    for url in urls {
      guard url.pathExtension.lowercased() == "jsonl" else { continue }
      switch dimension {
      case .created:
        if let day = Int(url.deletingLastPathComponent().lastPathComponent) {
          counts[day, default: 0] += 1
        }
      case .updated:
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        if let date = lastUpdatedTimestamp(
          for: url, modificationDate: values?.contentModificationDate),
          cal.isDate(date, equalTo: monthStart, toGranularity: .month)
        {
          let day = cal.component(.day, from: date)
          counts[day, default: 0] += 1
        }
      }
    }
    return counts
  }

  // MARK: - Updated dimension index

  /// Fast index: record the last update timestamp per file to avoid repeated scans
  private var updatedDateIndex: [String: Date] = [:]
  /// Tail token scan for codex/gemini when tokens are zero (avoids full reparse)
  private func readTailTotalTokens(url: URL) -> Int? {
    let chunkSize = 128 * 1024
    guard
      let handle = try? FileHandle(forReadingFrom: url)
    else { return nil }
    defer { try? handle.close() }

    do {
      let fileSize = try handle.seekToEnd()
      let offset = fileSize > chunkSize ? fileSize - UInt64(chunkSize) : 0
      try handle.seek(toOffset: offset)
      guard let data = try handle.readToEnd(), !data.isEmpty else { return nil }
      let newline: UInt8 = 0x0A
      let carriageReturn: UInt8 = 0x0D
      for var slice in data.split(separator: newline, omittingEmptySubsequences: true).reversed() {
        if slice.last == carriageReturn { slice = slice.dropLast() }
        guard !slice.isEmpty else { continue }
        if let row = try? decoder.decode(SessionRow.self, from: Data(slice)) {
          if case let .eventMessage(payload) = row.kind, payload.type == "token_count" {
            if let msg = payload.message, let range = msg.range(of: "total: ") {
              let numStr = msg[range.upperBound...].prefix(while: { $0.isNumber })
              if let val = Int(numStr) { return val }
            }
            if let info = payload.info,
               case .object(let dict) = info,
               case .number(let total) = dict["total"]
            {
              return Int(total)
            }
          }
        }
      }
    } catch {
      return nil
    }
    return nil
  }

  /// Build the date index for the Updated dimension (async in the background)
  func buildUpdatedIndex(root: URL) async -> [String: Date] {
    var index: [String: Date] = [:]
    guard
      let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      )
    else { return [:] }

    let urls = enumerator.compactMap { $0 as? URL }

    await withTaskGroup(of: (String, Date)?.self) { group in
      for url in urls {
        guard url.pathExtension.lowercased() == "jsonl" else { continue }
        group.addTask { [weak self] in
          guard let self else { return nil }
          // Try disk cache first
          let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
          if
            let cached = try? await self.sqliteStore.fetch(
              path: url.path,
              modificationDate: values?.contentModificationDate,
              fileSize: nil),
            let updated = cached.lastUpdatedAt
          {
            return (url.path, updated)
          }
          // Otherwise read tail timestamp quickly
          if let tailDate = self.readTailTimestamp(url: url) {
            return (url.path, tailDate)
          }
          return nil
        }
      }
      for await item in group {
        if let (path, date) = item {
          index[path] = date
        }
      }
    }
    return index
  }

  /// Quickly filter files to load based on the Updated index
  func sessionFileURLsForUpdatedDay(root: URL, day: Date, index: [String: Date]) -> [URL] {
    let cal = Calendar.current
    let dayStart = cal.startOfDay(for: day)

    var urls: [URL] = []
    for (path, updatedDate) in index {
      if cal.isDate(updatedDate, inSameDayAs: dayStart) {
        urls.append(URL(fileURLWithPath: path))
      }
    }
    return urls
  }

  private func scopeBaseURL(root: URL, scope: SessionLoadScope) -> URL? {
    switch scope {
    case .today:
      return dayDirectory(root: root, date: Date())
    case .day(let date):
      return dayDirectory(root: root, date: date)
    case .month(let date):
      return monthDirectory(root: root, date: date)
    case .all:
      return directoryIfExists(root)
    }
  }

  private func monthDirectory(root: URL, date: Date) -> URL? {
    let cal = Calendar.current
    let components = cal.dateComponents([.year, .month], from: date)
    guard let year = components.year, let month = components.month else { return nil }
    return monthDirectory(root: root, year: year, month: month)
  }

  private func dayDirectory(root: URL, date: Date) -> URL? {
    let cal = Calendar.current
    let components = cal.dateComponents([.year, .month, .day], from: cal.startOfDay(for: date))
    guard let year = components.year,
      let month = components.month,
      let day = components.day
    else { return nil }
    return dayDirectory(root: root, year: year, month: month, day: day)
  }

  private func monthDirectory(root: URL, year: Int, month: Int) -> URL? {
    guard
      let yearURL = directoryIfExists(
        root.appendingPathComponent("\(year)", isDirectory: true))
    else { return nil }
    return numberedDirectory(base: yearURL, value: month)
  }

  private func dayDirectory(root: URL, year: Int, month: Int, day: Int) -> URL? {
    guard let monthURL = monthDirectory(root: root, year: year, month: month) else {
      return nil
    }
    return numberedDirectory(base: monthURL, value: day)
  }

  private func numberedDirectory(base: URL, value: Int) -> URL? {
    let candidates = [String(format: "%02d", value), "\(value)"]
    for name in candidates {
      let url = base.appendingPathComponent(name, isDirectory: true)
      if let existing = directoryIfExists(url) { return existing }
    }
    return nil
  }

  private func directoryIfExists(_ url: URL) -> URL? {
    var isDir: ObjCBool = false
    if fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
      return url
    }
    return nil
  }

  // Sidebar: collect cwd counts using disk cache or quick head-scan
  func collectCWDCounts(root: URL) async -> [String: Int] {
    var result: [String: Int] = [:]
    guard
      let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants])
    else { return [:] }

    // Collect URLs synchronously first to avoid Swift 6 async/iterator issues
    let urls = enumerator.compactMap { $0 as? URL }

    await withTaskGroup(of: (String, Int)?.self) { group in
      for url in urls {
        guard url.pathExtension.lowercased() == "jsonl" else { continue }
        group.addTask { [weak self] in
          guard let self else { return nil }
          let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
          let m = values?.contentModificationDate
          if
            let cached = try? await self.sqliteStore.fetch(
              path: url.path, modificationDate: m, fileSize: nil),
            !cached.cwd.isEmpty
          {
            return (cached.cwd, 1)
          }
          if let cwd = self.fastExtractCWD(url: url) { return (cwd, 1) }
          return nil
        }
      }
      for await item in group {
        if let (cwd, inc) = item { result[cwd, default: 0] += inc }
      }
    }
    return result
  }

  nonisolated private func fastExtractCWD(url: URL) -> String? {
    guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), !data.isEmpty else {
      return nil
    }
    let newline: UInt8 = 0x0A
    let carriageReturn: UInt8 = 0x0D
    for var slice in data.split(separator: newline, omittingEmptySubsequences: true).prefix(200) {
      if slice.last == carriageReturn { slice = slice.dropLast() }
      if let row = try? decoder.decode(SessionRow.self, from: Data(slice)) {
        switch row.kind {
        case .sessionMeta(let p): return p.cwd
        case .turnContext(let p): if let c = p.cwd { return c }
        default: break
        }
      }
    }
    return nil
  }

  private func buildSummaryFast(for url: URL, builder: inout SessionSummaryBuilder) throws
    -> SessionSummary?
  {
    // Memory-map file (fast and low memory overhead)
    guard let data = try mappedDataIfAvailable(at: url) else { return nil }
    guard !data.isEmpty else { return nil }

    let newline: UInt8 = 0x0A
    let carriageReturn: UInt8 = 0x0D
    let fastLineLimit = 64
    var lineCount = 0
    for var slice in data.split(separator: newline, omittingEmptySubsequences: true) {
      if slice.last == carriageReturn { slice = slice.dropLast() }
      guard !slice.isEmpty else { continue }
      if lineCount >= fastLineLimit, builder.hasEssentialMetadata {
        break
      }
      do {
        let row = try decoder.decode(SessionRow.self, from: Data(slice))
        builder.observe(row)
      } catch {
        // Silently ignore parse errors for individual lines
      }
      lineCount += 1
    }
    // Ensure lastUpdatedAt reflects last JSON line timestamp
    if let tailDate = readTailTimestamp(url: url) {
      if builder.lastUpdatedAt == nil || (builder.lastUpdatedAt ?? .distantPast) < tailDate {
        builder.seedLastUpdated(tailDate)
      }
    }
    // Lightweight token fallback for sources emitting token_count events.
    if builder.totalTokens == 0,
      shouldUseTokenFallback(for: url),
      let snapshot = SessionTimelineLoader().loadLatestTokenUsageWithFallback(url: url),
      let fallbackTokens = snapshot.totalTokens
    {
      builder.seedTotalTokens(fallbackTokens)
    }
    // Tail token_count scan for Codex/Gemini to avoid full reparse when tokens are 0.
    if builder.totalTokens == 0, let tail = readTailTotalTokens(url: url) {
      builder.seedTotalTokens(tail)
    }

    if let result = builder.build(for: url) { return result }
    return try buildSummaryFull(for: url, builder: &builder)
  }

  private func shouldUseTokenFallback(for url: URL) -> Bool {
    // Claude Code logs do not emit token_count events; skip the fallback to avoid extra scans.
    return !url.path.contains("/.claude/")
  }

  private func buildSummaryFull(for url: URL, builder: inout SessionSummaryBuilder) throws
    -> SessionSummary?
  {
    guard let data = try mappedDataIfAvailable(at: url) else { return nil }
    guard !data.isEmpty else { return nil }
    let newline: UInt8 = 0x0A
    let carriageReturn: UInt8 = 0x0D
    var lastError: Error?
    for var slice in data.split(separator: newline, omittingEmptySubsequences: true) {
      if slice.last == carriageReturn { slice = slice.dropLast() }
      guard !slice.isEmpty else { continue }
      do {
        let row = try decoder.decode(SessionRow.self, from: Data(slice))
        builder.observe(row)
      } catch {
        lastError = error
      }
    }
    if let result = builder.build(for: url) { return result }
    if let error = lastError { throw error }
    return nil
  }

  // Public API for background enrichment
  func enrich(url: URL) async throws -> SessionSummary? {
    let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    var builder = SessionSummaryBuilder()
    if let size = values.fileSize { builder.setFileSize(UInt64(size)) }
    if let tailDate = readTailTimestamp(url: url) { builder.seedLastUpdated(tailDate) }
    guard let base = try buildSummaryFull(for: url, builder: &builder) else { return nil }

    // Compute accurate active duration from grouped turns
    let active = computeActiveDuration(url: url)
    let enriched = SessionSummary(
      id: base.id,
      fileURL: base.fileURL,
      fileSizeBytes: base.fileSizeBytes,
      startedAt: base.startedAt,
      endedAt: base.endedAt,
      activeDuration: active,
      cliVersion: base.cliVersion,
      cwd: base.cwd,
      originator: base.originator,
      instructions: base.instructions,
      model: base.model,
      approvalPolicy: base.approvalPolicy,
      userMessageCount: base.userMessageCount,
      assistantMessageCount: base.assistantMessageCount,
      toolInvocationCount: base.toolInvocationCount,
      responseCounts: base.responseCounts,
      turnContextCount: base.turnContextCount,
      totalTokens: base.totalTokens,
      eventCount: base.eventCount,
      lineCount: base.lineCount,
      lastUpdatedAt: base.lastUpdatedAt,
      source: base.source,
      remotePath: base.remotePath,
      userTitle: base.userTitle,
      userComment: base.userComment
    )

    // Persist to in-memory and disk caches keyed by mtime
    store(summary: enriched, for: url as NSURL, modificationDate: values.contentModificationDate)
    do {
      try await sqliteStore.upsert(
        summary: enriched,
        project: nil,
        fileModificationTime: values.contentModificationDate,
        fileSize: values.fileSize.flatMap { UInt64($0) },
        tokenBreakdown: nil,
        parseError: nil)
    } catch {
      logger.error(
        "Failed to persist enriched summary: \(error.localizedDescription, privacy: .public) path=\(url.path, privacy: .public)"
      )
    }
    return enriched
  }

  // Compute sum of turn durations: for each turn, duration = (last output timestamp - user message timestamp).
  // If a turn has no user message, start from first output. If no outputs exist, contributes 0.
  nonisolated private func computeActiveDuration(url: URL) -> TimeInterval? {
    let loader = SessionTimelineLoader()
    guard let turns = try? loader.load(url: url) else { return nil }
    let filtered = turns.removingEnvironmentContext()
    var total: TimeInterval = 0
    for turn in filtered {
      let start: Date?
      if let u = turn.userMessage?.timestamp {
        start = u
      } else {
        start = turn.outputs.first?.timestamp
      }
      guard let s = start, let end = turn.outputs.last?.timestamp else { continue }
      let dt = end.timeIntervalSince(s)
      if dt > 0 { total += dt }
      if Task.isCancelled { return total }
    }
    return total
  }

  // MARK: - Fulltext scanning
  func fileContains(url: URL, term: String) async -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    let needle = term
    let chunkSize = 128 * 1024
    var carry = Data()
    while let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
      var combined = carry
      combined.append(chunk)
      if let s = String(data: combined, encoding: .utf8),
        s.range(of: needle, options: .caseInsensitive) != nil
      {
        return true
      }
      // keep tail to catch matches across boundaries
      let keep = min(needle.utf8.count - 1, combined.count)
      carry = combined.suffix(keep)
      if Task.isCancelled { return false }
    }
    if !carry.isEmpty, let s = String(data: carry, encoding: .utf8),
      s.range(of: needle, options: .caseInsensitive) != nil
    {
      return true
    }
    return false
  }

  // MARK: - Tail timestamp helper
  nonisolated private func readTailTimestamp(url: URL) -> Date? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }

    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    let fileSize = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0

    // Start with a reasonable chunk size, will expand if needed
    let chunkSize: UInt64 = 4096
    let maxChunkSize: UInt64 = 1024 * 1024  // 1MB max to avoid excessive memory usage
    let maxAttempts = 3

    let newline: UInt8 = 0x0A
    let carriageReturn: UInt8 = 0x0D

    for attempt in 0..<maxAttempts {
      let currentChunkSize = min(chunkSize * UInt64(1 << attempt), maxChunkSize, fileSize)
      let offset = fileSize > currentChunkSize ? fileSize - currentChunkSize : 0

      do { try handle.seek(toOffset: offset) } catch { return nil }
      guard let buffer = try? handle.readToEnd(), !buffer.isEmpty else { return nil }

      let lines = buffer.split(separator: newline, omittingEmptySubsequences: true)
      guard var slice = lines.last else { continue }

      if slice.last == carriageReturn { slice = slice.dropLast() }
      guard !slice.isEmpty else { continue }

      // Check if this looks like a complete line by looking for opening brace
      // (all session log lines are JSON objects starting with {)
      let hasOpeningBrace = slice.first == 0x7B  // '{'

      if !hasOpeningBrace && attempt < maxAttempts - 1 {
        // Line appears truncated, try with larger chunk
        continue
      }

      // Try to extract timestamp from first 100 bytes for performance
      let limitedSlice = slice.prefix(100)
      if let text = String(data: Data(limitedSlice), encoding: .utf8)
        ?? String(bytes: limitedSlice, encoding: .utf8),
        let timestamp = extractTimestamp(from: text)
      {
        return timestamp
      }

      // Fallback: try full line
      if let fullText = String(data: Data(slice), encoding: .utf8),
        let timestamp = extractTimestamp(from: fullText)
      {
        return timestamp
      }

      // If we've tried full line and still failed, no point in retrying with larger chunk
      break
    }

    return nil
  }

  nonisolated private func extractTimestamp(from text: String) -> Date? {
    let pattern = #""timestamp"\s*:\s*"([^"]+)""#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
      return nil
    }
    let range = NSRange(location: 0, length: (text as NSString).length)
    guard let match = regex.firstMatch(in: text, options: [], range: range),
      match.numberOfRanges >= 2
    else { return nil }
    let nsText = text as NSString
    let isoString = nsText.substring(with: match.range(at: 1))
    return SessionIndexer.makeTailTimestampFormatter().date(from: isoString)
  }

  // Global count for sidebar label
  func countAllSessions(root: URL) async -> Int {
    var total = 0
    guard
      let enumerator = fileManager.enumerator(
        at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants])
    else { return 0 }

    while let obj = enumerator.nextObject() {
      guard let url = obj as? URL else { continue }
      guard url.pathExtension.lowercased() == "jsonl" else { continue }
      let name = url.deletingPathExtension().lastPathComponent
      if name.hasPrefix("agent-") { continue }
      let values = try? url.resourceValues(forKeys: [.fileSizeKey])
      if let size = values?.fileSize, size == 0 { continue }
      total += 1
    }
    return total
  }

  /// Expose current meta for UI/diagnostics (non-mutating).
  func currentMeta() async -> SessionIndexMeta? {
    return try? await sqliteStore.fetchMeta()
  }

  /// Persist project assignments into the shared SQLite cache for scoped aggregates.
  func updateProjects(
    for sessions: [SessionSummary],
    resolver: @escaping @Sendable (SessionSummary) -> String?
  ) async {
    guard !sessions.isEmpty else { return }
    for session in sessions {
      let project = resolver(session)
      do {
        try await sqliteStore.updateProject(sessionId: session.id, project: project)
      } catch {
        logger.error("Failed to update project for \(session.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  /// Returns cached summaries when a full index already exists.
  func cachedAllSummaries() async -> [SessionSummary]? {
    return await cachedAllSummariesFromMeta()
  }
}

// MARK: - SessionProvider

extension SessionIndexer: SessionProvider {
  nonisolated var kind: SessionSource.Kind { .codex }
  nonisolated var identifier: String { "codex-local" }
  nonisolated var label: String { "Codex (local)" }

  func load(context: SessionProviderContext) async throws -> SessionProviderResult {
    guard let root = context.sessionsRoot else {
      return SessionProviderResult(summaries: [], coverage: nil, cacheHit: true)
    }
    switch context.cachePolicy {
    case .cacheOnly:
      // Try scoped cached summaries first
      if let cached = try? await sqliteStore.fetchSummaries(
        kinds: [.codex],
        includeRemote: false,
        dateColumn: dateColumn(for: context.dateDimension),
        dateRange: context.dateRange,
        projectIds: context.projectIds
      ), !cached.isEmpty {
        let coverage = await currentCoverage()
        return SessionProviderResult(summaries: cached, coverage: coverage, cacheHit: true)
      }
      if context.scope == .all, let cached = await cachedAllSummaries() {
        let coverage = await currentCoverage()
        return SessionProviderResult(
          summaries: cached,
          coverage: coverage,
          cacheHit: true
        )
      }
      return SessionProviderResult(summaries: [], coverage: await currentCoverage(), cacheHit: false)
    case .refresh:
      let summaries = try await refreshSessions(
        root: root,
        scope: context.scope,
        dateRange: context.dateRange,
        projectIds: context.projectIds,
        projectDirectories: context.projectDirectories,
        dateDimension: context.dateDimension
      )
      let coverage = await currentCoverage()
      return SessionProviderResult(
        summaries: summaries,
        coverage: coverage,
        cacheHit: false
      )
    }
  }

  private func dateColumn(for dimension: DateDimension) -> String {
    switch dimension {
    case .created: return "started_at"
    case .updated: return "COALESCE(last_updated_at, started_at)"
    }
  }
}

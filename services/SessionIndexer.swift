import Foundation
import OSLog

// Lightweight disk cache
fileprivate actor DiskCache {
  private struct Entry: Codable {
    let path: String
    let modificationTime: TimeInterval?
    let summary: SessionSummary
  }

  private var map: [String: Entry] = [:]
  private let url: URL

  init() {
    let fileManager = FileManager.default
    let dir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
      .appendingPathComponent("CodMate", isDirectory: true)
    try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
    url = dir.appendingPathComponent("sessionIndex-v2.json")

    // Load cache on init
    if let data = try? Data(contentsOf: url),
      let entries = try? JSONDecoder().decode([Entry].self, from: data)
    {
      map = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
    }
  }

  func get(path: String, modificationDate: Date?) -> SessionSummary? {
    guard let entry = map[path] else { return nil }
    let mt = modificationDate?.timeIntervalSince1970
    if entry.modificationTime == mt {
      return entry.summary
    }
    return nil
  }

  func set(path: String, modificationDate: Date?, summary: SessionSummary) {
    let mt = modificationDate?.timeIntervalSince1970
    map[path] = Entry(path: path, modificationTime: mt, summary: summary)
    // Simple save logic
    let entries = Array(map.values)
    if let data = try? JSONEncoder().encode(entries) {
      try? data.write(to: url, options: .atomic)
    }
  }

  func resetAll() {
    map.removeAll()
    try? FileManager.default.removeItem(at: url)
  }
}

actor SessionIndexer {
  private let fileManager: FileManager
  private let decoder: JSONDecoder
  private let cache = NSCache<NSURL, CacheEntry>()
  private let diskCache: DiskCache
  private let logger = Logger(subsystem: "io.umate.codmate", category: "SessionIndexer")
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

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
    self.diskCache = DiskCache()
    decoder = FlexibleDecoders.iso8601Flexible()
  }

  func refreshSessions(root: URL, scope: SessionLoadScope) async throws -> [SessionSummary] {
    let sessionFiles = try sessionFileURLs(at: root, scope: scope)
    logger.info(
      "Refreshing sessions under \(root.path, privacy: .public) scope=\(String(describing: scope), privacy: .public) count=\(sessionFiles.count)"
    )
    guard !sessionFiles.isEmpty else { return [] }

    let cpuCount = max(2, ProcessInfo.processInfo.processorCount)
    var summaries: [SessionSummary] = []
    var firstError: Error?
    summaries.reserveCapacity(sessionFiles.count)

    await withTaskGroup(of: Result<SessionSummary?, Error>.self) { group in
      var iterator = sessionFiles.makeIterator()

      func addNextTasks(_ n: Int) {
        for _ in 0..<n {
          guard let url = iterator.next() else { return }
          group.addTask { [weak self] in
            guard let self else { return .success(nil) }
            do {
              let values = try url.resourceValues(forKeys: [
                .contentModificationDateKey, .fileSizeKey, .isRegularFileKey,
              ])
              guard values.isRegularFile == true else { return .success(nil) }

              // In-memory cache
              if let cached = await self.cachedSummary(
                for: url as NSURL, modificationDate: values.contentModificationDate)
              {
                return .success(cached)
              }
              // Disk cache
              if let disk = await self.diskCache.get(
                path: url.path, modificationDate: values.contentModificationDate)
              {
                await self.store(
                  summary: disk, for: url as NSURL,
                  modificationDate: values.contentModificationDate)
                return .success(disk)
              }

              var builder = SessionSummaryBuilder()
              if let size = values.fileSize { builder.setFileSize(UInt64(size)) }
              // Seed updatedAt by fs metadata to avoid full scan for recency
              if let lastUpdated = self.lastUpdatedTimestamp(
                for: url, modificationDate: values.contentModificationDate)
              {
                builder.seedLastUpdated(lastUpdated)
              }
              guard
                let summary = try await self.buildSummaryFast(
                  for: url, builder: &builder)
              else { return .success(nil) }
              await self.store(
                summary: summary, for: url as NSURL,
                modificationDate: values.contentModificationDate)
              await self.diskCache.set(
                path: url.path, modificationDate: values.contentModificationDate,
                summary: summary)
              return .success(summary)
            } catch {
              return .failure(error)
            }
          }
        }
      }

      addNextTasks(cpuCount)

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

  /// Clear both in-memory and on-disk session index caches.
  func resetAllCaches() async {
    cache.removeAllObjects()
    await diskCache.resetAll()
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

  private func store(summary: SessionSummary, for key: NSURL, modificationDate: Date?) {
    let entry = CacheEntry(modificationDate: modificationDate, summary: summary)
    cache.setObject(entry, forKey: key)
  }

  nonisolated private func lastUpdatedTimestamp(for url: URL, modificationDate: Date?) -> Date? {
    // Updated timestamp is derived from JSONL content only; ignore file
    // modification times to avoid treating non-session edits as activity.
    return readTailTimestamp(url: url)
  }

  private func sessionFileURLs(at root: URL, scope: SessionLoadScope) throws -> [URL] {
    var urls: [URL] = []
    guard let enumeratorURL = scopeBaseURL(root: root, scope: scope) else {
      logger.warning(
        "No enumerator URL for scope=\(String(describing: scope), privacy: .public) root=\(root.path, privacy: .public)"
      )
      return []
    }

    guard
      let enumerator = fileManager.enumerator(
        at: enumeratorURL,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      )
    else {
      logger.warning("Enumerator could not open \(enumeratorURL.path, privacy: .public)")
      return []
    }

    while let obj = enumerator.nextObject() {
      guard let fileURL = obj as? URL else { continue }
      if fileURL.pathExtension.lowercased() == "jsonl" {
        urls.append(fileURL)
      }
    }
    logger.info("Enumerated \(urls.count) files under \(enumeratorURL.path, privacy: .public)")
    return urls
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
          if let cached = await self.diskCache.get(
            path: url.path,
            modificationDate: values?.contentModificationDate
          ), let updated = cached.lastUpdatedAt {
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
          if let cached = await self.diskCache.get(path: url.path, modificationDate: m),
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

    if let result = builder.build(for: url) { return result }
    // Fallback: full parse if we didn't capture session_meta early
    return try buildSummaryFull(for: url, builder: &builder)
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
    await diskCache.set(
      path: url.path, modificationDate: values.contentModificationDate, summary: enriched)
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
}

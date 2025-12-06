import Foundation
#if canImport(Darwin)
import Darwin
#endif

actor ClaudeSessionProvider {
    enum SessionProviderCacheError: Error {
        case cacheUnavailable
    }

    private let parser = ClaudeSessionParser()
    private let fileManager: FileManager
    private let root: URL?
    private let cacheStore: SessionIndexSQLiteStore?
    // Best-effort cache: sessionId -> canonical file URL (updated on scans)
    private var canonicalURLById: [String: URL] = [:]
    // mtime/size summary cache to skip re-parse when unchanged
    private var summaryCache: [String: CacheEntry] = [:]

    private struct CacheEntry {
        let modificationDate: Date?
        let fileSize: UInt64?
        let summary: SessionSummary
    }

    init(fileManager: FileManager = .default, cacheStore: SessionIndexSQLiteStore? = nil) {
        self.fileManager = fileManager
        self.cacheStore = cacheStore
        // Use real user home directory, not sandbox container
        let home = Self.getRealUserHomeURL()
        let projects = home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
        root = fileManager.fileExists(atPath: projects.path) ? projects : nil
    }
    
    /// Get the real user home directory (not sandbox container)
    private static func getRealUserHomeURL() -> URL {
        #if canImport(Darwin)
        if let homeDir = getpwuid(getuid())?.pointee.pw_dir {
            let path = String(cString: homeDir)
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    func sessions(scope: SessionLoadScope) async throws -> [SessionSummary] {
        guard cacheStore != nil else { throw SessionProviderCacheError.cacheUnavailable }
        let preferFullInitialParse = ((try? await cacheStore?.fetchMeta().sessionCount) ?? 0) == 0
        guard let root else { return [] }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }

        // Gather all parsed summaries then dedupe by sessionId,
        // preferring canonical filenames and newer/longer files.
        var bestById: [String: SessionSummary] = [:]
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "jsonl" else { continue }
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isRegularFile == true else { continue }
            let fileSize = resolveFileSize(for: url, resourceValues: values)
            let mtime = values.contentModificationDate
            let summary: SessionSummary?
            if preferFullInitialParse {
                summary = try await cachedSummary(for: url, modificationDate: mtime, fileSize: fileSize)
                    ?? parser.parse(at: url, fileSize: fileSize)?.summary
                    ?? parser.parseSummary(at: url, fileSize: fileSize)
            } else {
                summary = try await cachedSummary(for: url, modificationDate: mtime, fileSize: fileSize)
                    ?? parser.parseSummary(at: url, fileSize: fileSize)
                    ?? parser.parse(at: url, fileSize: fileSize)?.summary
            }
            guard let summary else { continue }
            guard matches(scope: scope, summary: summary) else { continue }
            cache(summary: summary, for: url, modificationDate: mtime, fileSize: fileSize)
            persist(summary: summary, modificationDate: mtime, fileSize: fileSize)

            if let existing = bestById[summary.id] {
                let pick = prefer(lhs: existing, rhs: summary)
                bestById[summary.id] = pick
            } else {
                bestById[summary.id] = summary
            }
        }

        // Update canonical map for later fallbacks
        for (_, s) in bestById { canonicalURLById[s.id] = s.fileURL }
        return Array(bestById.values)
    }

    /// Load only the sessions under a specific project directory (e.g. ~/.claude/projects/-Users-loocor-GitHub-CodMate)
    /// Directory should be the original project cwd; it will be encoded to Claude's folder name.
    func sessions(inProjectDirectory directory: String) async throws -> [SessionSummary] {
        guard cacheStore != nil else { throw SessionProviderCacheError.cacheUnavailable }
        let preferFullInitialParse = ((try? await cacheStore?.fetchMeta().sessionCount) ?? 0) == 0
        guard let root else { return [] }
        let folder = encodeProjectFolder(from: directory)
        let projectURL = root.appendingPathComponent(folder, isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: projectURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }

        var results: [SessionSummary] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "jsonl" else { continue }
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isRegularFile == true else { continue }
            let fileSize = resolveFileSize(for: url, resourceValues: values)
            let mtime = values.contentModificationDate
            let summary: SessionSummary?
            if preferFullInitialParse {
                summary = try await cachedSummary(for: url, modificationDate: mtime, fileSize: fileSize)
                    ?? parser.parse(at: url, fileSize: fileSize)?.summary
                    ?? parser.parseSummary(at: url, fileSize: fileSize)
            } else {
                summary = try await cachedSummary(for: url, modificationDate: mtime, fileSize: fileSize)
                    ?? parser.parseSummary(at: url, fileSize: fileSize)
                    ?? parser.parse(at: url, fileSize: fileSize)?.summary
            }

            if let summary {
                cache(summary: summary, for: url, modificationDate: mtime, fileSize: fileSize)
                persist(summary: summary, modificationDate: mtime, fileSize: fileSize)
                results.append(summary)
            }
        }
        return results
    }

    private func encodeProjectFolder(from cwd: String) -> String {
        let expanded = (cwd as NSString).expandingTildeInPath
        var standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        if standardized.hasSuffix("/") && standardized.count > 1 { standardized.removeLast() }
        var name = standardized.replacingOccurrences(of: ":", with: "-")
        name = name.replacingOccurrences(of: "/", with: "-")
        if !name.hasPrefix("-") { name = "-" + name }
        return name
    }

    func countAllSessions() -> Int {
        guard let root else { return 0 }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return 0 }
        var total = 0
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "jsonl" {
            let name = url.deletingPathExtension().lastPathComponent
            if name.hasPrefix("agent-") { continue }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            if let size = values?.fileSize, size == 0 { continue }
            total += 1
        }
        return total
    }

    func collectCWDCounts() async -> [String: Int] {
        guard let root else { return [:] }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [:] }

        var counts: [String: Int] = [:]
        do {
            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "jsonl" else { continue }
                let values = try url.resourceValues(
                    forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
                guard values.isRegularFile == true else { continue }
                let fileSize = resolveFileSize(for: url, resourceValues: values)
                let mtime = values.contentModificationDate
                if let summary = try await cachedSummary(for: url, modificationDate: mtime, fileSize: fileSize) {
                    counts[summary.cwd, default: 0] += 1
                    continue
                }
                if let parsed = parser.parse(at: url, fileSize: fileSize) {
                    cache(summary: parsed.summary, for: url, modificationDate: mtime, fileSize: fileSize)
                    counts[parsed.summary.cwd, default: 0] += 1
                }
            }
        } catch {
            return [:]
        }
        return counts
    }

    func enrich(summary: SessionSummary) -> SessionSummary? {
        guard summary.source.baseKind == .claude else { return summary }
        // Parse using canonical file path when available
        let url = resolveCanonicalURL(for: summary)
        guard let parsed = parser.parse(at: url) else { return nil }
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
            totalTokens: parsed.summary.totalTokens,
            eventCount: parsed.summary.eventCount,
            lineCount: parsed.summary.lineCount,
            lastUpdatedAt: parsed.summary.lastUpdatedAt,
            source: parsed.summary.source,
            remotePath: parsed.summary.remotePath,
            userTitle: parsed.summary.userTitle,
            userComment: parsed.summary.userComment
        )
    }

    func timeline(for summary: SessionSummary) -> [ConversationTurn]? {
        guard summary.source.baseKind == .claude else { return nil }
        let url = resolveCanonicalURL(for: summary)
        guard let parsed = parser.parse(at: url) else { return nil }
        let loader = SessionTimelineLoader()
        return loader.turns(from: parsed.rows)
    }

    private func matches(scope: SessionLoadScope, summary: SessionSummary) -> Bool {
        let calendar = Calendar.current
        let referenceDates = [
            summary.startedAt,
            summary.lastUpdatedAt ?? summary.startedAt
        ]
        switch scope {
        case .all:
            return true
        case .today:
            return referenceDates.contains(where: { calendar.isDateInToday($0) })
        case .day(let day):
            return referenceDates.contains(where: { calendar.isDate($0, inSameDayAs: day) })
        case .month(let date):
            return referenceDates.contains {
                calendar.isDate($0, equalTo: date, toGranularity: .month)
            }
        }
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

    private func cachedSummary(for url: URL, modificationDate: Date?, fileSize: UInt64?) async throws -> SessionSummary? {
        if let entry = summaryCache[url.path],
           entry.modificationDate == modificationDate,
           entry.fileSize == fileSize {
            canonicalURLById[entry.summary.id] = url
            return entry.summary
        }
        guard let cacheStore, let modificationDate else { return nil }
        guard let cached = try await cacheStore.fetch(
            path: url.path,
            modificationDate: modificationDate,
            fileSize: fileSize
        ) else { return nil }
        cache(summary: cached, for: url, modificationDate: modificationDate, fileSize: fileSize)
        return cached
    }

    private func cache(summary: SessionSummary, for url: URL, modificationDate: Date?, fileSize: UInt64?) {
        summaryCache[url.path] = CacheEntry(modificationDate: modificationDate, fileSize: fileSize, summary: summary)
        canonicalURLById[summary.id] = url
    }

    private func persist(summary: SessionSummary, modificationDate: Date?, fileSize: UInt64?) {
        guard let cacheStore else { return }
        Task.detached { [cacheStore] in
            try? await cacheStore.upsert(
                summary: summary,
                project: nil,
                fileModificationTime: modificationDate,
                fileSize: fileSize,
                tokenBreakdown: nil,
                parseError: nil
            )
        }
    }

    private func resolveFileSize(for url: URL) -> UInt64? {
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
           let size = values.fileSize {
            return UInt64(size)
        }
        if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
           let number = attributes[.size] as? NSNumber {
            return number.uint64Value
        }
        return nil
    }

    private func resolveFileSize(for url: URL, resourceValues: URLResourceValues) -> UInt64? {
        if let size = resourceValues.fileSize { return UInt64(size) }
        return resolveFileSize(for: url)
    }

    // MARK: - Canonical resolution and dedupe helpers

    /// Prefer canonical filename and more complete/updated files for the same session ID.
    /// Heuristics:
    /// - Prefer non "agent-" filenames over "agent-" (agent is an early placeholder)
    /// - If both non-agent, pick the one with later lastUpdated or larger file size
    private func prefer(lhs: SessionSummary, rhs: SessionSummary) -> SessionSummary {
        if lhs.id != rhs.id { return lhs } // shouldn't happen, but keep lhs
        let isAgentL = lhs.fileURL.deletingPathExtension().lastPathComponent.hasPrefix("agent-")
        let isAgentR = rhs.fileURL.deletingPathExtension().lastPathComponent.hasPrefix("agent-")
        if isAgentL != isAgentR { return isAgentL ? rhs : lhs }
        // Both same class; prefer newer lastUpdated, then larger size
        let lt = lhs.lastUpdatedAt ?? lhs.startedAt
        let rt = rhs.lastUpdatedAt ?? rhs.startedAt
        if lt != rt { return lt > rt ? lhs : rhs }
        let ls = lhs.fileSizeBytes ?? 0
        let rs = rhs.fileSizeBytes ?? 0
        if ls != rs { return ls > rs ? lhs : rhs }
        // Stable fallback: lexical by filename to reduce churn
        return lhs.fileURL.lastPathComponent < rhs.fileURL.lastPathComponent ? lhs : rhs
    }

    /// Resolve a stable file URL for a session summary. Handles cases where the
    /// initial file was "agent-*.jsonl" and later renamed to canonical UUID or
    /// rollout-named files. Falls back to summary.fileURL if nothing better is found.
    private func resolveCanonicalURL(for summary: SessionSummary) -> URL {
        // 1) If file exists and is readable, use it.
        if fileManager.fileExists(atPath: summary.fileURL.path) {
            return summary.fileURL
        }
        // 2) Return cached mapping if available
        if let cached = canonicalURLById[summary.id], fileManager.fileExists(atPath: cached.path) {
            return cached
        }
        // 3) Probe sibling files under the project folder for a better match
        let dir = summary.fileURL.deletingLastPathComponent()
        if let best = findSibling(bySessionId: summary.id, inDirectory: dir) {
            canonicalURLById[summary.id] = best
            return best
        }
        // 4) As a last resort, scan the entire Claude root
        if let root, let best = findSibling(bySessionId: summary.id, inDirectory: root) {
            canonicalURLById[summary.id] = best
            return best
        }
        return summary.fileURL
    }

    /// Find a file in the given directory tree that belongs to the sessionId,
    /// preferring non-agent names and newest mtime.
    private func findSibling(bySessionId sessionId: String, inDirectory base: URL) -> URL? {
        guard let enumerator = fileManager.enumerator(
            at: base,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }

        var candidates: [(url: URL, mtime: Date, isAgent: Bool)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "jsonl" else { continue }
            // Quick filename check: many canonical files include the sessionId directly
            let name = url.deletingPathExtension().lastPathComponent
            if name.contains(sessionId) {
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                candidates.append((url, mtime, name.hasPrefix("agent-")))
                continue
            }
            // As a fallback, peek the sessionId from file contents (cheap prefix scan)
            if let sid = parser.fastSessionId(at: url), sid == sessionId {
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                candidates.append((url, mtime, name.hasPrefix("agent-")))
            }
        }
        guard !candidates.isEmpty else { return nil }
        // Prefer non-agent, then newest mtime
        candidates.sort { a, b in
            if a.isAgent != b.isAgent { return !a.isAgent } // non-agent first
            if a.mtime != b.mtime { return a.mtime > b.mtime }
            return a.url.lastPathComponent < b.url.lastPathComponent
        }
        return candidates.first?.url
    }
}

// MARK: - SessionProvider

extension ClaudeSessionProvider: SessionProvider {
    nonisolated var kind: SessionSource.Kind { .claude }
    nonisolated var identifier: String { "claude-local" }
    nonisolated var label: String { "Claude (local)" }

    func load(context: SessionProviderContext) async throws -> SessionProviderResult {
        switch context.cachePolicy {
        case .cacheOnly:
            if let cacheStore {
                let dateColumn = context.dateDimension == .updated ? "COALESCE(last_updated_at, started_at)" : "started_at"
                let range = context.dateRange ?? Self.dateRange(for: context.scope)
                let cached = try await cacheStore.fetchSummaries(
                    kinds: [.claude],
                    includeRemote: false,
                    dateColumn: dateColumn,
                    dateRange: range,
                    projectIds: context.projectIds
                )
                if !cached.isEmpty {
                    return SessionProviderResult(summaries: cached, coverage: nil, cacheHit: true)
                }
            }
            return SessionProviderResult(summaries: [], coverage: nil, cacheHit: true)
        case .refresh:
            guard let cacheStore else { throw SessionProviderCacheError.cacheUnavailable }
            // Require cache availability; if missing/unopenable, surface error instead of falling back to parse.
            _ = try await cacheStore.fetchMeta()
            let summaries = try await sessions(scope: context.scope)
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
}

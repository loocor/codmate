import Foundation

enum RemoteSyncState: Equatable {
    case idle
    case syncing
    case succeeded(Date)
    case failed(Date, String)
}

actor RemoteSessionProvider {
    private let hostResolver: SSHConfigResolver
    private let mirror: RemoteSessionMirror
    private let indexer: SessionIndexer
    private let parser = ClaudeSessionParser()
    private let fileManager: FileManager
    private var cachedHosts: [SSHHost] = []
    private var cachedConfigTimestamp: Date?
    private var lastHostsRefresh: Date?
    private var mirrorStore: [String: RemoteMirrorOutcome] = [:]
    private var syncStates: [String: RemoteSyncState] = [:]
    // Scope-based refresh debouncing: track active and recent refreshes
    private var activeRefreshes: Set<String> = []  // Currently executing refresh keys
    private var lastRefreshTimes: [String: Date] = [:]
    private let recentCompletionWindow: TimeInterval = 0.1  // 100ms to filter rapid duplicates

    init(
        hostResolver: SSHConfigResolver = SSHConfigResolver(),
        mirror: RemoteSessionMirror = RemoteSessionMirror(),
        indexer: SessionIndexer = SessionIndexer(),
        fileManager: FileManager = .default
    ) {
        self.hostResolver = hostResolver
        self.mirror = mirror
        self.indexer = indexer
        self.fileManager = fileManager
    }

    func codexSessions(scope: SessionLoadScope, enabledHosts: Set<String>) async -> [SessionSummary] {
        let hosts = filteredHosts(enabledHosts)
        guard !hosts.isEmpty else { return [] }

        let key = refreshKey(scope: scope, kind: .codex, hosts: enabledHosts)

        // Skip if already executing or just completed
        if shouldSkipRefresh(key: key) {
            return []
        }

        activeRefreshes.insert(key)
        defer {
            activeRefreshes.remove(key)
            lastRefreshTimes[key] = Date()
        }

        return await fetchCodexSessions(scope: scope, hosts: hosts)
    }

    func claudeSessions(scope: SessionLoadScope, enabledHosts: Set<String>) async -> [SessionSummary] {
        let hosts = filteredHosts(enabledHosts)
        guard !hosts.isEmpty else { return [] }

        let key = refreshKey(scope: scope, kind: .claude, hosts: enabledHosts)

        // Skip if already executing or just completed
        if shouldSkipRefresh(key: key) {
            return []
        }

        activeRefreshes.insert(key)
        defer {
            activeRefreshes.remove(key)
            lastRefreshTimes[key] = Date()
        }

        let sessions = await fetchClaudeSessions(scope: scope, hosts: hosts)
        await cacheExternalSummaries(sessions)
        return sessions
    }

    func collectCWDAggregates(kind: RemoteSessionKind, enabledHosts: Set<String>) async -> [String: Int] {
        let hosts = filteredHosts(enabledHosts)
        guard !hosts.isEmpty else { return [:] }
        var result: [String: Int] = [:]
        for host in hosts {
            do {
                guard let outcome = mirrorOutcome(host: host, kind: kind) else { continue }
                switch kind {
                case .codex:
                    let counts = try await collectCodexCounts(localRoot: outcome.localRoot)
                    for (key, value) in counts {
                        result[key, default: 0] += value
                    }
                case .claude:
                    let counts = collectClaudeCounts(localRoot: outcome.localRoot)
                    for (key, value) in counts {
                        result[key, default: 0] += value
                    }
                }
            } catch {
                continue
            }
        }
        return result
    }

    func countSessions(kind: RemoteSessionKind, enabledHosts: Set<String>) async -> Int {
        let hosts = filteredHosts(enabledHosts)
        guard !hosts.isEmpty else { return 0 }
        var total = 0
        for host in hosts {
            guard let outcome = mirrorOutcome(host: host, kind: kind) else { continue }
            switch kind {
            case .codex:
                let enumerator = fileManager.enumerator(
                    at: outcome.localRoot,
                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
                while let url = enumerator?.nextObject() as? URL {
                    guard url.pathExtension.lowercased() == "jsonl" else { continue }
                    let name = url.deletingPathExtension().lastPathComponent
                    if name.hasPrefix("agent-") { continue }
                    if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                       let s = values.fileSize, s == 0 { continue }
                    total += 1
                }
            case .claude:
                let enumerator = fileManager.enumerator(
                    at: outcome.localRoot,
                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
                while let url = enumerator?.nextObject() as? URL {
                    guard url.pathExtension.lowercased() == "jsonl" else { continue }
                    let name = url.deletingPathExtension().lastPathComponent
                    if name.hasPrefix("agent-") { continue }
                    if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                       let s = values.fileSize, s == 0 { continue }
                    total += 1
                }
            }
        }
        return total
    }

    // MARK: - Private helpers

    private func fetchCodexSessions(scope: SessionLoadScope, hosts: [SSHHost]) async -> [SessionSummary] {
        var aggregate: [SessionSummary] = []
        for host in hosts {
            do {
                guard let outcome = mirrorOutcome(host: host, kind: .codex) else { continue }
                let summaries = try await indexer.refreshSessions(
                    root: outcome.localRoot,
                    scope: scope,
                    dateRange: nil,
                    projectIds: nil,
                    projectDirectories: nil,
                    dateDimension: .updated
                )
                for summary in summaries {
                    guard let metadata = outcome.fileMap[summary.fileURL] else { continue }
                    let remoteSource: SessionSource = .codexRemote(host: host.alias)
                    aggregate.append(
                        summary.withRemoteMetadata(
                            source: remoteSource,
                            remotePath: metadata.remotePath
                        )
                    )
                }
            } catch {
                continue
            }
        }
        return aggregate
    }

    private func fetchClaudeSessions(scope: SessionLoadScope, hosts: [SSHHost]) async -> [SessionSummary] {
        var aggregate: [SessionSummary] = []
        for host in hosts {
            guard let outcome = mirrorOutcome(host: host, kind: .claude) else { continue }
            let sessions = loadClaudeSessions(
                at: outcome.localRoot,
                scope: scope,
                host: host.alias,
                fileMap: outcome.fileMap
            )
            aggregate.append(contentsOf: sessions)
        }
        return aggregate
    }

    private func collectCodexCounts(localRoot: URL) async throws -> [String: Int] {
        let counts = await indexer.collectCWDCounts(root: localRoot)
        return counts
    }

    private func collectClaudeCounts(localRoot: URL) -> [String: Int] {
        guard let enumerator = fileManager.enumerator(
            at: localRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [:] }
        var counts: [String: Int] = [:]
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "jsonl" else { continue }
            if let parsed = parser.parse(at: url) {
                counts[parsed.summary.cwd, default: 0] += 1
            }
        }
        return counts
    }

    private func loadClaudeSessions(
        at root: URL,
        scope: SessionLoadScope,
        host: String,
        fileMap: [URL: RemoteMirrorOutcome.MirroredFile]
    ) -> [SessionSummary] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var sessions: [SessionSummary] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "jsonl" else { continue }
            let fileSize = resolveFileSize(for: url)
            guard let parsed = parser.parse(at: url, fileSize: fileSize) else { continue }
            guard matches(scope: scope, summary: parsed.summary) else { continue }
            guard let metadata = fileMap[url] else { continue }
            sessions.append(
                parsed.summary.withRemoteMetadata(
                    source: .claudeRemote(host: host),
                    remotePath: metadata.remotePath
                )
            )
        }
        return sessions
    }

    private func filteredHosts(_ enabledHosts: Set<String>) -> [SSHHost] {
        guard !enabledHosts.isEmpty else { return [] }
        if shouldReloadHosts() {
            cachedHosts = hostResolver.resolvedHosts()
            cachedConfigTimestamp = currentConfigTimestamp()
            lastHostsRefresh = Date()
            mirrorStore.removeAll()
        }
        let enabledLowercased = Set(enabledHosts.map { $0.lowercased() })
        return cachedHosts.filter { enabledLowercased.contains($0.alias.lowercased()) }
    }

    private func shouldReloadHosts() -> Bool {
        if cachedHosts.isEmpty { return true }
        let configChanged = currentConfigTimestamp() != cachedConfigTimestamp
        if configChanged { return true }
        return false
    }

    private func currentConfigTimestamp() -> Date? {
        let attrs = try? fileManager.attributesOfItem(atPath: hostResolver.configurationURL.path)
        return attrs?[.modificationDate] as? Date
    }

    private func cachedMirrorOutcome(
        host: SSHHost,
        kind: RemoteSessionKind,
        scope: SessionLoadScope,
        force: Bool = false
    ) async throws -> RemoteMirrorOutcome {
        let key = mirrorCacheKey(host: host, kind: kind, scope: scope)
        if !force, let cached = mirrorStore[key] {
            return cached
        }
        let outcome = try await mirror.ensureMirror(host: host, kind: kind, scope: scope)
        mirrorStore[key] = outcome
        return outcome
    }

    private func mirrorOutcome(host: SSHHost, kind: RemoteSessionKind) -> RemoteMirrorOutcome? {
        mirrorStore[mirrorCacheKey(host: host, kind: kind, scope: .all)]
    }

    private func mirrorCacheKey(host: SSHHost, kind: RemoteSessionKind, scope: SessionLoadScope) -> String {
        mirrorCacheKey(alias: host.alias, kind: kind, scope: scope)
    }

    private func mirrorCacheKey(alias: String, kind: RemoteSessionKind, scope: SessionLoadScope) -> String {
        alias.lowercased() + "|" + kind.rawValue + "|" + scopeKey(scope)
    }

    private func scopeKey(_ scope: SessionLoadScope) -> String {
        switch scope {
        case .all: return "all"
        case .today: return "today"
        case .day(let date): return "day-\(Int(date.timeIntervalSince1970))"
        case .month(let date): return "month-\(Int(date.timeIntervalSince1970))"
        }
    }

    func syncHosts(_ enabledHosts: Set<String>, force: Bool) async {
        let hosts = filteredHosts(enabledHosts)
        guard !hosts.isEmpty else { return }
        for host in hosts {
            syncStates[host.alias] = .syncing
            do {
                _ = try await cachedMirrorOutcome(host: host, kind: .codex, scope: .all, force: true)
                _ = try await cachedMirrorOutcome(host: host, kind: .claude, scope: .all, force: true)
                syncStates[host.alias] = .succeeded(Date())
            } catch {
                syncStates[host.alias] = .failed(Date(), formatSyncError(error))
            }
        }
    }

    func syncStatusSnapshot() -> [String: RemoteSyncState] {
        syncStates
    }

    private func formatSyncError(_ error: Error) -> String {
        if let shell = error as? ShellCommandError {
            switch shell {
            case .commandFailed(let executable, _, let stderr, let exitCode):
                if !stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return "\(stderr.trimmingCharacters(in: .whitespacesAndNewlines)) (\(executable) exited \(exitCode))"
                }
                return "\(executable) exited with code \(exitCode)"
            }
        }
        return error.localizedDescription
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

    private func cacheExternalSummaries(_ summaries: [SessionSummary]) async {
        guard !summaries.isEmpty else { return }
        await indexer.cacheExternalSummaries(summaries)
    }

    private func refreshKey(scope: SessionLoadScope, kind: RemoteSessionKind, hosts: Set<String>) -> String {
        let scopePart = scopeKey(scope)
        let hostsPart = hosts.sorted().joined(separator: ",")
        return "\(kind.rawValue)|\(scopePart)|\(hostsPart)"
    }

    private func shouldSkipRefresh(key: String) -> Bool {
        // Skip if already executing
        if activeRefreshes.contains(key) {
            return true
        }

        // Skip if just completed (< 100ms) to filter rapid duplicates
        guard let lastTime = lastRefreshTimes[key] else { return false }
        return Date().timeIntervalSince(lastTime) < recentCompletionWindow
    }
}

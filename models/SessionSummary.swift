import Foundation

struct SessionSummary: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let fileURL: URL
    let fileSizeBytes: UInt64?
    let startedAt: Date
    let endedAt: Date?
    // Sum of actual active conversation segments (user → Codex),
    // computed from grouped timeline turns during enrichment.
    // Nil until enriched; falls back to (endedAt - startedAt) in UI when nil.
    let activeDuration: TimeInterval?
    let cliVersion: String
    let cwd: String
    let originator: String
    let instructions: String?
    let model: String?
    let approvalPolicy: String?
    let userMessageCount: Int
    let assistantMessageCount: Int
    var toolInvocationCount: Int
    let responseCounts: [String: Int]
    let turnContextCount: Int
    let totalTokens: Int?
    let eventCount: Int
    let lineCount: Int
    let lastUpdatedAt: Date?
    let source: SessionSource
    let remotePath: String?

    // User-provided metadata (rename/comment)
    var userTitle: String? = nil
    var userComment: String? = nil

    // Task association (optional - nil means standalone session)
    var taskId: UUID? = nil

    public enum ParseLevel: String, Codable, Sendable, Comparable {
        case metadata
        case full
        case enriched

        public static func < (lhs: ParseLevel, rhs: ParseLevel) -> Bool {
            switch (lhs, rhs) {
            case (.metadata, .full), (.metadata, .enriched), (.full, .enriched): return true
            default: return false
            }
        }
    }

    var parseLevel: ParseLevel? = nil

    var duration: TimeInterval {
        if let activeDuration { return activeDuration }
        guard let end = endedAt ?? lastUpdatedAt else { return 0 }
        return end.timeIntervalSince(startedAt)
    }

    var actualTotalTokens: Int {
        return totalTokens ?? 0
    }

    var displayName: String {
        let filename = fileURL.deletingPathExtension().lastPathComponent

        // Handle new format: agent-6afec743 -> extract agentId from filename
        if filename.hasPrefix("agent-") {
            // Use the agentId portion from filename to distinguish between parallel agents
            let agentId = String(filename.dropFirst("agent-".count))
            if !agentId.isEmpty {
                return "agent-\(agentId)"
            }
            // Fallback to sessionId if agentId extraction failed
            return id
        }

        // Handle old UUID format: ed5f5b12-a30b-4c86-b3ff-5bcf5dba65c0 -> use as is
        if filename.components(separatedBy: "-").count == 5 &&
           filename.count == 36 &&
           UUID(uuidString: filename) != nil {
            return filename
        }

        // Handle rollout format: "rollout-2025-10-17T14-11-18-0199f124-8c38-7140-969c-396260d0099c"
        // Keep only the last 5 segments after removing rollout + timestamp (5 parts)
        let components = filename.components(separatedBy: "-")
        if components.count >= 7 {
            // Skip first component (rollout) and next 5 components (timestamp), keep last 5
            let sessionIdComponents = Array(components.dropFirst(6))
            return sessionIdComponents.joined(separator: "-")
        }

        return filename
    }

    // Prefer user-provided title when available
    var effectiveTitle: String { (userTitle?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? displayName }

    var instructionSnippet: String {
        guard let instructions, !instructions.isEmpty else { return "—" }
        let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 220 {
            return trimmed
        }
        let index = trimmed.index(trimmed.startIndex, offsetBy: 220)
        return "\(trimmed[..<index])…"
    }

    // Prefer user comment (100 chars) when available
    var commentSnippet: String {
        if let s = userComment?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            if s.count <= 100 { return s }
            let idx = s.index(s.startIndex, offsetBy: 100)
            return String(s[..<idx]) + "…"
        }
        return instructionSnippet
    }

    var readableDuration: String {
        return Self.durationFormatter.string(from: duration) ?? "—"
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .pad
        return formatter
    }()

    var displayModel: String? {
        guard let model else { return nil }
        return source.friendlyModelName(for: model)
    }

    var remoteHost: String? { source.remoteHost }
    var isRemote: Bool { source.isRemote }
    var identityKey: String {
        if let host = remoteHost {
            return "\(host)::\(id)"
        }
        return id
    }

    var fileSizeDisplay: String {
        guard let bytes = resolvedFileSizeBytes else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    var resolvedFileSizeBytes: UInt64? {
        return fileSizeBytes
    }

    func matches(search term: String) -> Bool {
        guard !term.isEmpty else { return true }
        
        if id.localizedCaseInsensitiveContains(term) { return true }
        if displayName.localizedCaseInsensitiveContains(term) { return true }
        if let userTitle, userTitle.localizedCaseInsensitiveContains(term) { return true }
        if let userComment, userComment.localizedCaseInsensitiveContains(term) { return true }
        if cliVersion.localizedCaseInsensitiveContains(term) { return true }
        if cwd.localizedCaseInsensitiveContains(term) { return true }
        if originator.localizedCaseInsensitiveContains(term) { return true }
        if let instructions, instructions.localizedCaseInsensitiveContains(term) { return true }
        if let model, model.localizedCaseInsensitiveContains(term) { return true }
        if let approvalPolicy, approvalPolicy.localizedCaseInsensitiveContains(term) { return true }
        if let host = remoteHost, host.localizedCaseInsensitiveContains(term) { return true }
        if let remotePath, remotePath.localizedCaseInsensitiveContains(term) { return true }
        
        return false
    }
}

extension SessionSummary {
    func overridingSource(_ newSource: SessionSource, remotePath: String? = nil) -> SessionSummary {
        if newSource == source, remotePath == self.remotePath { return self }
        let adjustedModel = (newSource.baseKind == source.baseKind) ? model : nil
        let adjustedApproval = (newSource.baseKind == source.baseKind) ? approvalPolicy : nil
        var s = SessionSummary(
            id: id,
            fileURL: fileURL,
            fileSizeBytes: fileSizeBytes,
            startedAt: startedAt,
            endedAt: endedAt,
            activeDuration: activeDuration,
            cliVersion: cliVersion,
            cwd: cwd,
            originator: originator,
            instructions: instructions,
            model: adjustedModel,
            approvalPolicy: adjustedApproval,
            userMessageCount: userMessageCount,
            assistantMessageCount: assistantMessageCount,
            toolInvocationCount: toolInvocationCount,
            responseCounts: responseCounts,
            turnContextCount: turnContextCount,
            totalTokens: totalTokens,
            eventCount: eventCount,
            lineCount: lineCount,
            lastUpdatedAt: lastUpdatedAt,
            source: newSource,
            remotePath: remotePath ?? self.remotePath,
            userTitle: userTitle,
            userComment: userComment,
            taskId: taskId
        )
        s.parseLevel = parseLevel
        return s
    }

    func withRemoteMetadata(source: SessionSource, remotePath: String) -> SessionSummary {
        return overridingSource(source, remotePath: remotePath)
    }

    func overridingCounts(
        userMessages: Int? = nil,
        assistantMessages: Int? = nil,
        toolInvocations: Int? = nil
    ) -> SessionSummary {
        var s = SessionSummary(
            id: id,
            fileURL: fileURL,
            fileSizeBytes: fileSizeBytes,
            startedAt: startedAt,
            endedAt: endedAt,
            activeDuration: activeDuration,
            cliVersion: cliVersion,
            cwd: cwd,
            originator: originator,
            instructions: instructions,
            model: model,
            approvalPolicy: approvalPolicy,
            userMessageCount: userMessages ?? userMessageCount,
            assistantMessageCount: assistantMessages ?? assistantMessageCount,
            toolInvocationCount: toolInvocations ?? toolInvocationCount,
            responseCounts: responseCounts,
            turnContextCount: turnContextCount,
            totalTokens: totalTokens,
            eventCount: eventCount,
            lineCount: lineCount,
            lastUpdatedAt: lastUpdatedAt,
            source: source,
            remotePath: remotePath,
            userTitle: userTitle,
            userComment: userComment,
            taskId: taskId
        )
        s.parseLevel = parseLevel
        return s
    }
    
    func withParseLevel(_ level: ParseLevel?) -> SessionSummary {
        var s = self
        s.parseLevel = level
        return s
    }
    
    func withParseLevel(fromString levelString: String?) -> SessionSummary {
        guard let levelString, let level = ParseLevel(rawValue: levelString) else { return self }
        return withParseLevel(level)
    }
}

enum SessionSortOrder: String, CaseIterable, Identifiable, Sendable {
    case mostRecent
    case longestDuration
    case mostActivity
    case alphabetical
    case largestSize

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mostRecent: return "Recent"
        case .longestDuration: return "Duration"
        case .mostActivity: return "Activity"
        case .alphabetical: return "Name"
        case .largestSize: return "Size"
        }
    }

    func sort(_ sessions: [SessionSummary]) -> [SessionSummary] {
        switch self {
        case .mostRecent:
            return sessions.sorted {
                ($0.lastUpdatedAt ?? $0.startedAt) > ($1.lastUpdatedAt ?? $1.startedAt)
            }
        case .longestDuration:
            return sessions.sorted { $0.duration > $1.duration }
        case .mostActivity:
            return sessions.sorted {
                if $0.eventCount != $1.eventCount { return $0.eventCount > $1.eventCount }
                let l0 = $0.lastUpdatedAt ?? $0.startedAt
                let l1 = $1.lastUpdatedAt ?? $1.startedAt
                if l0 != l1 { return l0 > l1 }
                return $0.effectiveTitle
                    .localizedCaseInsensitiveCompare($1.effectiveTitle) == .orderedAscending
            }
        case .alphabetical:
            return sessions.sorted {
                let cmp = $0.effectiveTitle.localizedStandardCompare($1.effectiveTitle)
                if cmp == .orderedSame {
                    let l0 = $0.lastUpdatedAt ?? $0.startedAt
                    let l1 = $1.lastUpdatedAt ?? $1.startedAt
                    if l0 != l1 { return l0 > l1 }
                    return $0.id < $1.id
                }
                return cmp == .orderedAscending
            }
        case .largestSize:
            return sessions.sorted { ($0.fileSizeBytes ?? 0) > ($1.fileSizeBytes ?? 0) }
        }
    }

    // Dimension-aware sorting variant used by the middle list. For "Recent",
    // order by created vs. last-updated depending on the calendar mode; other
    // sort orders fall back to the default behavior above.
    func sort(_ sessions: [SessionSummary], dimension: DateDimension) -> [SessionSummary] {
        switch self {
        case .mostRecent:
            let key: (SessionSummary) -> Date = {
                switch dimension {
                case .created: return $0.startedAt
                case .updated: return $0.lastUpdatedAt ?? $0.startedAt
                }
            }
            return sessions.sorted { key($0) > key($1) }
        default:
            return sort(sessions)
        }
    }
}

struct SessionDaySection: Identifiable, Hashable, Sendable {
    let id: Date
    let title: String
    let totalDuration: TimeInterval
    let totalEvents: Int
    let sessions: [SessionSummary]
}

enum SessionSource: Hashable, Sendable {
    case codexLocal
    case claudeLocal
    case geminiLocal
    case codexRemote(host: String)
    case claudeRemote(host: String)
    case geminiRemote(host: String)

    var isRemote: Bool {
        switch self {
        case .codexRemote, .claudeRemote, .geminiRemote: return true
        default: return false
        }
    }

    var remoteHost: String? {
        switch self {
        case .codexRemote(let host), .claudeRemote(let host), .geminiRemote(let host): return host
        default: return nil
        }
    }

    var baseKind: Kind {
        switch self {
        case .codexLocal, .codexRemote: return .codex
        case .claudeLocal, .claudeRemote: return .claude
        case .geminiLocal, .geminiRemote: return .gemini
        }
    }

    enum Kind: String, Sendable {
    case codex
    case claude
    case gemini
    
    var cliExecutableName: String {
        switch self {
        case .codex: return "codex"
        case .claude: return "claude"
        case .gemini: return "gemini"
        }
    }
    }
}

extension SessionSource.Kind {
    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        }
    }
}

extension SessionSource: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case host
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .codexLocal:
            var container = encoder.singleValueContainer()
            try container.encode("codex")
        case .claudeLocal:
            var container = encoder.singleValueContainer()
            try container.encode("claude")
        case .geminiLocal:
            var container = encoder.singleValueContainer()
            try container.encode("gemini")
        case .codexRemote(let host):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("codexRemote", forKey: .kind)
            try container.encode(host, forKey: .host)
        case .claudeRemote(let host):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("claudeRemote", forKey: .kind)
            try container.encode(host, forKey: .host)
        case .geminiRemote(let host):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("geminiRemote", forKey: .kind)
            try container.encode(host, forKey: .host)
        }
    }

    init(from decoder: Decoder) throws {
        if let singleValue = try? decoder.singleValueContainer(),
           let raw = try? singleValue.decode(String.self)
        {
            switch raw {
            case "codex":
                self = .codexLocal
            case "claude":
                self = .claudeLocal
            case "gemini":
                self = .geminiLocal
            case "codexLocal":
                self = .codexLocal
            case "claudeLocal":
                self = .claudeLocal
            case "geminiLocal":
                self = .geminiLocal
            default:
                throw DecodingError.dataCorruptedError(
                    in: singleValue, debugDescription: "Unknown SessionSource raw value \(raw)")
            }
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "codexRemote":
            let host = try container.decode(String.self, forKey: .host)
            self = .codexRemote(host: host)
        case "claudeRemote":
            let host = try container.decode(String.self, forKey: .host)
            self = .claudeRemote(host: host)
        case "geminiRemote":
            let host = try container.decode(String.self, forKey: .host)
            self = .geminiRemote(host: host)
        case "codex":
            self = .codexLocal
        case "claude":
            self = .claudeLocal
        case "gemini":
            self = .geminiLocal
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container, debugDescription: "Unknown SessionSource kind \(kind)")
        }
    }
}

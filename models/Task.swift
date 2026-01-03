import Foundation

// MARK: - Task Type

enum TaskType: String, Codable, CaseIterable, Identifiable, Sendable {
    case feature = "feature"
    case bugFix = "bug_fix"
    case discussion = "discussion"
    case refactor = "refactor"
    case documentation = "documentation"
    case other = "other"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .feature: return "Feature"
        case .bugFix: return "Bug Fix"
        case .discussion: return "Discussion"
        case .refactor: return "Refactor"
        case .documentation: return "Documentation"
        case .other: return "Other"
        }
    }

    var icon: String {
        switch self {
        case .feature: return "star.fill"
        case .bugFix: return "ladybug.fill"
        case .discussion: return "bubble.left.and.bubble.right.fill"
        case .refactor: return "arrow.triangle.2.circlepath"
        case .documentation: return "doc.text.fill"
        case .other: return "ellipsis.circle.fill"
        }
    }

    var descriptionTemplate: String {
        switch self {
        case .feature:
            return "Implement a new feature or functionality"
        case .bugFix:
            return "Fix a bug or resolve an issue"
        case .discussion:
            return "Discuss requirements, architecture, or approach"
        case .refactor:
            return "Refactor code to improve structure or performance"
        case .documentation:
            return "Write or update documentation"
        case .other:
            return "General task"
        }
    }
}

// MARK: - Task Status

enum TaskStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed
    case canceled
    case archived

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pending: return "Pending"
        case .inProgress: return "In Progress"
        case .completed: return "Completed"
        case .canceled: return "Canceled"
        case .archived: return "Archived"
        }
    }

    var icon: String {
        switch self {
        case .pending: return "circle"
        case .inProgress: return "circle.dotted"
        case .completed: return "checkmark.circle.fill"
        case .canceled: return "xmark.circle.fill"
        case .archived: return "archivebox.fill"
        }
    }
}

enum ContextType: String, Codable, Sendable {
    case userMarked = "user_marked"
    case autoSuggested = "auto_suggested"
}

struct ContextItem: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var content: String
    var sourceSessionId: String
    var sourceMessageId: String?
    var addedAt: Date
    var type: ContextType

    init(
        id: UUID = UUID(),
        content: String,
        sourceSessionId: String,
        sourceMessageId: String? = nil,
        addedAt: Date = Date(),
        type: ContextType = .userMarked
    ) {
        self.id = id
        self.content = content
        self.sourceSessionId = sourceSessionId
        self.sourceMessageId = sourceMessageId
        self.addedAt = addedAt
        self.type = type
    }
}

struct CodMateTask: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var title: String
    var description: String?
    var taskType: TaskType
    var projectId: String
    var createdAt: Date
    var updatedAt: Date

    // Shared context
    var sharedContext: [ContextItem]
    var agentsConfig: String? // Reference to Agents.md sections
    var memoryItems: [String] // Memory item IDs

    // Contained sessions
    var sessionIds: [String]

    // Metadata
    var status: TaskStatus
    var tags: [String]

    // Primary provider for this task
    var primaryProvider: ProjectSessionSource?

    init(
        id: UUID = UUID(),
        title: String,
        description: String? = nil,
        taskType: TaskType = .other,
        projectId: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        sharedContext: [ContextItem] = [],
        agentsConfig: String? = nil,
        memoryItems: [String] = [],
        sessionIds: [String] = [],
        status: TaskStatus = .pending,
        tags: [String] = [],
        primaryProvider: ProjectSessionSource? = nil
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.taskType = taskType
        self.projectId = projectId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sharedContext = sharedContext
        self.agentsConfig = agentsConfig
        self.memoryItems = memoryItems
        self.sessionIds = sessionIds
        self.status = status
        self.tags = tags
        self.primaryProvider = primaryProvider
    }

    var effectiveTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Task" : trimmed
    }

    var effectiveDescription: String? {
        guard let desc = description else { return nil }
        let trimmed = desc.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func matches(search term: String) -> Bool {
        guard !term.isEmpty else { return true }
        let needle = term.lowercased()
        let haystack = [
            title,
            description ?? "",
            tags.joined(separator: " "),
            agentsConfig ?? ""
        ].map { $0.lowercased() }

        return haystack.contains(where: { $0.contains(needle) })
    }
}

// CodMateTask with enriched session summaries for display
struct TaskWithSessions: Identifiable, Hashable {
    let task: CodMateTask
    let sessions: [SessionSummary]

    var id: UUID { task.id }

    var totalDuration: TimeInterval {
        sessions.reduce(0) { $0 + $1.duration }
    }

    var totalTokens: Int {
        sessions.reduce(0) { $0 + $1.turnContextCount }
    }

    var lastActivityDate: Date {
        let sessionDates = sessions.compactMap { $0.lastUpdatedAt ?? $0.startedAt }
        return sessionDates.max() ?? task.updatedAt
    }
}

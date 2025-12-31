import Foundation
import SwiftUI

@MainActor
class ProjectWorkspaceViewModel: ObservableObject {
    @Published var selectedMode: ProjectWorkspaceMode = .tasks
    @Published var tasks: [CodMateTask] = []

    // Task title/description generation state
    @Published var isGeneratingTitleDescription: Bool = false
    @Published var generatingTaskId: UUID? = nil

    // Temporary edit state for generated content
    @Published var generatedTaskTitle: String? = nil
    @Published var generatedTaskDescription: String? = nil

    private let tasksStore: TasksStore
    private let sessionListViewModel: SessionListViewModel
    private let contextTreeshaker = ContextTreeshaker()

    init(tasksStore: TasksStore = TasksStore(), sessionListViewModel: SessionListViewModel) {
        self.tasksStore = tasksStore
        self.sessionListViewModel = sessionListViewModel
    }

    // MARK: - Task Management

    func loadTasks(for projectId: String) async {
        let loaded = await tasksStore.listTasks(for: projectId)
        await MainActor.run {
            self.tasks = loaded
        }
    }

    func createTask(title: String, description: String?, projectId: String) async {
        let task = CodMateTask(
            title: title,
            description: description,
            projectId: projectId
        )
        await tasksStore.upsertTask(task)
        await loadTasks(for: projectId)
    }

    func updateTask(_ task: CodMateTask) async {
        // Enforce 0/1 membership: a session can belong to at most one task
        var normalized = task
        // Deduplicate session IDs within this task
        let uniqueIds = Array(Set(normalized.sessionIds))
        normalized.sessionIds = uniqueIds

        let projectId = normalized.projectId
        let idsSet = Set(uniqueIds)

        // Remove these sessions from all other tasks in the same project
        for var other in tasks where other.id != normalized.id && other.projectId == projectId {
            let filtered = other.sessionIds.filter { !idsSet.contains($0) }
            if filtered != other.sessionIds {
                other.sessionIds = filtered
                await tasksStore.upsertTask(other)
            }
        }

        await tasksStore.upsertTask(normalized)
        await loadTasks(for: projectId)
    }

    func deleteTask(_ taskId: UUID, projectId: String) async {
        await tasksStore.deleteTask(id: taskId)
        await loadTasks(for: projectId)
    }

    func assignSessionsToTask(_ sessionIds: [String], taskId: UUID?) async {
        await tasksStore.assignSessions(sessionIds, to: taskId)
        // Reload tasks to reflect the changes
        if let task = tasks.first(where: { $0.id == taskId }) {
            await loadTasks(for: task.projectId)
        }
    }

    func addContextToTask(_ item: ContextItem, taskId: UUID) async {
        await tasksStore.addContextItem(item, to: taskId)
        if let task = tasks.first(where: { $0.id == taskId }) {
            await loadTasks(for: task.projectId)
        }
    }

    func removeContextFromTask(_ contextId: UUID, taskId: UUID) async {
        await tasksStore.removeContextItem(id: contextId, from: taskId)
        if let task = tasks.first(where: { $0.id == taskId }) {
            await loadTasks(for: task.projectId)
        }
    }

    // MARK: - Shared Task Context

    /// Regenerates the shared context file for the given task.
    /// The file is written to ~/.codmate/tasks/context-<taskId>.md and contains a
    /// compact markdown snapshot of the most recent sessions under this task.
    func syncTaskContext(taskId: UUID, maxSessions: Int = 5) async -> URL? {
        // Prefer in-memory snapshot; fall back to store when needed
        let task: CodMateTask
        if let cached = tasks.first(where: { $0.id == taskId }) {
            task = cached
        } else if let loaded = await tasksStore.getTask(id: taskId) {
            task = loaded
        } else {
            return nil
        }

        // Resolve sessions for this task from the global list
        let allSessions = sessionListViewModel.allSessions
        let sessionsForTask = allSessions.filter { task.sessionIds.contains($0.id) }
        let sortedSessions = sessionsForTask.sorted { lhs, rhs in
            let lDate = lhs.lastUpdatedAt ?? lhs.startedAt
            let rDate = rhs.lastUpdatedAt ?? rhs.startedAt
            return lDate < rDate
        }
        let limited = Array(sortedSessions.suffix(maxSessions))

        // Build slim markdown using the same engine as the legacy New With Context flow…
        var options = TreeshakeOptions()
        let kinds = sessionListViewModel.preferences.markdownVisibleKinds
        options.visibleKinds = kinds
        options.includeReasoning = kinds.contains(.reasoning)
        options.includeToolSummary = kinds.contains(.infoOther)

        let body: String
        if limited.isEmpty {
            body = "_No sessions available for this task yet._"
        } else {
            body = await contextTreeshaker.generateMarkdown(for: limited, options: options)
        }

        var headerLines: [String] = [
            "# Task: \(task.effectiveTitle)",
            "",
            "- Updated: \(Date().formatted(date: .abbreviated, time: .shortened))",
            "- Project: \(task.projectId)",
            "- Status: \(task.status.displayName)"
        ]

        if let desc = task.effectiveDescription {
            headerLines.append("- Description: \(desc)")
        }

        let sessionList = task.sessionIds.joined(separator: ", ")
        if !sessionList.isEmpty {
            headerLines.append("- Sessions: \(sessionList)")
        }

        headerLines.append("")

        if !sortedSessions.isEmpty {
            headerLines.append("## Sessions in this Task")
            headerLines.append("")

            for session in sortedSessions {
                headerLines.append("- \(session.effectiveTitle)")

                if let rawComment = session.userComment?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !rawComment.isEmpty
                {
                    let snippet =
                        rawComment.count > 200
                        ? String(rawComment.prefix(200)) + "…"
                        : rawComment
                    headerLines.append("  - Note: \(snippet)")
                } else if let rawInstructions = session.instructions?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !rawInstructions.isEmpty
                {
                    let snippet =
                        rawInstructions.count > 200
                        ? String(rawInstructions.prefix(200)) + "…"
                        : rawInstructions
                    headerLines.append("  - Instructions: \(snippet)")
                }
            }

            headerLines.append("")
        }

        headerLines.append("## Shared Context")
        headerLines.append("")

        let content = (headerLines + [body]).joined(separator: "\n")

        let fm = FileManager.default
        let paths = TasksStore.Paths.default(fileManager: fm)
        let root = paths.root
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let url = root.appendingPathComponent("context-\(taskId.uuidString).md", isDirectory: false)
            try content.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Task With Sessions

    func enrichTasksWithSessions() -> [TaskWithSessions] {
        let allSessions = sessionListViewModel.allSessions
        return tasks.map { task in
            let sessions = allSessions.filter { task.sessionIds.contains($0.id) }
            // Keep session ordering consistent with the main list
            // by reusing the current sort order.
            let sorted = sessionListViewModel.sortOrder.sort(sessions)
            return TaskWithSessions(task: task, sessions: sorted)
        }
    }

    func getSessionsForTask(_ taskId: UUID) -> [SessionSummary] {
        guard let task = tasks.first(where: { $0.id == taskId }) else { return [] }
        let allSessions = sessionListViewModel.allSessions
        return allSessions.filter { task.sessionIds.contains($0.id) }
    }

    // MARK: - Overview Statistics

    func getProjectStatistics(for projectId: String) -> ProjectStatistics {
        let projectSessions = sessionListViewModel.allSessions.filter { session in
            sessionListViewModel.projectIdForSession(session.id) == projectId
        }

        let totalDuration = projectSessions.reduce(0) { $0 + $1.duration }
        let totalTokens = projectSessions.reduce(0) { $0 + $1.actualTotalTokens }
        let totalEvents = projectSessions.reduce(0) { $0 + $1.eventCount }

        let projectTasks = tasks.filter { $0.projectId == projectId }
        let completedTasks = projectTasks.filter { $0.status == .completed }.count
        let inProgressTasks = projectTasks.filter { $0.status == .inProgress }.count
        let pendingTasks = projectTasks.filter { $0.status == .pending }.count

        return ProjectStatistics(
            totalSessions: projectSessions.count,
            totalTasks: projectTasks.count,
            completedTasks: completedTasks,
            inProgressTasks: inProgressTasks,
            pendingTasks: pendingTasks,
            totalDuration: totalDuration,
            totalTokens: totalTokens,
            totalEvents: totalEvents
        )
    }
}

struct ProjectStatistics {
    let totalSessions: Int
    let totalTasks: Int
    let completedTasks: Int
    let inProgressTasks: Int
    let pendingTasks: Int
    let totalDuration: TimeInterval
    let totalTokens: Int
    let totalEvents: Int

    var taskCompletionRate: Double {
        guard totalTasks > 0 else { return 0 }
        return Double(completedTasks) / Double(totalTasks)
    }

    var averageSessionDuration: TimeInterval {
        guard totalSessions > 0 else { return 0 }
        return totalDuration / Double(totalSessions)
    }

    var averageTokensPerSession: Double {
        guard totalSessions > 0 else { return 0 }
        return Double(totalTokens) / Double(totalSessions)
    }
}

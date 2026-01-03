import Foundation

// TasksStore: manages task metadata and session-to-task relationships
// Layout (under ~/.codmate/tasks):
//  - metadata/<taskId>.json  (one file per task)
//  - relationships.json      (central mapping: { version, sessionToTask, taskToProject })

struct TaskMeta: Codable, Hashable, Sendable {
    var id: UUID
    var title: String
    var description: String?
    var taskType: TaskType
    var projectId: String
    var createdAt: Date
    var updatedAt: Date
    var sharedContext: [ContextItem]
    var agentsConfig: String?
    var memoryItems: [String]
    var sessionIds: [String]
    var status: TaskStatus
    var tags: [String]
    var primaryProvider: ProjectSessionSource?

    init(from task: CodMateTask) {
        self.id = task.id
        self.title = task.title
        self.description = task.description
        self.taskType = task.taskType
        self.projectId = task.projectId
        self.createdAt = task.createdAt
        self.updatedAt = task.updatedAt
        self.sharedContext = task.sharedContext
        self.agentsConfig = task.agentsConfig
        self.memoryItems = task.memoryItems
        self.sessionIds = task.sessionIds
        self.status = task.status
        self.tags = task.tags
        self.primaryProvider = task.primaryProvider
    }

    // Custom decoder to handle backward compatibility with old task data
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)

        // Provide default value for taskType if not present (backward compatibility)
        taskType = try container.decodeIfPresent(TaskType.self, forKey: .taskType) ?? .other

        projectId = try container.decode(String.self, forKey: .projectId)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        sharedContext = try container.decode([ContextItem].self, forKey: .sharedContext)
        agentsConfig = try container.decodeIfPresent(String.self, forKey: .agentsConfig)
        memoryItems = try container.decode([String].self, forKey: .memoryItems)
        sessionIds = try container.decode([String].self, forKey: .sessionIds)
        status = try container.decode(TaskStatus.self, forKey: .status)
        tags = try container.decode([String].self, forKey: .tags)

        // primaryProvider is optional, so old data without it will have nil
        primaryProvider = try container.decodeIfPresent(ProjectSessionSource.self, forKey: .primaryProvider)
    }

    func asTask() -> CodMateTask {
        CodMateTask(
            id: id,
            title: title,
            description: description,
            taskType: taskType,
            projectId: projectId,
            createdAt: createdAt,
            updatedAt: updatedAt,
            sharedContext: sharedContext,
            agentsConfig: agentsConfig,
            memoryItems: memoryItems,
            sessionIds: sessionIds,
            status: status,
            tags: tags,
            primaryProvider: primaryProvider
        )
    }
}

actor TasksStore {
    struct Paths {
        let root: URL
        let metadataDir: URL
        let relationshipsURL: URL

        static func `default`(fileManager: FileManager = .default) -> Paths {
            let home = fileManager.homeDirectoryForCurrentUser
            let root = home.appendingPathComponent(".codmate", isDirectory: true)
                .appendingPathComponent("tasks", isDirectory: true)
            return Paths(
                root: root,
                metadataDir: root.appendingPathComponent("metadata", isDirectory: true),
                relationshipsURL: root.appendingPathComponent("relationships.json", isDirectory: false)
            )
        }
    }

    private let fm: FileManager
    private let paths: Paths

    // Runtime caches
    private var tasks: [UUID: TaskMeta] = [:] // taskId -> meta
    private var sessionToTask: [String: UUID] = [:] // sessionId -> taskId

    // Special "Others" task ID - consistent across sessions
    static let othersTaskId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    init(paths: Paths = .default(), fileManager: FileManager = .default) {
        self.fm = fileManager
        self.paths = paths
        try? fm.createDirectory(at: paths.metadataDir, withIntermediateDirectories: true)

        // Load relationships
        if let data = try? Data(contentsOf: paths.relationshipsURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let map = obj["sessionToTask"] as? [String: String]
        {
            self.sessionToTask = map.compactMapValues { UUID(uuidString: $0) }
        }

        // Load metadata
        var loadedTasks: [UUID: TaskMeta] = [:]
        if let en = fm.enumerator(at: paths.metadataDir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            for case let url as URL in en {
                if url.pathExtension.lowercased() != "json" { continue }
                if let data = try? Data(contentsOf: url),
                   let meta = try? dec.decode(TaskMeta.self, from: data)
                {
                    loadedTasks[meta.id] = meta
                }
            }
        }
        self.tasks = loadedTasks

        // Ensure "Others" task exists (directly inline to avoid actor isolation issue in init)
        if self.tasks[Self.othersTaskId] == nil {
            let othersTask = CodMateTask(
                id: Self.othersTaskId,
                title: "Others",
                description: "Automatically collected sessions without explicit task assignment",
                taskType: .other,
                projectId: "others",
                status: .inProgress
            )
            let meta = TaskMeta(from: othersTask)
            self.tasks[Self.othersTaskId] = meta

            // Save to disk
            let url = paths.metadataDir.appendingPathComponent(meta.id.uuidString + ".json")
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            enc.dateEncodingStrategy = .iso8601
            if let data = try? enc.encode(meta) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    // MARK: - Others Task Management

    func assignToOthers(sessionId: String) {
        assignSessions([sessionId], to: Self.othersTaskId)
    }

    // MARK: - Public API

    func listTasks() -> [CodMateTask] {
        tasks.values.map { $0.asTask() }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func listTasks(for projectId: String) -> [CodMateTask] {
        tasks.values
            .filter { $0.projectId == projectId }
            .map { $0.asTask() }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func getTask(id: UUID) -> CodMateTask? {
        tasks[id]?.asTask()
    }

    func upsertTask(_ task: CodMateTask) {
        var meta = tasks[task.id] ?? TaskMeta(from: task)
        meta.title = task.title
        meta.description = task.description
        meta.taskType = task.taskType
        meta.projectId = task.projectId
        meta.sharedContext = task.sharedContext
        meta.agentsConfig = task.agentsConfig
        meta.memoryItems = task.memoryItems
        meta.sessionIds = task.sessionIds
        meta.status = task.status
        meta.tags = task.tags
        meta.primaryProvider = task.primaryProvider
        meta.updatedAt = Date()
        tasks[task.id] = meta

        // Update session-to-task mappings
        for sessionId in task.sessionIds {
            sessionToTask[sessionId] = task.id
        }

        saveTaskMeta(meta)
        saveRelationships()
    }

    func deleteTask(id: UUID) {
        // Remove meta
        tasks.removeValue(forKey: id)
        let metaURL = paths.metadataDir.appendingPathComponent(id.uuidString + ".json")

        // Move to Trash instead of permanent deletion
        var resulting: NSURL?
        if fm.fileExists(atPath: metaURL.path) {
            do { try fm.trashItem(at: metaURL, resultingItemURL: &resulting) } catch { /* best-effort */ }
        }

        // Unassign all sessions under this task
        var changed = false
        for (sid, tid) in sessionToTask where tid == id {
            sessionToTask.removeValue(forKey: sid)
            changed = true
        }
        if changed { saveRelationships() }
    }

    func assignSessions(_ sessionIds: [String], to taskId: UUID?) {
        var changed = false
        for sid in sessionIds {
            let trimmed = sid.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            if let tid = taskId {
                if sessionToTask[trimmed] != tid {
                    sessionToTask[trimmed] = tid
                    changed = true
                }
            } else {
                if sessionToTask.removeValue(forKey: trimmed) != nil {
                    changed = true
                }
            }
        }
        if changed { saveRelationships() }
    }

    func taskId(for sessionId: String) -> UUID? {
        sessionToTask[sessionId]
    }

    func addContextItem(_ item: ContextItem, to taskId: UUID) {
        guard var meta = tasks[taskId] else { return }
        meta.sharedContext.append(item)
        meta.updatedAt = Date()
        tasks[taskId] = meta
        saveTaskMeta(meta)
    }

    func removeContextItem(id: UUID, from taskId: UUID) {
        guard var meta = tasks[taskId] else { return }
        meta.sharedContext.removeAll { $0.id == id }
        meta.updatedAt = Date()
        tasks[taskId] = meta
        saveTaskMeta(meta)
    }

    // MARK: - Private Methods

    private func saveTaskMeta(_ meta: TaskMeta) {
        try? fm.createDirectory(at: paths.metadataDir, withIntermediateDirectories: true)
        let url = paths.metadataDir.appendingPathComponent(meta.id.uuidString + ".json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(meta) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func saveRelationships() {
        let sessionToTaskStrings = sessionToTask.mapValues { $0.uuidString }
        let obj: [String: Any] = [
            "version": 1,
            "sessionToTask": sessionToTaskStrings
        ]
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) {
            try? fm.createDirectory(at: paths.root, withIntermediateDirectories: true)
            try? data.write(to: paths.relationshipsURL, options: .atomic)
        }
    }
}

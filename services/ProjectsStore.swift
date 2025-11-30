import Foundation

// ProjectsStore: manages project metadata and session memberships
// Layout (under ~/.codmate/projects):
//  - metadata/<projectId>.json  (one file per project)
//  - memberships.json           (central mapping: { version, sessionToProject })

struct ProjectMeta: Codable, Hashable, Sendable {
    var id: String
    var name: String
    var directory: String?
    var trustLevel: String?
    var overview: String?
    var instructions: String?
    var profileId: String?
    var profile: ProjectProfile?
    var parentId: String?
    var sources: [ProjectSessionSource]?
    var createdAt: Date
    var updatedAt: Date

    init(from project: Project) {
        self.id = project.id
        self.name = project.name
        self.directory = project.directory
        self.trustLevel = project.trustLevel
        self.overview = project.overview
        self.instructions = project.instructions
        self.profileId = project.profileId
        self.profile = project.profile
        self.parentId = project.parentId
        self.sources = Array(project.sources).sorted { $0.rawValue < $1.rawValue }
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    func asProject() -> Project {
        var sourceSet = Set(sources ?? ProjectSessionSource.allCases)
        if sourceSet.isEmpty {
            sourceSet = ProjectSessionSource.allSet
        }
        if !sourceSet.contains(.gemini) {
            sourceSet.insert(.gemini)
        }
        return Project(
            id: id,
            name: name,
            directory: directory,
            trustLevel: trustLevel,
            overview: overview,
            instructions: instructions,
            profileId: profileId,
            profile: profile,
            parentId: parentId,
            sources: sourceSet
        )
    }
}

struct SessionAssignment: Codable, Hashable, Sendable {
    let id: String
    let source: ProjectSessionSource
}

actor ProjectsStore {
    struct Paths {
        let root: URL
        let metadataDir: URL
        let membershipsURL: URL

        static func `default`(fileManager: FileManager = .default) -> Paths {
            let home = fileManager.homeDirectoryForCurrentUser
            // New centralized CodMate data root
            let root = home.appendingPathComponent(".codmate", isDirectory: true)
                .appendingPathComponent("projects", isDirectory: true)
            return Paths(
                root: root,
                metadataDir: root.appendingPathComponent("metadata", isDirectory: true),
                membershipsURL: root.appendingPathComponent("memberships.json", isDirectory: false)
            )
        }
    }

    private let fm: FileManager
    private let paths: Paths

    // runtime caches
    private var projects: [String: ProjectMeta] = [:] // id -> meta
    private var sessionToProject: [String: String] = [:] // membershipKey -> projectId
    private let membershipVersion = 2

    init(paths: Paths = .default(), fileManager: FileManager = .default) {
        self.fm = fileManager
        self.paths = paths
        // Before creating new directories, attempt legacy migration from ~/.codex/projects → ~/.codmate/projects
        Self.migrateLegacyIfNeeded(to: paths, fm: fm)
        try? fm.createDirectory(at: paths.metadataDir, withIntermediateDirectories: true)
        // Load memberships
        if let data = try? Data(contentsOf: paths.membershipsURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            let map = obj["sessionToProject"] as? [String: String] ?? [:]
            let version = obj["version"] as? Int ?? 1
            if version >= 2 {
                self.sessionToProject = map
            } else {
                // Legacy keys did not encode the session source; assume Codex
                self.sessionToProject = map.reduce(into: [:]) { result, entry in
                    let legacyKey = membershipKey(for: entry.key, source: .codex)
                    result[legacyKey] = entry.value
                }
            }
        }
        // Load metadata
        if let en = fm.enumerator(at: paths.metadataDir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            for case let url as URL in en {
                if url.pathExtension.lowercased() != "json" { continue }
                if let data = try? Data(contentsOf: url),
                   let meta = try? dec.decode(ProjectMeta.self, from: data)
                {
                    self.projects[meta.id] = meta
                }
            }
        }
    }

    // MARK: - Public API
    func listProjects() -> [Project] { projects.values.map { $0.asProject() }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    func getProject(id: String) -> Project? { projects[id]?.asProject() }

    func upsertProject(_ p: Project) {
        var meta = projects[p.id] ?? ProjectMeta(from: p)
        meta.name = p.name
        meta.directory = p.directory
        meta.trustLevel = p.trustLevel
        meta.overview = p.overview
        meta.instructions = p.instructions
        meta.profileId = p.profileId
        meta.profile = p.profile
        meta.parentId = p.parentId
        meta.sources = Array(p.sources).sorted { $0.rawValue < $1.rawValue }
        meta.updatedAt = Date()
        projects[p.id] = meta
        saveProjectMeta(meta)
    }

    func deleteProject(id: String) {
        // Remove meta
        projects.removeValue(forKey: id)
        let metaURL = paths.metadataDir.appendingPathComponent(id + ".json")
        // Move to Trash instead of permanent deletion for safety
        var resulting: NSURL?
        if fm.fileExists(atPath: metaURL.path) {
            do { try fm.trashItem(at: metaURL, resultingItemURL: &resulting) } catch { /* best-effort */ }
        }
        // Unassign all sessions under this project
        var changed = false
        for (sid, pid) in sessionToProject where pid == id {
            sessionToProject.removeValue(forKey: sid)
            changed = true
        }
        if changed { saveMemberships() }
    }

    private func membershipKey(for id: String, source: ProjectSessionSource) -> String {
        return "\(source.rawValue)|\(id)"
    }

    func assign(sessions: [SessionAssignment], to projectId: String?) {
        var changed = false
        for entry in sessions {
            let trimmed = entry.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let key = membershipKey(for: trimmed, source: entry.source)
            if let pid = projectId {
                if sessionToProject[key] != pid {
                    sessionToProject[key] = pid
                    changed = true
                }
            } else {
                if sessionToProject.removeValue(forKey: key) != nil {
                    changed = true
                }
            }
        }
        if changed { saveMemberships() }
    }

    func projectId(for sessionId: String, source: ProjectSessionSource) -> String? {
        sessionToProject[membershipKey(for: sessionId, source: source)]
    }
    func membershipsSnapshot() -> [String: String] { sessionToProject }
    func counts() -> [String: Int] {
        sessionToProject.values.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    // MARK: - Load/Save
    private func loadAll() { /* unused post-init; kept for future reload hooks */ }

    private func saveProjectMeta(_ meta: ProjectMeta) {
        try? fm.createDirectory(at: paths.metadataDir, withIntermediateDirectories: true)
        let url = paths.metadataDir.appendingPathComponent(meta.id + ".json")
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]; enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(meta) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func saveMemberships() {
        let obj: [String: Any] = [
            "version": membershipVersion,
            "sessionToProject": sessionToProject
        ]
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) {
            try? fm.createDirectory(at: paths.root, withIntermediateDirectories: true)
            try? data.write(to: paths.membershipsURL, options: .atomic)
        }
    }

    // MARK: - Legacy migration
    /// Move or copy legacy data from `~/.codex/projects` into the new `~/.codmate/projects` location.
    /// - Behavior:
    ///   - If legacy root exists and new root is missing or empty, attempt a directory move.
    ///   - If new root exists with content, copy over missing files (non-destructive) and keep legacy as-is.
    private static func migrateLegacyIfNeeded(to paths: Paths, fm: FileManager) {
        let home = fm.homeDirectoryForCurrentUser
        let legacyRoot = home.appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
        let newRoot = paths.root

        // Quick existence check
        var isDir: ObjCBool = false
        let legacyExists = fm.fileExists(atPath: legacyRoot.path, isDirectory: &isDir) && isDir.boolValue
        guard legacyExists else { return }

        // Ensure parent of new root exists
        let newParent = newRoot.deletingLastPathComponent()
        try? fm.createDirectory(at: newParent, withIntermediateDirectories: true)

        // Determine if new root exists and is empty
        var newIsDir: ObjCBool = false
        let newExists = fm.fileExists(atPath: newRoot.path, isDirectory: &newIsDir) && newIsDir.boolValue
        let newIsEmpty: Bool = {
            guard newExists else { return true }
            do {
                let items = try fm.contentsOfDirectory(atPath: newRoot.path)
                return items.isEmpty
            } catch { return true }
        }()

        // Prefer moving the whole directory if safe
        if !newExists || newIsEmpty {
            do {
                if newExists && newIsEmpty {
                    // Remove empty shell so move succeeds
                    try? fm.removeItem(at: newRoot)
                }
                try fm.moveItem(at: legacyRoot, to: newRoot)
                return
            } catch {
                // Fall back to per-file copy if move fails (e.g., cross-device)
            }
        }

        // Non-destructive copy of missing files
        do {
            try fm.createDirectory(at: newRoot, withIntermediateDirectories: true)

            // Copy memberships.json if missing
            let legacyMemberships = legacyRoot.appendingPathComponent("memberships.json")
            let newMemberships = newRoot.appendingPathComponent("memberships.json")
            if fm.fileExists(atPath: legacyMemberships.path) && !fm.fileExists(atPath: newMemberships.path) {
                try? fm.copyItem(at: legacyMemberships, to: newMemberships)
            }

            // Copy metadata directory contents if missing
            let legacyMetadata = legacyRoot.appendingPathComponent("metadata", isDirectory: true)
            let newMetadata = newRoot.appendingPathComponent("metadata", isDirectory: true)
            var isLegacyMetaDir: ObjCBool = false
            if fm.fileExists(atPath: legacyMetadata.path, isDirectory: &isLegacyMetaDir), isLegacyMetaDir.boolValue {
                try? fm.createDirectory(at: newMetadata, withIntermediateDirectories: true)
                if let en = fm.enumerator(at: legacyMetadata, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                    for case let url as URL in en {
                        if url.pathExtension.lowercased() != "json" { continue }
                        let dest = newMetadata.appendingPathComponent(url.lastPathComponent)
                        if !fm.fileExists(atPath: dest.path) {
                            try? fm.copyItem(at: url, to: dest)
                        }
                    }
                }
            }
        } catch {
            // Best effort; do not block app startup on migration failures
        }
    }
}

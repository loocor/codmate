import Foundation

struct ProjectMCPSelection: Identifiable, Hashable {
    var id: String { server.name }
    var server: MCPServer
    var isSelected: Bool
    var targets: MCPServerTargets
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: ProjectMCPSelection, rhs: ProjectMCPSelection) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
final class ProjectExtensionsViewModel: ObservableObject {
    private let extensionsStore = ProjectExtensionsStore()
    private let skillsStore = SkillsStore()
    private let mcpStore = MCPServersStore()
    private let applier = ProjectExtensionsApplier()
    private var skillRecords: [SkillRecord] = []
    private var projectId: String?
    private var projectDirectory: URL?

    @Published var skills: [SkillSummary] = []
    @Published var mcpSelections: [ProjectMCPSelection] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var showMCPImportSheet: Bool = false
    @Published var showSkillsImportSheet: Bool = false
    @Published var mcpImportCandidates: [MCPImportCandidate] = []
    @Published var skillsImportCandidates: [SkillImportCandidate] = []
    @Published var isImportingMCP: Bool = false
    @Published var isImportingSkills: Bool = false
    @Published var mcpImportStatusMessage: String?
    @Published var skillsImportStatusMessage: String?

    func load(projectId: String?, projectDirectory: String) async {
        isLoading = true
        defer { isLoading = false }

        self.projectId = projectId
        let dir = projectDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        self.projectDirectory = dir.isEmpty ? nil : URL(fileURLWithPath: dir, isDirectory: true)

        skillRecords = await skillsStore.list()
        let config: ProjectExtensionsConfig?
        if let projectId {
            config = await extensionsStore.load(projectId: projectId)
        } else {
            config = nil
        }

        let skillConfigMap = config?.skills.reduce(into: [String: ProjectSkillConfig]()) { $0[$1.id] = $1 } ?? [:]
        skills = skillRecords.map { record in
            let cfg = skillConfigMap[record.id]
            return SkillSummary(
                id: record.id,
                name: record.name,
                description: record.description,
                summary: record.summary,
                tags: record.tags,
                source: record.source,
                path: record.path,
                isSelected: cfg?.isSelected ?? false,
                targets: cfg?.targets ?? record.targets
            )
        }

        let servers = await mcpStore.list()
        let mcpConfigMap = config?.mcpServers.reduce(into: [String: ProjectMCPConfig]()) { $0[$1.id] = $1 } ?? [:]
        mcpSelections = servers.map { server in
            let targets = server.targets ?? MCPServerTargets()
            let cfg = mcpConfigMap[server.name]
            return ProjectMCPSelection(
                server: server,
                isSelected: cfg?.isSelected ?? false,
                targets: cfg?.targets ?? targets
            )
        }
    }

    func updateMCPSelection(id: String, isSelected: Bool) {
        guard let idx = mcpSelections.firstIndex(where: { $0.id == id }) else { return }
        mcpSelections[idx].isSelected = isSelected
        if !isSelected {
            mcpSelections[idx].targets.codex = false
            mcpSelections[idx].targets.claude = false
            mcpSelections[idx].targets.gemini = false
        } else {
            mcpSelections[idx].targets.codex = true
            mcpSelections[idx].targets.claude = true
            mcpSelections[idx].targets.gemini = true
        }
        Task { await persistAndApplyIfPossible() }
    }

    func updateMCPTarget(id: String, target: MCPServerTarget, value: Bool) {
        guard let idx = mcpSelections.firstIndex(where: { $0.id == id }) else { return }
        mcpSelections[idx].targets.setEnabled(value, for: target)
        if value && !mcpSelections[idx].isSelected {
            mcpSelections[idx].isSelected = true
        } else if !mcpSelections[idx].targets.codex && !mcpSelections[idx].targets.claude && !mcpSelections[idx].targets.gemini {
            mcpSelections[idx].isSelected = false
        }
        Task { await persistAndApplyIfPossible() }
    }

    func updateSkillTarget(id: String, target: MCPServerTarget, value: Bool) {
        guard let idx = skills.firstIndex(where: { $0.id == id }) else { return }
        var updated = skills[idx]
        updated.targets.setEnabled(value, for: target)
        if value && !updated.isSelected {
            updated.isSelected = true
        } else if !updated.targets.codex && !updated.targets.claude && !updated.targets.gemini {
            updated.isSelected = false
        }
        skills[idx] = updated
        Task { await persistAndApplyIfPossible() }
    }

    func updateSkillSelection(id: String, value: Bool) {
        guard let idx = skills.firstIndex(where: { $0.id == id }) else { return }
        skills[idx].isSelected = value
        if !value {
            skills[idx].targets.codex = false
            skills[idx].targets.claude = false
            skills[idx].targets.gemini = false
        } else {
            skills[idx].targets.codex = true
            skills[idx].targets.claude = true
            skills[idx].targets.gemini = true
        }
        Task { await persistAndApplyIfPossible() }
    }

    func persistSelections(projectId: String, directory: String?) async {
        self.projectId = projectId
        if let dir = directory?.trimmingCharacters(in: .whitespacesAndNewlines), !dir.isEmpty {
            self.projectDirectory = URL(fileURLWithPath: dir, isDirectory: true)
        }
        await persistAndApplyIfPossible()
    }

    // MARK: - Project Import
    func beginProjectMCPImport() {
        showMCPImportSheet = true
        Task { await loadProjectMCPCandidates() }
    }

    func beginProjectSkillsImport() {
        showSkillsImportSheet = true
        Task { await loadProjectSkillsCandidates() }
    }

    func loadProjectMCPCandidates() async {
        isImportingMCP = true
        mcpImportStatusMessage = "Scanning…"
        guard let projectDirectory else {
            mcpImportCandidates = []
            mcpImportStatusMessage = "Choose a project directory first."
            isImportingMCP = false
            return
        }
        if SecurityScopedBookmarks.shared.isSandboxed {
            AuthorizationHub.shared.ensureDirectoryAccessOrPrompt(
                directory: projectDirectory,
                purpose: .generalAccess,
                message: "Authorize project directory to import MCP servers"
            )
        }

        let existing = await mcpStore.list()
        let existingNames = Set(existing.map(\.name))
        let managedSignatures = Set(existing.map { MCPImportService.signature(for: $0) })

        let scanned = await Task.detached(priority: .userInitiated) {
            MCPImportService.scan(scope: .project(directory: projectDirectory))
        }.value

        // CodMate store is the source of truth; provider configs can drift if edited by other tools.
        let filtered = MCPImportService.filterManagedCandidates(scanned, managedSignatures: managedSignatures)
        let candidates = filtered.map { item -> MCPImportCandidate in
            var updated = item
            if existingNames.contains(item.name) {
                updated.hasConflict = true
                updated.isSelected = false
                updated.resolution = .skip
                updated.renameName = item.name
            }
            return updated
        }

        if candidates.isEmpty {
            mcpImportStatusMessage = "No MCP servers found."
        } else {
            mcpImportStatusMessage = nil
        }

        mcpImportCandidates = candidates
        isImportingMCP = false
    }

    func loadProjectSkillsCandidates() async {
        isImportingSkills = true
        skillsImportStatusMessage = "Scanning…"
        guard let projectDirectory else {
            skillsImportCandidates = []
            skillsImportStatusMessage = "Choose a project directory first."
            isImportingSkills = false
            return
        }
        if SecurityScopedBookmarks.shared.isSandboxed {
            AuthorizationHub.shared.ensureDirectoryAccessOrPrompt(
                directory: projectDirectory,
                purpose: .generalAccess,
                message: "Authorize project directory to import skills"
            )
        }

        let scanned = await Task.detached(priority: .userInitiated) {
            await SkillsImportService.scan(scope: .project(directory: projectDirectory))
        }.value
        let existing = await skillsStore.list()
        let managedIds = Set(existing.map(\.id))
        // CodMate store is the source of truth; provider directories can drift if edited by other tools.
        let filtered = scanned.filter { !managedIds.contains($0.id) }

        var candidates: [SkillImportCandidate] = []
        for item in filtered {
            var updated = item
            if let conflict = await skillsStore.conflictInfo(forProposedId: item.id) {
                updated.hasConflict = true
                updated.isSelected = false
                updated.resolution = .skip
                updated.renameId = conflict.suggestedId
                updated.suggestedId = conflict.suggestedId
                updated.conflictDetail = conflict.existingIsManaged
                    ? "Existing CodMate-managed skill"
                    : "Skill already exists"
            }
            candidates.append(updated)
        }

        skillsImportCandidates = candidates
        isImportingSkills = false
        skillsImportStatusMessage = candidates.isEmpty ? "No skills found." : nil
    }

    func cancelProjectMCPImport() {
        showMCPImportSheet = false
        mcpImportCandidates = []
        mcpImportStatusMessage = nil
    }

    func cancelProjectSkillsImport() {
        showSkillsImportSheet = false
        skillsImportCandidates = []
        skillsImportStatusMessage = nil
    }

    func importProjectMCPSelections() async {
        let selected = mcpImportCandidates.filter { $0.isSelected }
        guard !selected.isEmpty else {
            mcpImportStatusMessage = "No servers selected."
            return
        }

        let resolvedNames = selected.compactMap { item -> String? in
            let resolution = item.resolution
            switch resolution {
            case .skip:
                return nil
            case .overwrite:
                return item.name
            case .rename:
                let trimmed = item.renameName.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        }
        let duplicates = Dictionary(grouping: resolvedNames, by: { $0 }).filter { $1.count > 1 }.keys
        if !duplicates.isEmpty {
            mcpImportStatusMessage = "Resolve duplicate names before importing."
            return
        }

        if SecurityScopedBookmarks.shared.isSandboxed {
            let home = SessionPreferencesStore.getRealUserHomeURL()
            let codmate = home.appendingPathComponent(".codmate", isDirectory: true)
            let codex = home.appendingPathComponent(".codex", isDirectory: true)
            _ = AuthorizationHub.shared.ensureDirectoryAccessOrPromptSync(directory: codmate, purpose: .generalAccess, message: "Authorize ~/.codmate to save MCP servers")
            _ = AuthorizationHub.shared.ensureDirectoryAccessOrPromptSync(directory: codex, purpose: .generalAccess, message: "Authorize ~/.codex to update Codex config")
            _ = AuthorizationHub.shared.ensureDirectoryAccessOrPromptSync(directory: home, purpose: .generalAccess, message: "Authorize your Home folder to update Claude config")
        }

        var incoming: [MCPServer] = []
        var importedCandidateIds: Set<UUID> = []
        for item in selected {
            let resolution = item.resolution
            switch resolution {
            case .skip:
                continue
            case .overwrite, .rename:
                let finalName = (resolution == .rename ? item.renameName : item.name)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !finalName.isEmpty else { continue }
                let meta = MCPServerMeta(description: item.description, version: nil, websiteUrl: nil, repositoryURL: nil)
                let server = MCPServer(
                    name: finalName,
                    kind: item.kind,
                    command: item.command,
                    args: item.args,
                    env: item.env,
                    url: item.url,
                    headers: item.headers,
                    meta: meta,
                    enabled: true,
                    capabilities: [],
                    targets: MCPServerTargets()
                )
                incoming.append(server)
                importedCandidateIds.insert(item.id)
            }
        }

        do {
            try await mcpStore.upsertMany(incoming)
            await load(projectId: projectId, projectDirectory: projectDirectory?.path ?? "")
            let importedNames = Set(incoming.map(\.name))
            for idx in mcpSelections.indices where importedNames.contains(mcpSelections[idx].id) {
                mcpSelections[idx].isSelected = true
            }
            await persistAndApplyIfPossible()
            mcpImportStatusMessage = "Imported \(incoming.count) server(s)."
            if !importedCandidateIds.isEmpty {
                mcpImportCandidates.removeAll { importedCandidateIds.contains($0.id) }
            }
            if mcpImportCandidates.isEmpty {
                closeMCPImportSheetAfterDelay()
            }
        } catch {
            mcpImportStatusMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    func importProjectSkillsSelections() async {
        let selected = skillsImportCandidates.filter { $0.isSelected }
        guard !selected.isEmpty else {
            skillsImportStatusMessage = "No skills selected."
            return
        }

        if SecurityScopedBookmarks.shared.isSandboxed {
            let home = SessionPreferencesStore.getRealUserHomeURL()
            let codmate = home.appendingPathComponent(".codmate", isDirectory: true)
            AuthorizationHub.shared.ensureDirectoryAccessOrPrompt(
                directory: codmate,
                purpose: .generalAccess,
                message: "Authorize ~/.codmate to import skills"
            )
        }

        var importedIds: [String] = []
        var importedCandidateIds: Set<String> = []
        var importedCandidates: [SkillImportCandidate] = []
        for item in selected {
            let resolution = item.hasConflict ? item.resolution : .overwrite
            switch resolution {
            case .skip:
                continue
            case .overwrite:
                let req = SkillInstallRequest(mode: .folder, url: URL(fileURLWithPath: item.sourcePath), text: nil)
                let outcome = await skillsStore.install(request: req, resolution: .overwrite)
                if case .installed(let record) = outcome {
                    await skillsStore.markImported(id: record.id)
                    importedIds.append(record.id)
                    importedCandidateIds.insert(item.id)
                    importedCandidates.append(item)
                }
            case .rename:
                let newId = item.renameId.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !newId.isEmpty else { continue }
                let req = SkillInstallRequest(mode: .folder, url: URL(fileURLWithPath: item.sourcePath), text: nil)
                let outcome = await skillsStore.install(request: req, resolution: .rename(newId))
                if case .installed(let record) = outcome {
                    await skillsStore.markImported(id: record.id)
                    importedIds.append(record.id)
                    importedCandidateIds.insert(item.id)
                    importedCandidates.append(item)
                }
            }
        }

        if let projectDirectory, !importedCandidates.isEmpty {
            removeImportedProjectProviderCopies(importedCandidates, projectDirectory: projectDirectory)
        }
        await load(projectId: projectId, projectDirectory: projectDirectory?.path ?? "")
        let importedSet = Set(importedIds)
        for idx in skills.indices where importedSet.contains(skills[idx].id) {
            skills[idx].isSelected = true
        }
        await persistAndApplyIfPossible()
        skillsImportStatusMessage = "Imported \(importedIds.count) skill(s)."
        if !importedCandidateIds.isEmpty {
            skillsImportCandidates.removeAll { importedCandidateIds.contains($0.id) }
        }
        if skillsImportCandidates.isEmpty {
            closeSkillsImportSheetAfterDelay()
        }
    }

    private func closeMCPImportSheetAfterDelay(_ delay: TimeInterval = 0.6) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self.showMCPImportSheet = false
            self.mcpImportStatusMessage = nil
        }
    }

    private func closeSkillsImportSheetAfterDelay(_ delay: TimeInterval = 0.6) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self.showSkillsImportSheet = false
            self.skillsImportStatusMessage = nil
        }
    }

    private func removeImportedProjectProviderCopies(
        _ items: [SkillImportCandidate],
        projectDirectory: URL
    ) {
        let providerRoots: [String: URL] = [
            "Codex": projectDirectory.appendingPathComponent(".codex", isDirectory: true)
                .appendingPathComponent("skills", isDirectory: true),
            "Claude": projectDirectory.appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("skills", isDirectory: true),
            "Gemini": projectDirectory.appendingPathComponent(".gemini", isDirectory: true)
                .appendingPathComponent("skills", isDirectory: true)
        ]
        let fm = FileManager.default
        for item in items {
            if item.sourcePaths.isEmpty {
                for source in item.sources {
                    guard let root = providerRoots[source] else { continue }
                    let dir = URL(fileURLWithPath: item.sourcePath, isDirectory: true)
                    if dir.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path) {
                        try? fm.removeItem(at: dir)
                    }
                }
                continue
            }
            for (source, path) in item.sourcePaths {
                guard let root = providerRoots[source] else { continue }
                let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
                if dir.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path) {
                    try? fm.removeItem(at: dir)
                }
            }
        }
    }

    private func persistAndApplyIfPossible() async {
        guard let projectId else { return }

        let config = ProjectExtensionsConfig(
            projectId: projectId,
            mcpServers: mcpSelections.map { entry in
                ProjectMCPConfig(id: entry.id, isSelected: entry.isSelected, targets: entry.targets)
            },
            skills: skills.map { skill in
                ProjectSkillConfig(id: skill.id, isSelected: skill.isSelected, targets: skill.targets)
            },
            updatedAt: Date()
        )
        await extensionsStore.save(config)

        guard let projectDirectory,
              FileManager.default.fileExists(atPath: projectDirectory.path)
        else { return }
        AuthorizationHub.shared.ensureDirectoryAccessOrPrompt(
            directory: projectDirectory,
            purpose: .generalAccess,
            message: "Authorize project directory to update Extensions"
        )
        let selections = skills.map { skill in
            SkillsSyncService.SkillSelection(id: skill.id, isSelected: skill.isSelected, targets: skill.targets)
        }
        await applier.apply(
            projectDirectory: projectDirectory,
            mcpSelections: mcpSelections,
            skillRecords: skillRecords,
            skillSelections: selections
        )
    }
}

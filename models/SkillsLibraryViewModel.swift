import Foundation
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

struct SkillSummary: Identifiable, Hashable {
    let id: String
    var name: String
    var description: String
    var summary: String
    var tags: [String]
    var source: String
    var path: String?
    var isSelected: Bool
    var targets: MCPServerTargets
    var sourceType: String?

    var displayName: String { name.isEmpty ? id : name }
    var isTemplateCreated: Bool { sourceType == "template" }
}

@MainActor
final class SkillsLibraryViewModel: ObservableObject {
    private let store = SkillsStore()
    private let syncer = SkillsSyncService()

    @Published var skills: [SkillSummary] = []
    @Published var selectedSkillId: String?
    @Published var searchText: String = ""
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var installStatusMessage: String?

    @Published var showInstallSheet: Bool = false
    @Published var installMode: SkillInstallMode = .folder
    @Published var pendingInstallURL: URL?
    @Published var pendingInstallText: String = ""
    @Published var installConflict: SkillInstallConflict?

    @Published var showCreateSheet: Bool = false
    @Published var newSkillName: String = ""
    @Published var newSkillDescription: String = ""
    @Published var createErrorMessage: String?
    @Published var pendingWizardDraft: SkillWizardDraft? = nil
    @Published var createStartsWithWizard: Bool = false
    @Published var wizardPreviewSkill: SkillSummary? = nil

    private var wizardPreviewURL: URL? = nil
    @Published var showImportSheet: Bool = false
    @Published var importCandidates: [SkillImportCandidate] = []
    @Published var isImporting: Bool = false
    @Published var importStatusMessage: String?

    var filteredSkills: [SkillSummary] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return skills }
        return skills.filter { skill in
            let hay = [skill.displayName, skill.summary, skill.tags.joined(separator: " "), skill.source]
                .joined(separator: " ")
                .lowercased()
            return hay.contains(trimmed.lowercased())
        }
    }

    var selectedSkill: SkillSummary? {
        guard let id = selectedSkillId else { return nil }
        return skills.first(where: { $0.id == id })
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        let records = await store.list()
        skills = await withTaskGroup(of: (Int, SkillSummary).self) { group in
            for (index, record) in records.enumerated() {
                group.addTask {
                    let sourceType = await self.store.getSourceType(
                        at: URL(fileURLWithPath: record.path)
                    )
                    return (index, SkillSummary(
                        id: record.id,
                        name: record.name,
                        description: record.description,
                        summary: record.summary,
                        tags: record.tags,
                        source: record.source,
                        path: record.path,
                        isSelected: record.isEnabled,
                        targets: record.targets,
                        sourceType: sourceType
                    ))
                }
            }
            var results: [(Int, SkillSummary)] = []
            for await result in group {
                results.append(result)
            }
            return results.sorted(by: { $0.0 < $1.0 }).map { $0.1 }
        }
        if selectedSkillId == nil || !skills.contains(where: { $0.id == selectedSkillId }) {
            selectedSkillId = skills.first?.id
        }
    }

    // MARK: - Import (Home)
    func beginImportFromHome() {
        showImportSheet = true
        Task { await loadImportCandidatesFromHome() }
    }

    func loadImportCandidatesFromHome() async {
        isImporting = true
        importStatusMessage = "Scanning…"
        if SecurityScopedBookmarks.shared.isSandboxed {
            let home = SessionPreferencesStore.getRealUserHomeURL()
            AuthorizationHub.shared.ensureDirectoryAccessOrPrompt(
                directory: home,
                purpose: .generalAccess,
                message: "Authorize your Home folder to import skills"
            )
        }

        let scanned = await Task.detached(priority: .userInitiated) {
            await SkillsImportService.scan(scope: .home)
        }.value
        let existing = await store.list()
        let managedIds = Set(existing.map(\.id))
        // CodMate store is the source of truth; provider directories can drift if edited by other tools.
        let filtered = scanned.filter { !managedIds.contains($0.id) }

        var candidates: [SkillImportCandidate] = []
        for item in filtered {
            var updated = item
            if let conflict = await store.conflictInfo(forProposedId: item.id) {
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

        importCandidates = candidates
        isImporting = false
        importStatusMessage = candidates.isEmpty ? "No skills found." : nil
    }

    func cancelImport() {
        showImportSheet = false
        importCandidates = []
        importStatusMessage = nil
    }

    func importSelectedSkills() async {
        let selected = importCandidates.filter { $0.isSelected }
        guard !selected.isEmpty else {
            importStatusMessage = "No skills selected."
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

        var importedCount = 0
        var importedCandidateIds: Set<String> = []
        var importedCandidates: [SkillImportCandidate] = []
        for item in selected {
            let resolution = item.hasConflict ? item.resolution : .overwrite
            switch resolution {
            case .skip:
                continue
            case .overwrite:
                let req = SkillInstallRequest(mode: .folder, url: URL(fileURLWithPath: item.sourcePath), text: nil)
                let outcome = await store.install(request: req, resolution: .overwrite)
                if case .installed(let record) = outcome {
                    await store.markImported(id: record.id)
                    importedCount += 1
                    importedCandidateIds.insert(item.id)
                    importedCandidates.append(item)
                }
            case .rename:
                let newId = item.renameId.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !newId.isEmpty else { continue }
                let req = SkillInstallRequest(mode: .folder, url: URL(fileURLWithPath: item.sourcePath), text: nil)
                let outcome = await store.install(request: req, resolution: .rename(newId))
                if case .installed(let record) = outcome {
                    await store.markImported(id: record.id)
                    importedCount += 1
                    importedCandidateIds.insert(item.id)
                    importedCandidates.append(item)
                }
            }
        }

        if !importedCandidates.isEmpty {
            removeImportedProviderCopies(importedCandidates)
        }
        await load()
        await persistAndSync()
        importStatusMessage = "Imported \(importedCount) skill(s)."
        if !importedCandidateIds.isEmpty {
            importCandidates.removeAll { importedCandidateIds.contains($0.id) }
        }
        if importCandidates.isEmpty {
            closeImportSheetAfterDelay()
        }
    }

    private func closeImportSheetAfterDelay(_ delay: TimeInterval = 0.6) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self.showImportSheet = false
            self.importStatusMessage = nil
        }
    }

    private func removeImportedProviderCopies(_ items: [SkillImportCandidate]) {
        let home = SessionPreferencesStore.getRealUserHomeURL()
        let providerRoots: [String: URL] = [
            "Codex": home.appendingPathComponent(".codex", isDirectory: true)
                .appendingPathComponent("skills", isDirectory: true),
            "Claude": home.appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("skills", isDirectory: true)
        ]
        if SecurityScopedBookmarks.shared.isSandboxed {
            AuthorizationHub.shared.ensureDirectoryAccessOrPrompt(
                directory: home.appendingPathComponent(".codex", isDirectory: true),
                purpose: .generalAccess,
                message: "Authorize ~/.codex to adopt imported skills"
            )
            AuthorizationHub.shared.ensureDirectoryAccessOrPrompt(
                directory: home.appendingPathComponent(".claude", isDirectory: true),
                purpose: .generalAccess,
                message: "Authorize ~/.claude to adopt imported skills"
            )
        }

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

    func prepareInstall(mode: SkillInstallMode, url: URL? = nil, text: String? = nil) {
        installMode = mode
        pendingInstallURL = url
        pendingInstallText = text ?? ""
        installStatusMessage = nil
        installConflict = nil
        showInstallSheet = true
    }

    func cancelInstall() {
        showInstallSheet = false
        pendingInstallURL = nil
        pendingInstallText = ""
        installStatusMessage = nil
    }

    func testInstall() {
        installStatusMessage = "Validating…"
        Task {
            let request = installRequest()
            let ok = await store.validate(request: request)
            await MainActor.run {
                installStatusMessage = ok ? "Looks good. Ready to install." : "Unable to validate this source."
            }
        }
    }

    func finishInstall() {
        installStatusMessage = "Installing…"
        Task {
            let request = installRequest()
            let outcome = await store.install(request: request, resolution: nil)
            await MainActor.run {
                handleInstallOutcome(outcome)
            }
        }
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
        Task { await persistAndSync() }
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
        Task { await persistAndSync() }
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil)
                else { return }
                Task { @MainActor in
                    let isZip = url.pathExtension.lowercased() == "zip"
                    self.prepareInstall(mode: isZip ? .zip : .folder, url: url)
                }
            }
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    Task { @MainActor in
                        self.prepareInstall(mode: .url, text: url.absoluteString)
                    }
                }
            }
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                let text: String?
                if let data = item as? Data {
                    text = String(data: data, encoding: .utf8)
                } else {
                    text = item as? String
                }
                guard let text, !text.isEmpty else { return }
                Task { @MainActor in
                    self.prepareInstall(mode: .url, text: text)
                }
            }
            return true
        }
        return false
    }

    func resolveInstallConflict(_ resolution: SkillConflictResolution) {
        installStatusMessage = "Installing…"
        Task {
            let request = installRequest()
            let outcome = await store.install(request: request, resolution: resolution)
            await MainActor.run {
                handleInstallOutcome(outcome)
            }
        }
    }

    func uninstall(id: String) {
        Task {
            await store.uninstall(id: id)
            await load()
            await persistAndSync()
        }
    }

    func prepareCreateSkill(startWithWizard: Bool = false) {
        createStartsWithWizard = startWithWizard
        newSkillName = ""
        newSkillDescription = ""
        createErrorMessage = nil
        pendingWizardDraft = nil
        clearWizardPreview()
        showCreateSheet = true
    }

    func cancelCreateSkill() {
        showCreateSheet = false
        newSkillName = ""
        newSkillDescription = ""
        createErrorMessage = nil
        pendingWizardDraft = nil
        createStartsWithWizard = false
        clearWizardPreview()
    }

    func createSkill() {
        createErrorMessage = nil
        Task {
            do {
                guard var draft = pendingWizardDraft else {
                    await MainActor.run {
                        createErrorMessage = "Use the wizard to create a skill."
                    }
                    return
                }
                let trimmedName = newSkillName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedName.isEmpty {
                    draft.id = trimmedName
                    draft.name = trimmedName
                }
                let trimmedDesc = newSkillDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedDesc.isEmpty {
                    draft.description = trimmedDesc
                }
                let record = try await store.createFromWizard(draft: draft, enabled: false)
                await MainActor.run {
                    showCreateSheet = false
                    newSkillName = ""
                    newSkillDescription = ""
                    pendingWizardDraft = nil
                    createStartsWithWizard = false
                    clearWizardPreview()
                }
                await load()
                await MainActor.run {
                    selectedSkillId = record.id
                }
                await persistAndSync()
            } catch let error as SkillCreationError {
                await MainActor.run {
                    createErrorMessage = error.localizedDescription
                }
            } catch {
                await MainActor.run {
                    createErrorMessage = "Failed to create skill: \(error.localizedDescription)"
                }
            }
        }
    }

    func applyWizardDraft(_ draft: SkillWizardDraft) {
        pendingWizardDraft = draft
        newSkillName = draft.id.isEmpty ? draft.name : draft.id
        newSkillDescription = draft.description
        createErrorMessage = nil
        refreshWizardPreview()
    }

    func refreshWizardPreview() {
        guard var draft = pendingWizardDraft else {
            clearWizardPreview()
            return
        }
        let trimmedName = newSkillName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            draft.id = trimmedName
            draft.name = trimmedName
        }
        let trimmedDesc = newSkillDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDesc.isEmpty {
            draft.description = trimmedDesc
        }

        let previewDir: URL
        if let existing = wizardPreviewURL {
            previewDir = existing
        } else {
            let previewId = "wizard-preview-\(UUID().uuidString)"
            previewDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(previewId, isDirectory: true)
            wizardPreviewURL = previewDir
        }
        let previewId = "wizard-preview-\(UUID().uuidString)"
        do {
            try FileManager.default.createDirectory(at: previewDir, withIntermediateDirectories: true)
            let markdown = store.generateSkillMarkdownFromDraft(draft, id: previewId)
            let skillFile = previewDir.appendingPathComponent("SKILL.md", isDirectory: false)
            try markdown.write(to: skillFile, atomically: true, encoding: .utf8)

            let summary = draft.summary?.isEmpty == false ? draft.summary! : draft.description
            let targets = draft.targets ?? MCPServerTargets(codex: true, claude: true, gemini: false)
            wizardPreviewSkill = SkillSummary(
                id: previewId,
                name: draft.name,
                description: draft.description,
                summary: summary,
                tags: draft.tags,
                source: "Wizard Preview",
                path: previewDir.path,
                isSelected: false,
                targets: targets,
                sourceType: "preview"
            )
        } catch {
            wizardPreviewSkill = nil
        }
    }

    private func clearWizardPreview() {
        if let url = wizardPreviewURL {
            try? FileManager.default.removeItem(at: url)
        }
        wizardPreviewURL = nil
        wizardPreviewSkill = nil
    }

    func openInEditor(_ skill: SkillSummary, using editor: EditorApp) {
        guard let path = skill.path, !path.isEmpty else {
            errorMessage = "Skill path not available"
            return
        }

        let dirURL = URL(fileURLWithPath: path)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            errorMessage = "Skill directory does not exist: \(path)"
            return
        }

        if let executablePath = findExecutableInPath(editor.cliCommand) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = [path]
            process.standardOutput = Pipe()
            process.standardError = Pipe()

            do {
                try process.run()
                return
            } catch {
            }
        }

        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.bundleIdentifier) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true

            NSWorkspace.shared.open(
                [dirURL],
                withApplicationAt: appURL,
                configuration: config
            ) { _, error in
                if let error = error {
                    DispatchQueue.main.async {
                        self.errorMessage = "Failed to open \(editor.title): \(error.localizedDescription)"
                    }
                }
            }
            return
        }

        errorMessage = "\(editor.title) is not installed. Please install it or try a different editor."
    }

    private func findExecutableInPath(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else { return nil }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return path?.isEmpty == false ? path : nil
        } catch {
            return nil
        }
    }

    private func installRequest() -> SkillInstallRequest {
        SkillInstallRequest(mode: installMode, url: pendingInstallURL, text: pendingInstallText)
    }

    private func handleInstallOutcome(_ outcome: SkillInstallOutcome) {
        switch outcome {
        case .installed:
            installStatusMessage = "Installed."
            showInstallSheet = false
            pendingInstallURL = nil
            pendingInstallText = ""
            Task { await reloadAfterInstall() }
        case .conflict(let conflict):
            installStatusMessage = "Skill already exists."
            installConflict = conflict
        case .skipped:
            installStatusMessage = "Install skipped."
        }
    }

    private func reloadAfterInstall() async {
        await load()
        await persistAndSync()
    }

    private func persistAndSync() async {
        var records = await store.list()
        for idx in records.indices {
            if let summary = skills.first(where: { $0.id == records[idx].id }) {
                records[idx].name = summary.name
                records[idx].description = summary.description
                records[idx].summary = summary.summary
                records[idx].tags = summary.tags
                records[idx].source = summary.source
                if let path = summary.path { records[idx].path = path }
                records[idx].isEnabled = summary.isSelected
                records[idx].targets = summary.targets
            }
        }
        await store.saveAll(records)
        let home = SessionPreferencesStore.getRealUserHomeURL()
        AuthorizationHub.shared.ensureDirectoryAccessOrPrompt(
            directory: home.appendingPathComponent(".codex", isDirectory: true),
            purpose: .generalAccess,
            message: "Authorize ~/.codex to sync Codex skills"
        )
        AuthorizationHub.shared.ensureDirectoryAccessOrPrompt(
            directory: home.appendingPathComponent(".claude", isDirectory: true),
            purpose: .generalAccess,
            message: "Authorize ~/.claude to sync Claude skills"
        )
        let warnings = await syncer.syncGlobal(skills: records)
        if let warning = warnings.first {
            errorMessage = warning.message
        } else {
            errorMessage = nil
        }
    }
}

import AppKit
import OSLog
import Foundation

@MainActor
final class GitChangesViewModel: ObservableObject {
    private static let log = Logger(subsystem: "ai.codmate.app", category: "AICommit")
    @Published private(set) var repoRoot: URL? = nil
    @Published private(set) var changes: [GitService.Change] = []
    @Published var selectedPath: String? = nil
    enum CompareSide: Equatable { case unstaged, staged }
    @Published var selectedSide: CompareSide = .unstaged
    @Published var showPreviewInsteadOfDiff: Bool = false
    @Published var diffText: String = ""  // or file preview text when in preview mode
    @Published var isLoading = false
    @Published var errorMessage: String? = nil
    @Published var commitMessage: String = ""
    @Published var isGenerating: Bool = false
    @Published private(set) var generatingRepoPath: String? = nil
    @Published private(set) var isResolvingRepo: Bool = true
    @Published private(set) var treeSnapshot: GitReviewTreeSnapshot = .empty

    private let service = GitService()
    private var monitorWorktree: DirectoryMonitor?
    private var monitorIndex: DirectoryMonitor?
    private var refreshTask: Task<Void, Never>? = nil
    private var repo: GitService.Repo? = nil
    private var generatingTask: Task<Void, Never>? = nil
    private var treeBuildTask: Task<Void, Never>? = nil
    private var diffTask: Task<Void, Never>? = nil
    private var treeSnapshotGeneration: UInt64 = 0
    private var explorerFallbackRoot: URL? = nil

    func attach(to directory: URL, fallbackProjectDirectory: URL? = nil) {
        isResolvingRepo = true
        explorerFallbackRoot = fallbackProjectDirectory ?? directory
        Task { [weak self] in
            guard let self else { return }
            defer { self.isResolvingRepo = false }
            await self.resolveRepoRoot(from: directory, fallbackProjectDirectory: fallbackProjectDirectory)
            await self.refreshStatus()
            self.configureMonitors()
        }
    }

    func detach() {
        monitorWorktree?.cancel(); monitorWorktree = nil
        monitorIndex?.cancel(); monitorIndex = nil
        treeBuildTask?.cancel(); treeBuildTask = nil
        diffTask?.cancel(); diffTask = nil
        repo = nil
        repoRoot = nil
        explorerFallbackRoot = nil
        changes = []
        selectedPath = nil
        diffText = ""
        isResolvingRepo = false
        treeSnapshot = .empty
    }

    private func resolveRepoRoot(from directory: URL, fallbackProjectDirectory: URL?) async {
        let canonical = directory
        if let repo = await service.repositoryRoot(for: canonical) {
            assignRepoRoot(to: repo.root, reason: "git-cli (session)")
            return
        }
        if let fsRoot = filesystemGitRoot(startingAt: canonical) {
            assignRepoRoot(to: fsRoot, reason: "filesystem (session)")
            return
        }
        if let fallback = fallbackProjectDirectory {
            if let repo = await service.repositoryRoot(for: fallback) {
                assignRepoRoot(to: repo.root, reason: "git-cli (project)")
                return
            }
            if hasGitDirectory(at: fallback) {
                assignRepoRoot(to: fallback.standardizedFileURL, reason: "project directory")
                return
            }
        }
        Self.log.warning("No Git repository found starting from \(directory.path, privacy: .public)")
        self.repo = nil
        self.repoRoot = nil
        errorMessage = "No Git repository found"
    }

    private func assignRepoRoot(to root: URL, reason: String) {
        if SecurityScopedBookmarks.shared.isSandboxed {
            let hasBookmark = SecurityScopedBookmarks.shared.hasDynamicBookmark(for: root)
            #if DEBUG
            Self.log.info("Repository at \(root.path, privacy: .public) has bookmark: \(hasBookmark, privacy: .public)")
            #endif

            let hasAccess = SecurityScopedBookmarks.shared.startAccessDynamic(for: root)
            #if DEBUG
            Self.log.info("Started access for \(root.path, privacy: .public): \(hasAccess, privacy: .public)")
            #endif

            if !hasAccess {
                Self.log.error("Failed to start access for repository at \(root.path, privacy: .public)")
                if hasBookmark {
                    errorMessage = "Repository access failed. The bookmark may be stale. Please re-authorize."
                } else {
                    errorMessage = "Repository access required. Please authorize the repository folder: \(root.path)"
                }
            }
        }
        self.repo = GitService.Repo(root: root)
        self.repoRoot = root
        #if DEBUG
        Self.log.info("Git repository resolved via \(reason, privacy: .public): \(root.path, privacy: .public)")
        #endif
    }

    private func filesystemGitRoot(startingAt start: URL) -> URL? {
        var cur = start.standardizedFileURL
        var guardCounter = 0
        while guardCounter < 200 {
            if hasGitDirectory(at: cur) { return cur }
            let parent = cur.deletingLastPathComponent()
            if parent.path == cur.path { break }
            cur = parent
            guardCounter += 1
        }
        return nil
    }

    private func hasGitDirectory(at url: URL) -> Bool {
        let gitDir = url.appendingPathComponent(".git", isDirectory: true)
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: gitDir.path, isDirectory: &isDir) && isDir.boolValue
    }

    private func configureMonitors() {
        guard let root = repoRoot else { return }
        // Monitor the worktree directory (non-recursive; still good enough to get write pulses)
        monitorWorktree?.cancel()
        monitorWorktree = DirectoryMonitor(url: root) { [weak self] in self?.scheduleRefresh() }
        // Monitor .git/index changes (staging updates)
        let indexURL = root.appendingPathComponent(".git/index")
        monitorIndex?.cancel()
        monitorIndex = DirectoryMonitor(url: indexURL) { [weak self] in self?.scheduleRefresh() }
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
            await self.refreshStatus()
        }
    }

    private func scheduleTreeSnapshotRefresh() {
        treeBuildTask?.cancel()
        treeSnapshotGeneration &+= 1
        let generation = treeSnapshotGeneration
        let snapshotInput = self.changes
        treeBuildTask = Task { [weak self] in
            guard let self else { return }
            let built = await Task.detached(priority: .userInitiated) {
                GitReviewTreeBuilder.buildSnapshot(from: snapshotInput)
            }.value
            guard !Task.isCancelled else { return }
            if self.treeSnapshotGeneration == generation {
                self.treeSnapshot = built
            }
        }
    }

    func refreshStatus() async {
        guard let repo = self.repo else {
            changes = []; selectedPath = nil; diffText = ""; return
        }

        // Ensure we have access before executing git commands
        if SecurityScopedBookmarks.shared.isSandboxed {
            let hasAccess = SecurityScopedBookmarks.shared.startAccessDynamic(for: repo.root)
            if !hasAccess {
                Self.log.error("Failed to start access for repository at \(repo.root.path, privacy: .public)")
                errorMessage = "Repository access required. Please authorize the repository folder."
                changes = []
                return
            }
        }

        isLoading = true
        errorMessage = nil // Clear previous errors
        let list = await service.status(in: repo)
        isLoading = false

        if list.isEmpty {
            if let failure = await service.takeLastFailureDescription() {
                errorMessage = Self.describeGitFailure(failure)
            }
        } else {
            _ = await service.takeLastFailureDescription()
        }

        if list.isEmpty && SecurityScopedBookmarks.shared.isSandboxed {
            // Verify git can actually access the repository
            Self.log.warning("Git status returned empty for \(repo.root.path, privacy: .public)")
        }

        changes = list
        scheduleTreeSnapshotRefresh()
        // Maintain selection when possible
        if let sel = selectedPath, !list.contains(where: { $0.path == sel }) {
            selectedPath = nil
            diffText = ""
        }
        await refreshDetail()
    }

    func refreshDetail() async {
        diffTask?.cancel()
        guard let path = selectedPath else { diffText = ""; return }
        let currentRepo = self.repo

        if currentRepo == nil, showPreviewInsteadOfDiff, let base = repoRoot ?? explorerFallbackRoot {
            let url = base.appendingPathComponent(path)
            if let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) {
                diffText = text
            } else {
                diffText = "(Preview unavailable)"
            }
            return
        }
        guard let repo = currentRepo else { diffText = ""; return }

        // Ensure access before reading files
        if SecurityScopedBookmarks.shared.isSandboxed {
            _ = SecurityScopedBookmarks.shared.startAccessDynamic(for: repo.root)
        }

        let showPreview = showPreviewInsteadOfDiff
        let selectedSide = self.selectedSide
        let changesSnapshot = self.changes
        let service = self.service

        diffTask = Task { [weak self] in
            guard let self else { return }
            let text = await Task.detached(priority: .userInitiated) {
                await Self.computeDiffText(
                    service: service,
                    repo: repo,
                    path: path,
                    showPreview: showPreview,
                    selectedSide: selectedSide,
                    changes: changesSnapshot
                )
            }.value
            guard !Task.isCancelled else { return }
            if self.selectedPath == path,
               self.selectedSide == selectedSide,
               self.showPreviewInsteadOfDiff == showPreview {
                self.diffText = text
            }
        }
    }

    private static func computeDiffText(
        service: GitService,
        repo: GitService.Repo,
        path: String,
        showPreview: Bool,
        selectedSide: CompareSide,
        changes: [GitService.Change]
    ) async -> String {
        if showPreview {
            return await service.readFile(in: repo, path: path)
        }

        let isStagedSide = (selectedSide == .staged)
        var text = await service.diff(in: repo, path: path, staged: isStagedSide)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if isStagedSide {
                text = await service.diff(in: repo, path: path, staged: false)
            }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let kind = changes.first(where: { $0.path == path })?.worktree,
               kind == .untracked {
                let content = await service.readFile(in: repo, path: path)
                text = syntheticDiff(forPath: path, content: content)
            }
        }
        return text
    }

    private static func syntheticDiff(forPath path: String, content: String) -> String {
        // Produce a minimal unified diff for a new (untracked) file vs /dev/null
        let lines = content.split(separator: "\\n", omittingEmptySubsequences: false)
        let count = lines.count
        var out: [String] = []
        out.append("--- /dev/null")
        out.append("+++ b/\(path)")
        out.append("@@ -0,0 +\(count) @@")
        for l in lines { out.append("+" + String(l)) }
        return out.joined(separator: "\\n")
    }

    private static func describeGitFailure(_ raw: String) -> String {
        let message = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty {
            return "The git command failed without returning an error message."
        }
        if message.contains("App Sandbox") || message.contains("xcrun: error") {
            return "The built-in git relies on xcrun and was denied in the App Sandbox. Install Xcode Command Line Tools (xcode-select --install) or provide an accessible git executable."
        }
        if message.contains("not a git repository") {
            return "The current directory is not a Git repository."
        }
        return message
    }


    func toggleStage(for paths: [String]) async {
        guard let repo = self.repo else { return }
        // Determine which ones are staged
        let staged: Set<String> = Set(changes.compactMap { ($0.staged != nil) ? $0.path : nil })
        let toUnstage = paths.filter { staged.contains($0) }
        let toStage = paths.filter { !staged.contains($0) }
        if !toStage.isEmpty { await service.stage(in: repo, paths: toStage) }
        if !toUnstage.isEmpty { await service.unstage(in: repo, paths: toUnstage) }
        await refreshStatus()
    }

    // Explicit stage only
    func stage(paths: [String]) async {
        guard let repo = self.repo, !paths.isEmpty else { return }
        await service.stage(in: repo, paths: paths)
        await refreshStatus()
    }

    // Explicit unstage only
    func unstage(paths: [String]) async {
        guard let repo = self.repo, !paths.isEmpty else { return }
        await service.unstage(in: repo, paths: paths)
        await refreshStatus()
    }

    // Folder action: stage remaining if not all staged, otherwise unstage all
    func applyFolderStaging(for dirKey: String, paths: [String]) async {
        guard !paths.isEmpty else { return }
        let stagedSet: Set<String> = Set(changes.compactMap { ($0.staged != nil) ? $0.path : nil })
        let allStaged = paths.allSatisfy { stagedSet.contains($0) }
        if allStaged {
            await unstage(paths: paths)
        } else {
            let toStage = paths.filter { !stagedSet.contains($0) }
            await stage(paths: toStage)
        }
    }

    func commit() async {
        guard let repo = self.repo else { return }
        let code = await service.commit(in: repo, message: commitMessage)
        if code == 0 {
            commitMessage = ""
            await refreshStatus()
        } else {
            errorMessage = "Commit failed (exit code \(code))"
        }
    }

    // MARK: - Discard
    // includeStaged=false matches VS Code Git Graph semantics:
    // only discard unstaged/worktree changes, preserving any staged changes.
    func discard(paths: [String], includeStaged: Bool = false) async {
        guard let repo = self.repo else { return }
        let pathSet = Set(paths)
        let map: [String: GitService.Change] = Dictionary(uniqueKeysWithValues: changes.map { ($0.path, $0) })

        var untracked: [String] = []
        var trackedWorktreeOnly: [String] = []
        var trackedFullReset: [String] = []

        for p in pathSet {
            guard let change = map[p] else { continue }
            if change.worktree == .untracked {
                untracked.append(p)
                continue
            }
            // Tracked file
            if includeStaged {
                // Discard both staged and unstaged changes
                if change.staged != nil || change.worktree != nil {
                    trackedFullReset.append(p)
                }
            } else {
                // Discard only unstaged/worktree changes, keep any staged state
                if change.worktree != nil {
                    trackedWorktreeOnly.append(p)
                }
            }
        }

        if includeStaged {
            if !trackedFullReset.isEmpty {
                _ = await service.discardTracked(in: repo, paths: trackedFullReset)
            }
        } else {
            if !trackedWorktreeOnly.isEmpty {
                _ = await service.discardWorktree(in: repo, paths: trackedWorktreeOnly)
            }
        }

        if !untracked.isEmpty {
            _ = await service.cleanUntracked(in: repo, paths: untracked)
        }
        await refreshStatus()
    }

    // MARK: - Open in external editor (file)
    func openFile(_ path: String, using editor: EditorApp) {
        guard let root = repoRoot ?? explorerFallbackRoot else { return }
        let filePath = root.appendingPathComponent(path).path
        // Try CLI command first
        if let exe = Self.findExecutableInPath(editor.cliCommand) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = [filePath]
            p.standardOutput = Pipe(); p.standardError = Pipe()
            do {
                try p.run(); return
            } catch {
                // fall through
            }
        }
        // Fallback: open via bundle id
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.bundleIdentifier) {
            let config = NSWorkspace.OpenConfiguration(); config.activates = true
            NSWorkspace.shared.open([URL(fileURLWithPath: filePath)], withApplicationAt: appURL, configuration: config) { _, err in
                if let err {
                    Task { @MainActor in self.errorMessage = "Failed to open \(editor.title): \(err.localizedDescription)" }
                }
            }
            return
        }
        errorMessage = "\(editor.title) is not installed. Please install it or try a different editor."
    }

    func listVisiblePaths(limit: Int) async -> GitService.VisibleFilesResult? {
        guard let repo else { return nil }
        return await service.listVisibleFiles(in: repo, limit: limit)
    }

    private static func findExecutableInPath(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = Pipe()
        do {
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (path?.isEmpty == false) ? path : nil
        } catch { return nil }
    }

    // MARK: - Commit message generation (minimal pass)
    func generateCommitMessage(providerId: String? = nil, modelId: String? = nil, maxBytes: Int = 128 * 1024) {
        // Debounce: if already generating for the same repo, ignore
        if isGenerating, let current = repoRoot?.path, generatingRepoPath == current {
            #if DEBUG
            print("[AICommit] Debounced: generation already in progress for repo=\(current)")
            #endif
            Self.log.info("Debounced: generation already in progress for repo=\(current, privacy: .public)")
            return
        }
        generatingTask = Task { [weak self] in
            guard let self else { return }
            let shouldNotify = SessionPreferencesStore.isCommitMessageNotificationEnabled()
            let statusToken = StatusBarLogStore.shared.beginTask(
                "Generating commit message...",
                level: .info,
                source: "Git"
            )
            var finalStatus: (message: String, level: StatusBarLogLevel)?
            defer {
                if let finalStatus {
                    StatusBarLogStore.shared.endTask(
                        statusToken,
                        message: finalStatus.message,
                        level: finalStatus.level,
                        source: "Git"
                    )
                } else {
                    StatusBarLogStore.shared.endTask(statusToken)
                }
            }
            guard let repo = self.repo else {
                if shouldNotify {
                    await SystemNotifier.shared.notify(
                        title: "AI Commit",
                        body: "Cannot generate commit message: not a Git repository.",
                        threadId: "ai-commit"
                    )
                }
                finalStatus = ("Not a Git repository", .error)
                return
            }
            let repoPath = repo.root.path
            await MainActor.run {
                self.isGenerating = true
                self.generatingRepoPath = repoPath
            }
            defer { Task { @MainActor in
                self.isGenerating = false
                self.generatingRepoPath = nil
            } }
            // Fetch staged diff (index vs HEAD)
            let full = await self.service.stagedUnifiedDiff(in: repo)
            if full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if shouldNotify {
                    await SystemNotifier.shared.notify(
                        title: "AI Commit",
                        body: "No staged changes to summarize.",
                        threadId: "ai-commit"
                    )
                }
                #if DEBUG
                print("[AICommit] No staged changes; generation skipped")
                #endif
                Self.log.info("No staged changes; generation skipped")
                finalStatus = ("No staged changes to summarize", .warning)
                return
            }
            // Truncate by bytes for safety
            let truncated = Self.prefixBytes(of: full, maxBytes: maxBytes)
            let prompt = Self.commitPrompt(diff: truncated)
            let llm = LLMHTTPService()
            #if DEBUG
            print("[AICommit] Start generation providerId=\(providerId ?? "(auto)") bytes=\(truncated.utf8.count)")
            #endif
            Self.log.info("Start generation providerId=\(providerId ?? "(auto)", privacy: .public) bytes=\(truncated.utf8.count)")
            do {
                // Allow a slightly longer timeout for commit generation to reduce provider-specific timeouts
                var options = LLMHTTPService.Options()
                options.preferred = .auto
                options.model = modelId
                options.timeout = 45
                options.providerId = providerId
                options.maxTokens = 800
                options.systemPrompt = "Return only the commit message text. No labels, explanations, or extra commentary."
                let res = try await llm.generateText(prompt: prompt, options: options)
                let raw = res.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let cleaned = Self.cleanCommitMessage(from: raw)
                let finalMessage = cleaned.isEmpty ? raw : cleaned
                await MainActor.run {
                    guard self.repoRoot?.path == repoPath else {
                        // Repo changed during generation; drop the result
                        #if DEBUG
                        print("[AICommit] Repo switched during generation; result discarded for repo=\(repoPath)")
                        #endif
                        return
                    }
                    if finalMessage.isEmpty {
                        // Leave commit message unchanged; rely on system notification
                        return
                    }
                    self.commitMessage = finalMessage
                }
                if finalMessage.isEmpty {
                    #if DEBUG
                    print("[AICommit] Empty response from provider=\(res.providerId), elapsedMs=\(res.elapsedMs)")
                    #endif
                    Self.log.warning("Empty commit message from provider=\(res.providerId, privacy: .public)")
                    finalStatus = ("Empty commit message from provider", .warning)
                } else {
                    let preview = finalMessage.prefix(120)
                    #if DEBUG
                    print("[AICommit] Success provider=\(res.providerId) elapsedMs=\(res.elapsedMs) msg=\(preview)")
                    #endif
                    Self.log.info("Success provider=\(res.providerId, privacy: .public) elapsedMs=\(res.elapsedMs) msg=\(String(preview), privacy: .public)")
                    finalStatus = ("Commit message ready", .success)
                }
                if shouldNotify {
                    await SystemNotifier.shared.notify(
                        title: "AI Commit",
                        body: finalMessage.isEmpty
                            ? "Generation completed but returned an empty commit message."
                            : "Generated commit message (\(res.providerId)) in \(res.elapsedMs)ms",
                        threadId: "ai-commit"
                    )
                }
            } catch {
                #if DEBUG
                print("[AICommit] Error: \(error.localizedDescription)")
                #endif
                Self.log.error("Generation error: \(error.localizedDescription, privacy: .public)")
                if shouldNotify {
                    await SystemNotifier.shared.notify(
                        title: "AI Commit",
                        body: "Generation failed: \(error.localizedDescription)",
                        threadId: "ai-commit"
                    )
                }
                finalStatus = ("Generation failed: \(error.localizedDescription)", .error)
            }
        }
    }

    private static func prefixBytes(of s: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        let data = s.data(using: .utf8) ?? Data()
        if data.count <= maxBytes { return s }
        let slice = data.prefix(maxBytes)
        return String(data: slice, encoding: .utf8) ?? String(s.prefix(maxBytes / 2))
    }

    private static func commitPrompt(diff: String) -> String {
        // Allow user override via Settings › Git Review template stored in preferences.
        // The template acts as a preamble; we always append the diff after it.
        let key = "git.review.commitPromptTemplate"
        let outputPrefix = "Output only the commit message. Do not add any extra text."
        let basePrompt: String
        if let tpl = UserDefaults.standard.string(forKey: key), !tpl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            basePrompt = tpl
        } else if let payload = Self.payloadCommitPrompt {
            basePrompt = payload
        } else {
            basePrompt = [
                "Write a Conventional Commit in imperative mood.",
                "Include a concise subject line (type: scope? subject).",
                "Optionally add a brief body (2-4 lines) explaining motivation and key changes.",
                "Constraints: subject <= 80 chars; wrap body lines <= 72 chars; no trailing period in subject."
            ].joined(separator: "\n")
        }
        return [outputPrefix, "", basePrompt, "", "Diff:", diff].joined(separator: "\n")
    }

    private static let payloadCommitPrompt: String? = {
        let bundle = Bundle.main
        guard let url = bundle.url(forResource: "commit-message", withExtension: "md", subdirectory: "payload/prompts") else {
            return nil
        }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }()

    private static func cleanCommitMessage(from raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Remove surrounding code fences if any
        if s.hasPrefix("```") {
            if let range = s.range(of: "```", options: [], range: s.index(s.startIndex, offsetBy: 3)..<s.endIndex) {
                s = String(s[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if let end = s.range(of: "```") { s = String(s[..<end.lowerBound]) }
            }
        }
        // Strip surrounding quotes if the whole text is quoted
        if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            s = String(s.dropFirst().dropLast())
        }
        // Collapse spaces
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        return s
    }
}

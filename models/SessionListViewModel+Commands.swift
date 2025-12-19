import AppKit
import Foundation

@MainActor
extension SessionListViewModel {
    func resume(session: SessionSummary) async -> Result<ProcessResult, Error> {
        do {
            let cwd = resolvedWorkingDirectory(for: session)
            let result = try await actions.resume(
                session: session,
                executableURL: preferredExecutableURL(for: session.source),
                options: preferences.resumeOptions,
                workingDirectory: cwd)
            return .success(result)
        } catch {
            return .failure(error)
        }
    }

    private func preferredExecutableURL(for source: SessionSource) -> URL {
        if let override = preferences.resolvedCommandOverrideURL(for: source.baseKind) {
            return override
        }
        return URL(fileURLWithPath: "/usr/bin/env")
    }

    private func preferredExecutablePath(for kind: SessionSource.Kind) -> String {
        if let override = preferences.resolvedCommandOverrideURL(for: kind) {
            return override.path
        }
        return kind.cliExecutableName
    }

    private func preferredExternalTerminalProfile() -> ExternalTerminalProfile? {
        ExternalTerminalProfileStore.shared.resolvePreferredProfile(
            id: preferences.defaultResumeExternalAppId
        )
    }

    var shouldCopyCommandsToClipboard: Bool {
        preferences.defaultResumeCopyToClipboard
    }

    func copyResumeCommands(session: SessionSummary) {
        let cwd = resolvedWorkingDirectory(for: session)
        actions.copyResumeCommands(
            session: session,
            executableURL: preferredExecutableURL(for: session.source),
            options: preferences.resumeOptions,
            simplifiedForExternal: true,
            workingDirectory: cwd
        )
    }

    private func warpResumeTitle(for session: SessionSummary) -> String? {
        if let title = session.userTitle, let sanitized = warpSanitizedTitle(from: title) {
            return sanitized
        }
        let defaultScope = warpScopeCandidate(for: session, project: projectForSession(session))
        let defaultValue = WarpTitleBuilder.newSessionLabel(scope: defaultScope, task: taskTitle(for: session))
        return resolveWarpTitleInput(defaultValue: defaultValue, forcePrompt: true)
    }

    private func projectForSession(_ session: SessionSummary) -> Project? {
        guard let pid = projectIdForSession(session.id) else { return nil }
        return projects.first(where: { $0.id == pid })
    }

    @discardableResult
    func copyResumeCommandsRespectingProject(
        session: SessionSummary,
        destinationApp: ExternalTerminalProfile? = nil
    ) -> Bool {
        let cwd = resolvedWorkingDirectory(for: session)
        var warpHint: String? = nil
        if destinationApp?.usesWarpCommands == true {
            guard let hint = warpResumeTitle(for: session) else { return false }
            warpHint = hint
        }

        if session.source != .codexLocal {
            actions.copyResumeCommands(
                session: session,
                executableURL: preferredExecutableURL(for: session.source),
                options: preferences.resumeOptions,
                simplifiedForExternal: true,
                destinationApp: destinationApp,
                titleHint: warpHint,
                workingDirectory: cwd
            )
            return true
        }
        if let pid = projectIdForSession(session.id),
            let p = projects.first(where: { $0.id == pid }),
            p.profile != nil || (p.profileId?.isEmpty == false)
        {
            actions.copyResumeUsingProjectProfileCommands(
                session: session, project: p,
                executableURL: preferredExecutableURL(for: .codexLocal),
                options: preferences.resumeOptions,
                destinationApp: destinationApp,
                titleHint: warpHint)
        } else {
            actions.copyResumeCommands(
                session: session,
                executableURL: preferredExecutableURL(for: .codexLocal),
                options: preferences.resumeOptions,
                simplifiedForExternal: true,
                destinationApp: destinationApp,
                titleHint: warpHint,
                workingDirectory: cwd)
        }
        return true
    }

    @discardableResult
    func copyResumeCommandsIfEnabled(
        session: SessionSummary,
        destinationApp: ExternalTerminalProfile? = nil
    ) -> Bool {
        guard preferences.defaultResumeCopyToClipboard else { return true }
        return copyResumeCommandsRespectingProject(session: session, destinationApp: destinationApp)
    }

    func openInTerminal(session: SessionSummary) -> Bool {
        let cwd = resolvedWorkingDirectory(for: session)
        return actions.openInTerminal(
            session: session,
            executableURL: preferredExecutableURL(for: session.source),
            options: preferences.resumeOptions,
            workingDirectory: cwd)
    }

    func buildResumeCommands(session: SessionSummary) -> String {
        let cwd = resolvedWorkingDirectory(for: session)
        return actions.buildResumeCommandLines(
            session: session,
            executableURL: preferredExecutableURL(for: session.source),
            options: preferences.resumeOptions,
            workingDirectory: cwd
        )
    }

    func buildExternalResumeCommands(session: SessionSummary) -> String {
        let cwd = resolvedWorkingDirectory(for: session)
        return actions.buildExternalResumeCommands(
            session: session,
            executableURL: preferredExecutableURL(for: session.source),
            options: preferences.resumeOptions,
            workingDirectory: cwd
        )
    }

    func buildResumeCLIInvocation(session: SessionSummary) -> String {
        let execName = preferredExecutablePath(for: session.source.baseKind)
        return actions.buildResumeCLIInvocation(
            session: session,
            executablePath: execName,
            options: preferences.resumeOptions
        )
    }

    // MARK: - Embedded CLI Console helpers (dev)
    func buildResumeCLIArgs(session: SessionSummary) -> [String] {
        actions.buildResumeArguments(session: session, options: preferences.resumeOptions)
    }

    func buildNewSessionCLIArgs(session: SessionSummary) -> [String] {
        actions.buildNewSessionArguments(session: session, options: preferences.resumeOptions)
    }

    func buildResumeCLIInvocationRespectingProject(session: SessionSummary) -> String {
        if session.isRemote,
           let remote = actions.remoteResumeInvocationForTerminal(
                session: session,
                options: preferences.resumeOptions
            ) {
            return remote
        }
        if session.source == .codexLocal,
            let pid = projectIdForSession(session.id),
            let p = projects.first(where: { $0.id == pid }),
            p.profile != nil || (p.profileId?.isEmpty == false)
        {
            return actions.buildResumeUsingProjectProfileCLIInvocation(
                session: session, project: p, executablePath: preferredExecutablePath(for: .codex),
                options: preferences.resumeOptions)
        }
        return actions.buildResumeCLIInvocation(
            session: session,
            executablePath: preferredExecutablePath(for: session.source.baseKind),
            options: preferences.resumeOptions)
    }

    func copyNewSessionCommands(session: SessionSummary) {
        actions.copyNewSessionCommands(
            session: session,
            executableURL: preferredExecutableURL(for: session.source),
            options: preferences.resumeOptions
        )
    }

    func buildNewSessionCLIInvocation(session: SessionSummary) -> String {
        actions.buildNewSessionCLIInvocation(
            session: session,
            options: preferences.resumeOptions,
            executablePath: preferredExecutablePath(for: session.source.baseKind)
        )
    }

    func openNewSession(session: SessionSummary) -> Bool {
        actions.openNewSession(
            session: session,
            executableURL: preferredExecutableURL(for: session.source),
            options: preferences.resumeOptions
        )
    }

    func buildNewProjectCLIInvocation(project: Project) -> String {
        actions.buildNewProjectCLIInvocation(
            project: project,
            options: preferences.resumeOptions,
            executablePath: preferredExecutablePath(for: .codex)
        )
    }

    @discardableResult
    func copyNewProjectCommands(project: Project, destinationApp: ExternalTerminalProfile? = nil) -> Bool {
        var warpHint: String? = nil
        if destinationApp?.usesWarpCommands == true {
            let base = warpTitleForProject(project)
            guard let resolved = resolveWarpTitleInput(defaultValue: base) else { return false }
            warpHint = resolved
        }
        actions.copyNewProjectCommands(
            project: project,
            executableURL: preferredExecutableURL(for: .codexLocal),
            options: preferences.resumeOptions,
            destinationApp: destinationApp,
            titleHint: warpHint
        )
        return true
    }

    /// Unified Project "New Session" entry. Respects embedded/external preference
    /// to reduce branching between Sidebar and Detail flows.
    func newSession(project: Project) {
        let embeddedPreferred = preferences.defaultResumeUseEmbeddedTerminal
        NSLog(
            "📌 [SessionListVM] newSession(project:%@) embeddedPreferred=%@ useEmbeddedCLIConsole=%@",
            project.id,
            embeddedPreferred ? "YES" : "NO",
            preferences.useEmbeddedCLIConsole ? "YES" : "NO"
        )
        // Record intent so the new session can be auto-assigned to this project
        recordIntentForProjectNew(project: project)

        if preferences.defaultResumeUseEmbeddedTerminal {
            // Embedded terminal path: signal ContentView to start an embedded
            // shell anchored to this project and perform targeted refresh.
            pendingEmbeddedProjectNew = project
            setIncrementalHintForCodexToday()
            // Also broadcast a notification for robustness across views
            NotificationCenter.default.post(
                name: .codMateStartEmbeddedNewProject,
                object: nil,
                userInfo: ["projectId": project.id]
            )
            Task { await SystemNotifier.shared.notify(title: "CodMate", body: "Starting embedded New…") }
            return
        }

        // Resolve preferred external terminal and open at the project directory
        guard let profile = preferredExternalTerminalProfile() else { return }
        let dir: String = {
            let d = (project.directory ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return d.isEmpty ? NSHomeDirectory() : d
        }()

        // External terminal path: copy command and open preferred terminal.
        guard copyNewProjectCommands(project: project, destinationApp: profile) else { return }

        if !profile.isNone {
            let cmd = profile.supportsCommandResolved
                ? actions.buildNewProjectCLIInvocation(project: project, options: preferences.resumeOptions)
                : nil

            if profile.isTerminal {
                _ = openAppleTerminal(at: dir)
            } else {
                openPreferredTerminalViaScheme(profile: profile, directory: dir, command: cmd)
            }
        }

        // Friendly nudge so users know the command was placed on clipboard
        Task {
            await SystemNotifier.shared.notify(
                title: "CodMate", body: "Command copied. Paste it in the opened terminal.")
        }

        // Event-driven incremental refresh hint + proactive targeted refresh for today
        setIncrementalHintForCodexToday()
        Task { await self.refreshIncrementalForNewCodexToday() }
    }

    /// Build CLI invocation, respecting project profile if applicable.
    /// - Parameters:
    ///   - session: Session to launch.
    ///   - initialPrompt: Optional initial prompt text to pass to CLI.
    /// - Returns: Complete CLI command string.
    func buildNewSessionCLIInvocationRespectingProject(
        session: SessionSummary,
        initialPrompt: String? = nil
    ) -> String {
        if session.isRemote,
           let remote = actions.remoteNewInvocationForTerminal(
                session: session,
                options: preferences.resumeOptions,
                initialPrompt: initialPrompt
            ) {
            return remote
        }
        if session.source == .codexLocal,
            let pid = projectIdForSession(session.id),
            let p = projects.first(where: { $0.id == pid }),
            p.profile != nil || (p.profileId?.isEmpty == false)
        {
            return actions.buildNewSessionUsingProjectProfileCLIInvocation(
                session: session,
                project: p,
                options: preferences.resumeOptions,
                initialPrompt: initialPrompt,
                executablePath: preferredExecutablePath(for: session.source.baseKind))
        }
        return actions.buildNewSessionCLIInvocation(
            session: session,
            options: preferences.resumeOptions,
            initialPrompt: initialPrompt,
            executablePath: preferredExecutablePath(for: session.source.baseKind))
    }

    @discardableResult
    func copyNewSessionCommandsRespectingProject(
        session: SessionSummary,
        destinationApp: ExternalTerminalProfile? = nil
    ) -> Bool {
        let project = projectIdForSession(session.id).flatMap { pid in
            projects.first(where: { $0.id == pid })
        }
        var warpHint: String? = nil
        if destinationApp?.usesWarpCommands == true {
            let base = warpNewSessionTitleHint(for: session, project: project)
            guard let resolved = resolveWarpTitleInput(defaultValue: base) else { return false }
            warpHint = resolved
        }

        if session.source == .codexLocal,
            let project,
            project.profile != nil || (project.profileId?.isEmpty == false)
        {
            actions.copyNewSessionUsingProjectProfileCommands(
                session: session, project: project, executableURL: preferredExecutableURL(for: session.source),
                options: preferences.resumeOptions,
                destinationApp: destinationApp,
                titleHint: warpHint)
        } else {
            actions.copyNewSessionCommands(
                session: session,
                executableURL: preferredExecutableURL(for: session.source),
                options: preferences.resumeOptions,
                destinationApp: destinationApp,
                titleHint: warpHint)
        }
        return true
    }

    @discardableResult
    func copyNewSessionCommandsIfEnabled(
        session: SessionSummary,
        destinationApp: ExternalTerminalProfile? = nil,
        initialPrompt: String? = nil
    ) -> Bool {
        guard preferences.defaultResumeCopyToClipboard else { return true }
        if let initialPrompt {
            return copyNewSessionCommandsRespectingProject(
                session: session,
                destinationApp: destinationApp,
                initialPrompt: initialPrompt
            )
        }
        return copyNewSessionCommandsRespectingProject(session: session, destinationApp: destinationApp)
    }

    @discardableResult
    func copyNewSessionCommandsRespectingProject(
        session: SessionSummary,
        destinationApp: ExternalTerminalProfile? = nil,
        initialPrompt: String
    ) -> Bool {
        let project = projectIdForSession(session.id).flatMap { pid in
            projects.first(where: { $0.id == pid })
        }
        var warpHint: String? = nil
        if destinationApp?.usesWarpCommands == true {
            let base = warpNewSessionTitleHint(for: session, project: project)
            guard let resolved = resolveWarpTitleInput(defaultValue: base) else { return false }
            warpHint = resolved
        }

        if session.source == .codexLocal,
            let project,
            project.profile != nil || (project.profileId?.isEmpty == false)
        {
            actions.copyNewSessionUsingProjectProfileCommands(
                session: session, project: project, executableURL: preferredExecutableURL(for: session.source),
                options: preferences.resumeOptions,
                destinationApp: destinationApp,
                initialPrompt: initialPrompt,
                titleHint: warpHint)
        } else {
            let cmd = actions.buildNewSessionCLIInvocation(
                session: session,
                options: preferences.resumeOptions,
                initialPrompt: initialPrompt,
                executablePath: preferredExecutablePath(for: session.source.baseKind))
            let pb = NSPasteboard.general
            pb.clearContents()
            if destinationApp?.usesWarpCommands == true, let title = warpHint {
                let lines = ["#\(title)", cmd]
                pb.setString(lines.joined(separator: "\n") + "\n", forType: .string)
            } else {
                pb.setString(cmd + "\n", forType: .string)
            }
        }
        return true
    }

    @discardableResult
    func copyNewProjectCommandsIfEnabled(
        project: Project,
        destinationApp: ExternalTerminalProfile? = nil
    ) -> Bool {
        guard preferences.defaultResumeCopyToClipboard else { return true }
        return copyNewProjectCommands(project: project, destinationApp: destinationApp)
    }

    private func warpSanitizedTitle(from raw: String?) -> String? {
        guard var s = raw else { return nil }
        s = s.replacingOccurrences(of: "\r", with: " ")
        s = s.replacingOccurrences(of: "\n", with: " ")
        s = s.replacingOccurrences(of: "\t", with: " ")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.count > 80 { s = String(s.prefix(80)) }
        let collapsed = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: "-")
        return collapsed.isEmpty ? nil : collapsed
    }

    private func warpScopeCandidate(for session: SessionSummary, project: Project?) -> String? {
        if let name = project?.name.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if let title = session.userTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
            !title.isEmpty
        {
            return title
        }
        let cwd =
            FileManager.default.fileExists(atPath: session.cwd)
            ? session.cwd : session.fileURL.deletingLastPathComponent().path
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? session.displayName : trimmed
    }

    private func taskTitle(for session: SessionSummary) -> String? {
        guard let tid = session.taskId else { return nil }
        return workspaceVM?.tasks.first(where: { $0.id == tid })?.effectiveTitle
    }

    private func warpNewSessionTitleHint(for session: SessionSummary, project: Project?) -> String {
        let scope = warpScopeCandidate(for: session, project: project)
        let task = taskTitle(for: session)
        var extras: [String] = []
        if session.isRemote, let host = session.remoteHost {
            extras.append(host)
        }
        return WarpTitleBuilder.newSessionLabel(scope: scope, task: task, extras: extras)
    }

    private func warpTitleForProject(_ project: Project) -> String {
        WarpTitleBuilder.newSessionLabel(scope: project.name, task: nil)
    }

    private func resolveWarpTitleInput(defaultValue: String, forcePrompt: Bool = false) -> String? {
        if preferences.promptForWarpTitle || forcePrompt {
            guard let userInput = WarpTitlePrompt.requestCustomTitle(defaultValue: defaultValue) else {
                return nil
            }
            let trimmed = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return defaultValue
            }
            return warpSanitizedTitle(from: trimmed) ?? defaultValue
        }
        return defaultValue
    }


    func openNewSessionRespectingProject(session: SessionSummary) {
        if session.source == .codexLocal,
            let pid = projectIdForSession(session.id),
            let p = projects.first(where: { $0.id == pid }),
            p.profile != nil || (p.profileId?.isEmpty == false)
        {
            _ = actions.openNewSessionUsingProjectProfile(
                session: session, project: p, executableURL: preferredExecutableURL(for: session.source),
                options: preferences.resumeOptions)
        } else {
            _ = actions.openNewSession(
                session: session,
                executableURL: preferredExecutableURL(for: session.source),
                options: preferences.resumeOptions)
        }
    }

    func openNewSessionRespectingProject(session: SessionSummary, initialPrompt: String) {
        if session.source == .codexLocal,
            let pid = projectIdForSession(session.id),
            let p = projects.first(where: { $0.id == pid }),
            p.profile != nil || (p.profileId?.isEmpty == false)
        {
            _ = actions.openNewSessionUsingProjectProfile(
                session: session, project: p, executableURL: preferredExecutableURL(for: session.source),
                options: preferences.resumeOptions, initialPrompt: initialPrompt)
        } else {
            _ = actions.openNewSession(
                session: session,
                executableURL: preferredExecutableURL(for: session.source),
                options: preferences.resumeOptions)
        }
    }

    func projectIdForSession(_ id: String) -> String? {
        if let summary = sessionSummary(for: id) {
            return projectId(for: summary)
        }
        for source in ProjectSessionSource.allCases {
            if let pid = projectId(for: id, source: source) {
                return pid
            }
        }
        return nil
    }

    func projectForId(_ id: String) async -> Project? {
        await projectsStore.getProject(id: id)
    }

    func allowedSources(for session: SessionSummary) -> [ProjectSessionSource] {
        if let pid = projectIdForSession(session.id),
            let p = projects.first(where: { $0.id == pid })
        {
            let allowed = p.sources.isEmpty ? ProjectSessionSource.allSet : p.sources
            return Array(allowed).sorted { $0.displayName < $1.displayName }
        }
        return ProjectSessionSource.allCases
    }

    func copyRealResumeCommand(session: SessionSummary) {
        actions.copyRealResumeInvocation(
            session: session,
            executableURL: preferredExecutableURL(for: session.source),
            options: preferences.resumeOptions
        )
    }

    func openWarpLaunch(session: SessionSummary) {
        let cwd = resolvedWorkingDirectory(for: session)
        _ = actions.openWarpLaunchConfig(
            session: session,
            options: preferences.resumeOptions,
            executableURL: preferredExecutableURL(for: session.source),
            workingDirectory: cwd
        )
    }

    func openPreferredTerminal(profile: ExternalTerminalProfile) {
        actions.openTerminalApp(profile)
    }

    func openPreferredTerminalViaScheme(
        profile: ExternalTerminalProfile,
        directory: String,
        command: String? = nil
    ) {
        actions.openTerminalViaScheme(profile, directory: directory, command: command)
    }

    func openAppleTerminal(at directory: String) -> Bool {
        actions.openAppleTerminal(at: directory)
    }
}

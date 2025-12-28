import Foundation

struct SessionCommandGenerator {
    let actions: SessionActions

    func embeddedResume(
        session: SessionSummary,
        executableURL: URL,
        options: ResumeOptions,
        workingDirectory: String? = nil,
        codexHome: String? = nil
    ) -> String {
        actions.buildEmbeddedResumeCommandLines(
            session: session,
            executableURL: executableURL,
            options: options,
            workingDirectory: workingDirectory,
            codexHome: codexHome
        )
    }

    func embeddedNew(
        session: SessionSummary,
        project: Project? = nil,
        executableURL: URL,
        options: ResumeOptions,
        initialPrompt: String? = nil,
        codexHome: String? = nil
    ) -> String {
        if session.source == .codexLocal,
           let project,
           project.profile != nil || (project.profileId?.isEmpty == false)
        {
            return actions.buildNewSessionUsingProjectProfileCommandLines(
                session: session,
                project: project,
                executableURL: executableURL,
                options: options,
                initialPrompt: initialPrompt,
                codexHome: codexHome
            )
        }
        return actions.buildEmbeddedNewSessionCommandLines(
            session: session,
            executableURL: executableURL,
            options: options,
            initialPrompt: initialPrompt,
            codexHome: codexHome
        )
    }

    func embeddedNewProject(
        project: Project,
        executableURL: URL,
        options: ResumeOptions,
        codexHome: String? = nil
    ) -> String {
        actions.buildEmbeddedNewProjectCommandLines(
            project: project,
            executableURL: executableURL,
            options: options,
            codexHome: codexHome
        )
    }

    func inlineResume(
        session: SessionSummary,
        project: Project? = nil,
        executablePath: String,
        options: ResumeOptions,
        codexHome: String? = nil
    ) -> String {
        if session.isRemote,
           let remote = actions.remoteResumeInvocationForTerminal(
                session: session,
                options: options
            ) {
            return remote
        }
        if session.source == .codexLocal,
           let project,
           project.profile != nil || (project.profileId?.isEmpty == false)
        {
            return actions.buildResumeUsingProjectProfileCLIInvocation(
                session: session,
                project: project,
                executablePath: executablePath,
                options: options,
                codexHome: codexHome
            )
        }
        return actions.buildResumeCLIInvocation(
            session: session,
            executablePath: executablePath,
            options: options,
            codexHome: codexHome
        )
    }

    func inlineNew(
        session: SessionSummary,
        project: Project? = nil,
        executablePath: String,
        options: ResumeOptions,
        initialPrompt: String? = nil,
        codexHome: String? = nil
    ) -> String {
        if session.isRemote,
           let remote = actions.remoteNewInvocationForTerminal(
                session: session,
                options: options,
                initialPrompt: initialPrompt
            ) {
            return remote
        }
        if session.source == .codexLocal,
           let project,
           project.profile != nil || (project.profileId?.isEmpty == false)
        {
            return actions.buildNewSessionUsingProjectProfileCLIInvocation(
                session: session,
                project: project,
                options: options,
                initialPrompt: initialPrompt,
                executablePath: executablePath,
                codexHome: codexHome
            )
        }
        return actions.buildNewSessionCLIInvocation(
            session: session,
            options: options,
            initialPrompt: initialPrompt,
            executablePath: executablePath,
            codexHome: codexHome
        )
    }

    func inlineNewProject(
        project: Project,
        executablePath: String,
        options: ResumeOptions,
        codexHome: String? = nil
    ) -> String {
        actions.buildNewProjectCLIInvocation(
            project: project,
            options: options,
            executablePath: executablePath,
            codexHome: codexHome
        )
    }

    func warpResume(
        session: SessionSummary,
        executableURL: URL,
        options: ResumeOptions,
        titleHint: String? = nil,
        codexHome: String? = nil
    ) -> String {
        actions.buildWarpResumeCommands(
            session: session,
            executableURL: executableURL,
            options: options,
            titleHint: titleHint,
            codexHome: codexHome
        )
    }

    func warpNewSession(
        session: SessionSummary,
        executableURL: URL,
        options: ResumeOptions,
        titleHint: String? = nil,
        codexHome: String? = nil
    ) -> String {
        actions.buildWarpNewSessionCommands(
            session: session,
            executableURL: executableURL,
            options: options,
            titleHint: titleHint,
            codexHome: codexHome
        )
    }

    func warpNewProject(
        project: Project,
        executableURL: URL,
        options: ResumeOptions,
        titleHint: String? = nil,
        codexHome: String? = nil
    ) -> String {
        actions.buildWarpNewProjectCommands(
            project: project,
            executableURL: executableURL,
            options: options,
            titleHint: titleHint,
            codexHome: codexHome
        )
    }

    func projectClaudeInvocation(
        project: Project,
        executablePath: String,
        options: ResumeOptions,
        fallbackModel: String?
    ) -> String {
        let effectiveModel = (project.profile?.model ?? fallbackModel)
        return actions.buildClaudeProjectCLIInvocation(
            executablePath: executablePath,
            options: options,
            model: effectiveModel
        )
    }

    func projectGeminiInvocation(
        executablePath: String,
        options: ResumeOptions
    ) -> String {
        actions.buildGeminiCLIInvocation(
            executablePath: executablePath,
            options: options
        )
    }
}

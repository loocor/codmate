import AppKit
import Security
import Foundation

extension SessionActions {
    @MainActor
    func resume(
        session: SessionSummary,
        executableURL: URL,
        options: ResumeOptions,
        workingDirectory: String? = nil
    ) async throws
        -> ProcessResult
    {
        // Prefer PATH resolution; allow an optional user-specified executable override when valid.
        let resolvedExec = resolvedExecutablePath(
            for: session.source.baseKind,
            executableURL: executableURL
        )

        // Prepare arguments first, including async MCP config if needed
        var additionalEnv: [String: String] = [:]
        var args: [String]
        switch session.source.baseKind {
        case .codex:
            args = buildResumeArguments(session: session, options: options)
        case .claude:
            args = ["--resume", session.id]
            // Apply Claude advanced flags from resume options
            if options.claudeVerbose { args.append("--verbose") }
            if options.claudeDebug {
                args.append("-d")
                if let f = options.claudeDebugFilter, !f.isEmpty { args.append(f) }
            }
            if let pm = options.claudePermissionMode, pm != .default {
                args.append(contentsOf: ["--permission-mode", pm.rawValue])
            }
            if options.claudeSkipPermissions { args.append("--dangerously-skip-permissions") }
            if options.claudeAllowSkipPermissions { args.append("--allow-dangerously-skip-permissions") }
            // Claude CLI does not support an "--allow-unsandboxed-commands" flag; omit it.
            if let allowed = options.claudeAllowedTools, !allowed.isEmpty {
                args.append(contentsOf: ["--allowed-tools", allowed])
            }
            if let disallowed = options.claudeDisallowedTools, !disallowed.isEmpty {
                args.append(contentsOf: ["--disallowed-tools", disallowed])
            }
            if let addDirs = options.claudeAddDirs, !addDirs.isEmpty {
                // Split by comma and add multiple flags
                let parts = addDirs.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map { String($0) }.filter { !$0.isEmpty }
                for dir in parts { args.append(contentsOf: ["--add-dir", dir]) }
            }
            if options.claudeIDE { args.append("--ide") }
            if options.claudeStrictMCP { args.append("--strict-mcp-config") }
            // Export MCP servers to ~/.claude/settings.json (Claude Code auto-loads from there)
            let mcpStore = MCPServersStore()
            try? await mcpStore.exportEnabledForClaudeConfig()
            if let fb = options.claudeFallbackModel, !fb.isEmpty { args.append(contentsOf: ["--fallback-model", fb]) }
        case .gemini:
            let config = geminiRuntimeConfiguration(options: options)
            args = ["--resume", conversationId(for: session)] + config.flags
            additionalEnv = config.environment
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            let cwd = self.workingDirectory(for: session, override: workingDirectory)
            let cwdURL = URL(fileURLWithPath: cwd, isDirectory: true)
            Task.detached {
                do {
                    let process = Process()
                    if resolvedExec == session.source.baseKind.cliExecutableName {
                        // Use env to resolve the executable on PATH
                        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                        process.arguments = [resolvedExec] + args
                    } else {
                        process.executableURL = URL(fileURLWithPath: resolvedExec)
                        process.arguments = args
                    }
                    // Prefer original session cwd if exists
                    process.currentDirectoryURL = cwdURL

                    let pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = pipe
                    var env = ProcessInfo.processInfo.environment
                    let basePath = CLIEnvironment.buildBasePATH()
                    if let current = env["PATH"], !current.isEmpty {
                        env["PATH"] = basePath + ":" + current
                    } else {
                        env["PATH"] = basePath
                    }
                    // Prepare environment overlays (Claude Code picks up Anthropic-compatible vars)
                    if session.source.baseKind == .claude {
                        var envOverlays: [String: String] = [:]
                        let registry = ProvidersRegistryService()
                        let bindings = await registry.getBindings()
                        let activeId = bindings.activeProvider?[ProvidersRegistryService.Consumer.claudeCode.rawValue]
                        if let activeId, !activeId.isEmpty {
                            let providers = await registry.listAllProviders()
                            if let p = providers.first(where: { $0.id == activeId }) {
                                let conn = p.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue]
                                let loginMethod = conn?.loginMethod?.lowercased() ?? "api"
                                if let base = conn?.baseURL, !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    envOverlays["ANTHROPIC_BASE_URL"] = base
                                }
                                // Subscription login: do not inject token; rely on `claude login`
                                if loginMethod != "subscription" {
                                    // Map custom env key to ANTHROPIC_AUTH_TOKEN if available in current env
                                    if let keyName = (p.envKey ?? conn?.envKey), !keyName.isEmpty {
                                        if let tokenVal = ProcessInfo.processInfo.environment[keyName], !tokenVal.isEmpty {
                                            envOverlays["ANTHROPIC_AUTH_TOKEN"] = tokenVal
                                        } else {
                                            // If keyName itself looks like a token, use it directly
                                            let v = keyName
                                            let looksLikeToken = v.lowercased().contains("sk-") || v.hasPrefix("eyJ") || v.contains(".")
                                            if looksLikeToken { envOverlays["ANTHROPIC_AUTH_TOKEN"] = v }
                                        }
                                    } else if let tokenVal = ProcessInfo.processInfo.environment["ANTHROPIC_AUTH_TOKEN"], !tokenVal.isEmpty {
                                        envOverlays["ANTHROPIC_AUTH_TOKEN"] = tokenVal
                                    }
                                }
                                // Aliases: default and small/fast
                                if let aliases = conn?.modelAliases {
                                    if let d = aliases["default"], !d.isEmpty { envOverlays["ANTHROPIC_MODEL"] = d }
                                    if let h = aliases["haiku"], !h.isEmpty { envOverlays["ANTHROPIC_SMALL_FAST_MODEL"] = h }
                                }
                                // Fall back to registry default model if alias not set
                                if envOverlays["ANTHROPIC_MODEL"] == nil,
                                   let dm = bindings.defaultModel?[ProvidersRegistryService.Consumer.claudeCode.rawValue],
                                   !dm.isEmpty {
                                    envOverlays["ANTHROPIC_MODEL"] = dm
                                }
                            }
                        }
                        for (k, v) in envOverlays { env[k] = v }
                    } else {
                        // Built-in (no provider selected): respect login method default (subscription) by not injecting token.
                        // Nothing to inject here; PATH is already set above.
                    }
                    if session.source.baseKind == .gemini {
                        for (key, value) in additionalEnv {
                            env[key] = value
                        }
                    }
                    process.environment = env

                    try process.run()
                    process.waitUntilExit()

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""

                    if process.terminationStatus == 0 {
                        continuation.resume(returning: ProcessResult(output: output))
                    } else {
                        continuation.resume(
                            throwing: SessionActionError.resumeFailed(output: output))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Resume helpers (copy/open Terminal)
    private func shellEscapedPath(_ path: String) -> String {
        // Simple escape: wrap in single quotes and escape existing single quotes
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func shellQuoteIfNeeded(_ s: String) -> String {
        // Only quote when the string contains whitespace or shell‑sensitive characters.
        // Keep it readable (e.g., codex stays unquoted).
        let unsafe: Set<Character> = Set(" \t\n\r\"'`$&|;<>*?()[]{}\\")
        if s.contains(where: { unsafe.contains($0) }) {
            return shellEscapedPath(s)
        }
        return s
    }

    private func sshInvocation(
        host: String,
        remoteCommand: String,
        resolvedArguments: [String]? = nil
    ) -> String {
        let contextArguments = resolvedArguments ?? resolvedSSHContext(for: host)
        if let args = contextArguments {
            let parts = ["ssh", "-t"] + args
            let command = parts.map { shellQuoteIfNeeded($0) }.joined(separator: " ")
            return "\(command) \(shellSingleQuoted(remoteCommand))"
        }
        return "ssh -t \(shellQuoteIfNeeded(host)) \(shellSingleQuoted(remoteCommand))"
    }

    // Reliable conversation id for resume commands: always use the session_meta id
    // parsed from the log (SessionSummary.id). This matches Codex CLI's
    // expectation (UUID) and Claude's native id semantics.
    private func conversationId(for session: SessionSummary) -> String { session.id }

    private func executableName(for kind: SessionSource.Kind) -> String {
        kind.cliExecutableName
    }

    func resolvedExecutablePath(for kind: SessionSource.Kind, executableURL: URL) -> String {
        let candidate = executableURL.path
        if candidate != "/usr/bin/env", fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return kind.cliExecutableName
    }

    private func embeddedExportLines(for source: SessionSource) -> [String] { [] }

    struct GeminiRuntimeConfiguration {
        let flags: [String]
        let environment: [String: String]
    }

    func geminiRuntimeConfiguration(options: ResumeOptions) -> GeminiRuntimeConfiguration {
        var flags: [String] = []
        var env: [String: String] = [:]

        if options.dangerouslyBypass {
            flags.append("--yolo")
            return GeminiRuntimeConfiguration(flags: flags, environment: env)
        }

        if options.approval == .never {
            flags.append("--yolo")
        } else if options.fullAuto {
            flags.append(contentsOf: ["--approval-mode", "auto_edit"])
        }

        var sandboxPreference = options.sandbox
        if sandboxPreference == nil && options.fullAuto {
            sandboxPreference = .workspaceWrite
        }

        if let sandboxPreference, sandboxPreference != .dangerFullAccess {
            flags.append("--sandbox")
            env["GEMINI_SANDBOX"] = "sandbox-exec"
            env["SEATBELT_PROFILE"] = geminiSeatbeltProfile(for: sandboxPreference)
        }

        return GeminiRuntimeConfiguration(flags: flags, environment: env)
    }

    func geminiEnvironmentOverrides(options: ResumeOptions) -> [String: String] {
        geminiRuntimeConfiguration(options: options).environment
    }

    private func geminiSeatbeltProfile(for mode: SandboxMode) -> String {
        switch mode {
        case .readOnly:
            // Restrictive profile keeps writes tightly contained while allowing network access
            return "restrictive-open"
        case .workspaceWrite:
            return "permissive-open"
        case .dangerFullAccess:
            return "permissive-open"
        }
    }

    func geminiEnvironmentExportLines(environment: [String: String]) -> [String] {
        guard !environment.isEmpty else { return [] }
        return environment
            .sorted { $0.key < $1.key }
            .map { "export \($0.key)=\(shellSingleQuoted($0.value))" }
    }

    // Build environment overlay map for embedding (DEV CLI console)
    func embeddedEnvironment(for source: SessionSource) -> [String: String] {
        var env: [String: String] = [:]
        env["LANG"] = "zh_CN.UTF-8"
        env["LC_ALL"] = "zh_CN.UTF-8"
        env["LC_CTYPE"] = "zh_CN.UTF-8"
        env["TERM"] = "xterm-256color"
        if source.baseKind == .codex { env["CODEX_DISABLE_COLOR_QUERY"] = "1" }
        return env
    }

    private func flags(from options: ResumeOptions) -> [String] {
        // Highest precedence: dangerously bypass
        if options.dangerouslyBypass { return ["--dangerously-bypass-approvals-and-sandbox"] }
        // Next: full-auto shortcut
        if options.fullAuto { return ["--full-auto"] }
        // Otherwise explicit -s and -a when provided
        var f: [String] = []
        if let s = options.sandbox { f += ["-s", s.rawValue] }
        if let a = options.approval { f += ["-a", a.rawValue] }
        return f
    }

    func buildResumeCLIInvocation(
        session: SessionSummary, executablePath: String, options: ResumeOptions
    ) -> String {
        let exe = shellQuoteIfNeeded(executablePath)
        switch session.source.baseKind {
        case .codex:
            let f = flags(from: options).map { shellQuoteIfNeeded($0) }
            if f.isEmpty { return "\(exe) resume \(conversationId(for: session))" }
            return ([exe] + f + ["resume", shellQuoteIfNeeded(conversationId(for: session))]).joined(separator: " ")
        case .claude:
            let args = claudeResumeArguments(session: session, options: options).map {
                shellQuoteIfNeeded($0)
            }
            return ([exe] + args).joined(separator: " ")
        case .gemini:
            let config = geminiRuntimeConfiguration(options: options)
            let args: [String] = ["--resume", conversationId(for: session)] + config.flags
            return ([exe] + args.map { shellQuoteIfNeeded($0) }).joined(separator: " ")
        }
    }

    private func claudeResumeArguments(
        session: SessionSummary,
        options: ResumeOptions
    ) -> [String] {
        var parts: [String] = ["--resume", session.id]
        if options.claudeVerbose { parts.append("--verbose") }
        if options.claudeDebug {
            parts.append("-d")
            if let f = options.claudeDebugFilter, !f.isEmpty { parts.append(f) }
        }
        if let pm = options.claudePermissionMode, pm != .default {
            parts.append(contentsOf: ["--permission-mode", pm.rawValue])
        }
        if options.claudeSkipPermissions { parts.append("--dangerously-skip-permissions") }
        if options.claudeAllowSkipPermissions { parts.append("--allow-dangerously-skip-permissions") }
        if let allowed = options.claudeAllowedTools, !allowed.isEmpty {
            parts.append(contentsOf: ["--allowed-tools", allowed])
        }
        if let disallowed = options.claudeDisallowedTools, !disallowed.isEmpty {
            parts.append(contentsOf: ["--disallowed-tools", disallowed])
        }
        if let addDirs = options.claudeAddDirs, !addDirs.isEmpty {
            let dirParts = addDirs.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map { String($0) }.filter { !$0.isEmpty }
            for dir in dirParts { parts.append(contentsOf: ["--add-dir", dir]) }
        }
        if options.claudeIDE { parts.append("--ide") }
        if options.claudeStrictMCP { parts.append("--strict-mcp-config") }
        if let fb = options.claudeFallbackModel, !fb.isEmpty {
            parts.append(contentsOf: ["--fallback-model", fb])
        }
        return parts
    }

    func buildNewSessionArguments(session: SessionSummary, options: ResumeOptions) -> [String] {
        switch session.source.baseKind {
        case .codex:
            var args: [String] = []
            if let normalized = normalizedCodexModelName(session.model) {
                args += ["--model", normalized]
            }
            args += flags(from: options)
            return args
        case .claude:
            return []
        case .gemini:
            var args: [String] = []
            if let rawModel = session.model?.trimmingCharacters(in: .whitespacesAndNewlines),
               !rawModel.isEmpty {
                args += ["--model", rawModel]
            }
            args.append(contentsOf: geminiRuntimeConfiguration(options: options).flags)
            return args
        }
    }

    func buildNewSessionCLIInvocation(
        session: SessionSummary,
        options: ResumeOptions,
        initialPrompt: String? = nil,
        executablePath: String? = nil
    ) -> String {
        // Check if this is a remote session and return SSH command if so
        if session.isRemote, let host = session.remoteHost {
            let sshContext = resolvedSSHContext(for: host)
            let remoteCommand = buildRemoteNewShellCommand(
                session: session,
                options: options,
                initialPrompt: initialPrompt
            )
            return sshInvocation(
                host: host,
                remoteCommand: remoteCommand,
                resolvedArguments: sshContext
            )
        }
        
        // Local session handling
        return buildLocalNewSessionCLIInvocation(
            session: session,
            options: options,
            initialPrompt: initialPrompt,
            executablePath: executablePath
        )
    }

    func buildLocalNewSessionCLIInvocation(
        session: SessionSummary,
        options: ResumeOptions,
        initialPrompt: String? = nil,
        executablePath: String? = nil
    ) -> String {
        // Local session handling (without checking remote status)
        switch session.source.baseKind {
        case .codex:
            // Launch a fresh Codex session by invoking `codex` directly (no "new" subcommand).
            let exe = shellQuoteIfNeeded(executablePath ?? "codex")
            var parts: [String] = [exe]
            let args = buildNewSessionArguments(session: session, options: options).map {
                arg -> String in
                if arg.contains(where: { $0.isWhitespace || $0 == "'" }) {
                    return shellEscapedPath(arg)
                }
                return arg
            }
            parts.append(contentsOf: args)
            if let prompt = initialPrompt, !prompt.isEmpty {
                parts.append(shellSingleQuoted(prompt))
            }
            return parts.joined(separator: " ")
        case .claude:
            var parts: [String] = [shellQuoteIfNeeded(executablePath ?? "claude")]

            // Apply model if specified
            // For Built-in provider: either omit --model or use short alias (sonnet/haiku/opus)
            // Built-in models follow pattern: claude-3-X-Y-latest or claude-3-5-X-latest
            // Also handle fallback names like "Claude", "Sonnet", "Haiku", "Opus"
            if let model = session.model, !model.trimmingCharacters(in: .whitespaces).isEmpty {
                let trimmed = model.trimmingCharacters(in: .whitespaces)
                let lowerModel = trimmed.lowercased()

                // Check if this is a generic fallback name (Claude) - omit it
                if lowerModel == "claude" {
                    // Generic fallback - don't pass --model, let CLI use default
                } else if lowerModel == "sonnet" || lowerModel == "haiku" || lowerModel == "opus" {
                    // Already a short alias - pass as-is (lowercase)
                    parts.append("--model")
                    parts.append(lowerModel)
                } else if trimmed.hasPrefix("claude-") && trimmed.hasSuffix("-latest") {
                    // Built-in format detected: use short alias
                    let shortAlias: String?
                    if lowerModel.contains("sonnet") {
                        shortAlias = "sonnet"
                    } else if lowerModel.contains("haiku") {
                        shortAlias = "haiku"
                    } else if lowerModel.contains("opus") {
                        shortAlias = "opus"
                    } else {
                        shortAlias = nil  // Unknown built-in model, omit --model
                    }
                    if let alias = shortAlias {
                        parts.append("--model")
                        parts.append(alias)
                    }
                } else {
                    // Third-party or custom model: pass as-is
                    parts.append("--model")
                    parts.append(shellQuoteIfNeeded(trimmed))
                }
            }

            // Apply Claude runtime configuration from options (matching resume behavior)
            if options.claudeVerbose { parts.append("--verbose") }
            if options.claudeDebug {
                parts.append("-d")
                if let f = options.claudeDebugFilter, !f.isEmpty { parts.append(shellQuoteIfNeeded(f)) }
            }
            if let pm = options.claudePermissionMode, pm != .default {
                parts.append(contentsOf: ["--permission-mode", shellQuoteIfNeeded(pm.rawValue)])
            }
            if options.claudeSkipPermissions { parts.append("--dangerously-skip-permissions") }
            if options.claudeAllowSkipPermissions { parts.append("--allow-dangerously-skip-permissions") }
            // Claude CLI does not support an "--allow-unsandboxed-commands" flag; omit it.
            if let allowed = options.claudeAllowedTools, !allowed.isEmpty {
                parts.append(contentsOf: ["--allowed-tools", shellQuoteIfNeeded(allowed)])
            }
            if let disallowed = options.claudeDisallowedTools, !disallowed.isEmpty {
                parts.append(contentsOf: ["--disallowed-tools", shellQuoteIfNeeded(disallowed)])
            }
            if let addDirs = options.claudeAddDirs, !addDirs.isEmpty {
                let dirParts = addDirs.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map { String($0) }.filter { !$0.isEmpty }
                for dir in dirParts { parts.append(contentsOf: ["--add-dir", shellQuoteIfNeeded(dir)]) }
            }
            if options.claudeIDE { parts.append("--ide") }
            if options.claudeStrictMCP { parts.append("--strict-mcp-config") }
            if let fb = options.claudeFallbackModel, !fb.isEmpty { parts.append(contentsOf: ["--fallback-model", shellQuoteIfNeeded(fb)]) }

            // Note: MCP config file is only attached in actual process execution (resume method),
            // not in CLI invocation strings for external terminals, as it requires async export

            if let prompt = initialPrompt, !prompt.isEmpty {
                parts.append(shellSingleQuoted(prompt))
            }
            return parts.joined(separator: " ")
        case .gemini:
            let exe = shellQuoteIfNeeded(executablePath ?? "gemini")
            var parts: [String] = [exe]
            let args = buildNewSessionArguments(session: session, options: options).map {
                arg -> String in
                if arg.contains(where: { $0.isWhitespace || $0 == "'" }) {
                    return shellEscapedPath(arg)
                }
                return arg
            }
            parts.append(contentsOf: args)
            if let prompt = initialPrompt, !prompt.isEmpty {
                parts.append(shellSingleQuoted(prompt))
            }
            return parts.joined(separator: " ")
        }
    }

    func buildResumeArguments(session: SessionSummary, options: ResumeOptions) -> [String] {
        switch session.source.baseKind {
        case .codex:
            let f = flags(from: options)
            return f + ["resume", conversationId(for: session)]
        case .claude:
            return claudeResumeArguments(session: session, options: options)
        case .gemini:
            let config = geminiRuntimeConfiguration(options: options)
            return ["--resume", conversationId(for: session)] + config.flags
        }
    }

    func buildResumeCommandLines(
        session: SessionSummary,
        executableURL: URL,
        options: ResumeOptions,
        workingDirectory: String? = nil
    ) -> String {
        #if APPSTORE
        let cwd = self.workingDirectory(for: session, override: workingDirectory)
        let cd = "cd " + shellEscapedPath(cwd)
        let exports = embeddedExportLines(for: session.source).joined(separator: "; ")
        // MAS sandbox: do not auto-execute external CLI inside the app. Only prepare directory and env.
        // The user can copy or insert the real command via UI prompts.
        let cliName = executableName(for: session.source.baseKind)
        let notice = "echo \"[CodMate] App Store 沙盒无法直接运行 \(cliName) CLI，请使用右侧按钮复制命令，在外部终端执行。\""
        return cd + "\n" + exports + "\n" + notice + "\n"
        #else
        if session.isRemote, let host = session.remoteHost {
            let sshContext = resolvedSSHContext(for: host)
            let remote = buildRemoteResumeShellCommand(
                session: session,
                options: options
            )
            return sshInvocation(
                host: host,
                remoteCommand: remote,
                resolvedArguments: sshContext
            ) + "\n"
        }
        let cwd = self.workingDirectory(for: session, override: workingDirectory)
        let cd = "cd " + shellEscapedPath(cwd)
        var exportLines = embeddedExportLines(for: session.source)
        if session.source.baseKind == .gemini {
            let envLines = geminiEnvironmentExportLines(
                environment: geminiRuntimeConfiguration(options: options).environment)
            exportLines.append(contentsOf: envLines)
        }
        let exports = exportLines.joined(separator: "; ")
        let injectedPATH = CLIEnvironment.buildInjectedPATH()
        // Use override executable when configured; otherwise fall back to PATH resolution.
        let execPath = resolvedExecutablePath(
            for: session.source.baseKind,
            executableURL: executableURL
        )
        let invocation = buildResumeCLIInvocation(
            session: session, executablePath: execPath, options: options)
        let resume = "PATH=\(injectedPATH) \(invocation)"
        return cd + "\n" + exports + "\n" + resume + "\n"
        #endif
    }

    func buildNewSessionCommandLines(
        session: SessionSummary, executableURL: URL, options: ResumeOptions
    ) -> String {
        #if APPSTORE
        let cwd =
            FileManager.default.fileExists(atPath: session.cwd)
            ? session.cwd : session.fileURL.deletingLastPathComponent().path
        let cd = "cd " + shellEscapedPath(cwd)
        // MAS: do not execute external CLI in embedded terminal; only show a notice.
        let notice = "echo \"[CodMate] App Store 沙盒无法直接运行 \(session.source.baseKind.cliExecutableName) CLI，请在外部终端执行复制的命令。\""
        return cd + "\n" + notice + "\n"
        #else
        if session.isRemote, let host = session.remoteHost {
            let sshContext = resolvedSSHContext(for: host)
            let remote = buildRemoteNewShellCommand(
                session: session,
                options: options,
                initialPrompt: nil
            )
            return sshInvocation(
                host: host,
                remoteCommand: remote,
                resolvedArguments: sshContext
            ) + "\n"
        }
        let cwd =
            FileManager.default.fileExists(atPath: session.cwd)
            ? session.cwd : session.fileURL.deletingLastPathComponent().path
        let cd = "cd " + shellEscapedPath(cwd)
        var exportLines: [String] = []
        if session.source.baseKind == .gemini {
            exportLines = embeddedExportLines(for: session.source)
            let envLines = geminiEnvironmentExportLines(
                environment: geminiRuntimeConfiguration(options: options).environment)
            exportLines.append(contentsOf: envLines)
        }
        let exports = exportLines.isEmpty ? nil : exportLines.joined(separator: "; ")
        let execPath = resolvedExecutablePath(
            for: session.source.baseKind,
            executableURL: executableURL
        )
        let invocation = buildNewSessionCLIInvocation(
            session: session, options: options, executablePath: execPath)
        var lines = [cd]
        if let exports { lines.append(exports) }
        lines.append(invocation)
        return lines.joined(separator: "\n") + "\n"
        #endif
    }

    func buildExternalNewSessionCommands(
        session: SessionSummary, executableURL: URL, options: ResumeOptions
    ) -> String {
        if session.isRemote, let host = session.remoteHost {
            let sshContext = resolvedSSHContext(for: host)
            let remote = buildRemoteNewShellCommand(
                session: session,
                options: options,
                initialPrompt: nil
            )
            return sshInvocation(
                host: host,
                remoteCommand: remote,
                resolvedArguments: sshContext
            ) + "\n"
        }
        let cwd =
            FileManager.default.fileExists(atPath: session.cwd)
            ? session.cwd : session.fileURL.deletingLastPathComponent().path
        let cd = "cd " + shellEscapedPath(cwd)
        let execPath = resolvedExecutablePath(
            for: session.source.baseKind,
            executableURL: executableURL
        )
        let newCommand = buildNewSessionCLIInvocation(
            session: session, options: options, executablePath: execPath)
        var lines = [cd]
        if session.source.baseKind == .gemini {
            lines.append(contentsOf: embeddedExportLines(for: session.source))
            let envLines = geminiEnvironmentExportLines(
                environment: geminiRuntimeConfiguration(options: options).environment)
            lines.append(contentsOf: envLines)
        }
        lines.append(newCommand)
        return lines.joined(separator: "\n") + "\n"
    }

    // Simplified two-line command for external terminals
    func buildExternalResumeCommands(
        session: SessionSummary,
        executableURL: URL,
        options: ResumeOptions,
        workingDirectory: String? = nil
    ) -> String {
        if session.isRemote, let host = session.remoteHost {
            let sshContext = resolvedSSHContext(for: host)
            let remote = buildRemoteResumeShellCommand(
                session: session,
                options: options
            )
            return sshInvocation(
                host: host,
                remoteCommand: remote,
                resolvedArguments: sshContext
            ) + "\n"
        }
        let cwd = self.workingDirectory(for: session, override: workingDirectory)
        let cd = "cd " + shellEscapedPath(cwd)
        let execPath = resolvedExecutablePath(
            for: session.source.baseKind,
            executableURL: executableURL
        )
        let resume = buildResumeCLIInvocation(
            session: session, executablePath: execPath, options: options)
        var lines = [cd]
        if session.source.baseKind == .gemini {
            lines.append(contentsOf: embeddedExportLines(for: session.source))
            let envLines = geminiEnvironmentExportLines(
                environment: geminiRuntimeConfiguration(options: options).environment)
            lines.append(contentsOf: envLines)
        }
        lines.append(resume)
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Warp-optimized clipboard commands
    //
    // Warp appears to derive a new tab title from the first pasted "command" line.
    // When our external clipboard text starts with `cd ...`, the tab title becomes `cd`.
    // For Warp flows we prepend a harmless comment line and omit `cd` entirely because
    // we already open Warp at the target directory via URL scheme.
    private func warpTitleCommentLine(_ title: String?) -> String? {
        guard var s = title else { return nil }
        s = s.replacingOccurrences(of: "\r", with: " ")
        s = s.replacingOccurrences(of: "\n", with: " ")
        s = s.replacingOccurrences(of: "\t", with: " ")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.count > 80 { s = String(s.prefix(80)) }
        let collapsed = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: "-")
        guard !collapsed.isEmpty else { return nil }
        return "#" + collapsed
    }

    private func warpScope(from session: SessionSummary) -> String? {
        if let title = session.userTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
            !title.isEmpty
        {
            return title
        }
        let cwd =
            FileManager.default.fileExists(atPath: session.cwd)
            ? session.cwd : session.fileURL.deletingLastPathComponent().path
        let dirName = URL(fileURLWithPath: cwd).lastPathComponent
        if !dirName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return dirName
        }
        return session.displayName
    }

    func buildWarpResumeCommands(
        session: SessionSummary, executableURL: URL, options: ResumeOptions, titleHint: String? = nil
    ) -> String {
        if session.isRemote, let host = session.remoteHost {
            let sshContext = resolvedSSHContext(for: host)
            let remote = buildRemoteResumeShellCommand(session: session, options: options)
            let cmd = sshInvocation(host: host, remoteCommand: remote, resolvedArguments: sshContext)
            let lines = [warpTitleCommentLine(titleHint ?? session.effectiveTitle), cmd].compactMap { $0 }
            return lines.joined(separator: "\n") + "\n"
        }
        let execPath = resolvedExecutablePath(
            for: session.source.baseKind,
            executableURL: executableURL
        )
        let resume = buildResumeCLIInvocation(session: session, executablePath: execPath, options: options)
        var lines: [String] = []
        if let title = warpTitleCommentLine(titleHint ?? session.effectiveTitle) { lines.append(title) }
        if session.source.baseKind == .gemini {
            lines.append(contentsOf: embeddedExportLines(for: session.source))
            let envLines = geminiEnvironmentExportLines(
                environment: geminiRuntimeConfiguration(options: options).environment)
            lines.append(contentsOf: envLines)
        }
        lines.append(resume)
        return lines.joined(separator: "\n") + "\n"
    }

    func buildWarpNewSessionCommands(
        session: SessionSummary, executableURL: URL, options: ResumeOptions, titleHint: String? = nil
    ) -> String {
        if session.isRemote, let host = session.remoteHost {
            let sshContext = resolvedSSHContext(for: host)
            let remote = buildRemoteNewShellCommand(
                session: session,
                options: options,
                initialPrompt: nil
            )
            let cmd = sshInvocation(host: host, remoteCommand: remote, resolvedArguments: sshContext)
            let extras = [host]
            let base = titleHint ?? WarpTitleBuilder.newSessionLabel(
                scope: warpScope(from: session),
                task: nil,
                extras: extras
            )
            let title = warpTitleCommentLine(base)
            let lines = [title, cmd].compactMap { $0 }
            return lines.joined(separator: "\n") + "\n"
        }
        let execPath = resolvedExecutablePath(
            for: session.source.baseKind,
            executableURL: executableURL
        )
        let base = titleHint ?? WarpTitleBuilder.newSessionLabel(
            scope: warpScope(from: session),
            task: nil
        )
        let newCommand = buildNewSessionCLIInvocation(
            session: session, options: options, executablePath: execPath)
        var lines: [String] = []
        if let title = warpTitleCommentLine(base) { lines.append(title) }
        if session.source.baseKind == .gemini {
            lines.append(contentsOf: embeddedExportLines(for: session.source))
            let envLines = geminiEnvironmentExportLines(
                environment: geminiRuntimeConfiguration(options: options).environment)
            lines.append(contentsOf: envLines)
        }
        lines.append(newCommand)
        return lines.joined(separator: "\n") + "\n"
    }

    func copyResumeCommands(
        session: SessionSummary, executableURL: URL, options: ResumeOptions,
        simplifiedForExternal: Bool = true,
        destinationApp: ExternalTerminalProfile? = nil,
        titleHint: String? = nil,
        workingDirectory: String? = nil
    ) {
        let commands: String
        if simplifiedForExternal, destinationApp?.usesWarpCommands == true {
            commands = buildWarpResumeCommands(
                session: session, executableURL: executableURL, options: options, titleHint: titleHint)
        } else {
            commands =
                simplifiedForExternal
                ? buildExternalResumeCommands(
                    session: session,
                    executableURL: executableURL,
                    options: options,
                    workingDirectory: workingDirectory)
                : buildResumeCommandLines(
                    session: session,
                    executableURL: executableURL,
                    options: options,
                    workingDirectory: workingDirectory)
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(commands, forType: .string)
    }

    func copyNewSessionCommands(
        session: SessionSummary, executableURL: URL, options: ResumeOptions,
        simplifiedForExternal: Bool = true,
        destinationApp: ExternalTerminalProfile? = nil,
        titleHint: String? = nil
    ) {
        let commands: String
        if simplifiedForExternal, destinationApp?.usesWarpCommands == true {
            commands = buildWarpNewSessionCommands(
                session: session, executableURL: executableURL, options: options, titleHint: titleHint)
        } else {
            commands =
                simplifiedForExternal
                ? buildExternalNewSessionCommands(
                    session: session, executableURL: executableURL, options: options)
                : buildNewSessionCommandLines(
                    session: session, executableURL: executableURL, options: options)
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(commands, forType: .string)
    }

    // MARK: - Project-level new session helpers
    private func buildNewProjectArguments(project: Project, options: ResumeOptions) -> [String] {
        var args: [String] = []
        // Embedded per-project profile config (preferred)
        let pp = project.profile
        let profileId = project.profileId?.trimmingCharacters(in: .whitespaces)

        // Flags only; avoid explicit --model for Codex new to keep behavior consistent
        if let pp {
            if pp.dangerouslyBypass == true {
                args += ["--dangerously-bypass-approvals-and-sandbox"]
            } else if pp.fullAuto == true {
                args += ["--full-auto"]
            } else {
                if let s = pp.sandbox { args += ["-s", s.rawValue] }
                if let a = pp.approval { args += ["-a", a.rawValue] }
            }
        } else {
            // Fallback to explicit flags
            args += flags(from: options)
        }

        // Always use -c to inject inline profile (zero-write approach)
        if let profileId, !profileId.isEmpty {
            // Resolve effective approval/sandbox for project-level new inline profile
            var approvalRaw: String? = pp?.approval?.rawValue
            var sandboxRaw: String? = pp?.sandbox?.rawValue
            if sandboxRaw == nil {
                if pp?.dangerouslyBypass == true {
                    sandboxRaw = SandboxMode.dangerFullAccess.rawValue
                } else if let opt = options.sandbox?.rawValue {
                    sandboxRaw = opt
                }
            }
            if approvalRaw == nil {
                if let opt = options.approval?.rawValue {
                    approvalRaw = opt
                } else {
                    approvalRaw = ApprovalPolicy.onRequest.rawValue
                }
            }
            if sandboxRaw == nil { sandboxRaw = SandboxMode.workspaceWrite.rawValue }

            if let inline = renderInlineProfileConfig(
                key: profileId,
                model: pp?.model,  // include model only inside profile injection
                approvalPolicy: approvalRaw,
                sandboxMode: sandboxRaw
            ) {
                args += ["--profile", profileId, "-c", inline]
            } else {
                // profile id provided but nothing to inject; omit --profile to avoid referring to a non-existent profile
            }
        }
        return args
    }

    func buildNewProjectCLIInvocation(
        project: Project,
        options: ResumeOptions,
        executablePath: String? = nil
    ) -> String {
        let exe = shellQuoteIfNeeded(executablePath ?? "codex")
        let args = buildNewProjectArguments(project: project, options: options).map {
            arg -> String in
            if arg.contains(where: { $0.isWhitespace || $0 == "'" }) {
                return shellEscapedPath(arg)
            }
            return arg
        }
        // Invoke `codex` directly without a "new" subcommand
        return ([exe] + args).joined(separator: " ")
    }

    func buildNewProjectCommandLines(project: Project, executableURL: URL, options: ResumeOptions)
        -> String
    {
        let cdLine: String? = {
            if let dir = project.directory,
                !dir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return "cd " + shellEscapedPath(dir)
            }
            return nil
        }()
        // PATH injection: prepend project-specific paths if any
        let prepend = project.profile?.pathPrepend ?? []
        let prependString = prepend.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.joined(separator: ":")
        let injectedPATH = CLIEnvironment.buildInjectedPATH(
            additionalPaths: prependString.isEmpty ? [] : [prependString]
        )
        // Exports: locale defaults + project env
        var exportLines: [String] = [
            "export LANG=zh_CN.UTF-8",
            "export LC_ALL=zh_CN.UTF-8",
            "export LC_CTYPE=zh_CN.UTF-8",
            "export TERM=xterm-256color",
            "export CODEX_DISABLE_COLOR_QUERY=1",
        ]
        if let env = project.profile?.env {
            for (k, v) in env {
                let key = k.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { continue }
                exportLines.append("export \(key)=\(shellSingleQuoted(v))")
            }
        }
        let exports = exportLines.joined(separator: "; ")
        let execPath = resolvedExecutablePath(for: .codex, executableURL: executableURL)
        let invocation = buildNewProjectCLIInvocation(
            project: project, options: options, executablePath: execPath)
        let command = "PATH=\(injectedPATH) \(invocation)"
        if let cd = cdLine {
            return cd + "\n" + exports + "\n" + command + "\n"
        } else {
            return exports + "\n" + command + "\n"
        }
    }

    func buildExternalNewProjectCommands(
        project: Project, executableURL: URL, options: ResumeOptions
    ) -> String {
        let cdLine: String? = {
            if let dir = project.directory,
                !dir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return "cd " + shellEscapedPath(dir)
            }
            return nil
        }()
        let execPath = resolvedExecutablePath(for: .codex, executableURL: executableURL)
        let cmd = buildNewProjectCLIInvocation(
            project: project, options: options, executablePath: execPath)
        if let cd = cdLine {
            // Standard external New Session: emit `cd` + bare CLI invocation only.
            return cd + "\n" + cmd + "\n"
        } else {
            return cmd + "\n"
        }
    }

    func copyNewProjectCommands(
        project: Project, executableURL: URL, options: ResumeOptions,
        simplifiedForExternal: Bool = true,
        destinationApp: ExternalTerminalProfile? = nil,
        titleHint: String? = nil
    ) {
        let commands: String
        if simplifiedForExternal, destinationApp?.usesWarpCommands == true {
            let base = titleHint ?? WarpTitleBuilder.newSessionLabel(
                scope: project.name,
                task: nil
            )
            let title = warpTitleCommentLine(base)
            let execPath = resolvedExecutablePath(for: .codex, executableURL: executableURL)
            let cmd = buildNewProjectCLIInvocation(
                project: project, options: options, executablePath: execPath)
            let lines = [title, cmd].compactMap { $0 }
            commands = lines.joined(separator: "\n") + "\n"
        } else {
            commands =
                simplifiedForExternal
                ? buildExternalNewProjectCommands(
                    project: project, executableURL: executableURL, options: options)
                : buildNewProjectCommandLines(
                    project: project, executableURL: executableURL, options: options)
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(commands, forType: .string)
    }

    @discardableResult
    func openNewProject(project: Project, executableURL: URL, options: ResumeOptions) -> Bool {
        let scriptText = {
            let lines = buildNewProjectCommandLines(
                project: project, executableURL: executableURL, options: options
            )
            .replacingOccurrences(of: "\n", with: "; ")
            return """
                tell application "Terminal"
                  activate
                  do script "\(lines)"
                end tell
                """
        }()

        if let script = NSAppleScript(source: scriptText) {
            var errorDict: NSDictionary?
            script.executeAndReturnError(&errorDict)
            return errorDict == nil
        }
        return false
    }

    // MARK: - Detail New using Project Profile (cd = session.cwd)
    private func buildNewSessionArguments(
        using project: Project, fallbackModel: String?, options: ResumeOptions
    ) -> [String] {
        var args: [String] = []
        let pid = project.profileId?.trimmingCharacters(in: .whitespaces)

        // Flags precedence: danger -> full-auto -> explicit -s/-a when present in project profile
        if project.profile?.dangerouslyBypass == true {
            args += ["--dangerously-bypass-approvals-and-sandbox"]
        } else if project.profile?.fullAuto == true {
            args += ["--full-auto"]
        } else {
            if let s = project.profile?.sandbox { args += ["-s", s.rawValue] }
            if let a = project.profile?.approval { args += ["-a", a.rawValue] }
        }

        // Always use -c to inject inline profile (zero-write approach)
        if let pid, !pid.isEmpty {
            // Do not append explicit --model for Codex new; rely on project profile (persisted or inline) or global config
            let modelFromProject = project.profile?.model

            // Effective policies for inline profile injection (New using project):
            // - approval: prefer explicit; otherwise prefer options; else default to on-request
            // - sandbox: prefer explicit; otherwise Danger Bypass => danger-full-access; otherwise options; else default to workspace-write
            var approvalRaw: String? = project.profile?.approval?.rawValue
            var sandboxRaw: String? = project.profile?.sandbox?.rawValue
            if sandboxRaw == nil {
                if project.profile?.dangerouslyBypass == true {
                    sandboxRaw = SandboxMode.dangerFullAccess.rawValue
                } else if let opt = options.sandbox?.rawValue {
                    sandboxRaw = opt
                }
            }
            if approvalRaw == nil {
                if let opt = options.approval?.rawValue {
                    approvalRaw = opt
                } else {
                    approvalRaw = ApprovalPolicy.onRequest.rawValue
                }
            }
            if sandboxRaw == nil { sandboxRaw = SandboxMode.workspaceWrite.rawValue }

            if let inline = renderInlineProfileConfig(
                key: pid,
                model: modelFromProject ?? fallbackModel,
                approvalPolicy: approvalRaw,
                sandboxMode: sandboxRaw
            ) {
                // Zero-write: inject the inline profile and select it
                args += ["--profile", pid, "-c", inline]
            }
        }
        return args
    }

    func buildNewSessionUsingProjectProfileCLIInvocation(
        session: SessionSummary,
        project: Project,
        options: ResumeOptions,
        initialPrompt: String? = nil,
        executablePath: String? = nil
    ) -> String {
        // Launch using project profile; choose executable based on session source.
        let exe = shellQuoteIfNeeded(executablePath ?? executableName(for: session.source.baseKind))
        var parts: [String] = [exe]

        // For Claude, only include model if specified; profile settings don't apply.
        if session.source.baseKind == .claude {
            if let model = session.model, !model.trimmingCharacters(in: .whitespaces).isEmpty {
                parts.append("--model")
                parts.append(shellQuoteIfNeeded(model))
            }
            if let prompt = initialPrompt, !prompt.isEmpty {
                parts.append(shellSingleQuoted(prompt))
            }
            return parts.joined(separator: " ")
        }

        if session.source.baseKind == .gemini {
            if let prompt = initialPrompt, !prompt.isEmpty {
                parts.append(shellSingleQuoted(prompt))
            }
            return parts.joined(separator: " ")
        }
        // For Codex, use full project profile arguments
        let args = buildNewSessionArguments(
            using: project, fallbackModel: effectiveCodexModel(for: session), options: options
        ).map { arg -> String in
            if arg.contains(where: { $0.isWhitespace || $0 == "'" }) {
                return shellEscapedPath(arg)
            }
            return arg
        }
        parts.append(contentsOf: args)
        if let prompt = initialPrompt, !prompt.isEmpty {
            parts.append(shellSingleQuoted(prompt))
        }
        return parts.joined(separator: " ")
    }

    func buildNewSessionUsingProjectProfileCommandLines(
        session: SessionSummary, project: Project, executableURL: URL, options: ResumeOptions,
        initialPrompt: String? = nil
    ) -> String {
        if session.isRemote, let host = session.remoteHost {
            let invocation = buildNewSessionUsingProjectProfileCLIInvocation(
                session: session, project: project, options: options, initialPrompt: initialPrompt)
            var exportLines: [String] = [
                "export LANG=zh_CN.UTF-8",
                "export LC_ALL=zh_CN.UTF-8",
                "export LC_CTYPE=zh_CN.UTF-8",
                "export TERM=xterm-256color",
            ]
            if let env = project.profile?.env {
                for (k, v) in env {
                    let key = k.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !key.isEmpty else { continue }
                    exportLines.append("export \(key)=\(shellSingleQuoted(v))")
                }
            }
            let sshContext = resolvedSSHContext(for: host)
            let remote = buildRemoteShellCommand(
                session: session,
                exports: exportLines,
                invocation: invocation
            )
            return sshInvocation(
                host: host,
                remoteCommand: remote,
                resolvedArguments: sshContext
            ) + "\n"
        }
        let cwd =
            FileManager.default.fileExists(atPath: session.cwd)
            ? session.cwd : session.fileURL.deletingLastPathComponent().path
        let cd = "cd " + shellEscapedPath(cwd)
        let execPath = resolvedExecutablePath(
            for: session.source.baseKind,
            executableURL: executableURL
        )
        let invocation = buildNewSessionUsingProjectProfileCLIInvocation(
            session: session,
            project: project,
            options: options,
            initialPrompt: initialPrompt,
            executablePath: execPath
        )
        // Local project-profile New: only emit `cd` + bare CLI invocation.
        return cd + "\n" + invocation + "\n"
    }

    func buildExternalNewSessionUsingProjectProfileCommands(
        session: SessionSummary, project: Project, executableURL: URL, options: ResumeOptions,
        initialPrompt: String? = nil
    ) -> String {
        if session.isRemote, let host = session.remoteHost {
            let sshContext = resolvedSSHContext(for: host)
            var exportLines: [String] = [
                "export LANG=zh_CN.UTF-8",
                "export LC_ALL=zh_CN.UTF-8",
                "export LC_CTYPE=zh_CN.UTF-8",
                "export TERM=xterm-256color",
            ]
            if let env = project.profile?.env {
                for (k, v) in env {
                    let key = k.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !key.isEmpty else { continue }
                    exportLines.append("export \(key)=\(shellSingleQuoted(v))")
                }
            }
            let invocation = buildNewSessionUsingProjectProfileCLIInvocation(
                session: session, project: project, options: options, initialPrompt: initialPrompt)
            let remote = buildRemoteShellCommand(
                session: session,
                exports: exportLines,
                invocation: invocation
            )
            return sshInvocation(
                host: host,
                remoteCommand: remote,
                resolvedArguments: sshContext
            ) + "\n"
        }
        let cwd =
            FileManager.default.fileExists(atPath: session.cwd)
            ? session.cwd : session.fileURL.deletingLastPathComponent().path
        let cd = "cd " + shellEscapedPath(cwd)
        let cmd = buildNewSessionUsingProjectProfileCLIInvocation(
            session: session,
            project: project,
            options: options,
            initialPrompt: initialPrompt,
            executablePath: resolvedExecutablePath(
                for: session.source.baseKind,
                executableURL: executableURL
            )
        )
        return cd + "\n" + cmd + "\n"
    }

    func copyNewSessionUsingProjectProfileCommands(
        session: SessionSummary, project: Project, executableURL: URL, options: ResumeOptions,
        simplifiedForExternal: Bool = true,
        destinationApp: ExternalTerminalProfile? = nil,
        initialPrompt: String? = nil,
        titleHint: String? = nil
    ) {
        let commands: String
        if simplifiedForExternal, destinationApp?.usesWarpCommands == true {
            let invocation: String
            if session.isRemote {
                invocation = buildNewSessionUsingProjectProfileCLIInvocation(
                    session: session, project: project, options: options, initialPrompt: initialPrompt)
            } else {
                let execPath = resolvedExecutablePath(
                    for: session.source.baseKind,
                    executableURL: executableURL
                )
                invocation = buildNewSessionUsingProjectProfileCLIInvocation(
                    session: session,
                    project: project,
                    options: options,
                    initialPrompt: initialPrompt,
                    executablePath: execPath
                )
            }
            let extraHost = session.isRemote ? session.remoteHost : nil
            let base = titleHint ?? WarpTitleBuilder.newSessionLabel(
                scope: project.name,
                task: nil,
                extras: extraHost.flatMap { [$0] } ?? []
            )
            let title = warpTitleCommentLine(base)
            if session.isRemote, let host = session.remoteHost {
                let sshContext = resolvedSSHContext(for: host)
                var exportLines: [String] = [
                    "export LANG=zh_CN.UTF-8",
                    "export LC_ALL=zh_CN.UTF-8",
                    "export LC_CTYPE=zh_CN.UTF-8",
                    "export TERM=xterm-256color",
                ]
                if let env = project.profile?.env {
                    for (k, v) in env {
                        let key = k.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !key.isEmpty else { continue }
                        exportLines.append("export \(key)=\(shellSingleQuoted(v))")
                    }
                }
                let remote = buildRemoteShellCommand(
                    session: session,
                    exports: exportLines,
                    invocation: invocation
                )
                let ssh = sshInvocation(host: host, remoteCommand: remote, resolvedArguments: sshContext)
                commands = [title, ssh].compactMap { $0 }.joined(separator: "\n") + "\n"
            } else {
                commands = [title, invocation].compactMap { $0 }.joined(separator: "\n") + "\n"
            }
        } else {
            commands =
                simplifiedForExternal
                ? buildExternalNewSessionUsingProjectProfileCommands(
                    session: session, project: project, executableURL: executableURL, options: options,
                    initialPrompt: initialPrompt)
                : buildNewSessionUsingProjectProfileCommandLines(
                    session: session, project: project, executableURL: executableURL, options: options,
                    initialPrompt: initialPrompt)
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(commands, forType: .string)
    }

    // MARK: - Resume (detail) respecting Project Profile
    private func buildResumeArguments(
        using project: Project, fallbackModel: String?, options: ResumeOptions
    ) -> [String] {
        var args: [String] = []
        let pid = project.profileId?.trimmingCharacters(in: .whitespaces)

        // Always use -c to inject inline profile (zero-write approach)
        // Only select profile; do not pass flags to preserve original resume semantics
        if let pid, !pid.isEmpty {
            // Compute effective approval/sandbox for resume inline profile
            // approval: prefer explicit; else options; else default on-request
            // sandbox: prefer explicit; else Danger Bypass => danger-full-access; else options; else default workspace-write
            var approvalRaw: String? = project.profile?.approval?.rawValue
            var sandboxRaw: String? = project.profile?.sandbox?.rawValue
            if sandboxRaw == nil {
                if project.profile?.dangerouslyBypass == true {
                    sandboxRaw = SandboxMode.dangerFullAccess.rawValue
                } else if let opt = options.sandbox?.rawValue {
                    sandboxRaw = opt
                }
            }
            if approvalRaw == nil {
                if let opt = options.approval?.rawValue {
                    approvalRaw = opt
                } else {
                    approvalRaw = ApprovalPolicy.onRequest.rawValue
                }
            }
            if sandboxRaw == nil { sandboxRaw = SandboxMode.workspaceWrite.rawValue }

            if let inline = renderInlineProfileConfig(
                key: pid,
                model: project.profile?.model ?? fallbackModel,
                approvalPolicy: approvalRaw,
                sandboxMode: sandboxRaw
            ) {
                // Zero-write: inject the inline profile and select it
                args += ["--profile", pid, "-c", inline]
            }
        }
        return args
    }

    func buildResumeUsingProjectProfileCLIInvocation(
        session: SessionSummary, project: Project, options: ResumeOptions
    ) -> String {
        // Choose executable based on session source; select profile (no flags for Claude).
        let exe = executableName(for: session.source.baseKind)
        var parts: [String] = [exe]

        // For Claude, profiles don't apply; use simple resume command.
        if session.source.baseKind == .claude {
            parts.append("--resume")
            parts.append(session.id)
            return parts.joined(separator: " ")
        }

        // For Codex, place flags + profile before subcommand: codex <flags> --profile <pid> resume <id>
        let globalFlags = flags(from: options).map { arg -> String in
            arg.contains(where: { $0.isWhitespace || $0 == "'" }) ? shellEscapedPath(arg) : arg
        }
        let args = buildResumeArguments(
            using: project, fallbackModel: effectiveCodexModel(for: session), options: options
        ).map { arg -> String in
            if arg.contains(where: { $0.isWhitespace || $0 == "'" }) {
                return shellEscapedPath(arg)
            }
            return arg
        }
        parts.append(contentsOf: globalFlags + args)
        parts.append("resume")
        parts.append(conversationId(for: session))
        return parts.joined(separator: " ")
    }

    func buildResumeUsingProjectProfileCLIInvocation(
        session: SessionSummary, project: Project, executablePath: String, options: ResumeOptions
    ) -> String {
        let exe = shellQuoteIfNeeded(executablePath)
        var parts: [String] = [exe]

        // For Claude, profiles don't apply; use simple resume command.
        if session.source.baseKind == .claude {
            parts.append("--resume")
            parts.append(session.id)
            return parts.joined(separator: " ")
        }

        // For Codex, place flags + profile before subcommand: codex <flags> --profile <pid> resume <id>
        let globalFlags = flags(from: options).map { arg -> String in
            arg.contains(where: { $0.isWhitespace || $0 == "'" }) ? shellEscapedPath(arg) : arg
        }
        let args = buildResumeArguments(
            using: project, fallbackModel: effectiveCodexModel(for: session), options: options
        ).map { arg -> String in
            if arg.contains(where: { $0.isWhitespace || $0 == "'" }) {
                return shellEscapedPath(arg)
            }
            return arg
        }
        parts.append(contentsOf: globalFlags + args)
        parts.append("resume")
        parts.append(conversationId(for: session))
        return parts.joined(separator: " ")
    }

    func buildResumeUsingProjectProfileCommandLines(
        session: SessionSummary, project: Project, executableURL: URL, options: ResumeOptions
    ) -> String {
        var exportLines: [String] = [
            "export LANG=zh_CN.UTF-8",
            "export LC_ALL=zh_CN.UTF-8",
            "export LC_CTYPE=zh_CN.UTF-8",
            "export TERM=xterm-256color",
        ]
        if let env = project.profile?.env {
            for (k, v) in env {
                let key = k.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { continue }
                exportLines.append("export \(key)=\(shellSingleQuoted(v))")
            }
        }
        if session.isRemote, let host = session.remoteHost {
            let invocation = buildResumeUsingProjectProfileCLIInvocation(
                session: session, project: project, options: options)
            let sshContext = resolvedSSHContext(for: host)
            let remote = buildRemoteShellCommand(
                session: session,
                exports: exportLines,
                invocation: invocation
            )
            return sshInvocation(
                host: host,
                remoteCommand: remote,
                resolvedArguments: sshContext
            ) + "\n"
        }
        let cwd =
            FileManager.default.fileExists(atPath: session.cwd)
            ? session.cwd : session.fileURL.deletingLastPathComponent().path
        let cd = "cd " + shellEscapedPath(cwd)
        let exports = exportLines.joined(separator: "; ")
        let execPath = resolvedExecutablePath(
            for: session.source.baseKind,
            executableURL: executableURL
        )
        let command = buildResumeUsingProjectProfileCLIInvocation(
            session: session,
            project: project,
            executablePath: execPath,
            options: options
        )
        return cd + "\n" + exports + "\n" + command + "\n"
    }

    func buildExternalResumeUsingProjectProfileCommands(
        session: SessionSummary, project: Project, executableURL: URL, options: ResumeOptions
    ) -> String {
        if session.isRemote, let host = session.remoteHost {
            let sshContext = resolvedSSHContext(for: host)
            var exportLines: [String] = [
                "export LANG=zh_CN.UTF-8",
                "export LC_ALL=zh_CN.UTF-8",
                "export LC_CTYPE=zh_CN.UTF-8",
                "export TERM=xterm-256color",
            ]
            if let env = project.profile?.env {
                for (k, v) in env {
                    let key = k.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !key.isEmpty else { continue }
                    exportLines.append("export \(key)=\(shellSingleQuoted(v))")
                }
            }
            let invocation = buildResumeUsingProjectProfileCLIInvocation(
                session: session, project: project, options: options)
            let remote = buildRemoteShellCommand(
                session: session,
                exports: exportLines,
                invocation: invocation
            )
            return sshInvocation(
                host: host,
                remoteCommand: remote,
                resolvedArguments: sshContext
            ) + "\n"
        }
        let cwd =
            FileManager.default.fileExists(atPath: session.cwd)
            ? session.cwd : session.fileURL.deletingLastPathComponent().path
        let cd = "cd " + shellEscapedPath(cwd)
        let execPath = resolvedExecutablePath(
            for: session.source.baseKind,
            executableURL: executableURL
        )
        let cmd = buildResumeUsingProjectProfileCLIInvocation(
            session: session, project: project, executablePath: execPath, options: options)
        return cd + "\n" + cmd + "\n"
    }

    func copyResumeUsingProjectProfileCommands(
        session: SessionSummary, project: Project, executableURL: URL, options: ResumeOptions,
        simplifiedForExternal: Bool = true,
        destinationApp: ExternalTerminalProfile? = nil,
        titleHint: String? = nil
    ) {
        let commands: String
        if simplifiedForExternal, destinationApp?.usesWarpCommands == true {
            let invocation: String
            if session.isRemote {
                invocation = buildResumeUsingProjectProfileCLIInvocation(
                    session: session, project: project, options: options)
            } else {
                let execPath = resolvedExecutablePath(
                    for: session.source.baseKind,
                    executableURL: executableURL
                )
                invocation = buildResumeUsingProjectProfileCLIInvocation(
                    session: session,
                    project: project,
                    executablePath: execPath,
                    options: options
                )
            }
            let title = warpTitleCommentLine(titleHint ?? session.effectiveTitle)
            if session.isRemote, let host = session.remoteHost {
                let sshContext = resolvedSSHContext(for: host)
                var exportLines: [String] = [
                    "export LANG=zh_CN.UTF-8",
                    "export LC_ALL=zh_CN.UTF-8",
                    "export LC_CTYPE=zh_CN.UTF-8",
                    "export TERM=xterm-256color",
                ]
                if let env = project.profile?.env {
                    for (k, v) in env {
                        let key = k.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !key.isEmpty else { continue }
                        exportLines.append("export \(key)=\(shellSingleQuoted(v))")
                    }
                }
                let remote = buildRemoteShellCommand(
                    session: session,
                    exports: exportLines,
                    invocation: invocation
                )
                let ssh = sshInvocation(host: host, remoteCommand: remote, resolvedArguments: sshContext)
                commands = [title, ssh].compactMap { $0 }.joined(separator: "\n") + "\n"
            } else {
                commands = [title, invocation].compactMap { $0 }.joined(separator: "\n") + "\n"
            }
        } else {
            commands =
                simplifiedForExternal
                ? buildExternalResumeUsingProjectProfileCommands(
                    session: session, project: project, executableURL: executableURL, options: options)
                : buildResumeUsingProjectProfileCommandLines(
                    session: session, project: project, executableURL: executableURL, options: options)
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(commands, forType: .string)
    }

    @discardableResult
    func openNewSessionUsingProjectProfile(
        session: SessionSummary, project: Project, executableURL: URL, options: ResumeOptions,
        initialPrompt: String? = nil
    ) -> Bool {
        let scriptText = {
            let lines = buildNewSessionUsingProjectProfileCommandLines(
                session: session, project: project, executableURL: executableURL, options: options,
                initialPrompt: initialPrompt
            )
            .replacingOccurrences(of: "\n", with: "; ")
            return """
                tell application "Terminal"
                  activate
                  do script "\(lines)"
                end tell
                """
        }()

        if let script = NSAppleScript(source: scriptText) {
            var errorDict: NSDictionary?
            script.executeAndReturnError(&errorDict)
            return errorDict == nil
        }
        return false
    }

    // MARK: - Helpers
    private func shellSingleQuoted(_ v: String) -> String {
        "'" + v.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func copyRealResumeInvocation(
        session: SessionSummary, executableURL: URL, options: ResumeOptions
    ) {
        let command: String
        if session.isRemote, let host = session.remoteHost {
            let sshContext = resolvedSSHContext(for: host)
            let remote = buildRemoteResumeShellCommand(
                session: session,
                options: options
            )
            command = sshInvocation(
                host: host,
                remoteCommand: remote,
                resolvedArguments: sshContext
            )
        } else {
            let execName = resolvedExecutablePath(
                for: session.source.baseKind,
                executableURL: executableURL
            )
            command = buildResumeCLIInvocation(
            session: session, executablePath: execName, options: options)
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(command + "\n", forType: .string)
    }
}

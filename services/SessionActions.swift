import AppKit
import Foundation

struct ProcessResult {
    let output: String
}

enum SessionActionError: LocalizedError {
    case executableNotFound(URL)
    case resumeFailed(output: String)
    case deletionFailed(URL)
    case featureUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let url):
            return "Executable codex CLI not found: \(url.path)"
        case .resumeFailed(let output):
            return "Failed to resume session: \(output)"
        case .deletionFailed(let url):
            return "Failed to move file to Trash: \(url.path)"
        case .featureUnavailable(let message):
            return message
        }
    }
}

struct SessionActions {
    let fileManager: FileManager = .default
    private let codexHome: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex", isDirectory: true)
    private let sshExecutablePath = "/usr/bin/ssh"
    private let defaultPathInjection =
        "source ~/.bashrc; . \"$HOME/.nvm/nvm.sh\"; . \"$HOME/.nvm/bash_completion\""
    private let sshConfigResolver = SSHConfigResolver()
    let terminalLaunchQueue = DispatchQueue(label: "io.umate.codemate.terminalLaunch", qos: .userInitiated)
    
    func configuredProfiles() async -> Set<String> {
        let persisted = listPersistedProfiles()
        // Use listProviders() instead of configuredProfiles() which doesn't exist
        let configured = await codexConfigService.listProviders().map { $0.id }
        let merged = persisted.union(Set(configured))
        return merged
    }

    func resolveModel(for session: SessionSummary) -> String? {
        // For now, just check if the model is non-empty
        // The configuredProfiles check requires async context, so we'll handle it differently
        if session.source.baseKind == .codex {
            if let m = session.model?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty {
                return m
            }
        }
        return session.model
    }

    func resolveExecutableURL(preferred: URL, executableName: String) -> URL? {
        // Prefer user-specified path if it exists
        if fileManager.fileExists(atPath: preferred.path) {
            return preferred
        }
        // Fallback to PATH resolution
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        let components = path.split(separator: ":")
        for component in components {
            let candidate = URL(fileURLWithPath: String(component)).appendingPathComponent(executableName)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Resume helpers (moved to extension to avoid conflicts)
    internal func resumeRemote(
        session: SessionSummary,
        host: String,
        options: ResumeOptions
    ) async throws -> ProcessResult {
        let sshArguments = resolvedSSHContext(for: host)
        let command = buildRemoteResumeShellCommand(
            session: session,
            options: options
        )
        let sshPath = sshExecutablePath
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: sshPath)
                    var arguments: [String] = ["-t"]
                    if let sshArguments {
                        arguments.append(contentsOf: sshArguments)
                    } else {
                        arguments.append(host)
                    }
                    arguments.append(command)
                    process.arguments = arguments

                    let pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = pipe

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
        let escaped = path.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }

    private func shellQuoteIfNeeded(_ text: String) -> String {
        if text.contains(" ") || text.contains(";") || text.contains("&") || text.contains("|") {
            return shellEscapedPath(text)
        }
        return text
    }

    private func shellSingleQuoted(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }

    private func embeddedExportLines(for source: SessionSource) -> [String] {
        var lines: [String] = [
            "export LANG=zh_CN.UTF-8",
            "export LC_ALL=zh_CN.UTF-8",
            "export LC_CTYPE=zh_CN.UTF-8",
            "export TERM=xterm-256color",
        ]
        if source.baseKind == .codex {
            lines.append("export CODEX_DISABLE_COLOR_QUERY=1")
        }
        return lines
    }

    private func workingDirectory(for session: SessionSummary) -> String {
        if session.isRemote {
            let trimmed = session.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
            if let remotePath = session.remotePath {
                let parent = (remotePath as NSString).deletingLastPathComponent
                if !parent.isEmpty { return parent }
            }
            return session.cwd
        }
        if fileManager.fileExists(atPath: session.cwd) {
            return session.cwd
        }
        return session.fileURL.deletingLastPathComponent().path
    }

    private func remoteExecutableName(for session: SessionSummary) -> String {
        session.source.baseKind.cliExecutableName
    }

    func resolvedSSHContext(for alias: String) -> [String]? {
        let hosts = sshConfigResolver.resolvedHosts()
        guard let host = hosts.first(where: { $0.alias.caseInsensitiveCompare(alias) == .orderedSame })
        else { return nil }
        return sshArguments(for: host)
    }

    private func sshArguments(for host: SSHHost) -> [String] {
        var args: [String] = []
        if let user = host.user, !user.isEmpty {
            args += ["-l", user]
        }
        if let port = host.port {
            args += ["-p", String(port)]
        }
        if let identity = host.identityFile, !identity.isEmpty {
            args += ["-i", identity]
        }
        if let proxyJump = host.proxyJump, !proxyJump.isEmpty {
            args += ["-J", proxyJump]
        }
        if let proxyCommand = host.proxyCommand, !proxyCommand.isEmpty {
            args += ["-o", "ProxyCommand=\(proxyCommand)"]
        }
        if let forwardAgent = host.forwardAgent {
            args += ["-o", "ForwardAgent=\(forwardAgent ? "yes" : "no")"]
        }
        args.append(host.hostname ?? host.alias)
        return args
    }

    private func buildSSHInvocation(host: String, arguments: [String]?, remoteCommand: String) -> String {
        let args = arguments ?? [host]
        let sshParts = (["ssh", "-t"] + args).map { shellQuoteIfNeeded($0) }.joined(separator: " ")
        return "\(sshParts) \(shellSingleQuoted(remoteCommand))"
    }

    func remoteResumeInvocationForTerminal(
        session: SessionSummary,
        options: ResumeOptions
    ) -> String? {
        guard session.isRemote, let host = session.remoteHost else { return nil }
        let remoteCommand = buildRemoteResumeShellCommand(session: session, options: options)
        let args = resolvedSSHContext(for: host)
        return buildSSHInvocation(host: host, arguments: args, remoteCommand: remoteCommand)
    }

    func remoteNewInvocationForTerminal(
        session: SessionSummary,
        options: ResumeOptions,
        initialPrompt: String? = nil
    ) -> String? {
        guard session.isRemote, let host = session.remoteHost else { return nil }
        let remoteCommand = buildRemoteNewShellCommand(
            session: session,
            options: options,
            initialPrompt: initialPrompt
        )
        let args = resolvedSSHContext(for: host)
        return buildSSHInvocation(host: host, arguments: args, remoteCommand: remoteCommand)
    }

    func buildRemoteShellCommand(
        session: SessionSummary,
        exports: [String],
        invocation: String
    ) -> String {
        let cwd = workingDirectory(for: session)
        var scriptParts: [String] = [defaultPathInjection]
        scriptParts.append("cd \(shellEscapedPath(cwd))")
        if !exports.isEmpty {
            scriptParts.append(exports.joined(separator: "; "))
        }
        scriptParts.append(invocation)
        let script = scriptParts.joined(separator: "; ")
        let sanitized = script.replacingOccurrences(of: "\"", with: "\\\"")
        return #"bash -lc "\#(sanitized)""#
    }

    func buildRemoteResumeShellCommand(
        session: SessionSummary,
        options: ResumeOptions
    ) -> String {
        let exports = embeddedExportLines(for: session.source)
        let invocation = buildResumeCLIInvocation(
            session: session,
            executablePath: remoteExecutableName(for: session),
            options: options
        )
        return buildRemoteShellCommand(
            session: session,
            exports: exports,
            invocation: invocation
        )
    }

    func buildRemoteNewShellCommand(
        session: SessionSummary,
        options: ResumeOptions,
        initialPrompt: String? = nil
    ) -> String {
        let exports = embeddedExportLines(for: session.source)
        let invocation = buildLocalNewSessionCLIInvocation(
            session: session,
            options: options,
            initialPrompt: initialPrompt
        )
        return buildRemoteShellCommand(
            session: session,
            exports: exports,
            invocation: invocation
        )
    }

    private func flags(from options: ResumeOptions) -> [String] {
        // Highest precedence: dangerously bypass
        if options.dangerouslyBypass { return ["--dangerously-bypass-approvals-and-sandbox"] }
        // Next: sandbox mode
        switch options.sandbox {
        case .none: return []
        case .readOnly: return ["--sandbox=read-only"]
        case .workspaceWrite: return ["--sandbox=workspace-write"]
        case .dangerFullAccess: return ["--sandbox=danger-full-access"]
        }
    }

    // Note: buildResumeArguments and buildClaudeResumeArguments are implemented in SessionActions+Commands.swift
    // to avoid conflicts

    // Note: buildNewSessionCLIInvocation is implemented in SessionActions+Commands.swift
    // to avoid conflicts

    // Note: buildResumeCommandLines is implemented in SessionActions+Commands.swift
    // to avoid conflicts

    // Note: buildNewSessionCommandLines is implemented in SessionActions+Commands.swift
    // to avoid conflicts

    // Note: buildExternalResumeCommands is implemented in SessionActions+Commands.swift
    // to avoid conflicts

    // Additional helper methods would continue here...
    // For brevity, I'll add the essential ones needed for remote support

    private func conversationId(for session: SessionSummary) -> String {
        return session.id
    }

    private let codexConfigService = CodexConfigService()
}

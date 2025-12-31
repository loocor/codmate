import Foundation
import OSLog

enum RemoteSessionKind: String, Sendable {
    case codex
    case claude

    var remoteBasePath: String {
        switch self {
        case .codex: return "$HOME/.codex/sessions"
        case .claude: return "$HOME/.claude/projects"
        }
    }

    var cacheComponent: String {
        switch self {
        case .codex: return "codex"
        case .claude: return "claude"
        }
    }
}

struct RemoteMirrorOutcome {
    let localRoot: URL
    let fileMap: [URL: MirroredFile]

    struct MirroredFile {
        let remotePath: String
        let remoteTimestamp: TimeInterval
    }
}

actor RemoteSessionMirror {
    private let fileManager: FileManager
    private let cacheRoot: URL
    private let logger = Logger(subsystem: "io.umate.codemate", category: "RemoteSessionMirror")
    private static let sshExecutable = "/usr/bin/ssh"
    private static let scpExecutable = "/usr/bin/scp"
    private static let rsyncExecutable = "/usr/bin/rsync"
    private static let sshDefaultOptions: [String] = [
        "-o", "ControlMaster=no",
        "-o", "ControlPersist=no",
        "-o", "ControlPath=none",
        "-o", "ServerAliveInterval=60",
        "-o", "ServerAliveCountMax=3",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "HashKnownHosts=yes"
    ]

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CodMate", isDirectory: true)
            .appendingPathComponent("remote", isDirectory: true)
        self.cacheRoot = base
        try? fileManager.createDirectory(at: base, withIntermediateDirectories: true)
    }

    func ensureMirror(
        host: SSHHost,
        kind: RemoteSessionKind,
        scope: SessionLoadScope
    ) async throws -> RemoteMirrorOutcome {
        let localHostRoot = cacheRoot.appendingPathComponent(host.alias, isDirectory: true)
            .appendingPathComponent(kind.cacheComponent, isDirectory: true)
        try? fileManager.createDirectory(at: localHostRoot, withIntermediateDirectories: true)

        let remoteListing = try fetchRemoteListing(host: host, kind: kind, scope: scope)
        var pendingDownloads: [PendingDownload] = []
        var fileMap: [URL: RemoteMirrorOutcome.MirroredFile] = [:]

        for entry in remoteListing {
            let localURL = localHostRoot.appendingPathComponent(entry.relativePath, isDirectory: false)
            try? fileManager.createDirectory(
                at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if needsDownload(localURL: localURL, remoteSize: entry.size, remoteTimestamp: entry.timestamp) {
                pendingDownloads.append(.init(entry: entry, localURL: localURL))
            }
            fileMap[localURL] = .init(
                remotePath: entry.absolutePath,
                remoteTimestamp: entry.timestamp
            )
        }

        if !pendingDownloads.isEmpty {
            do {
                try downloadBatch(
                    host: host,
                    kind: kind,
                    localRoot: localHostRoot,
                    downloads: pendingDownloads
                )
            } catch {
                logger.warning(
                    "rsync fetch failed for host=\(host.alias, privacy: .public) count=\(pendingDownloads.count) error=\(String(describing: error), privacy: .public); falling back to scp"
                )
                for pending in pendingDownloads {
                    try download(
                        host: host,
                        remoteAbsolutePath: pending.entry.absolutePath,
                        to: pending.localURL
                    )
                    let attributes: [FileAttributeKey: Any] = [
                        .modificationDate: Date(timeIntervalSince1970: pending.entry.timestamp)
                    ]
                    try? fileManager.setAttributes(attributes, ofItemAtPath: pending.localURL.path)
                }
            }
        }

        return RemoteMirrorOutcome(localRoot: localHostRoot, fileMap: fileMap)
    }

    private struct RemoteEntry {
        let relativePath: String
        let absolutePath: String
        let size: UInt64
        let timestamp: TimeInterval
    }

    private struct PendingDownload {
        let entry: RemoteEntry
        let localURL: URL
    }

    private func fetchRemoteListing(
        host: SSHHost,
        kind: RemoteSessionKind,
        scope: SessionLoadScope
    ) throws -> [RemoteEntry] {
        let base = kind.remoteBasePath
        let directories = relativeDirectories(for: scope)
        let searchPaths = directories.isEmpty ? ["."]
            : directories.map { $0.hasPrefix("./") ? $0 : "./\($0)" }

        let command = buildFindCommand(base: base, searchPaths: searchPaths)
        let arguments = buildSSHArguments(for: host, remoteCommand: command)
        let result = try ShellCommandRunner.run(
            executable: Self.sshExecutable,
            arguments: arguments
        )

        let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: true)
        var entries: [RemoteEntry] = []
        entries.reserveCapacity(lines.count)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let components = trimmed.split(separator: "|", omittingEmptySubsequences: false)
            guard components.count >= 3 else { continue }
            var pathComponent = String(components[0])
            if pathComponent.hasPrefix("./") { pathComponent.removeFirst(2) }
            guard !pathComponent.isEmpty else { continue }
            let size = UInt64(components[1]) ?? 0
            let timestamp = TimeInterval(components[2]) ?? 0
            let absolute = joinRemote(base: base, relative: pathComponent)
            entries.append(
                RemoteEntry(
                    relativePath: pathComponent,
                    absolutePath: absolute,
                    size: size,
                    timestamp: timestamp
                )
            )
        }
        return entries
    }

    private func downloadBatch(
        host: SSHHost,
        kind: RemoteSessionKind,
        localRoot: URL,
        downloads: [PendingDownload]
    ) throws {
        guard !downloads.isEmpty else { return }

        let remoteBase = normalizeRemoteBaseForTransfer(kind.remoteBasePath)
        let manifest = downloads.map { $0.entry.relativePath }.joined(separator: "\n")
        let tempDirectory = fileManager.temporaryDirectory
        let manifestURL = tempDirectory.appendingPathComponent(
            "codemate-rsync-\(UUID().uuidString).lst",
            isDirectory: false
        )
        try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: manifestURL) }

        let sshCommand = buildRsyncSSHCommand(for: host)
        let targetHost = connectionTarget(for: host)
        let sourceArg = "\(targetHost):\(remoteBase)/"

        let arguments: [String] = [
            "-e", sshCommand,
            "--archive",
            "--compress",
            "--prune-empty-dirs",
            "--files-from=\(manifestURL.path)",
            sourceArg,
            localRoot.path
        ]

        logger.info(
            "Starting rsync mirror host=\(host.alias, privacy: .public) count=\(downloads.count)"
        )
        try ShellCommandRunner.run(
            executable: Self.rsyncExecutable,
            arguments: arguments
        )

        for pending in downloads {
            let attributes: [FileAttributeKey: Any] = [
                .modificationDate: Date(timeIntervalSince1970: pending.entry.timestamp)
            ]
            try? fileManager.setAttributes(attributes, ofItemAtPath: pending.localURL.path)
        }
    }

    private func download(host: SSHHost, remoteAbsolutePath: String, to localURL: URL) throws {
        let remotePathForSCP: String
        if remoteAbsolutePath.hasPrefix("$HOME") {
            let tail = remoteAbsolutePath.dropFirst("$HOME".count)
            remotePathForSCP = "~" + tail
        } else {
            remotePathForSCP = remoteAbsolutePath
        }

        let arguments = buildSCPArguments(
            for: host,
            remotePath: remotePathForSCP,
            localPath: localURL.path
        )
        logger.info(
            "Fetching via scp host=\(host.alias, privacy: .public) file=\(remotePathForSCP, privacy: .public)"
        )
        try ShellCommandRunner.run(
            executable: Self.scpExecutable,
            arguments: arguments
        )
    }

    private func buildSSHArguments(for host: SSHHost, remoteCommand: String) -> [String] {
        var args = buildBaseSSHOptions(for: host)
        args.append(connectionTarget(for: host))
        args.append(remoteCommand)
        return args
    }

    private func buildSCPArguments(for host: SSHHost, remotePath: String, localPath: String) -> [String] {
        var args = buildBaseSCPOptions(for: host)
        args += ["-q", "-p"]
        args.append("\(scpConnectionTarget(for: host)):\(remotePath)")
        args.append(localPath)
        return args
    }

    private func buildBaseSSHOptions(for host: SSHHost) -> [String] {
        var args = Self.sshDefaultOptions
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
        return args
    }

    private func buildBaseSCPOptions(for host: SSHHost) -> [String] {
        // SCP has different option syntax than SSH:
        // - No -l flag (user goes in target: user@host:path)
        // - Port uses -P (uppercase) instead of -p
        var args = Self.sshDefaultOptions
        if let port = host.port {
            args += ["-P", String(port)]
        }
        if let identity = host.identityFile, !identity.isEmpty {
            args += ["-i", identity]
        }
        if let proxyJump = host.proxyJump, !proxyJump.isEmpty {
            args += ["-o", "ProxyJump=\(proxyJump)"]
        }
        if let proxyCommand = host.proxyCommand, !proxyCommand.isEmpty {
            args += ["-o", "ProxyCommand=\(proxyCommand)"]
        }
        if let forwardAgent = host.forwardAgent {
            args += ["-o", "ForwardAgent=\(forwardAgent ? "yes" : "no")"]
        }
        return args
    }

    private func buildRsyncSSHCommand(for host: SSHHost) -> String {
        let parts = [Self.sshExecutable] + buildBaseSSHOptions(for: host)
        return parts.map(shellEscaped).joined(separator: " ")
    }

    private func connectionTarget(for host: SSHHost) -> String {
        host.hostname ?? host.alias
    }

    private func scpConnectionTarget(for host: SSHHost) -> String {
        // SCP requires user@host format (doesn't support -l flag)
        let hostname = host.hostname ?? host.alias
        // If hostname already contains @, don't add user prefix to avoid user@user@host
        guard !hostname.contains("@") else { return hostname }
        if let user = host.user, !user.isEmpty {
            return "\(user)@\(hostname)"
        }
        return hostname
    }

    private func shellEscaped(_ argument: String) -> String {
        guard argument.contains(where: { $0.isWhitespace || $0 == "'" || $0 == "\"" }) else {
            return argument
        }
        return "'\(argument.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private func buildFindCommand(base: String, searchPaths: [String]) -> String {
        let quotedBase = doubleQuoted(base)
        let pathArgs = searchPaths.map { doubleQuoted($0) }.joined(separator: " ")
        // Use /bin/sh -c to ensure POSIX shell execution regardless of remote login shell (e.g., fish)
        // Use double quotes for find arguments to avoid nested single-quote escaping complexity
        let innerCommand = "cd \(quotedBase) && { find \(pathArgs) -type f -name \"*.jsonl\" -printf \"%p|%s|%T@\\n\" 2>/dev/null || true; }"
        return "/bin/sh -c '\(innerCommand.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func needsDownload(localURL: URL, remoteSize: UInt64, remoteTimestamp: TimeInterval) -> Bool {
        guard let attrs = try? fileManager.attributesOfItem(atPath: localURL.path) else { return true }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        guard size == remoteSize else { return true }
        if let mtime = attrs[.modificationDate] as? Date {
            let delta = abs(mtime.timeIntervalSince1970 - remoteTimestamp)
            if delta > 0.5 { return true }
        } else {
            return true
        }
        return false
    }

    private func normalizeRemoteBaseForTransfer(_ base: String) -> String {
        if base.hasPrefix("$HOME") {
            let tail = base.dropFirst("$HOME".count)
            if tail.hasPrefix("/") {
                return "~" + tail
            }
            return "~/" + tail
        }
        return base
    }

    private func relativeDirectories(for scope: SessionLoadScope) -> [String] {
        let calendar = Calendar.current
        switch scope {
        case .all:
            return []
        case .today:
            let today = calendar.startOfDay(for: Date())
            return [formatDayComponents(calendar: calendar, date: today)]
        case .day(let date):
            let start = calendar.startOfDay(for: date)
            return [formatDayComponents(calendar: calendar, date: start)]
        case .month(let date):
            let comps = calendar.dateComponents([.year, .month], from: date)
            guard let year = comps.year, let month = comps.month else { return [] }
            return [String(format: "%04d/%02d", year, month)]
        }
    }

    private func formatDayComponents(calendar: Calendar, date: Date) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = comps.year, let month = comps.month, let day = comps.day else { return "." }
        return String(format: "%04d/%02d/%02d", year, month, day)
    }

    private func doubleQuoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func joinRemote(base: String, relative: String) -> String {
        if base.hasSuffix("/") {
            return base + relative
        }
        return base + "/" + relative
    }
}

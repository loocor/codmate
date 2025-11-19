import Darwin
import Foundation
import OSLog

// Actor responsible for interacting with Git in a given working tree.
// Uses `/usr/bin/env git` and a robust PATH as per CLI integration guidance.
actor GitService {
    private static let log = Logger(subsystem: "ai.codmate.app", category: "Git")
    struct Change: Identifiable, Sendable, Hashable {
        enum Kind: String, Sendable { case modified, added, deleted, untracked }
        let id = UUID()
        var path: String
        var staged: Kind?
        var worktree: Kind?
    }

    struct FileChange: Identifiable, Sendable, Hashable {
        let id = UUID()
        var path: String
        var statusCode: String
        var oldPath: String?

        var statusLetter: String {
            guard let first = statusCode.first else { return "?" }
            return String(first)
        }
    }

    struct Repo: Sendable, Hashable {
        var root: URL
    }

    struct VisibleFilesResult: Sendable {
        var paths: [String]
        var truncated: Bool
    }

    private static let realHomeDirectory: String = {
        let fmHome = FileManager.default.homeDirectoryForCurrentUser.path
        if !fmHome.isEmpty { return fmHome }
        if let pwDir = getpwuid(getuid())?.pointee.pw_dir {
            return String(cString: pwDir)
        }
        if let envHome = ProcessInfo.processInfo.environment["HOME"], !envHome.isEmpty {
            return envHome
        }
        return NSHomeDirectory()
    }()

    private let envPATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    private let gitCandidates: [String] = GitService.detectGitCandidates()
    private var blockedExecutables: Set<String> = []
    private var lastFailureDescription: String?

    private static func detectGitCandidates() -> [String] {
        let fm = FileManager.default
        var seen: Set<String> = []
        var out: [String] = []
        func append(_ path: String) {
            guard !seen.contains(path) else { return }
            seen.insert(path)
            if fm.isExecutableFile(atPath: path) {
                out.append(path)
            }
        }
        let preferred = [
            "/Library/Developer/CommandLineTools/usr/bin/git",
            "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
            "/Applications/Xcode-beta.app/Contents/Developer/usr/bin/git",
            "/usr/bin/git",
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
        ]
        for path in preferred { append(path) }
        if !seen.contains("/usr/bin/git") {
            append("/usr/bin/git")
        }
        return out
    }

    // Discover the git repository root for a directory, or nil if not a repo
    func repositoryRoot(for directory: URL) async -> Repo? {
        guard let out = try? await runGit(["rev-parse", "--show-toplevel"], cwd: directory),
              out.exitCode == 0
        else { return nil }
        let raw = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return Repo(root: URL(fileURLWithPath: raw, isDirectory: true))
    }

    // Aggregate staged/unstaged/untracked status. Prefer name-status to preserve kind when cheap.
    func status(in repo: Repo) async -> [Change] {
        // Parse name-status for both staged and unstaged; fall back to name-only semantics if parsing fails
        let stagedMap: [String: Change.Kind]
        if let out = try? await runGit(["diff", "--name-status", "--cached", "-z"], cwd: repo.root) {
            stagedMap = Self.parseNameStatusZ(out.stdout)
        } else {
            stagedMap = [:]
        }
        
        let unstagedMap: [String: Change.Kind]
        if let out = try? await runGit(["diff", "--name-status", "-z"], cwd: repo.root) {
            unstagedMap = Self.parseNameStatusZ(out.stdout)
        } else {
            unstagedMap = [:]
        }
        
        let untrackedNames = (try? await runGit(["ls-files", "--others", "--exclude-standard", "-z"], cwd: repo.root))?.stdout.split(separator: "\0").map { String($0) } ?? []

        var map: [String: Change] = [:]
        func ensure(_ path: String) -> Change {
            if let c = map[path] { return c }
            let c = Change(path: path, staged: nil, worktree: nil)
            map[path] = c
            return c
        }
        // staged
        for (name, kind) in stagedMap where !name.isEmpty {
            var c = ensure(name)
            c.staged = kind
            map[name] = c
        }
        // unstaged
        for (name, kind) in unstagedMap where !name.isEmpty {
            var c = ensure(name)
            c.worktree = kind
            map[name] = c
        }
        // untracked
        for name in untrackedNames where !name.isEmpty {
            var c = ensure(name)
            c.worktree = .untracked
            map[name] = c
        }

        var result = Array(map.values).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        if result.isEmpty {
            // Fallback: parse porcelain output if name-status produced nothing (e.g., some git configs)
            if let out = try? await runGit(["status", "--porcelain", "-z"], cwd: repo.root) {
                let (stagedF, worktreeF, untrackedF) = Self.parsePorcelainZ(out.stdout)
                var fmap: [String: Change] = [:]
                func ensure(_ p: String) -> Change { if let c = fmap[p] { return c }; let c = Change(path: p, staged: nil, worktree: nil); fmap[p] = c; return c }
                for (p, k) in stagedF { var c = ensure(p); c.staged = k; fmap[p] = c }
                for (p, k) in worktreeF { var c = ensure(p); c.worktree = k; fmap[p] = c }
                for p in untrackedF { var c = ensure(p); c.worktree = .untracked; fmap[p] = c }
                result = Array(fmap.values).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            }
        }
        return result
    }

    func listVisibleFiles(in repo: Repo, limit: Int) async -> VisibleFilesResult? {
        let arguments = ["ls-files", "-co", "--exclude-standard", "-z"]
        guard let out = try? await runGit(arguments, cwd: repo.root),
              out.exitCode == 0
        else {
            return nil
        }
        let components = out.stdout.split(separator: "\0", omittingEmptySubsequences: false)
        let maxEntries = limit > 0 ? limit : Int.max
        var paths: [String] = []
        paths.reserveCapacity(min(components.count, maxEntries))
        var truncated = false
        for component in components {
            if component.isEmpty { continue }
            if paths.count >= maxEntries {
                truncated = true
                break
            }
            paths.append(String(component))
        }
        if components.count > maxEntries {
            truncated = true
        }
        return VisibleFilesResult(paths: paths, truncated: truncated)
    }

    // Minimal parser for `git diff --name-status -z` output.
    // Handles: M/A/D/T/U and R/C (renames, copies) by attributing to the new path as modified.
    private static func parseNameStatusZ(_ stdout: String) -> [String: Change.Kind] {
        var result: [String: Change.Kind] = [:]
        let tokens = stdout.split(separator: "\0").map(String.init)
        var i = 0
        while i < tokens.count {
            let status = tokens[i]
            guard i + 1 < tokens.count else { break }
            let path1 = tokens[i + 1]
            var pathOut = path1
            var kind: Change.Kind = .modified
            // Normalize leading letter
            let code = status.first.map(String.init) ?? "M"
            switch code {
            case "A": kind = .added
            case "D": kind = .deleted
            case "M", "T", "U": kind = .modified
            case "R", "C":
                // Renames/Copies provide an extra path; choose the new path when present
                if i + 2 < tokens.count {
                    pathOut = tokens[i + 2]
                    i += 1 // consume the extra path as well below
                }
                kind = .modified
            default:
                kind = .modified
            }
            result[pathOut] = kind
            i += 2
        }
        return result
    }

    // Parse `git status --porcelain -z` into staged/worktree/untracked sets
    private static func parsePorcelainZ(_ stdout: String) -> ([String: Change.Kind], [String: Change.Kind], [String]) {
        let tokens = stdout.split(separator: "\0").map(String.init)
        var i = 0
        var staged: [String: Change.Kind] = [:]
        var worktree: [String: Change.Kind] = [:]
        var untracked: [String] = []
        func kind(for code: Character) -> Change.Kind {
            switch code {
            case "A": return .added
            case "D": return .deleted
            case "M", "T", "U": return .modified
            default: return .modified
            }
        }
        while i < tokens.count {
            let entry = tokens[i]
            guard entry.count >= 2 else { break }
            let x = entry.first!  // index
            let y = entry.dropFirst().first!  // worktree
            var path = String(entry.dropFirst(3)) // usually starts at index 3: "XY "
            // Renames show as Rxxx or Cxxx followed by NUL then new path
            if x == "R" || x == "C" {
                // Next token is the new path
                if i + 1 < tokens.count { path = tokens[i+1]; i += 1 }
            }
            if x == "?" && y == "?" {
                untracked.append(path)
            } else {
                if x != " " { staged[path] = kind(for: x) }
                if y != " " { worktree[path] = kind(for: y) }
            }
            i += 1
        }
        return (staged, worktree, untracked)
    }

    // Unified diff for the file; staged toggles --cached
    func diff(in repo: Repo, path: String, staged: Bool) async -> String {
        let args = ["diff", staged ? "--cached" : "", "--", path].filter { !$0.isEmpty }
        if let out = try? await runGit(args, cwd: repo.root) {
            return out.stdout
        }
        return ""
    }

    // Unified diff for all staged changes (index vs HEAD). Large outputs are returned as-is;
    // callers should truncate if needed before sending to external systems.
    func stagedUnifiedDiff(in repo: Repo) async -> String {
        if let out = try? await runGit(["diff", "--cached"], cwd: repo.root) {
            return out.stdout
        }
        return ""
    }

    // Read file content from the worktree for preview
    func readFile(in repo: Repo, path: String, maxBytes: Int = 1_000_000) async -> String {
        let url = repo.root.appendingPathComponent(path)
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        let data = try? h.read(upToCount: maxBytes)
        if let d = data, let s = String(data: d, encoding: .utf8) { return s }
        return ""
    }

    // Stage/unstage operations
    func stage(in repo: Repo, paths: [String]) async {
        guard !paths.isEmpty else { return }
        // Use -A to ensure deletions are staged as well
        _ = try? await runGit(["add", "-A", "--"] + paths, cwd: repo.root)
    }

    func unstage(in repo: Repo, paths: [String]) async {
        guard !paths.isEmpty else { return }
        _ = try? await runGit(["restore", "--staged", "--"] + paths, cwd: repo.root)
    }

    func commit(in repo: Repo, message: String) async -> Int32 {
        let msg = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else { return -1 }
        let out = try? await runGit(["commit", "-m", msg], cwd: repo.root)
        return out?.exitCode ?? -1
    }

    // Discard only worktree (unstaged) changes for specific paths, preserving the index.
    func discardWorktree(in repo: Repo, paths: [String]) async -> Int32 {
        guard !paths.isEmpty else { return 0 }
        let out = try? await runGit(["restore", "--worktree", "--"] + paths, cwd: repo.root)
        return out?.exitCode ?? -1
    }

    // Discard tracked changes (both index and worktree) for specific paths
    func discardTracked(in repo: Repo, paths: [String]) async -> Int32 {
        guard !paths.isEmpty else { return 0 }
        let out = try? await runGit(["restore", "--staged", "--worktree", "--"] + paths, cwd: repo.root)
        return out?.exitCode ?? -1
    }

    // Remove untracked files for specific paths
    func cleanUntracked(in repo: Repo, paths: [String]) async -> Int32 {
        guard !paths.isEmpty else { return 0 }
        let out = try? await runGit(["clean", "-f", "-d", "--"] + paths, cwd: repo.root)
        return out?.exitCode ?? -1
    }

    // MARK: - History APIs (lightweight)
    struct Commit: Identifiable, Sendable, Hashable {
        let id: String            // full SHA
        let shortId: String       // short SHA
        let author: String
        let date: String          // human friendly (relative)
        let subject: String
    }

    struct GraphCommit: Identifiable, Sendable, Hashable {
        let id: String
        let shortId: String
        let author: String
        let date: String
        let subject: String
        let parents: [String]   // full SHAs
        let decorations: [String] // branch/tag names from %D
    }

    /// Return recent commits for the repository, newest first.
    func logCommits(in repo: Repo, limit: Int = 200) async -> [Commit] {
        // Print one commit per line; fields separated by 0x1F (Unit Separator).
        // Avoid NULs in arguments and output to keep parsing simple and safe.
        let fmt = "%H%x1f%h%x1f%an%x1f%ad%x1f%s"
        let args = [
            "log",
            "--no-color",
            "--date=relative",
            "--pretty=format:\(fmt)",
            "-n", String(max(1, limit))
        ]
        guard let out = try? await runGit(args, cwd: repo.root), out.exitCode == 0 else {
            return []
        }
        let lines = out.stdout.split(separator: "\n")
        var commits: [Commit] = []
        commits.reserveCapacity(lines.count)
        for line in lines {
            let parts = line.split(separator: "\u{001f}", omittingEmptySubsequences: false).map(String.init)
            if parts.count >= 5 {
                commits.append(Commit(id: parts[0], shortId: parts[1], author: parts[2], date: parts[3], subject: parts[4]))
            }
        }
        return commits
    }

    /// Files changed in a given commit, including change type/status.
    func filesChanged(in repo: Repo, commitId: String) async -> [FileChange] {
        // diff-tree gives reliable name-status output, including renames/copies.
        let args = ["diff-tree", "--no-commit-id", "--name-status", "-r", commitId]
        guard let out = try? await runGit(args, cwd: repo.root), out.exitCode == 0 else {
            return []
        }
        var results: [FileChange] = []
        for rawLine in out.stdout.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            let components = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard let status = components.first, !status.isEmpty else { continue }
            let code = status
            if let first = status.first, first == "R" || first == "C" {
                // Rename/Copy: expect "R100\told\tnew"
                guard components.count >= 3 else { continue }
                let oldPath = components[1]
                let newPath = components[2]
                results.append(FileChange(path: newPath, statusCode: code, oldPath: oldPath))
            } else {
                guard components.count >= 2 else { continue }
                let path = components[1]
                results.append(FileChange(path: path, statusCode: code, oldPath: nil))
            }
        }
        return results
    }

    /// Unified diff patch for a specific commit against its first parent.
    func commitPatch(in repo: Repo, commitId: String) async -> String {
        // --pretty=format: to suppress commit header; we render header in UI.
        // --no-ext-diff to avoid external diff tools, --no-color for clean parsing.
        let args = ["show", "--pretty=format:", "--no-ext-diff", "--no-color", commitId]
        guard let out = try? await runGit(args, cwd: repo.root), out.exitCode == 0 else { return "" }
        return out.stdout
    }

    /// Unified diff patch for a specific file in a given commit.
    func filePatch(in repo: Repo, commitId: String, path: String) async -> String {
        // Restrict git show to a single path; suppress commit header and external diff tools.
        let args = ["show", "--pretty=format:", "--no-ext-diff", "--no-color", commitId, "--", path]
        guard let out = try? await runGit(args, cwd: repo.root), out.exitCode == 0 else { return "" }
        return out.stdout
    }

    /// Full commit message (subject + body) for a given commit.
    func commitMessage(in repo: Repo, commitId: String) async -> String {
        let args = ["show", "-s", "--format=%B", "--no-color", commitId]
        guard let out = try? await runGit(args, cwd: repo.root), out.exitCode == 0 else { return "" }
        return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Fetch all remotes (equivalent to `git fetch --all --prune`).
    func fetchAllRemotes(in repo: Repo) async -> Int32 {
        let args = ["fetch", "--all", "--prune"]
        let out = try? await runGit(args, cwd: repo.root)
        return out?.exitCode ?? -1
    }

    /// Pull the current branch from its upstream in fast-forward mode.
    func pullCurrentBranch(in repo: Repo) async -> Int32 {
        // Prefer fast-forward to avoid interactive merges; users can rebase manually if desired.
        let args = ["pull", "--ff-only"]
        let out = try? await runGit(args, cwd: repo.root)
        return out?.exitCode ?? -1
    }

    /// Push the current branch to its upstream. If no upstream is configured, attempts to
    /// set origin/HEAD as the upstream target automatically.
    func pushCurrentBranch(in repo: Repo) async -> Int32 {
        // Check whether an upstream is already configured.
        let upstream = try? await runGit(
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
            cwd: repo.root
        )
        if upstream?.exitCode == 0 {
            let out = try? await runGit(["push"], cwd: repo.root)
            return out?.exitCode ?? -1
        } else {
            // Determine current branch name; fallback to HEAD if detection fails.
            let branch = try? await runGit(["rev-parse", "--abbrev-ref", "HEAD"], cwd: repo.root)
            let name = branch?.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if let current = name, !current.isEmpty, current != "HEAD" {
                let out = try? await runGit(
                    ["push", "--set-upstream", "origin", current],
                    cwd: repo.root
                )
                return out?.exitCode ?? -1
            } else {
                let out = try? await runGit(
                    ["push", "--set-upstream", "origin", "HEAD"],
                    cwd: repo.root
                )
                return out?.exitCode ?? -1
            }
        }
    }

    /// Full graph-friendly commit list with parents and decorations. Optional inclusion of remotes.
    /// If `singleRef` is provided, only that ref is listed (overrides other branch toggles).
    func logGraphCommits(
        in repo: Repo,
        limit: Int = 300,
        includeAllBranches: Bool = true,
        includeRemoteBranches: Bool = true,
        singleRef: String? = nil
    ) async -> [GraphCommit] {
        var revArgs: [String] = []
        if let single = singleRef, !single.isEmpty {
            revArgs = [single]
        } else if includeAllBranches {
            revArgs.append(includeRemoteBranches ? "--all" : "--branches")
        } else {
            // default HEAD current branch only; explicit to be safe
            revArgs.append("HEAD")
        }

        let fmt = "%H%x1f%h%x1f%an%x1f%ad%x1f%s%x1f%P%x1f%D"
        var args = [
            "log",
            "--no-color",
            "--date=relative",
            "--decorate=short",
            "--topo-order",
            "--pretty=format:\(fmt)",
            "-n", String(max(1, limit))
        ]
        args += revArgs

        guard let out = try? await runGit(args, cwd: repo.root), out.exitCode == 0 else {
            return []
        }
        let lines = out.stdout.split(separator: "\n")
        var list: [GraphCommit] = []
        list.reserveCapacity(lines.count)
        for line in lines {
            let parts = line.split(separator: "\u{001f}", omittingEmptySubsequences: false).map(String.init)
            if parts.count >= 7 {
                let parents = parts[5].split(separator: " ").map(String.init)
                let decosRaw = parts[6]
                let decorations: [String] = decosRaw.split(separator: ",").map { s in
                    var t = s.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("HEAD -> ") { t = String(t.dropFirst("HEAD -> ".count)) }
                    return t
                }.filter { !$0.isEmpty }
                list.append(GraphCommit(
                    id: parts[0], shortId: parts[1], author: parts[2], date: parts[3], subject: parts[4],
                    parents: parents, decorations: decorations
                ))
            }
        }
        return list
    }

    /// Query commit ids whose subject or body match a case-insensitive query using git --grep.
    func searchCommitIds(
        in repo: Repo,
        query: String,
        includeAllBranches: Bool = true,
        includeRemoteBranches: Bool = true,
        singleRef: String? = nil
    ) async -> Set<String> {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var revArgs: [String] = []
        if let single = singleRef, !single.isEmpty {
            revArgs = [single]
        } else if includeAllBranches {
            revArgs.append(includeRemoteBranches ? "--all" : "--branches")
        } else {
            revArgs.append("HEAD")
        }
        var args = [
            "log",
            "--no-color",
            "--regexp-ignore-case",
            "--grep", q,
            "--pretty=format:%H",
            "-n", "10000"
        ]
        args += revArgs
        guard let out = try? await runGit(args, cwd: repo.root), out.exitCode == 0 else { return [] }
        let lines = out.stdout.split(separator: "\n").map(String.init)
        return Set(lines)
    }

    /// List branches. Returns short names. Optionally include remote branches.
    func listBranches(in repo: Repo, includeRemoteBranches: Bool = false) async -> [String] {
        // Local branches
        let localArgs = [
            "for-each-ref",
            "--format=%(refname:short)",
            "refs/heads"
        ]
        var names: [String] = []
        if let out = try? await runGit(localArgs, cwd: repo.root), out.exitCode == 0 {
            names.append(contentsOf: out.stdout.split(separator: "\n").map(String.init))
        }
        if includeRemoteBranches {
            let remoteArgs = [
                "for-each-ref",
                "--format=%(refname:short)",
                "refs/remotes"
            ]
            if let out = try? await runGit(remoteArgs, cwd: repo.root), out.exitCode == 0 {
                names.append(contentsOf: out.stdout.split(separator: "\n").map(String.init))
            }
        }
        // De-duplicate and sort natural-ish
        let unique = Array(Set(names)).filter { !$0.isEmpty }
        return unique.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: - Helpers
    private struct ProcOut { let stdout: String; let stderr: String; let exitCode: Int32 }

    func takeLastFailureDescription() -> String? {
        let message = lastFailureDescription
        lastFailureDescription = nil
        return message
    }

    private func runGit(_ args: [String], cwd: URL) async throws -> ProcOut {
        var lastError: ProcOut? = nil
        let home = Self.realHomeDirectory
        #if DEBUG
        Self.log.debug("Running git \(args.joined(separator: " "), privacy: .public) in \(cwd.path, privacy: .public)")
        #endif

        let candidates = gitCandidates + ["/usr/bin/env"]
        for path in candidates {
            if blockedExecutables.contains(path) {
                continue
            }
            let proc = Process()
            if path == "/usr/bin/env" {
                proc.executableURL = URL(fileURLWithPath: path)
                proc.arguments = ["git"] + args
            } else {
                proc.executableURL = URL(fileURLWithPath: path)
                proc.arguments = args
            }
            proc.currentDirectoryURL = cwd

            var env = ProcessInfo.processInfo.environment
            // Robust PATH for sandboxed process
            env["PATH"] = envPATH + ":" + (env["PATH"] ?? "")
            // Avoid invoking pagers or external tools
            env["GIT_PAGER"] = "cat"
            env["GIT_EDITOR"] = ":"
            env["GIT_OPTIONAL_LOCKS"] = "0"
            // Prevent reading global/system configs that may live outside sandbox
            env["GIT_CONFIG_NOSYSTEM"] = "0"
            let existingConfigCount = Int(env["GIT_CONFIG_COUNT"] ?? "0") ?? 0
            env["GIT_CONFIG_COUNT"] = String(existingConfigCount + 1)
            env["GIT_CONFIG_KEY_\(existingConfigCount)"] = "safe.directory"
            env["GIT_CONFIG_VALUE_\(existingConfigCount)"] = "*"
            env["HOME"] = home
            if path.contains("/CommandLineTools/") {
                env["DEVELOPER_DIR"] = "/Library/Developer/CommandLineTools"
            } else if path.contains("/Applications/Xcode") {
                env["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
            }
            proc.environment = env

            let outPipe = Pipe(); proc.standardOutput = outPipe
            let errPipe = Pipe(); proc.standardError = errPipe

            do {
                try proc.run()
            } catch {
                #if DEBUG
                Self.log.debug("Failed to launch \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                #endif
                if path != "/usr/bin/env" {
                    blockedExecutables.insert(path)
                }
                continue
            }
            let outData = try outPipe.fileHandleForReading.readToEnd() ?? Data()
            let errData = try errPipe.fileHandleForReading.readToEnd() ?? Data()
            proc.waitUntilExit()
            let stdout = String(data: outData, encoding: .utf8) ?? ""
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            let out = ProcOut(stdout: stdout, stderr: stderr, exitCode: proc.terminationStatus)
            if out.exitCode == 0 {
                #if DEBUG
                Self.log.debug("git succeeded via \(path, privacy: .public)")
                #endif
                return out
            }
            #if DEBUG
            Self.log.debug("git via \(path, privacy: .public) exited with code \(out.exitCode, privacy: .public)")
            #endif
            if path != "/usr/bin/env",
               out.stderr.contains("App Sandbox") || out.stderr.contains("xcrun: error")
            {
                blockedExecutables.insert(path)
            }
            lastError = out
            // Try next candidate
        }
        if let e = lastError {
            Self.log.error("git failed: code=\(e.exitCode, privacy: .public), stderr=\(e.stderr, privacy: .public)")
            let text = e.stderr.isEmpty ? e.stdout : e.stderr
            lastFailureDescription = text.isEmpty ? "git exited with code \(e.exitCode)" : text
            return e
        }
        let fallback = ProcOut(stdout: "", stderr: "failed to launch git", exitCode: -1)
        Self.log.error("git failed to launch via all candidates")
        lastFailureDescription = "git failed to launch via all candidates"
        return fallback
    }
}

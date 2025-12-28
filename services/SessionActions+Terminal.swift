import AppKit
import Foundation

extension SessionActions {
    func openInTerminal(
        session: SessionSummary,
        executableURL: URL,
        options: ResumeOptions,
        workingDirectory: String? = nil,
        codexHome: String? = nil
    ) -> Bool
    {
        #if APPSTORE
        // App Store build: avoid Apple Events. Copy command and open Terminal at directory.
        copyResumeCommands(
            session: session,
            executableURL: executableURL,
            options: options,
            workingDirectory: workingDirectory,
            codexHome: codexHome
        )
        let cwd = self.workingDirectory(for: session, override: workingDirectory)
        _ = openAppleTerminal(at: cwd)
        return true
        #else
        let scriptText = {
            let lines = buildEmbeddedResumeCommandLines(
                session: session,
                executableURL: executableURL,
                options: options,
                workingDirectory: workingDirectory,
                codexHome: codexHome
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
        #endif
    }

    @discardableResult
    func openNewSession(
        session: SessionSummary,
        executableURL: URL,
        options: ResumeOptions,
        codexHome: String? = nil
    ) -> Bool
    {
        #if APPSTORE
        // App Store build: copy command and open Terminal without Apple Events
        copyNewSessionCommands(
            session: session,
            executableURL: executableURL,
            options: options,
            codexHome: codexHome
        )
        let cwd = FileManager.default.fileExists(atPath: session.cwd) ? session.cwd : session.fileURL.deletingLastPathComponent().path
        _ = openAppleTerminal(at: cwd)
        return true
        #else
        let scriptText = {
            let lines = buildEmbeddedNewSessionCommandLines(
                session: session, executableURL: executableURL, options: options, codexHome: codexHome
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
        #endif
    }

    // Open a terminal app without auto-executing; user can paste clipboard
    func openTerminalApp(_ profile: ExternalTerminalProfile) {
        guard let bundleID = profile.resolvedBundleIdentifier else { return }

        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(
                at: appURL, configuration: config, completionHandler: nil)
        }
    }

    // Optional: open using URL schemes (iTerm2 / Warp) when available
    func openTerminalViaScheme(_ profile: ExternalTerminalProfile, directory: String?, command: String? = nil) {
        terminalLaunchQueue.async {
            self.openTerminalViaSchemeSync(profile: profile, directory: directory, command: command)
        }
    }

    private func openTerminalViaSchemeSync(profile: ExternalTerminalProfile, directory: String?, command: String?) {
        let dir = directory ?? NSHomeDirectory()
        switch profile.id {
        case "iterm2":
            if openITermViaAppleScript(directory: dir, command: command) {
                return
            }
            var comps = URLComponents()
            comps.scheme = "iterm2"
            comps.path = "/command"
            comps.queryItems = [URLQueryItem(name: "d", value: dir)]
            if let command {
                comps.queryItems?.append(URLQueryItem(name: "c", value: command))
            }
            if let url = comps.url {
                NSWorkspace.shared.open(url)
            } else {
                openTerminalApp(profile)
            }
        case "warp":
            var comps = URLComponents()
            comps.scheme = "warp"
            comps.host = "action"
            comps.path = "/new_tab"
            comps.queryItems = [URLQueryItem(name: "path", value: dir)]
            if let url = comps.url {
                NSWorkspace.shared.open(url)
            } else {
                openTerminalApp(profile)
            }
        default:
            if profile.isTerminal {
                _ = openAppleTerminal(at: dir)
                return
            }
            if let urlTemplate = profile.urlTemplate,
               let url = buildLaunchURL(template: urlTemplate, directory: dir, command: command, profile: profile) {
                NSWorkspace.shared.open(url)
                return
            }
            openTerminalApp(profile)
        }
    }

    // Open Terminal.app at a given directory (no auto-run). Returns success.
    @discardableResult
    func openAppleTerminal(at directory: String) -> Bool {
        // Use `open -a Terminal <dir>` to spawn a new window in that path
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-a", "Terminal", directory]
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch { return false }
    }

    private func buildLaunchURL(
        template: String,
        directory: String,
        command: String?,
        profile: ExternalTerminalProfile
    ) -> URL? {
        let encodedDir = directory.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? directory
        let encodedCommand: String? = {
            guard let command, profile.supportsCommandResolved else { return nil }
            return command.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? command
        }()
        var result = template.replacingOccurrences(of: "{cwd}", with: encodedDir)
        result = result.replacingOccurrences(of: "{command}", with: encodedCommand ?? "")
        return URL(string: result)
    }

    // MARK: - Warp Launch Configuration
    @discardableResult
    func openWarpLaunchConfig(
        session: SessionSummary,
        options: ResumeOptions,
        executableURL: URL,
        workingDirectory: String? = nil,
        codexHome: String? = nil
    ) -> Bool {
        let cwd = self.workingDirectory(for: session, override: workingDirectory)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folder = home.appendingPathComponent(".warp", isDirectory: true)
            .appendingPathComponent("launch_configurations", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch { /* ignore */  }

        let baseName = "codmate-resume-\(session.id)"
        let fileName = baseName + ".yaml"
        let fileURL = folder.appendingPathComponent(fileName)
        let commandString: String = {
            let execPath = resolvedExecutablePath(
                for: session.source.baseKind,
                executableURL: executableURL
            )
            return buildResumeCLIInvocation(
                session: session,
                executablePath: execPath,
                options: options,
                codexHome: codexHome
            )
        }()

        let yaml = """
            version: 1
            name: CodMate Resume \(session.id)
            windows:
              - tabs:
                  - title: Codex
                    panes:
                      - cwd: \(cwd)
                        commands:
                          - exec: \(commandString)
            """
        do { try yaml.data(using: String.Encoding.utf8)?.write(to: fileURL) } catch {}

        // Prefer warp://launch/<config_name> (Warp resolves in its config dir), fallback to absolute path.
        if let urlByName = URL(string: "warp://launch/\(baseName)") {
            let ok = NSWorkspace.shared.open(urlByName)
            if ok { return true }
        }
        var comps = URLComponents()
        comps.scheme = "warp"
        comps.host = "launch"
        comps.path = "/" + fileURL.path
        if let url = comps.url { return NSWorkspace.shared.open(url) }
        return false
    }
}

// MARK: - iTerm helpers
extension SessionActions {
    private func openITermViaAppleScript(directory: String, command: String?) -> Bool {
        let cdLine = "cd \(shellEscapedPathForScripts(directory))"
        var script = """
        tell application "iTerm2"
          activate
          set newWindow to (create window with default profile)
          tell current session of newWindow
            write text "\(appleScriptEscaped(cdLine))"
        """
        if let command,
           !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            script += """

            write text "\(appleScriptEscaped(command))"
            """
        }
        script += """

          end tell
        end tell
        """
        guard let appleScript = NSAppleScript(source: script) else { return false }
        var errorDict: NSDictionary?
        appleScript.executeAndReturnError(&errorDict)
        return errorDict == nil
    }

    private func shellEscapedPathForScripts(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleScriptEscaped(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\\", with: "\\\\")
        result = result.replacingOccurrences(of: "\"", with: "\\\"")
        result = result.replacingOccurrences(of: "\n", with: "; ")
        result = result.replacingOccurrences(of: "\r", with: "")
        return result
    }
}

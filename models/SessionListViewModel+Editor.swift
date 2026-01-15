import Foundation
import AppKit

extension SessionListViewModel {
    /// Open a project directory in the specified editor
    /// - Parameters:
    ///   - project: The project to open
    ///   - editor: The editor app to use (VSCode, Cursor, Zed, Antigravity)
    /// - Returns: True if successfully opened, false otherwise
    @discardableResult
    func openProjectInEditor(_ project: Project, using editor: EditorApp) -> Bool {
        guard let directory = project.directory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !directory.isEmpty else {
            errorMessage = "Project directory is not set"
            return false
        }

        let dirURL = URL(fileURLWithPath: directory)

        // Verify directory exists
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            errorMessage = "Directory does not exist: \(directory)"
            return false
        }

        // Strategy 1: Try CLI command first (most reliable, supports opening specific directories)
        if let executablePath = findExecutableInPath(editor.cliCommand) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = [directory]
            process.standardOutput = Pipe()
            process.standardError = Pipe()

            do {
                try process.run()
                return true
            } catch {
                // Fall through to Strategy 2
            }
        }

        // Strategy 2: Open via bundle identifier
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
            return true
        }

        // Editor not found
        errorMessage = "\(editor.title) is not installed. Please install it or try a different editor."
        return false
    }

    /// Reveal a project directory in Finder
    /// - Parameter project: The project to reveal
    func revealProjectDirectory(_ project: Project) {
        guard let directory = project.directory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !directory.isEmpty else {
            errorMessage = "Project directory is not set"
            return
        }

        let dirURL = URL(fileURLWithPath: directory)

        // Verify directory exists
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            errorMessage = "Directory does not exist: \(directory)"
            return
        }

        // Reveal in Finder (will activate Finder and select the folder)
        NSWorkspace.shared.activateFileViewerSelecting([dirURL])
    }

    /// Find an executable in the system PATH
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
}

import Foundation
import AppKit

enum EditorApp: String, CaseIterable, Identifiable {
    case vscode
    case cursor
    case zed
    case antigravity

    var id: String { rawValue }
    private static let menuIconSize = NSSize(width: 14, height: 14)

    /// Editors that are currently available on this system.
    /// This is computed once per launch by probing the bundle id and CLI.
    /// Results are sorted alphabetically by title.
    static let installedEditors: [EditorApp] = {
        allCases.filter(\.isInstalled).sorted(by: { $0.title < $1.title })
    }()

    var title: String {
        switch self {
        case .vscode: return "Visual Studio Code"
        case .cursor: return "Cursor"
        case .zed: return "Zed"
        case .antigravity: return "Antigravity"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .vscode: return "com.microsoft.VSCode"
        case .cursor: return "com.todesktop.230313mzl4w4u92"
        case .zed: return "dev.zed.Zed"
        case .antigravity: return "com.google.antigravity"
        }
    }

    var cliCommand: String {
        switch self {
        case .vscode: return "code"
        case .cursor: return "cursor"
        case .zed: return "zed"
        case .antigravity: return "antigravity"
        }
    }

    var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    var menuIcon: NSImage? {
        guard let url = appURL else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        return resizedMenuIcon(image)
    }

    /// Check if the editor is installed on the system
    var isInstalled: Bool {
        // Try to find the app via bundle identifier
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil {
            return true
        }

        // Fallback: check if CLI command is available in PATH
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [cliCommand]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func resizedMenuIcon(_ image: NSImage) -> NSImage {
        let newImage = NSImage(size: Self.menuIconSize)
        newImage.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: Self.menuIconSize),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1.0
        )
        newImage.unlockFocus()
        return newImage
    }
}

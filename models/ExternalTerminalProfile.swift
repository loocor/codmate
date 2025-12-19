import Foundation

struct ExternalTerminalProfile: Identifiable, Codable, Equatable {
    enum CommandStyle: String, Codable {
        case standard
        case warp
    }

    var id: String
    var title: String?
    var bundleIdentifiers: [String]?
    var urlTemplate: String?
    var supportsCommand: Bool?
    var supportsDirectory: Bool?
    var managedByCodMate: Bool?
    var commandStyle: CommandStyle?

    var displayTitle: String {
        let trimmed = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? id : trimmed
    }

    var isNone: Bool { id == "none" }
    var isTerminal: Bool { id == "terminal" }
    var isITerm2: Bool { id == "iterm2" }
    var isWarp: Bool { commandStyleResolved == .warp || id == "warp" }

    var commandStyleResolved: CommandStyle {
        if let commandStyle { return commandStyle }
        return id == "warp" ? .warp : .standard
    }

    var supportsCommandResolved: Bool {
        if let supportsCommand { return supportsCommand }
        if let urlTemplate, urlTemplate.contains("{command}") { return true }
        return isITerm2
    }

    var supportsDirectoryResolved: Bool {
        if let supportsDirectory { return supportsDirectory }
        return true
    }

    var resolvedBundleIdentifier: String? {
        if isTerminal { return "com.apple.Terminal" }
        guard let bundleIdentifiers, !bundleIdentifiers.isEmpty else { return nil }
        return AppAvailability.firstInstalledBundleIdentifier(in: bundleIdentifiers) ?? bundleIdentifiers.first
    }

    var isInstalled: Bool {
        if isTerminal { return true }
        guard let bundleIdentifiers, !bundleIdentifiers.isEmpty else { return false }
        return AppAvailability.isInstalled(bundleIdentifiers: bundleIdentifiers)
    }

    var isAvailable: Bool {
        if isNone || isTerminal { return true }
        if let bundleIdentifiers, !bundleIdentifiers.isEmpty {
            return AppAvailability.isInstalled(bundleIdentifiers: bundleIdentifiers)
        }
        if urlTemplate != nil { return true }
        return false
    }

    var usesWarpCommands: Bool { commandStyleResolved == .warp }
}

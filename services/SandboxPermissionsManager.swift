import Foundation
import SwiftUI

/// Get the real user home directory, not the sandbox container
private func getRealUserHome() -> String {
    // Use POSIX API to get the actual user home directory
    // This works even in sandbox mode
    if let homeDir = getpwuid(getuid())?.pointee.pw_dir {
        return String(cString: homeDir)
    }
    // Fallback to HOME environment variable
    if let home = ProcessInfo.processInfo.environment["HOME"] {
        return home
    }
    // Last resort fallback
    return NSHomeDirectory()
}

/// Manages sandbox permissions for critical directories needed by CodMate
@MainActor
final class SandboxPermissionsManager: ObservableObject {
    static let shared = SandboxPermissionsManager()

    @Published var needsAuthorization: Bool = false
    @Published var missingPermissions: [RequiredDirectory] = []

    enum RequiredDirectory: String, CaseIterable, Identifiable {
        case codexSessions = "~/.codex"
        case claudeSessions = "~/.claude"
        case geminiSessions = "~/.gemini"
        case codmateData = "~/.codmate"
        case sshConfig = "~/.ssh"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .codexSessions: return "Codex Directory"
            case .claudeSessions: return "Claude Code Directory"
            case .geminiSessions: return "Gemini Directory"
            case .codmateData: return "CodMate Data Directory"
            case .sshConfig: return "SSH Configuration"
            }
        }

        var description: String {
            switch self {
            case .codexSessions:
                return "Access Codex session history and data"
            case .claudeSessions:
                return "Access Claude Code projects and sessions"
            case .geminiSessions:
                return "Access Gemini CLI session history"
            case .codmateData:
                return "Access CodMate configuration, notes, and cache"
            case .sshConfig:
                return "Read your ~/.ssh/config file to discover remote hosts"
            }
        }

        var expandedPath: URL {
            // Get the real user home directory, NOT the sandbox container
            let realHomePath = getRealUserHome()
            let path = rawValue.replacingOccurrences(of: "~", with: realHomePath)
            return URL(fileURLWithPath: path)
        }

        /// Bookmark key for this directory
        var bookmarkKey: String {
            switch self {
            case .codexSessions: return "bookmark.codexSessions"
            case .claudeSessions: return "bookmark.claudeSessions"
            case .geminiSessions: return "bookmark.geminiSessions"
            case .codmateData: return "bookmark.codmateData"
            case .sshConfig: return "bookmark.sshConfig"
            }
        }
    }

    private let bookmarks = SecurityScopedBookmarks.shared
    private let defaults = UserDefaults.standard
    private var didRestorePermissions = false

    private init() {
        checkPermissions()
    }

    /// Check if all required directories have been authorized
    func checkPermissions() {
        guard bookmarks.isSandboxed else {
            needsAuthorization = false
            missingPermissions = []
            return
        }

        var missing: [RequiredDirectory] = []

        for dir in RequiredDirectory.allCases {
            if !hasPermission(for: dir) { missing.append(dir) }
        }

        missingPermissions = missing
        needsAuthorization = !missing.isEmpty
    }

    /// Check if we have permission for a specific directory
    func hasPermission(for directory: RequiredDirectory) -> Bool {
        guard bookmarks.isSandboxed else { return true }

        // Check if we have a saved bookmark
        return defaults.data(forKey: directory.bookmarkKey) != nil
    }

    /// Request authorization for a specific directory
    func requestPermission(for directory: RequiredDirectory) async -> Bool {
        guard bookmarks.isSandboxed else { return true }

        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let panel = NSOpenPanel()
                panel.message = "CodMate needs access to \(directory.displayName)"
                panel.prompt = "Grant Access"
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                panel.canCreateDirectories = true
                panel.showsHiddenFiles = true

                // Set the default directory to the real user home directory
                let url = directory.expandedPath

                // Debug: print the actual path we're trying to access
                print("[SandboxPermissions] Requesting access to: \(url.path)")
                print("[SandboxPermissions] Directory exists: \(FileManager.default.fileExists(atPath: url.path))")

                if FileManager.default.fileExists(atPath: url.path) {
                    panel.directoryURL = url
                } else {
                    // Show parent directory (user home) if the target doesn't exist
                    panel.directoryURL = url.deletingLastPathComponent()
                    panel.message = "CodMate needs access to \(directory.displayName)\n\nSelect or create the \(url.lastPathComponent) directory."
                }

                panel.begin { response in
                    guard response == .OK, let selectedURL = panel.url else {
                        print("[SandboxPermissions] User cancelled or no URL selected")
                        continuation.resume(returning: false)
                        return
                    }

                    print("[SandboxPermissions] User selected: \(selectedURL.path)")

                    // Save the security-scoped bookmark
                    do {
                        let bookmarkData = try selectedURL.bookmarkData(
                            options: [.withSecurityScope],
                            includingResourceValuesForKeys: nil,
                            relativeTo: nil
                        )
                        self.defaults.set(bookmarkData, forKey: directory.bookmarkKey)
                        self.defaults.synchronize()
                        
                        print("[SandboxPermissions] Bookmark saved for \(directory.displayName)")

                        // Start accessing immediately
                        if selectedURL.startAccessingSecurityScopedResource() {
                            print("[SandboxPermissions] Successfully started accessing \(directory.displayName)")
                            // Refresh permission status
                            Task { @MainActor in
                                self.checkPermissions()
                            }
                            continuation.resume(returning: true)
                        } else {
                            print("[SandboxPermissions] Failed to start accessing resource")
                            continuation.resume(returning: false)
                        }
                    } catch {
                        print("[SandboxPermissions] Failed to create bookmark: \(error)")
                        continuation.resume(returning: false)
                    }
                }
            }
        }
    }

    /// Request all missing permissions in sequence
    func requestAllMissingPermissions() async -> Bool {
        guard bookmarks.isSandboxed else { return true }

        var allGranted = true

        for dir in missingPermissions {
            let granted = await requestPermission(for: dir)
            if !granted {
                allGranted = false
            }
        }

        checkPermissions()
        return allGranted
    }
    
    /// Automatically request permissions for directories that don't exist yet but are needed
    /// This should be called at app launch after restoring existing bookmarks
    func ensureCriticalDirectoriesAccess() async {
        guard bookmarks.isSandboxed else { return }
        
        // Only request if we actually need these directories
        let criticalDirs: [RequiredDirectory] = [.codexSessions, .claudeSessions, .geminiSessions, .sshConfig]
        
        for dir in criticalDirs {
            // Skip if we already have permission
            if hasPermission(for: dir) {
                continue
            }
            
            // Only request if the directory actually exists
            let url = dir.expandedPath
            if FileManager.default.fileExists(atPath: url.path) {
                print("[SandboxPermissions] Found existing directory without permission: \(dir.displayName)")
                // Don't auto-prompt here, just mark as needing attention
                // User will see the "Grant Access" button in toolbar
            }
        }
        
        checkPermissions()
    }

    /// Restore access to all previously authorized directories on app launch
    func restoreAccess() {
        guard bookmarks.isSandboxed else { return }
        guard !didRestorePermissions else { return }
        didRestorePermissions = true

        for dir in RequiredDirectory.allCases {
            guard let data = defaults.data(forKey: dir.bookmarkKey) else { continue }

            var isStale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )

                if isStale {
                    // Refresh the bookmark
                    let freshData = try url.bookmarkData(
                        options: [.withSecurityScope],
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                    defaults.set(freshData, forKey: dir.bookmarkKey)
                }

                if url.startAccessingSecurityScopedResource() {
                    print("[SandboxPermissions] Successfully restored access to: \(dir.displayName) at \(url.path)")
                } else {
                    print("[SandboxPermissions] Failed to start access for: \(dir.displayName)")
                }
            } catch {
                print("[SandboxPermissions] Failed to restore access for \(dir.displayName): \(error)")
            }
        }

        checkPermissions()
    }
    
    /// Start accessing a specific directory if we have permission
    /// Returns true if access was started successfully
    @discardableResult
    func startAccessingIfAuthorized(directory: RequiredDirectory) -> Bool {
        guard bookmarks.isSandboxed else { return true }
        guard let data = defaults.data(forKey: directory.bookmarkKey) else { return false }
        
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            
            if isStale {
                let freshData = try url.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                defaults.set(freshData, forKey: directory.bookmarkKey)
            }
            
            return url.startAccessingSecurityScopedResource()
        } catch {
            print("[SandboxPermissions] Failed to start access for \(directory.displayName): \(error)")
            return false
        }
    }
    
    /// Check if we can currently access a specific directory path
    func canAccess(path: String) -> Bool {
        guard bookmarks.isSandboxed else { return true }
        
        // Check if this path is under any of our authorized directories
        let realHome = getRealUserHome()
        let normalizedPath = path.replacingOccurrences(of: "~", with: realHome)
        
        for dir in RequiredDirectory.allCases {
            let dirPath = dir.expandedPath.path
            if normalizedPath.hasPrefix(dirPath) {
                return hasPermission(for: dir)
            }
        }
        
        return false
    }
}

import Foundation

/// Shared utility for filtering session paths based on ignore rules.
/// Consolidates duplicate logic across SessionIndexer and session providers.
enum SessionPathFilter {
    /// Check if an absolute path should be ignored based on ignore rules.
    /// - Parameters:
    ///   - absolutePath: The full path to check
    ///   - ignoredPaths: Array of path substrings to match against (case-insensitive)
    /// - Returns: `true` if the path should be ignored
    static func shouldIgnorePath(_ absolutePath: String, ignoredPaths: [String]) -> Bool {
        guard !ignoredPaths.isEmpty else { return false }
        let lowercasedPath = absolutePath.lowercased()
        
        for ignored in ignoredPaths {
            let needle = ignored.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty else { continue }
            if lowercasedPath.contains(needle.lowercased()) {
                return true
            }
        }
        return false
    }
    
    /// Check if a session summary should be ignored based on its file path and working directory.
    /// - Parameters:
    ///   - summary: The session summary to check
    ///   - ignoredPaths: Array of path substrings to match against
    /// - Returns: `true` if the session should be ignored
    static func shouldIgnoreSummary(_ summary: SessionSummary, ignoredPaths: [String]) -> Bool {
        guard !ignoredPaths.isEmpty else { return false }
        
        // Check both file path and cwd (working directory is what users typically want to filter by)
        return shouldIgnorePath(summary.fileURL.path, ignoredPaths: ignoredPaths)
            || shouldIgnorePath(summary.cwd, ignoredPaths: ignoredPaths)
    }
}

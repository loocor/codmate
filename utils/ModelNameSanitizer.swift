import Foundation

/// Utility for sanitizing and cleaning AI model names for display in pickers and UI.
///
/// This sanitizer:
/// - Removes date suffixes (e.g., -20241022, -202410)
/// - Removes provider prefixes (e.g., anthropic/, google/, openai/)
/// - Handles duplicate models by keeping the latest version
/// - Provides clean, user-friendly model names
struct ModelNameSanitizer {

    /// Represents a sanitized model with both display name and original ID
    struct SanitizedModel {
        let displayName: String
        let originalId: String
    }

    /// Common provider prefixes to remove from model names
    private static let providerPrefixes = [
        "anthropic/",
        "google/",
        "openai/",
        "mistralai/",
        "meta-llama/",
        "cohere/",
        "ai21/",
        "aleph-alpha/",
        "amazon/",
        "claude/",
        "gemini/",
        "gpt/",
        "codex/"
    ]

    /// Sanitizes a list of model names by removing dates and provider prefixes,
    /// and eliminating duplicates (keeping the latest version).
    ///
    /// - Parameter models: Array of model names to sanitize
    /// - Returns: Array of SanitizedModel with display names and original IDs
    static func sanitize(_ models: [String]) -> [SanitizedModel] {
        var seenBaseNames: [String: ModelVersion] = [:]

        for model in models {
            let cleaned = removeProviderPrefix(model)
            let (baseName, version) = extractBaseNameAndVersion(cleaned)

            // Keep the latest version for each base name
            if let existing = seenBaseNames[baseName] {
                if version.isNewerThan(existing) {
                    seenBaseNames[baseName] = version
                }
            } else {
                seenBaseNames[baseName] = version
            }
        }

        // Sort by base name for consistent ordering
        return seenBaseNames.keys.sorted().map { baseName in
            SanitizedModel(
                displayName: baseName,
                originalId: seenBaseNames[baseName]!.originalName
            )
        }
    }

    /// Sanitizes a single model name by removing provider prefix and date suffix.
    ///
    /// - Parameter model: Model name to sanitize
    /// - Returns: Sanitized model name
    static func sanitizeSingle(_ model: String) -> String {
        let cleaned = removeProviderPrefix(model)
        let (baseName, _) = extractBaseNameAndVersion(cleaned)
        return baseName
    }

    /// Removes provider prefix from a model name.
    ///
    /// Example: "anthropic/claude-3-5-sonnet-20241022" -> "claude-3-5-sonnet-20241022"
    ///
    /// - Parameter model: Model name with potential provider prefix
    /// - Returns: Model name without provider prefix
    private static func removeProviderPrefix(_ model: String) -> String {
        for prefix in providerPrefixes {
            if model.hasPrefix(prefix) {
                return String(model.dropFirst(prefix.count))
            }
        }
        return model
    }

    /// Extracts the base name and version information from a model name.
    ///
    /// Identifies and removes date suffixes in formats:
    /// - YYYYMMDD (e.g., 20241022)
    /// - YYYYMM (e.g., 202410)
    ///
    /// Example: "claude-3-5-sonnet-20241022" -> ("claude-3-5-sonnet", ModelVersion)
    ///
    /// - Parameter model: Model name to process
    /// - Returns: Tuple of (base name, version info)
    private static func extractBaseNameAndVersion(_ model: String) -> (String, ModelVersion) {
        // Pattern for YYYYMMDD format (8 digits)
        let datePattern8 = #"^(.+?)[-_]?(\d{8})$"#
        // Pattern for YYYYMM format (6 digits)
        let datePattern6 = #"^(.+?)[-_]?(\d{6})$"#

        if let regex = try? NSRegularExpression(pattern: datePattern8),
           let match = regex.firstMatch(in: model, range: NSRange(model.startIndex..., in: model)),
           let baseRange = Range(match.range(at: 1), in: model),
           let dateRange = Range(match.range(at: 2), in: model) {
            let baseName = String(model[baseRange])
            let dateString = String(model[dateRange])
            return (baseName, ModelVersion(originalName: model, dateString: dateString, format: .yyyyMMdd))
        }

        if let regex = try? NSRegularExpression(pattern: datePattern6),
           let match = regex.firstMatch(in: model, range: NSRange(model.startIndex..., in: model)),
           let baseRange = Range(match.range(at: 1), in: model),
           let dateRange = Range(match.range(at: 2), in: model) {
            let baseName = String(model[baseRange])
            let dateString = String(model[dateRange])
            return (baseName, ModelVersion(originalName: model, dateString: dateString, format: .yyyyMM))
        }

        // No date pattern found, return as-is
        return (model, ModelVersion(originalName: model, dateString: nil, format: nil))
    }

    /// Represents version information extracted from a model name
    private struct ModelVersion {
        let originalName: String
        let dateString: String?
        let format: DateFormat?

        enum DateFormat {
            case yyyyMMdd
            case yyyyMM
        }

        /// Compares if this version is newer than another version
        func isNewerThan(_ other: ModelVersion) -> Bool {
            // If both have dates, compare them
            if let myDate = dateString, let otherDate = other.dateString {
                return myDate > otherDate
            }

            // If only this version has a date, it's considered newer
            if dateString != nil && other.dateString == nil {
                return true
            }

            // If only the other version has a date, it's considered newer
            if dateString == nil && other.dateString != nil {
                return false
            }

            // If neither has a date, compare original names lexicographically
            return originalName > other.originalName
        }
    }
}

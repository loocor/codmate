import Foundation

/// Builds intelligent summarization material from conversation turns
/// Implements truncation, deduplication, and code/log trimming strategies
struct SessionSummaryMaterialBuilder {

    // MARK: - Constants

    private static let messageSeparator = "\n\n"
    private static let sectionSeparator = "\n\n---\n\n"

    private static let defaultMaxLength = 8000
    private static let assistantMessageMaxLength = 3000

    private static let deduplicationThreshold = 0.95

    private static let codeBlockKeepFirst = 5
    private static let codeBlockKeepLast = 3

    private static let errorLogKeepFirst = 10
    private static let errorLogKeepLast = 5
    private static let errorLogMinLines = 5

    // Precompiled regex patterns for error detection
    private static let errorPatterns: [NSRegularExpression] = {
        let patterns = [
            "^\\s*at ",           // Stack trace
            "^\\s*Error:",        // Error message
            "^\\s*Exception:",    // Exception
            "^\\s*Traceback",     // Python traceback
            "^\\s*File \"",       // Python file reference
            "^\\s*\\d+\\s*\\|",   // Numbered error output
            "^\\s*/.*:\\d+",      // File path with line number
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: []) }
    }()

    // MARK: - Public Interface

    /// Build summarization material from conversation turns
    /// - Parameters:
    ///   - turns: The conversation turns to process
    ///   - maxLength: Maximum total character count (default: 8000)
    /// - Returns: Formatted material string for LLM prompt
    static func build(turns: [ConversationTurn], maxLength: Int = defaultMaxLength) -> String {
        // Extract user messages using shared helper
        let rawUserMessages = turns.extractUserMessages()

        // Deduplicate user messages
        let userMessages = deduplicate(rawUserMessages, threshold: deduplicationThreshold)

        // Process each message: trim code blocks and error logs
        let processedMessages = userMessages.map { msg in
            trimCodeBlocks(in: trimErrorLogs(in: msg))
        }

        // If exceeds maxLength, remove middle messages to fit
        let finalMessages = truncateMiddleMessages(processedMessages, maxLength: maxLength)
        let material = finalMessages.joined(separator: messageSeparator)

        // Append last assistant message
        if let lastAssistant = turns.extractLastAssistantMessage() {
            let trimmed = String(lastAssistant.prefix(assistantMessageMaxLength))
            return material + sectionSeparator + "Assistant's final response:\n\n\(trimmed)"
        }

        return material
    }

    // MARK: - Deduplication

    /// Deduplicate consecutive similar messages using Levenshtein distance
    /// Only compares adjacent messages (n vs n+1) for O(n) complexity
    private static func deduplicate(_ messages: [String], threshold: Double) -> [String] {
        guard !messages.isEmpty else { return [] }

        var result: [String] = [messages[0]]

        for i in 1..<messages.count {
            let current = messages[i]
            let previous = messages[i - 1]

            // Only compare with immediately previous message
            if similarity(previous, current) < threshold {
                result.append(current)
            }
            // If similar to previous, skip (deduplicate)
        }

        return result
    }

    /// Calculate similarity ratio between two strings using Levenshtein distance
    private static func similarity(_ s1: String, _ s2: String) -> Double {
        let len1 = s1.count
        let len2 = s2.count
        let maxLen = max(len1, len2)
        guard maxLen > 0 else { return 1.0 }

        // Quick length-based check: if length difference > 10%, consider different
        let lengthDiff = abs(len1 - len2)
        if Double(lengthDiff) / Double(maxLen) > 0.1 {
            return 0.0
        }

        // For very long strings, only compare first 1000 characters to save time
        let s1Trimmed = len1 > 1000 ? String(s1.prefix(1000)) : s1
        let s2Trimmed = len2 > 1000 ? String(s2.prefix(1000)) : s2

        let distance = levenshteinDistance(s1Trimmed, s2Trimmed)
        return 1.0 - Double(distance) / Double(max(s1Trimmed.count, s2Trimmed.count))
    }

    /// Calculate Levenshtein distance between two strings
    private static func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let a = Array(s1)
        let b = Array(s2)
        var matrix = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)

        for i in 0...a.count {
            matrix[i][0] = i
        }
        for j in 0...b.count {
            matrix[0][j] = j
        }

        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i-1] == b[j-1] ? 0 : 1
                matrix[i][j] = min(
                    matrix[i-1][j] + 1,      // deletion
                    matrix[i][j-1] + 1,      // insertion
                    matrix[i-1][j-1] + cost  // substitution
                )
            }
        }

        return matrix[a.count][b.count]
    }

    // MARK: - Code Block Trimming

    /// Trim code blocks to preserve first and last lines
    private static func trimCodeBlocks(in text: String) -> String {
        let pattern = "```[\\s\\S]*?```"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }

        let nsString = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))

        var result = text
        // Process matches in reverse to maintain string indices
        for match in matches.reversed() {
            let matchRange = match.range
            let codeBlock = nsString.substring(with: matchRange)
            let trimmed = trimBlock(codeBlock, keepFirst: codeBlockKeepFirst, keepLast: codeBlockKeepLast)

            let range = Range(matchRange, in: result)!
            result.replaceSubrange(range, with: trimmed)
        }

        return result
    }

    // MARK: - Error Log Trimming

    /// Trim error logs to preserve first and last lines
    private static func trimErrorLogs(in text: String) -> String {
        let lines = text.components(separatedBy: .newlines)

        var i = 0
        var result: [String] = []

        while i < lines.count {
            // Check if this starts an error block
            let errorBlockStart = detectErrorBlock(lines: lines, startIndex: i)

            if let blockLength = errorBlockStart, blockLength >= errorLogMinLines {
                // Found error block, trim it
                let blockEnd = i + blockLength
                let blockLines = Array(lines[i..<min(blockEnd, lines.count)])
                let trimmed = trimBlock(blockLines.joined(separator: "\n"), keepFirst: errorLogKeepFirst, keepLast: errorLogKeepLast)
                result.append(trimmed)
                i = blockEnd
            } else {
                // Regular line, keep as is
                result.append(lines[i])
                i += 1
            }
        }

        return result.joined(separator: "\n")
    }

    /// Detect if lines starting at index form an error block
    private static func detectErrorBlock(lines: [String], startIndex: Int) -> Int? {
        var count = 0
        var consecutiveMatches = 0

        for i in startIndex..<lines.count {
            let line = lines[i]
            let lineRange = NSRange(location: 0, length: line.utf16.count)

            // Check if line matches any error pattern (using precompiled regexes)
            let matches = errorPatterns.contains { regex in
                regex.firstMatch(in: line, options: [], range: lineRange) != nil
            }

            if matches {
                consecutiveMatches += 1
                count += 1
            } else if consecutiveMatches >= 3 {
                // Allow a few non-matching lines within error block
                count += 1
                if count - consecutiveMatches > 2 {
                    break
                }
            } else {
                break
            }
        }

        return consecutiveMatches >= 3 ? count : nil
    }

    // MARK: - Generic Block Trimming

    /// Trim a block of text to keep first N and last M lines
    private static func trimBlock(_ block: String, keepFirst: Int, keepLast: Int) -> String {
        let lines = block.components(separatedBy: .newlines)

        guard lines.count > keepFirst + keepLast + 3 else {
            return block // Too short to trim
        }

        let firstLines = lines.prefix(keepFirst)
        let lastLines = lines.suffix(keepLast)
        let omittedCount = lines.count - keepFirst - keepLast

        return ([
            firstLines.joined(separator: "\n"),
            omissionMarker(count: omittedCount, unit: "lines"),
            lastLines.joined(separator: "\n")
        ]).joined(separator: "\n")
    }

    // MARK: - Helpers

    /// Create an omission marker with count and unit
    private static func omissionMarker(count: Int, unit: String) -> String {
        return "... (\(count) \(unit) omitted) ..."
    }

    /// Calculate total length of messages including separators
    private static func calculateMessagesLength(_ messages: [String], separator: String = messageSeparator) -> Int {
        let textLength = messages.map { $0.count }.reduce(0, +)
        let separatorsLength = max(0, messages.count - 1) * separator.count
        return textLength + separatorsLength
    }

    // MARK: - Middle Message Truncation

    /// Remove messages from the middle to fit maxLength, preserving first and last messages
    /// - Parameters:
    ///   - messages: Array of processed user messages
    ///   - maxLength: Maximum total character count
    /// - Returns: Array of messages that fit within maxLength, maintaining original order
    private static func truncateMiddleMessages(_ messages: [String], maxLength: Int) -> [String] {
        guard messages.count > 2 else { return messages }
        guard calculateMessagesLength(messages) > maxLength else { return messages }

        // Protect first and last messages
        let firstMsg = messages.first!
        let lastMsg = messages.last!
        let middleMessages = Array(messages.dropFirst().dropLast())

        // Find a continuous range in the middle to remove
        // Strategy: expand removal range from center until we fit
        let middleCount = middleMessages.count
        let centerIndex = middleCount / 2

        // Try removing progressively larger ranges centered around the middle
        for removalCount in 1...middleCount {
            // Calculate removal range centered at centerIndex
            let halfRemoval = removalCount / 2
            let removeStart = max(0, centerIndex - halfRemoval)
            let removeEnd = min(middleCount, removeStart + removalCount)

            // Build result with this removal range
            let beforeRemoval = Array(middleMessages[0..<removeStart])
            let afterRemoval = Array(middleMessages[removeEnd..<middleCount])

            let testMessages = [firstMsg] + beforeRemoval + afterRemoval + [lastMsg]
            let marker = omissionMarker(count: removalCount, unit: "messages")
            let markerLength = marker.count + messageSeparator.count * 2

            if calculateMessagesLength(testMessages) + markerLength <= maxLength {
                // This works! Build the final result
                var result = [firstMsg]
                result.append(contentsOf: beforeRemoval)

                if !beforeRemoval.isEmpty && !afterRemoval.isEmpty {
                    result.append(marker)
                }

                result.append(contentsOf: afterRemoval)
                result.append(lastMsg)
                return result
            }
        }

        // If even removing all middle messages doesn't fit, return first and last only
        return [firstMsg, omissionMarker(count: middleCount, unit: "messages"), lastMsg]
    }
}

import Foundation

// MARK: - ConversationTurnPreview

/// Lightweight preview for conversation turns, used for fast initial rendering
/// before full timeline data is loaded. Cached in SQLite for instant display.
struct ConversationTurnPreview: Identifiable, Hashable, Sendable, Codable {
    let id: String  // Same stable ID as ConversationTurn
    let sessionId: String
    let turnIndex: Int
    let timestamp: Date

    // Preview text (truncated for display when collapsed)
    let userPreview: String?        // First ~100 chars of user message
    let outputsPreview: String?     // First ~100 chars of assistant/tool output
    let outputCount: Int            // Number of output events

    // Metadata flags
    let hasToolCalls: Bool
    let hasThinking: Bool

    /// Convert a full ConversationTurn to a preview
    init(from turn: ConversationTurn, sessionId: String, index: Int) {
        self.id = turn.id
        self.sessionId = sessionId
        self.turnIndex = index
        self.timestamp = turn.timestamp

        // Extract user preview (first 100 chars)
        if let userText = turn.userMessage?.text {
            let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
            self.userPreview = String(trimmed.prefix(100))
        } else {
            self.userPreview = nil
        }

        // Extract outputs preview (first assistant or tool output, first 100 chars)
        if let firstOutput = turn.outputs.first(where: { $0.actor == .assistant || $0.actor == .tool }),
           let text = firstOutput.text {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            self.outputsPreview = String(trimmed.prefix(100))
        } else if let firstText = turn.outputs.first?.text {
            let trimmed = firstText.trimmingCharacters(in: .whitespacesAndNewlines)
            self.outputsPreview = String(trimmed.prefix(100))
        } else {
            self.outputsPreview = nil
        }

        self.outputCount = turn.outputs.count

        // Check for tool calls and thinking
        self.hasToolCalls = turn.outputs.contains { $0.actor == .tool }
        self.hasThinking = turn.outputs.contains { $0.title == "Agent Reasoning" }
    }

    // Direct initializer for decoding from SQLite
    init(
        id: String,
        sessionId: String,
        turnIndex: Int,
        timestamp: Date,
        userPreview: String?,
        outputsPreview: String?,
        outputCount: Int,
        hasToolCalls: Bool,
        hasThinking: Bool
    ) {
        self.id = id
        self.sessionId = sessionId
        self.turnIndex = turnIndex
        self.timestamp = timestamp
        self.userPreview = userPreview
        self.outputsPreview = outputsPreview
        self.outputCount = outputCount
        self.hasToolCalls = hasToolCalls
        self.hasThinking = hasThinking
    }
}

// MARK: - ConversationTurn

struct ConversationTurn: Identifiable, Hashable {
    let id: String
    let timestamp: Date
    let userMessage: TimelineEvent?
    let outputs: [TimelineEvent]

    var allEvents: [TimelineEvent] {
        var items: [TimelineEvent] = []
        if let userMessage {
            items.append(userMessage)
        }
        items.append(contentsOf: outputs)
        return items
    }

    var actorSummary: String {
        actorSummary(using: "Codex")
    }

    func actorSummary(using assistantName: String) -> String {
        var parts: [String] = []
        if userMessage != nil {
            parts.append("User")
        }
        var seen: Set<TimelineActor> = []
        for event in outputs {
            if seen.insert(event.actor).inserted {
                parts.append(event.actor.displayName(assistantName: assistantName))
            }
        }
        if parts.isEmpty, let first = outputs.first {
            parts.append(first.actor.displayName(assistantName: assistantName))
        }
        return parts.joined(separator: " → ")
    }

    var previewText: String? {
        var snippets: [String] = []
        if let text = userMessage?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            snippets.append(text)
        }
        if let assistantReply = outputs.first(where: { $0.actor == .assistant })?.text?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !assistantReply.isEmpty
        {
            snippets.append(assistantReply)
        } else if let other = outputs.first?.text?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !other.isEmpty
        {
            snippets.append(other)
        }
        guard !snippets.isEmpty else { return nil }
        return snippets.joined(separator: "\n")
    }
}

private extension TimelineActor {
    func displayName(assistantName: String = "Codex") -> String {
        switch self {
        case .user: return "User"
        case .assistant: return assistantName
        case .tool: return "Tool"
        case .info: return "Info"
        }
    }
}

extension Array where Element == ConversationTurn {
    func removingEnvironmentContext() -> [ConversationTurn] {
        compactMap { turn in
            let filteredUser = (turn.userMessage?.title == TimelineEvent.environmentContextTitle)
                ? nil : turn.userMessage
            let filteredOutputs = turn.outputs.filter { $0.title != TimelineEvent.environmentContextTitle }
            if filteredUser == nil && filteredOutputs.isEmpty {
                return nil
            }
            if filteredUser == turn.userMessage && filteredOutputs.count == turn.outputs.count {
                return turn
            }
            return ConversationTurn(
                id: turn.id,
                timestamp: turn.timestamp,
                userMessage: filteredUser,
                outputs: filteredOutputs
            )
        }
    }

    func filtering(visibleKinds: Set<MessageVisibilityKind>) -> [ConversationTurn] {
        compactMap { turn in
            let userAllowed: Bool = {
                guard let u = turn.userMessage else { return false }
                return visibleKinds.contains(event: u)
            }()
            let keptOutputs = turn.outputs.filter { visibleKinds.contains(event: $0) }
            if !userAllowed && keptOutputs.isEmpty { return nil }
            return ConversationTurn(
                id: turn.id,
                timestamp: turn.timestamp,
                userMessage: userAllowed ? turn.userMessage : nil,
                outputs: keptOutputs
            )
        }
    }
}

import Foundation

struct SessionTimelineLoader {
    private let decoder: JSONDecoder
    private let skippedEventTypes: Set<String> = [
        "reasoning_output"
    ]
    private let turnBoundaryMetadataKey = "turn_boundary"

    init() {
        decoder = FlexibleDecoders.iso8601Flexible()
    }

    func load(url: URL) throws -> [ConversationTurn] {
        let events = try decodeEvents(url: url)
        return group(events: events)
    }

    func turns(from rows: [SessionRow]) -> [ConversationTurn] {
        let events = rows.compactMap { makeEvent(from: $0) }
        return group(events: events)
    }

    private func decodeEvents(url: URL) throws -> [TimelineEvent] {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard !data.isEmpty else { return [] }
        let newline: UInt8 = 0x0A
        let carriageReturn: UInt8 = 0x0D

        var events: [TimelineEvent] = []
        for var slice in data.split(separator: newline, omittingEmptySubsequences: true) {
            if slice.last == carriageReturn { slice = slice.dropLast() }
            guard !slice.isEmpty else { continue }
            guard let row = try? decoder.decode(SessionRow.self, from: Data(slice)) else { continue }
            guard let event = makeEvent(from: row) else { continue }
            events.append(event)
        }
        return events
    }

    private func makeEvent(from row: SessionRow) -> TimelineEvent? {
        switch row.kind {
        case .sessionMeta:
            return nil
        case .assistantMessage:
            // Assistant messages are handled by response_item events; skip here to avoid duplicates
            return nil
        case let .turnContext(payload):
            var parts: [String] = []
            if let model = payload.model { parts.append("model: \(model)") }
            if let ap = payload.approvalPolicy { parts.append("policy: \(ap)") }
            if let cwd = payload.cwd { parts.append("cwd: \(cwd)") }
            if let summary = payload.summary, !summary.isEmpty { parts.append(summary) }
            let text = parts.joined(separator: "\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            // Turn Context is already surfaced in the Environment Context section;
            // skip adding it to the conversation timeline.
            return nil
        case let .eventMessage(payload):
            let type = payload.type.lowercased()
            if type == "turn_boundary" {
                var metadata: [String: String] = [turnBoundaryMetadataKey: "1"]
                if let kind = payload.kind, !kind.isEmpty {
                    metadata["boundary_kind"] = kind
                }
                if let identifier = payload.message, !identifier.isEmpty {
                    metadata["boundary_message_id"] = identifier
                }
                return TimelineEvent(
                    id: UUID().uuidString,
                    timestamp: row.timestamp,
                    actor: .info,
                    title: nil,
                    text: nil,
                    metadata: metadata
                )
            }
            if skippedEventTypes.contains(type) { return nil }
            if type == "token_count" {
                return makeTokenCountEvent(timestamp: row.timestamp, payload: payload)
            }
            if type == "turn_aborted" || type == "turn aborted" || type == "compaction" || type == "compacted" {
                return nil
            }
            if type == "agent_reasoning" {
                let reasoning = cleanedText(payload.text ?? payload.message ?? "")
                guard !reasoning.isEmpty else { return nil }
                return TimelineEvent(
                    id: UUID().uuidString,
                    timestamp: row.timestamp,
                    actor: .info,
                    title: "Agent Reasoning",
                    text: reasoning,
                    metadata: nil,
                    visibilityKind: .reasoning
                )
            }
            if type == "ghost_snapshot" || type == "ghost snapshot" {
                return nil
            }
            if type == "environment_context" {
                if let env = payload.message ?? payload.text {
                    return makeEnvironmentContextEvent(text: env, timestamp: row.timestamp)
                }
                return nil
            }

            let message = cleanedText(payload.message ?? payload.text ?? payload.reason ?? "")
            let attachments = attachments(from: payload)
            guard !message.isEmpty || !attachments.isEmpty else { return nil }
            let displayMessage = message.isEmpty ? "[Image]" : message
            let mappedKind = MessageVisibilityKind.mappedKind(
                rawType: payload.type,
                title: payload.kind ?? payload.type,
                metadata: nil
            )
            let effectiveKind: MessageVisibilityKind? = {
                guard mappedKind == .tool else { return mappedKind }
                if containsCodeEditMarkers(message) || containsStrongEditOutputMarkers(message) {
                    return .codeEdit
                }
                return mappedKind
            }()
            switch type {
            case "user_message":
                return TimelineEvent(
                    id: UUID().uuidString,
                    timestamp: row.timestamp,
                    actor: .user,
                    title: nil,
                    text: displayMessage,
                    metadata: nil,
                    repeatCount: repeatCountHint(from: payload.info),
                    attachments: attachments,
                    visibilityKind: effectiveKind ?? .user
                )
            case "agent_message":
                return TimelineEvent(
                    id: UUID().uuidString,
                    timestamp: row.timestamp,
                    actor: .assistant,
                    title: nil,
                    text: displayMessage,
                    metadata: nil,
                    repeatCount: repeatCountHint(from: payload.info),
                    attachments: attachments,
                    visibilityKind: effectiveKind ?? .assistant
                )
            default:
                let actor = effectiveKind?.defaultActor ?? .info
                return TimelineEvent(
                    id: UUID().uuidString,
                    timestamp: row.timestamp,
                    actor: actor,
                    title: payload.type,
                    text: displayMessage,
                    metadata: nil,
                    attachments: attachments,
                    visibilityKind: effectiveKind
                )
            }
        case let .responseItem(payload):
            let type = payload.type.lowercased()
            if skippedEventTypes.contains(type) { return nil }
            if type == "ghost_snapshot" || type == "ghost snapshot" { return nil }
            if type == "reasoning",
               let summary = payload.summary,
               !summary.isEmpty,
               (payload.content == nil || payload.content?.isEmpty == true) {
                // Codex emits duplicate reasoning in response_item (summary only) + event_msg.
                // Keep the event_msg version and skip the summary-only duplicate.
                return nil
            }

            if type == "message" {
                let text = cleanedText(joinedText(from: payload.content ?? []))
                guard !text.isEmpty else { return nil }
                if payload.role?.lowercased() == "user" {
                    if let environment = makeEnvironmentContextEvent(text: text, timestamp: row.timestamp) {
                        return environment
                    }
                    // event_msg already covers user content; skip to avoid duplicates
                    return nil
                }
                return TimelineEvent(
                    id: UUID().uuidString,
                    timestamp: row.timestamp,
                    actor: .assistant,
                    title: nil,
                    text: text,
                    metadata: nil,
                    visibilityKind: .assistant
                )
            }

            let contentText = cleanedText(joinedText(from: payload.content ?? []))
            let summaryText = cleanedText(joinedSummary(from: payload.summary ?? []))
            let fallbackText = responseFallbackText(payload)
            let mappedKind = MessageVisibilityKind.mappedKind(
                rawType: payload.type,
                title: payload.type,
                metadata: nil
            )
            let detectionText: String = {
                if !contentText.isEmpty { return contentText }
                if !summaryText.isEmpty { return summaryText }
                return fallbackText
            }()
            let resolvedKind: MessageVisibilityKind? = {
                guard mappedKind == .tool else { return mappedKind }
                if isCodeEdit(payload: payload, fallbackText: detectionText) { return .codeEdit }
                return mappedKind
            }()
            let baseText: String
            if resolvedKind == .tool || resolvedKind == .codeEdit {
                if !contentText.isEmpty { baseText = contentText }
                else if !summaryText.isEmpty { baseText = summaryText }
                else { baseText = "" }
            } else {
                if !contentText.isEmpty { baseText = contentText }
                else if !summaryText.isEmpty { baseText = summaryText }
                else { baseText = fallbackText }
            }
            let bodyText: String
            if resolvedKind == .tool || resolvedKind == .codeEdit {
                let toolText = toolDisplayText(payload: payload, fallback: baseText)
                bodyText = toolText
            } else {
                bodyText = baseText
            }
            guard !bodyText.isEmpty else { return nil }
            let actor = resolvedKind?.defaultActor ?? .info
            return TimelineEvent(
                id: UUID().uuidString,
                timestamp: row.timestamp,
                actor: actor,
                title: payload.type,
                text: bodyText,
                metadata: nil,
                visibilityKind: resolvedKind,
                callID: payload.callID
            )
        case .unknown:
            return nil
        }
    }

    private func group(events: [TimelineEvent]) -> [ConversationTurn] {
        var turns: [ConversationTurn] = []
        var currentUser: TimelineEvent?
        var pendingOutputs: [TimelineEvent] = []

        // Use a stable, content-agnostic key per turn to preserve UI expansion state
        // across reloads when outputs are appended (commonly the last turn).
        var seenTurnKeys: [String: Int] = [:]

        func stableTurnID(anchor timestamp: Date, hasUser: Bool) -> String {
            let millis = Int(timestamp.timeIntervalSince1970 * 1000)
            let baseKey = "\(millis)-\(hasUser ? "u" : "o")"
            let seq = (seenTurnKeys[baseKey] ?? 0) + 1
            seenTurnKeys[baseKey] = seq
            return "t-\(baseKey)-\(seq)"
        }

        func flushTurn() {
            guard currentUser != nil || !pendingOutputs.isEmpty else { return }
            let timestamp = currentUser?.timestamp ?? pendingOutputs.first?.timestamp ?? Date()
            let id = stableTurnID(anchor: timestamp, hasUser: currentUser != nil)
            let turn = ConversationTurn(
                id: id,
                timestamp: timestamp,
                userMessage: currentUser,
                outputs: pendingOutputs
            )
            turns.append(turn)
            currentUser = nil
            pendingOutputs = []
        }

        let ordered = events.sorted(by: { $0.timestamp < $1.timestamp })
        let mergedTools = mergeToolInvocations(in: ordered)
        let deduped = collapseDuplicates(mergeConsecutiveUserMessages(mergedTools))

        for event in deduped {
            if event.title == TimelineEvent.environmentContextTitle {
                continue
            }
            if event.metadata?[turnBoundaryMetadataKey] == "1" {
                if currentUser == nil {
                    flushTurn()
                }
                continue
            }
            if event.actor == .user {
                flushTurn()
                currentUser = event
            } else {
                pendingOutputs.append(event)
            }
        }
        flushTurn()
        return turns
    }

    private func mergeToolInvocations(in events: [TimelineEvent]) -> [TimelineEvent] {
        var result: [TimelineEvent] = []
        var pendingByCallID: [String: Int] = [:]

        for event in events {
            guard isToolLike(event.visibilityKind),
                  let callID = event.callID,
                  !callID.isEmpty else {
                result.append(event)
                continue
            }

            if isToolOutputEvent(event), let index = pendingByCallID[callID] {
                let merged = mergeToolOutput(into: result[index], output: event)
                result[index] = merged
                continue
            }

            pendingByCallID[callID] = result.count
            result.append(event)
        }

        return result
    }

    private func isToolLike(_ kind: MessageVisibilityKind) -> Bool {
        switch kind {
        case .tool, .codeEdit:
            return true
        default:
            return false
        }
    }

    private func isToolOutputEvent(_ event: TimelineEvent) -> Bool {
        let type = (event.title ?? "").lowercased()
        if type.isEmpty { return false }
        if type.contains("output") || type.contains("result") { return true }
        return false
    }

    private func mergeToolOutput(into callEvent: TimelineEvent, output: TimelineEvent) -> TimelineEvent {
        let callText = callEvent.text ?? ""
        let outputText = output.text ?? ""
        let mergedText: String
        if outputText.isEmpty {
            mergedText = callText
        } else if callText.isEmpty {
            mergedText = outputText
        } else if callText.contains(outputText) {
            mergedText = callText
        } else {
            mergedText = [callText, outputText].joined(separator: "\n\n")
        }
        return TimelineEvent(
            id: callEvent.id,
            timestamp: callEvent.timestamp,
            actor: callEvent.actor,
            title: callEvent.title,
            text: mergedText,
            metadata: callEvent.metadata,
            repeatCount: callEvent.repeatCount,
            attachments: callEvent.attachments,
            visibilityKind: callEvent.visibilityKind,
            callID: callEvent.callID
        )
    }

    private func cleanedText(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        return text
            .replacingOccurrences(of: "<user_instructions>", with: "")
            .replacingOccurrences(of: "</user_instructions>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func joinedText(from blocks: [ResponseContentBlock]) -> String {
        blocks.compactMap { $0.text }.joined(separator: "\n\n")
    }

    private func joinedSummary(from items: [ResponseSummaryItem]) -> String {
        items.compactMap { $0.text }.joined(separator: "\n\n")
    }

    private func responseFallbackText(_ payload: ResponseItemPayload) -> String {
        var lines: [String] = []

        if let name = payload.name, !name.isEmpty {
            lines.append("name: \(name)")
        }
        if let args = renderValue(payload.arguments), !args.isEmpty {
            lines.append(formatLabel("arguments", value: args))
        }
        if let input = renderValue(payload.input), !input.isEmpty {
            lines.append(formatLabel("input", value: input))
        }
        if let output = renderValue(payload.output), !output.isEmpty {
            lines.append(formatLabel("output", value: output))
        }
        if let ghost = renderValue(payload.ghostCommit), !ghost.isEmpty {
            lines.append(formatLabel("ghost_commit", value: ghost))
        }

        if lines.isEmpty, let callID = payload.callID, !callID.isEmpty {
            lines.append("call_id: \(callID)")
        }

        return lines.joined(separator: "\n")
    }

    private func toolDisplayText(payload: ResponseItemPayload, fallback: String) -> String {
        var lines: [String] = []

        if let name = payload.name, !name.isEmpty {
            lines.append("name: \(name)")
        }

        let argumentValue = payload.arguments ?? payload.input
        if let args = renderValue(argumentValue), !args.isEmpty {
            lines.append(formatLabel("arguments", value: args))
        }

        if let output = renderValue(payload.output), !output.isEmpty {
            lines.append(formatLabel("output", value: output))
        }

        if lines.isEmpty { return fallback }

        let composed = lines.joined(separator: "\n")
        guard !fallback.isEmpty else { return composed }
        if fallback == composed { return composed }
        if composed.contains(fallback) { return composed }
        return [composed, fallback].joined(separator: "\n")
    }

    private func isCodeEdit(payload: ResponseItemPayload, fallbackText: String) -> Bool {
        let name = normalizeToolName(payload.name)
        if codeEditToolNames.contains(name) { return true }

        if containsEditKeys(payload.arguments) || containsEditKeys(payload.input) {
            return true
        }

        if name == "execcommand" || name == "bash" || name == "runshellcommand" {
            let argsText = stringValue(payload.arguments) ?? ""
            if containsCodeEditMarkers(argsText) { return true }
        }

        if let outputText = stringValue(payload.output),
           containsStrongEditOutputMarkers(outputText) { return true }

        if containsCodeEditMarkers(fallbackText) { return true }

        return false
    }

    private var codeEditToolNames: Set<String> {
        [
            "edit",
            "write",
            "replace",
            "applypatch",
            "patch",
            "createfile",
            "writefile",
            "deletefile",
            "fileedit",
            "filewrite",
            "updatefile",
            "insert",
            "append",
            "move",
            "rename",
            "remove",
            "multiedit"
        ]
    }

    private func normalizeToolName(_ name: String?) -> String {
        let raw = name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if raw.isEmpty { return "" }
        return raw
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    private func containsEditKeys(_ value: JSONValue?) -> Bool {
        guard let value else { return false }
        switch value {
        case .object(let dict):
            let keys = Set(dict.keys.map { $0.lowercased() })
            let hasPath = keys.contains("file_path") || keys.contains("filepath") || keys.contains("path")
            let hasOldNew = keys.contains("old_string") || keys.contains("new_string")
            let hasPatch = keys.contains("patch") || keys.contains("diff")
            let hasContent = keys.contains("content") || keys.contains("new_content") || keys.contains("text")
            if hasOldNew || hasPatch { return true }
            if hasPath && hasContent { return true }
            return dict.values.contains { containsEditKeys($0) }
        case .array(let array):
            return array.contains { containsEditKeys($0) }
        default:
            return false
        }
    }

    private func containsCodeEditMarkers(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered.contains("*** begin patch") { return true }
        if lowered.contains("*** update file") { return true }
        if lowered.contains("*** add file") { return true }
        if lowered.contains("*** delete file") { return true }
        if lowered.contains("update file:") { return true }
        return false
    }

    private func containsStrongEditOutputMarkers(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered.contains("updated the following files") { return true }
        if lowered.contains("success. updated the following files") { return true }
        return false
    }

    private func stringValue(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let string):
            return string
        case .number(let number):
            return String(number)
        case .bool(let flag):
            return flag ? "true" : "false"
        case .array, .object, .null:
            return nil
        }
    }

    private func formatLabel(_ label: String, value: String) -> String {
        value.contains("\n") ? "\(label):\n\(value)" : "\(label): \(value)"
    }

    private func attachments(from payload: EventMessagePayload) -> [TimelineAttachment] {
        guard let images = payload.images, !images.isEmpty else { return [] }
        return images.enumerated().compactMap { index, raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let label = "Image \(index + 1)"
            if let url = URL(string: trimmed), let scheme = url.scheme, scheme != "data" {
                return TimelineAttachment(kind: .image, label: label, url: url)
            }
            if trimmed.hasPrefix("/") {
                return TimelineAttachment(kind: .image, label: label, url: URL(fileURLWithPath: trimmed))
            }
            return TimelineAttachment(kind: .image, label: label, dataURL: trimmed)
        }
    }

    private func renderValue(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let string):
            return string
        case .number(let number):
            return String(number)
        case .bool(let flag):
            return flag ? "true" : "false"
        case .null:
            return nil
        case .array, .object:
            let raw = toAny(value)
            guard JSONSerialization.isValidJSONObject(raw),
                  let data = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]),
                  let text = String(data: data, encoding: .utf8)
            else { return nil }
            return text
        }
    }

    private func toAny(_ value: JSONValue) -> Any {
        switch value {
        case .string(let string):
            return string
        case .number(let number):
            return number
        case .bool(let flag):
            return flag
        case .array(let array):
            return array.map(toAny)
        case .object(let dict):
            return dict.mapValues(toAny)
        case .null:
            return NSNull()
        }
    }

    /// Merge consecutive user messages with the exact same timestamp
    /// This handles Claude Code's behavior of splitting a single user input into multiple JSONL records
    /// with identical timestamps (down to millisecond precision)
    private func mergeConsecutiveUserMessages(_ events: [TimelineEvent]) -> [TimelineEvent] {
        guard !events.isEmpty else { return [] }
        var result: [TimelineEvent] = []
        var pendingUserMessages: [TimelineEvent] = []
        var lastUserTimestamp: Date?

        func flushPendingUserMessages() {
            guard !pendingUserMessages.isEmpty else { return }

            // Filter out auto-generated image description messages
            // (text-only messages that start with "[Image:")
            let realMessages = pendingUserMessages.filter { event in
                if event.attachments.isEmpty,
                   let text = event.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                   text.hasPrefix("[Image:") {
                    return false  // Skip auto-generated image description
                }
                return true
            }

            if realMessages.count == 1 {
                // Only one real message, use it as-is
                result.append(realMessages[0])
            } else if realMessages.count > 1 {
                // Multiple messages need to be merged
                let first = realMessages[0]
                let mergedText = realMessages.compactMap { $0.text }.filter { !$0.isEmpty }.joined(separator: "\n\n")
                var mergedAttachments: [TimelineAttachment] = []

                for event in realMessages {
                    mergedAttachments.append(contentsOf: event.attachments)
                }

                // Create merged event
                let merged = TimelineEvent(
                    id: first.id,
                    timestamp: first.timestamp,
                    actor: first.actor,
                    title: first.title,
                    text: mergedText.isEmpty ? nil : mergedText,
                    metadata: first.metadata,
                    repeatCount: first.repeatCount,
                    attachments: mergedAttachments,
                    visibilityKind: first.visibilityKind,
                    callID: first.callID
                )
                result.append(merged)
            }

            pendingUserMessages.removeAll()
            lastUserTimestamp = nil
        }

        for event in events {
            if event.actor == .user {
                // Check if this user message has the exact same timestamp as pending ones
                if let lastTimestamp = lastUserTimestamp {
                    // Compare timestamps with exact equality (millisecond precision)
                    if event.timestamp == lastTimestamp {
                        pendingUserMessages.append(event)
                        continue
                    }
                }

                // Different timestamp, flush pending and start new batch
                flushPendingUserMessages()
                pendingUserMessages.append(event)
                lastUserTimestamp = event.timestamp
            } else {
                // Non-user message, flush pending user messages first
                flushPendingUserMessages()
                result.append(event)
            }
        }

        // Flush any remaining pending user messages
        flushPendingUserMessages()

        return result
    }

    private func collapseDuplicates(_ events: [TimelineEvent]) -> [TimelineEvent] {
        guard !events.isEmpty else { return [] }
        var result: [TimelineEvent] = []
        for event in events {
            if let last = result.last,
                last.actor == event.actor,
                last.title == event.title,
                (last.text ?? "") == (event.text ?? ""),
                normalize(metadata: last.metadata) == normalize(metadata: event.metadata)
            {
                result[result.count - 1] = last.incrementingRepeatCount()
            } else {
                result.append(event)
            }
        }
        return result
    }

    private func normalize(metadata: [String: String]?) -> [String: String] {
        metadata?.filter { !$0.value.isEmpty } ?? [:]
    }

    private func repeatCountHint(from info: JSONValue?) -> Int {
        guard let info else { return 1 }
        if case let .object(dict) = info, let value = dict["repeat_count"] {
            switch value {
            case .number(let number):
                return max(1, Int(number.rounded()))
            case .string(let string):
                if let parsed = Double(string) {
                    return max(1, Int(parsed.rounded()))
                }
            case .bool(let flag):
                return flag ? 1 : 1
            default:
                break
            }
        }
        return 1
    }

    private func makeEnvironmentContextEvent(text: String, timestamp: Date) -> TimelineEvent? {
        guard let rangeStart = text.range(of: "<environment_context>"),
            let rangeEnd = text.range(of: "</environment_context>")
        else { return nil }
        let inner = text[rangeStart.upperBound..<rangeEnd.lowerBound]
        let regex = try? NSRegularExpression(pattern: "<(\\w+)>\\s*([^<]+?)\\s*</\\1>", options: [])
        var metadata: [String: String] = [:]
        if let regex {
            let nsString = NSString(string: String(inner))
            let matches = regex.matches(in: String(inner), range: NSRange(location: 0, length: nsString.length))
            for match in matches where match.numberOfRanges >= 3 {
                let key = nsString.substring(with: match.range(at: 1))
                var value = nsString.substring(with: match.range(at: 2))
                value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                metadata[key] = value
            }
        }
        let sortedEntries = metadata.sorted(by: { $0.key < $1.key })
        let textLines = sortedEntries
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
        let displayText = textLines.isEmpty ? cleanedText(String(inner)) : textLines
        return TimelineEvent(
            id: UUID().uuidString,
            timestamp: timestamp,
            actor: .info,
            title: TimelineEvent.environmentContextTitle,
            text: displayText.isEmpty ? nil : displayText,
            metadata: metadata.isEmpty ? nil : metadata,
            visibilityKind: .environmentContext
        )
    }

    private func makeTokenCountEvent(timestamp: Date, payload: EventMessagePayload) -> TimelineEvent? {
        let infoDict = flatten(json: payload.info)
        let rateDict = flatten(json: payload.rateLimits, prefix: "rate_")
        let combined = infoDict.merging(rateDict) { current, _ in current }
        guard !combined.isEmpty else { return nil }
        return TimelineEvent(
            id: UUID().uuidString,
            timestamp: timestamp,
            actor: .info,
            title: "Token Usage",
            text: nil,
            metadata: combined,
            visibilityKind: .tokenUsage
        )
    }

    private func flatten(json: JSONValue?, prefix: String = "") -> [String: String] {
        guard let json else { return [:] }
        var result: [String: String] = [:]
        switch json {
        case .string(let value):
            result[prefix.isEmpty ? "value" : prefix] = value
        case .number(let value):
            let key = prefix.isEmpty ? "value" : prefix
            result[key] = String(value)
        case .bool(let value):
            let key = prefix.isEmpty ? "value" : prefix
            result[key] = value ? "true" : "false"
        case .object(let dict):
            for (key, value) in dict {
                let newPrefix = prefix.isEmpty ? key : "\(prefix)\(key.capitalized)"
                result.merge(flatten(json: value, prefix: newPrefix)) { current, _ in current }
            }
        case .array(let array):
            for (index, value) in array.enumerated() {
                let newPrefix = prefix.isEmpty ? "item\(index)" : "\(prefix)\(index)"
                result.merge(flatten(json: value, prefix: newPrefix)) { current, _ in current }
            }
        case .null:
            break
        }
        return result
    }

    func loadInstructions(url: URL) throws -> String? {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard !data.isEmpty else { return nil }
        let newline: UInt8 = 0x0A
        let carriageReturn: UInt8 = 0x0D
        for var slice in data.split(separator: newline, omittingEmptySubsequences: true) {
            if slice.last == carriageReturn { slice = slice.dropLast() }
            guard !slice.isEmpty else { continue }
            if let row = try? decoder.decode(SessionRow.self, from: Data(slice)) {
                if case let .sessionMeta(payload) = row.kind, let instructions = payload.instructions {
                    let cleaned = cleanedText(instructions)
                    if !cleaned.isEmpty { return cleaned }
                }
            }
        }
        return nil
    }

    func loadEnvironmentContext(from rows: [SessionRow]) -> EnvironmentContextInfo? {
        var latest: TimelineEvent?

        for row in rows {
            switch row.kind {
            case let .turnContext(payload):
                // Extract environment context from turnContext (for Gemini sessions)
                var metadata: [String: String] = [:]
                if let model = payload.model { metadata["model"] = model }
                if let cwd = payload.cwd { metadata["cwd"] = cwd }
                if let approval = payload.approvalPolicy { metadata["approval"] = approval }

                if !metadata.isEmpty {
                    var textParts: [String] = []
                    if let model = metadata["model"] { textParts.append("model: \(model)") }
                    if let cwd = metadata["cwd"] { textParts.append("cwd: \(cwd)") }
                    if let approval = metadata["approval"] { textParts.append("approval: \(approval)") }

                    latest = TimelineEvent(
                        id: UUID().uuidString,
                        timestamp: row.timestamp,
                        actor: .info,
                        title: TimelineEvent.environmentContextTitle,
                        text: textParts.joined(separator: "\n"),
                        metadata: metadata
                    )
                }
            case let .eventMessage(payload):
                let type = payload.type.lowercased()
                if type == "environment_context",
                   let envText = payload.message ?? payload.text,
                   let event = makeEnvironmentContextEvent(text: envText, timestamp: row.timestamp)
                {
                    latest = event
                }
            case let .responseItem(payload):
                if payload.type.lowercased() == "message" {
                    let text = joinedText(from: payload.content ?? [])
                    guard text.contains("<environment_context") else { continue }
                    if let event = makeEnvironmentContextEvent(text: text, timestamp: row.timestamp) {
                        latest = event
                    }
                }
            default:
                continue
            }
        }

        guard let event = latest else { return nil }
        let metadataPairs = (event.metadata ?? [:]).sorted(by: { $0.key < $1.key })
        let entries = metadataPairs.map { EnvironmentContextInfo.Entry(key: $0.key, value: $0.value) }
        return EnvironmentContextInfo(
            timestamp: event.timestamp,
            entries: entries,
            rawText: event.text
        )
    }

    func loadEnvironmentContext(url: URL) throws -> EnvironmentContextInfo? {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard !data.isEmpty else { return nil }
        let newline: UInt8 = 0x0A
        let carriageReturn: UInt8 = 0x0D
        var latest: TimelineEvent?

        for var slice in data.split(separator: newline, omittingEmptySubsequences: true) {
            if slice.last == carriageReturn { slice = slice.dropLast() }
            guard !slice.isEmpty else { continue }
            guard let row = try? decoder.decode(SessionRow.self, from: Data(slice)) else { continue }

            switch row.kind {
            case let .turnContext(payload):
                // Extract environment context from turnContext (for Gemini sessions)
                var metadata: [String: String] = [:]
                if let model = payload.model { metadata["model"] = model }
                if let cwd = payload.cwd { metadata["cwd"] = cwd }
                if let approval = payload.approvalPolicy { metadata["approval"] = approval }

                if !metadata.isEmpty {
                    var textParts: [String] = []
                    if let model = metadata["model"] { textParts.append("model: \(model)") }
                    if let cwd = metadata["cwd"] { textParts.append("cwd: \(cwd)") }
                    if let approval = metadata["approval"] { textParts.append("approval: \(approval)") }

                    latest = TimelineEvent(
                        id: UUID().uuidString,
                        timestamp: row.timestamp,
                        actor: .info,
                        title: TimelineEvent.environmentContextTitle,
                        text: textParts.joined(separator: "\n"),
                        metadata: metadata
                    )
                }
            case let .eventMessage(payload):
                let type = payload.type.lowercased()
                if type == "environment_context",
                   let envText = payload.message ?? payload.text,
                   let event = makeEnvironmentContextEvent(text: envText, timestamp: row.timestamp)
                {
                    latest = event
                }
            case let .responseItem(payload):
                if payload.type.lowercased() == "message" {
                    let text = joinedText(from: payload.content ?? [])
                    guard text.contains("<environment_context") else { continue }
                    if let event = makeEnvironmentContextEvent(text: text, timestamp: row.timestamp) {
                        latest = event
                    }
                }
            default:
                continue
            }
        }

        guard let event = latest else { return nil }
        let metadataPairs = (event.metadata ?? [:]).sorted(by: { $0.key < $1.key })
        let entries = metadataPairs.map { EnvironmentContextInfo.Entry(key: $0.key, value: $0.value) }
        return EnvironmentContextInfo(
            timestamp: event.timestamp,
            entries: entries,
            rawText: event.text
        )
    }

    func loadLatestTokenUsage(url: URL) throws -> TokenUsageSnapshot? {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard !data.isEmpty else { return nil }
        let newline: UInt8 = 0x0A
        let carriageReturn: UInt8 = 0x0D
        var latest: TokenUsageSnapshot?

        for var slice in data.split(separator: newline, omittingEmptySubsequences: true) {
            if slice.last == carriageReturn { slice = slice.dropLast() }
            guard !slice.isEmpty else { continue }
            guard let row = try? decoder.decode(SessionRow.self, from: Data(slice)) else { continue }
            guard case let .eventMessage(payload) = row.kind else { continue }
            if payload.type.lowercased() == "token_count",
               let snapshot = TokenUsageSnapshotBuilder.build(timestamp: row.timestamp, payload: payload)
            {
                latest = snapshot
            }
        }

        return latest
    }

}

struct TokenUsageSnapshot: Equatable {
    let timestamp: Date
    let totalTokens: Int?
    let contextWindow: Int?
    let primaryPercent: Double?
    let primaryWindowMinutes: Int?
    let primaryResetAt: Date?
    let secondaryPercent: Double?
    let secondaryWindowMinutes: Int?
    let secondaryResetAt: Date?
}

struct TokenUsageSnapshotBuilder {
    static func build(timestamp: Date, payload: EventMessagePayload) -> TokenUsageSnapshot? {
        let info = payload.info
        let totalTokens = info?.value(forKeyPath: ["last_token_usage", "total_tokens"])?.intValue
            ?? info?.value(forKeyPath: ["total_token_usage", "total_tokens"])?.intValue
        let contextWindow = info?.value(forKeyPath: ["model_context_window"])?.intValue

        let primaryRate = RateWindowSnapshot(json: payload.rateLimits, prefix: "primary", timestamp: timestamp)
        let secondaryRate = RateWindowSnapshot(json: payload.rateLimits, prefix: "secondary", timestamp: timestamp)

        if totalTokens == nil,
           contextWindow == nil,
           primaryRate.isEmpty,
           secondaryRate.isEmpty
        {
            return nil
        }

        return TokenUsageSnapshot(
            timestamp: timestamp,
            totalTokens: totalTokens,
            contextWindow: contextWindow,
            primaryPercent: primaryRate.usedPercent,
            primaryWindowMinutes: primaryRate.windowMinutes,
            primaryResetAt: primaryRate.resetDate,
            secondaryPercent: secondaryRate.usedPercent,
            secondaryWindowMinutes: secondaryRate.windowMinutes,
            secondaryResetAt: secondaryRate.resetDate
        )
    }
}

fileprivate struct TokenUsageFallbackParser {
    private let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    func loadLatest(url: URL) -> TokenUsageSnapshot? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), !data.isEmpty else { return nil }
        let newline: UInt8 = 0x0A
        let carriageReturn: UInt8 = 0x0D
        var latest: TokenUsageSnapshot?

        for var slice in data.split(separator: newline, omittingEmptySubsequences: true) {
            if slice.last == carriageReturn { slice = slice.dropLast() }
            guard let snapshot = parseLine(Data(slice)) else { continue }
            latest = snapshot
        }

        return latest
    }

    private func parseLine(_ data: Data) -> TokenUsageSnapshot? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = json["payload"] as? [String: Any],
              let type = (payload["type"] as? String)?.lowercased(),
              type == "token_count",
              let timestampString = json["timestamp"] as? String,
              let timestamp = isoFormatter.date(from: timestampString) ?? ISO8601DateFormatter().date(from: timestampString)
        else {
            return nil
        }

        let info = payload["info"] as? [String: Any]
        let rateLimits = payload["rate_limits"] as? [String: Any]
        let totalTokens = TokenUsageValueParser.int(TokenUsageValueParser.value(in: info, keyPath: ["total_token_usage", "total_tokens"]))
        let contextWindow = TokenUsageValueParser.int(info?["model_context_window"])
        let primary = RateLimitComponents(json: rateLimits, prefix: "primary", timestamp: timestamp)
        let secondary = RateLimitComponents(json: rateLimits, prefix: "secondary", timestamp: timestamp)

        if totalTokens == nil,
           contextWindow == nil,
           primary.isEmpty,
           secondary.isEmpty
        {
            return nil
        }

        return TokenUsageSnapshot(
            timestamp: timestamp,
            totalTokens: totalTokens,
            contextWindow: contextWindow,
            primaryPercent: primary.usedPercent,
            primaryWindowMinutes: primary.windowMinutes,
            primaryResetAt: primary.resetDate,
            secondaryPercent: secondary.usedPercent,
            secondaryWindowMinutes: secondary.windowMinutes,
            secondaryResetAt: secondary.resetDate
        )
    }
}

extension SessionTimelineLoader {
    func loadLatestTokenUsageWithFallback(url: URL) -> TokenUsageSnapshot? {
        if let snapshot = try? loadLatestTokenUsage(url: url) {
            return snapshot
        }
        return TokenUsageFallbackParser().loadLatest(url: url)
    }
}

private struct RateLimitComponents {
    var usedPercent: Double?
    var windowMinutes: Int?
    var resetDate: Date?

    var isEmpty: Bool { usedPercent == nil && windowMinutes == nil && resetDate == nil }

    init(json: [String: Any]?, prefix: String, timestamp: Date) {
        if let nested = json?[prefix] as? [String: Any] {
            parse(values: nested, timestamp: timestamp)
            return
        }

        guard let json else { return }
        var extracted: [String: Any] = [:]
        extracted["used_percent"] = json["\(prefix)_used_percent"]
        extracted["window_minutes"] = json["\(prefix)_window_minutes"]
        extracted["resets_in_seconds"] = json["\(prefix)_resets_in_seconds"]
        extracted["resets_at"] = json["\(prefix)_resets_at"]
        parse(values: extracted, timestamp: timestamp)
    }

    private mutating func parse(values: [String: Any], timestamp: Date) {
        usedPercent = TokenUsageValueParser.double(values["used_percent"])
        windowMinutes = TokenUsageValueParser.int(values["window_minutes"])
        if let resetsAt = TokenUsageValueParser.double(values["resets_at"]) {
            resetDate = Date(timeIntervalSince1970: resetsAt)
        } else if let resetsInSeconds = TokenUsageValueParser.double(values["resets_in_seconds"]) {
            resetDate = timestamp.addingTimeInterval(resetsInSeconds)
        }
    }
}

private enum TokenUsageValueParser {
    static func value(in root: Any?, keyPath: [String]) -> Any? {
        var current = root
        for key in keyPath {
            guard let dict = current as? [String: Any] else { return nil }
            current = dict[key]
        }
        return current
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string)
        default:
            return nil
        }
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }
}

private struct RateWindowSnapshot {
    var usedPercent: Double?
    var windowMinutes: Int?
    var resetsInSeconds: Double?
    var resetDate: Date? {
        guard let resetsInSeconds, let referenceTimestamp else { return nil }
        return referenceTimestamp.addingTimeInterval(resetsInSeconds)
    }

    private let referenceTimestamp: Date?

    init(json: JSONValue?, prefix: String, timestamp: Date) {
        referenceTimestamp = timestamp
        guard let json else { return }
        guard case let .object(dict) = json else { return }

        if let nested = dict[prefix] {
            usedPercent = nested.value(forKeyPath: ["used_percent"])?.doubleValue
            windowMinutes = nested.value(forKeyPath: ["window_minutes"])?.intValue
            resetsInSeconds = nested.value(forKeyPath: ["resets_in_seconds"])?.doubleValue
        } else {
            usedPercent = dict["\(prefix)_used_percent"]?.doubleValue
            windowMinutes = dict["\(prefix)_window_minutes"]?.intValue
            resetsInSeconds = dict["\(prefix)_resets_in_seconds"]?.doubleValue
        }
    }

    var isEmpty: Bool {
        usedPercent == nil && windowMinutes == nil && resetsInSeconds == nil
    }
}

private extension JSONValue {
    func value(forKeyPath path: [String]) -> JSONValue? {
        guard !path.isEmpty else { return self }
        var current: JSONValue = self
        for key in path {
            guard case let .object(dict) = current, let next = dict[key] else { return nil }
            current = next
        }
        return current
    }

    var doubleValue: Double? {
        switch self {
        case .number(let value):
            return value
        case .string(let string):
            return Double(string)
        case .bool(let bool):
            return bool ? 1 : 0
        default:
            return nil
        }
    }

}

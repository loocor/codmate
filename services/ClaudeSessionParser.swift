import Foundation

struct ClaudeParsedLog {
    let summary: SessionSummary
    let rows: [SessionRow]
}

private struct ActiveDurationAccumulator {
    var currentTurnStart: Date?
    var lastOutput: Date?
    var total: TimeInterval = 0

    mutating func observe(type: String?, timestamp: Date?) {
        guard let ts = timestamp else { return }
        switch type {
        case "user":
            flush()
            currentTurnStart = ts
            lastOutput = nil
        case "assistant", "system", "summary":
            lastOutput = ts
        default:
            break
        }
    }

    mutating func flush() {
        guard let end = lastOutput else { return }
        let start = currentTurnStart ?? end
        let delta = end.timeIntervalSince(start)
        if delta > 0 { total += delta }
        currentTurnStart = nil
        lastOutput = nil
    }
}

struct ClaudeSessionParser {
    private let decoder: JSONDecoder
    private let newline: UInt8 = 0x0A
    private let carriageReturn: UInt8 = 0x0D
    private let chunkSize = 64 * 1024

    init() {
        self.decoder = FlexibleDecoders.iso8601Flexible()
    }

    /// Fast path: extract sessionId by scanning until a line that carries it.
    /// Avoids doing full conversion work. Returns nil if not found.
    func fastSessionId(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), !data.isEmpty else {
            return nil
        }
        for var slice in data.split(separator: newline, omittingEmptySubsequences: true).prefix(256) {
            if slice.last == carriageReturn { slice = slice.dropLast() }
            guard !slice.isEmpty else { continue }
            guard let line = decodeLine(Data(slice)) else { continue }
            if let sid = line.sessionId, !sid.isEmpty { return sid }
        }
        return nil
    }

    /// Streaming summary-only parse to reduce memory for bulk indexing.
    func parseSummary(at url: URL, fileSize: UInt64? = nil) -> SessionSummary? {
        let filename = url.deletingPathExtension().lastPathComponent
        if filename.hasPrefix("agent-") {
            return nil
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var buffer = Data()
        var accumulator = SummaryAccumulator()
        var activeAccumulator = ActiveDurationAccumulator()
        var lineCount = 0

        func processLine(_ data: Data) {
            guard let line = decodeLine(data) else { return }
            if line.isSidechain == true { return }
            accumulator.consume(line)
            activeAccumulator.observe(type: line.type, timestamp: line.timestamp)
            lineCount += 1
        }

        while true {
            guard let chunk = try? handle.read(upToCount: chunkSize) else { break }
            if chunk.isEmpty {
                break
            }
            buffer.append(chunk)
            while let idx = buffer.firstIndex(of: newline) {
                let lineRange = buffer.startIndex..<idx
                let line = buffer[lineRange]
                let removeEnd = buffer.index(after: idx)
                buffer.removeSubrange(buffer.startIndex..<removeEnd)
                if line.isEmpty { continue }
                let trimmed = line.last == carriageReturn ? line.dropLast() : line[...]
                if !trimmed.isEmpty { processLine(Data(trimmed)) }
            }
        }
        if !buffer.isEmpty {
            let trimmed = buffer.last == carriageReturn ? buffer.dropLast() : buffer[...]
            if !trimmed.isEmpty { processLine(Data(trimmed)) }
        }

        activeAccumulator.flush()
        return accumulator.buildSummary(
            url: url,
            fileSize: fileSize,
            lineCount: lineCount,
            activeDuration: activeAccumulator.total > 0 ? activeAccumulator.total : nil
        )
    }

    func parse(at url: URL, fileSize: UInt64? = nil) -> ClaudeParsedLog? {
        // Skip agent-*.jsonl files entirely (sidechain warmup files)
        let filename = url.deletingPathExtension().lastPathComponent
        if filename.hasPrefix("agent-") {
            return nil
        }

        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              !data.isEmpty else { return nil }

        var accumulator = MetadataAccumulator()
        var activeAccumulator = ActiveDurationAccumulator()
        var rows: [SessionRow] = []
        rows.reserveCapacity(256)

        for var slice in data.split(separator: newline, omittingEmptySubsequences: true) {
            if slice.last == carriageReturn { slice = slice.dropLast() }
            guard !slice.isEmpty else { continue }
            guard let line = decodeLine(Data(slice)) else { continue }
            if line.isSidechain == true { continue }
            let renderedText = line.message.flatMap(renderFlatText)
            let model = line.message?.model
            let usageTokens = line.message?.usage?.totalTokens
            accumulator.consume(line, renderedText: renderedText, model: model, usageTokens: usageTokens)
            activeAccumulator.observe(type: line.type, timestamp: line.timestamp)
            rows.append(contentsOf: convert(line))
        }
        activeAccumulator.flush()

        let contextRow = accumulator.makeContextRow()
        guard let metaRow = accumulator.makeMetaRow(),
              let summary = buildSummary(
                url: url,
                fileSize: fileSize,
                metaRow: metaRow,
                contextRow: contextRow,
                additionalRows: rows,
                totalTokens: accumulator.totalTokens,
                lastTimestamp: accumulator.lastTimestamp,
                activeDuration: activeAccumulator.total > 0 ? activeAccumulator.total : nil) else {
            return nil
        }

        var combinedRows: [SessionRow] = [metaRow]
        if let contextRow { combinedRows.append(contextRow) }
        combinedRows.append(contentsOf: rows)
        return ClaudeParsedLog(summary: summary, rows: combinedRows)
    }

    private func decodeLine(_ data: Data) -> ClaudeLogLine? {
        do {
            return try decoder.decode(ClaudeLogLine.self, from: data)
        } catch {
            return nil
        }
    }

    private func convert(_ line: ClaudeLogLine) -> [SessionRow] {
        guard let timestamp = line.timestamp else { return [] }
        guard let type = line.type else { return [] }

        // Skip sidechain messages (warmup, etc.)
        if line.isSidechain == true {
            return []
        }

        switch type {
        case "user":
            return convertUser(line, timestamp: timestamp)
        case "assistant":
            return convertAssistant(line, timestamp: timestamp)
        case "system":
            return convertSystem(line, timestamp: timestamp)
        case "summary":
            guard let summary = line.summary else { return [] }
            let payload = EventMessagePayload(
                type: "system_summary",
                message: summary,
                kind: nil,
                text: summary,
                info: nil,
                rateLimits: nil)
            return [SessionRow(timestamp: timestamp, kind: .eventMessage(payload))]
        default:
            return []
        }
    }

    private func convertUser(_ line: ClaudeLogLine, timestamp: Date) -> [SessionRow] {
        guard let message = line.message else { return [] }
        let blocks = blocks(from: message)
        var rows: [SessionRow] = []

        for block in blocks {
            switch block.type {
            case "text", nil:
                if let text = renderText(from: block), !text.isEmpty {
                    let payload = EventMessagePayload(
                        type: "user_message",
                        message: text,
                        kind: nil,
                        text: text,
                        info: nil,
                        rateLimits: nil)
                    rows.append(SessionRow(timestamp: timestamp, kind: .eventMessage(payload)))
                }
            case "tool_result":
                if let text = renderText(from: block), !text.isEmpty {
                    let item = ResponseItemPayload(
                        type: "tool_output",
                        status: nil,
                        callID: block.toolUseId,
                        name: block.name,
                        content: [ResponseContentBlock(type: "text", text: text)],
                        summary: nil,
                        encryptedContent: nil,
                        role: "system")
                    rows.append(SessionRow(timestamp: timestamp, kind: .responseItem(item)))
                }
            default:
                break
            }
        }

        if let toolResult = line.toolUseResult,
           let rendered = stringify(toolResult),
           !rendered.isEmpty {
            let payload = EventMessagePayload(
                type: "tool_output",
                message: rendered,
                kind: nil,
                text: rendered,
                info: nil,
                rateLimits: nil)
            rows.append(SessionRow(timestamp: timestamp, kind: .eventMessage(payload)))
        }

        return rows
    }

    private func convertAssistant(_ line: ClaudeLogLine, timestamp: Date) -> [SessionRow] {
        guard let message = line.message else { return [] }
        let blocks = blocks(from: message)
        var rows: [SessionRow] = []

        for block in blocks {
            switch block.type {
            case "text", nil:
                if let text = renderText(from: block), !text.isEmpty {
                    let payload = EventMessagePayload(
                        type: "agent_message",
                        message: text,
                        kind: nil,
                        text: text,
                        info: nil,
                        rateLimits: nil)
                    rows.append(SessionRow(timestamp: timestamp, kind: .eventMessage(payload)))
                }
            case "tool_use":
                let rendered = block.input.flatMap { stringify($0) } ?? ""
                let contentBlocks = rendered.isEmpty
                    ? []
                    : [ResponseContentBlock(type: "text", text: rendered)]
                let item = ResponseItemPayload(
                    type: "tool_call",
                    status: nil,
                    callID: block.id,
                    name: block.name,
                    content: contentBlocks,
                    summary: nil,
                    encryptedContent: nil,
                    role: "assistant")
                rows.append(SessionRow(timestamp: timestamp, kind: .responseItem(item)))
            default:
                break
            }
        }

        return rows
    }

    private func convertSystem(_ line: ClaudeLogLine, timestamp: Date) -> [SessionRow] {
        guard let message = line.message else { return [] }
        let text = renderFlatText(message) ?? renderText(from: blocks(from: message).first)
        guard let text, !text.isEmpty else { return [] }
        let payload = EventMessagePayload(
            type: "system_message",
            message: text,
            kind: line.subtype,
            text: text,
            info: nil,
            rateLimits: nil)
        return [SessionRow(timestamp: timestamp, kind: .eventMessage(payload))]
    }

    private func buildSummary(
        url: URL,
        fileSize: UInt64?,
        metaRow: SessionRow,
        contextRow: SessionRow?,
        additionalRows: [SessionRow],
        totalTokens: Int,
        lastTimestamp: Date?,
        activeDuration: TimeInterval?
    ) -> SessionSummary? {
        var builder = SessionSummaryBuilder()
        builder.setSource(.claudeLocal)
        builder.setFileSize(fileSize)
        builder.seedTotalTokens(totalTokens)

        builder.observe(metaRow)
        if let contextRow { builder.observe(contextRow) }
        for row in additionalRows { builder.observe(row) }
        if let lastTimestamp { builder.seedLastUpdated(lastTimestamp) }
        builder.setModelFallback("Claude")
        guard let summary = builder.build(for: url) else { return nil }
        if let activeDuration {
            return SessionSummary(
                id: summary.id,
                fileURL: summary.fileURL,
                fileSizeBytes: summary.fileSizeBytes,
                startedAt: summary.startedAt,
                endedAt: summary.endedAt,
                activeDuration: activeDuration,
                cliVersion: summary.cliVersion,
                cwd: summary.cwd,
                originator: summary.originator,
                instructions: summary.instructions,
                model: summary.model,
                approvalPolicy: summary.approvalPolicy,
                userMessageCount: summary.userMessageCount,
                assistantMessageCount: summary.assistantMessageCount,
                toolInvocationCount: summary.toolInvocationCount,
                responseCounts: summary.responseCounts,
                turnContextCount: summary.turnContextCount,
                totalTokens: summary.totalTokens,
                eventCount: summary.eventCount,
                lineCount: summary.lineCount,
                lastUpdatedAt: summary.lastUpdatedAt,
                source: summary.source,
                remotePath: summary.remotePath,
                userTitle: summary.userTitle,
                userComment: summary.userComment,
                taskId: summary.taskId
            )
        }
        return summary
    }

    private func blocks(from message: ClaudeMessage) -> [ClaudeContentBlock] {
        switch message.content {
        case .string(let text):
            return [ClaudeContentBlock(type: "text", text: text, id: nil, name: nil, input: nil, toolUseId: nil, content: nil)]
        case .blocks(let blocks):
            return blocks
        case .none:
            return []
        }
    }

    private func renderFlatText(_ message: ClaudeMessage) -> String? {
        switch message.content {
        case .string(let text):
            return text
        case .blocks(let blocks):
            let rendered = blocks.compactMap { renderText(from: $0) }.joined(separator: "\n")
            return rendered.isEmpty ? nil : rendered
        case .none:
            return nil
        }
    }

    private func renderText(from block: ClaudeContentBlock?) -> String? {
        guard let block else { return nil }
        if let text = block.text, !text.isEmpty { return text }
        if let rendered = block.content.flatMap({ stringify($0) }), !rendered.isEmpty {
            return rendered
        }
        if let rendered = block.input.flatMap({ stringify($0) }), !rendered.isEmpty {
            return rendered
        }
        return nil
    }

    private func stringify(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let str):
            return str
        case .number(let number):
            return String(number)
        case .bool(let flag):
            return flag ? "true" : "false"
        case .array(let array):
            let rendered = array.compactMap { stringify($0) }.joined(separator: "\n")
            return rendered.isEmpty ? nil : rendered
        case .object(let object):
            let raw = object.mapValues { $0.toAnyValue() }
            guard JSONSerialization.isValidJSONObject(raw),
                  let data = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]),
                  let text = String(data: data, encoding: .utf8) else {
                return nil
            }
            return text
        case .null:
            return nil
        }
    }

    private struct MetadataAccumulator {
        var sessionId: String?
        var agentId: String?
        var version: String?
        var cwd: String?
        var model: String?
        var instructions: String?
        var firstTimestamp: Date?
        var lastTimestamp: Date?
        var totalTokens: Int = 0

        mutating func consume(
            _ line: ClaudeLogLine,
            renderedText: String?,
            model: String?,
            usageTokens: Int?
        ) {
            if let sid = line.sessionId, sessionId == nil { sessionId = sid }
            if let aid = line.agentId, agentId == nil { agentId = aid }
            if let ver = line.version, version == nil { version = ver }
            if let path = line.cwd, cwd == nil { cwd = path }
            if let timestamp = line.timestamp {
                if firstTimestamp == nil || timestamp < firstTimestamp! { firstTimestamp = timestamp }
                if lastTimestamp == nil || timestamp > lastTimestamp! { lastTimestamp = timestamp }
            }
            if instructions == nil, line.isMeta == true,
               let text = renderedText, !text.isEmpty {
                instructions = text
            }
            if self.model == nil, let model, !model.isEmpty {
                self.model = model
            }
            if let usageTokens, usageTokens > 0 {
                totalTokens &+= usageTokens
            }
        }

        func makeMetaRow() -> SessionRow? {
            guard let sessionId, let timestamp = firstTimestamp, let cwd else { return nil }
            let payload = SessionMetaPayload(
                id: sessionId,
                timestamp: timestamp,
                cwd: cwd,
                originator: "Claude Code",
                cliVersion: "claude-code \(version ?? "unknown")",
                instructions: instructions
            )
            return SessionRow(timestamp: timestamp, kind: .sessionMeta(payload))
        }

        func makeContextRow() -> SessionRow? {
            // For Claude sessions, we don't generate context update rows.
            // Model info is already shown in the session info card at the top.
            // This avoids duplicate "Syncing / Context Updated / model: xxx" entries in the timeline.
            return nil
        }
    }

    private struct ClaudeLogLine: Decodable {
        let type: String?
        let timestamp: Date?
        let sessionId: String?
        let agentId: String?
        let version: String?
        let cwd: String?
        let message: ClaudeMessage?
        let toolUseResult: JSONValue?
        let summary: String?
        let isMeta: Bool?
        let subtype: String?
        let isSidechain: Bool?
    }

    private struct ClaudeMessage: Decodable {
        let role: String?
        let model: String?
        let content: ClaudeMessageContent?
        let usage: ClaudeUsage?

        enum CodingKeys: String, CodingKey {
            case role
            case model
            case content
            case usage
        }
    }

    private struct ClaudeUsage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheReadInputTokens: Int?
        let cacheCreationInputTokens: Int?
        let cacheCreation: CacheCreation?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
            case cacheCreation = "cache_creation"
        }

        struct CacheCreation: Decodable {
            let ephemeral5m: Int?
            let ephemeral1h: Int?

            enum CodingKeys: String, CodingKey {
                case ephemeral5m = "ephemeral_5m_input_tokens"
                case ephemeral1h = "ephemeral_1h_input_tokens"
            }
        }

        var totalTokens: Int {
            let creation = (cacheCreationInputTokens ?? 0) +
                (cacheCreation?.ephemeral5m ?? 0) +
                (cacheCreation?.ephemeral1h ?? 0)
            return (inputTokens ?? 0) + (outputTokens ?? 0) + (cacheReadInputTokens ?? 0) + creation
        }
    }

    private enum ClaudeMessageContent: Decodable {
        case string(String)
        case blocks([ClaudeContentBlock])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .string(text)
                return
            }
            if let block = try? container.decode(ClaudeContentBlock.self) {
                self = .blocks([block])
                return
            }
            if let blocks = try? container.decode([ClaudeContentBlock].self) {
                self = .blocks(blocks)
                return
            }
            self = .blocks([])
        }
    }

    private struct ClaudeContentBlock: Decodable {
        let type: String?
        let text: String?
        let id: String?
        let name: String?
        let input: JSONValue?
        let toolUseId: String?
        let content: JSONValue?
    }

    private struct SummaryAccumulator {
        var sessionId: String?
        var version: String?
        var cwd: String?
        var model: String?
        var firstTimestamp: Date?
        var lastTimestamp: Date?
        var userMessageCount = 0
        var assistantMessageCount = 0
        var toolInvocationCount = 0
        var responseCounts: [String: Int] = [:]
        var totalTokens = 0

        mutating func consume(_ line: ClaudeLogLine) {
            guard let type = line.type else { return }
            if let sid = line.sessionId, sessionId == nil { sessionId = sid }
            if let ver = line.version, version == nil { version = ver }
            if let path = line.cwd, cwd == nil { cwd = path }
            if let m = line.message?.model, model == nil, !m.isEmpty { model = m }
            if let ts = line.timestamp {
                if firstTimestamp == nil || ts < firstTimestamp! { firstTimestamp = ts }
                if lastTimestamp == nil || ts > lastTimestamp! { lastTimestamp = ts }
            }

            switch type {
            case "user":
                userMessageCount &+= 1
            case "assistant":
                assistantMessageCount &+= 1
                if let usage = line.message?.usage {
                    totalTokens &+= usage.totalTokens
                }
                toolInvocationCount &+= countToolCalls(in: line.message)
            default:
                break
            }
        }

        func buildSummary(
            url: URL,
            fileSize: UInt64?,
            lineCount: Int,
            activeDuration: TimeInterval?
        ) -> SessionSummary? {
            guard let sessionId, let started = firstTimestamp, let cwd else { return nil }
        let summary = SessionSummary(
            id: sessionId,
            fileURL: url,
            fileSizeBytes: fileSize,
            startedAt: started,
            endedAt: lastTimestamp,
            activeDuration: activeDuration,
            cliVersion: "claude-code \(version ?? "unknown")",
            cwd: cwd,
            originator: "Claude Code",
            instructions: nil,
            model: model,
                approvalPolicy: nil,
                userMessageCount: userMessageCount,
                assistantMessageCount: assistantMessageCount,
                toolInvocationCount: toolInvocationCount,
                responseCounts: responseCounts,
                turnContextCount: 0,
                totalTokens: totalTokens,
                eventCount: userMessageCount + assistantMessageCount,
                lineCount: lineCount,
                lastUpdatedAt: lastTimestamp,
                source: .claudeLocal,
                remotePath: nil
            )
            return summary
        }

        private func countToolCalls(in message: ClaudeMessage?) -> Int {
            guard let message else { return 0 }
            switch message.content {
            case .blocks(let blocks):
                return blocks.reduce(0) { partial, block in
                    partial + (block.type == "tool_use" ? 1 : 0)
                }
            case .string, .none:
                return 0
            }
        }
    }
}

private extension JSONValue {
    func toAnyValue() -> Any {
        switch self {
        case .string(let str): return str
        case .number(let number): return number
        case .bool(let flag): return flag
        case .array(let array): return array.map { $0.toAnyValue() }
        case .object(let dict): return dict.mapValues { $0.toAnyValue() }
        case .null: return NSNull()
        }
    }
}

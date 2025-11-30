import Foundation

struct GeminiParsedLog {
  let summary: SessionSummary
  let rows: [SessionRow]
}

private let geminiAbsolutePathRegex = try! NSRegularExpression(
  pattern: #"((?:~|/)[^\s"']+)"#, options: [])
private let geminiPathTrimCharacters = CharacterSet(charactersIn: ",.;:)]}>\"'")

struct GeminiSessionParser {
  private struct ConversationRecord: Decodable {
    struct Message: Decodable {
      struct ToolCall: Decodable {
        let id: String?
        let name: String?
        let args: JSONValue?
        let result: JSONValue?
        let description: String?
        let displayName: String?
        let resultDisplay: String?
        let status: String?
        let renderOutputAsMarkdown: Bool?
      }

      struct Thought: Decodable {
        let subject: String?
        let description: String?
        let timestamp: String?
      }

      struct Tokens: Decodable {
        let input: Int?
        let output: Int?
        let cached: Int?
        let thoughts: Int?
        let tool: Int?
        let total: Int?
      }

      let id: String
      let timestamp: String?
      let type: String
      let content: JSONValue?
      let model: String?
      let toolCalls: [ToolCall]?
      let thoughts: [Thought]?
      let tokens: Tokens?
    }

    let sessionId: String
    let projectHash: String?
    let startTime: String
    let lastUpdated: String?
    let messages: [Message]
  }

  private let decoder: JSONDecoder
  private let isoFormatter: ISO8601DateFormatter
  private let fallbackFormatter: ISO8601DateFormatter

  init(decoder: JSONDecoder = JSONDecoder()) {
    self.decoder = decoder
    self.isoFormatter = ISO8601DateFormatter()
    self.isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    self.fallbackFormatter = ISO8601DateFormatter()
    self.fallbackFormatter.formatOptions = [.withInternetDateTime]
  }

  func parse(
    at url: URL,
    projectHash: String,
    resolvedProjectPath: String?
  ) -> GeminiParsedLog? {
    guard
      let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
      let record = try? decoder.decode(ConversationRecord.self, from: data),
      let startedAt = parseDate(record.startTime)
    else { return nil }

    let sessionFileId = url.deletingPathExtension().lastPathComponent
    let inferredDirectory =
      resolvedProjectPath
      ?? inferWorkingDirectory(from: record.messages)
      ?? defaultProjectPath(forHash: projectHash)
    let cwd = inferredDirectory
    var rows: [SessionRow] = []

    let meta = SessionMetaPayload(
      id: sessionFileId,
      timestamp: startedAt,
      cwd: cwd,
      originator: "Gemini CLI",
      cliVersion: "Gemini CLI",
      instructions: nil
    )
    let metaRow = SessionRow(timestamp: startedAt, kind: .sessionMeta(meta))
    rows.append(metaRow)

    if let model = firstModel(in: record.messages) {
      let ctx = TurnContextPayload(
        cwd: cwd,
        approvalPolicy: nil,
        model: model,
        effort: nil,
        summary: nil
      )
      rows.append(SessionRow(timestamp: startedAt, kind: .turnContext(ctx)))
    }

    var lastTimestamp = startedAt
    for message in record.messages {
      let messageRows = self.rows(from: message)
      rows.append(contentsOf: messageRows)
      if let last = messageRows.last?.timestamp, last > lastTimestamp {
        lastTimestamp = last
      }
    }

    let fileSize = resolveFileSize(for: url)
    var builder = SessionSummaryBuilder()
    builder.setFileSize(fileSize)
    builder.setSource(.geminiLocal)

    for row in rows {
      builder.observe(row)
    }

    if let updated = parseDate(record.lastUpdated) ?? rows.last?.timestamp {
      builder.seedLastUpdated(updated)
    } else {
      builder.seedLastUpdated(lastTimestamp)
    }

    guard var summary = builder.build(for: url) else { return nil }
    summary = summary.overridingSource(.geminiLocal)
    return GeminiParsedLog(summary: summary, rows: rows)
  }

  private func firstModel(in messages: [ConversationRecord.Message]) -> String? {
    for message in messages {
      if let model = message.model, !model.isEmpty {
        return model
      }
    }
    return nil
  }

  private func parseDate(_ value: String?) -> Date? {
    guard let value else { return nil }
    if let date = isoFormatter.date(from: value) { return date }
    if let date = fallbackFormatter.date(from: value) { return date }
    if let number = Double(value) {
      if number > 10_000_000_000 {
        return Date(timeIntervalSince1970: number / 1000.0)
      } else {
        return Date(timeIntervalSince1970: number)
      }
    }
    return nil
  }

  private func rows(from message: ConversationRecord.Message) -> [SessionRow] {
    guard let timestamp = parseDate(message.timestamp) else { return [] }
    var results: [SessionRow] = []
    let text = renderText(from: message.content) ?? ""
    let loweredType = message.type.lowercased()
    switch loweredType {
    case "user":
      if !text.isEmpty {
        results.append(
          SessionRow(
            timestamp: timestamp,
            kind: .eventMessage(
              EventMessagePayload(
                type: "user_message",
                message: text,
                kind: nil,
                text: text,
                info: nil,
                rateLimits: nil
              )))
        )
      }
    case "gemini":
      if !text.isEmpty {
        results.append(
          SessionRow(
            timestamp: timestamp,
            kind: .eventMessage(
              EventMessagePayload(
                type: "agent_message",
                message: text,
                kind: nil,
                text: text,
                info: nil,
                rateLimits: nil
              )))
        )
      }
      if let calls = message.toolCalls, !calls.isEmpty {
        for call in calls {
          if let row = toolCallRow(call, timestamp: timestamp) {
            results.append(row)
          }
        }
      }
      if let thoughts = message.thoughts {
        for thought in thoughts {
          if let row = thoughtRow(thought, fallback: timestamp) {
            results.append(row)
          }
        }
      }
      if let tokens = message.tokens {
        if let row = tokenRow(tokens, timestamp: timestamp) {
          results.append(row)
        }
      }
    case "info", "warning":
      if !text.isEmpty {
        results.append(
          SessionRow(
            timestamp: timestamp,
            kind: .eventMessage(
              EventMessagePayload(
                type: loweredType,
                message: text,
                kind: nil,
                text: text,
                info: nil,
                rateLimits: nil
              )))
        )
      }
    case "error":
      if !text.isEmpty {
        results.append(
          SessionRow(
            timestamp: timestamp,
            kind: .eventMessage(
              EventMessagePayload(
                type: "error",
                message: text,
                kind: nil,
                text: text,
                info: nil,
                rateLimits: nil
              )))
        )
      }
    default:
      if !text.isEmpty {
        results.append(
          SessionRow(
            timestamp: timestamp,
            kind: .eventMessage(
              EventMessagePayload(
                type: loweredType,
                message: text,
                kind: nil,
                text: text,
                info: nil,
                rateLimits: nil
              )))
        )
      }
    }
    return results
  }

  private func toolCallRow(
    _ call: ConversationRecord.Message.ToolCall,
    timestamp: Date
  ) -> SessionRow? {
    guard let name = call.name ?? call.displayName else { return nil }
    var blocks: [ResponseContentBlock] = []
    if let rendered = renderText(from: call.args), !rendered.isEmpty {
      blocks.append(ResponseContentBlock(type: "text", text: rendered))
    }
    if let rendered = renderText(from: call.result), !rendered.isEmpty {
      blocks.append(ResponseContentBlock(type: "text", text: rendered))
    }
    let payload = ResponseItemPayload(
      type: "tool_call",
      status: call.status,
      callID: call.id,
      name: name,
      content: blocks.isEmpty ? nil : blocks,
      summary: nil,
      encryptedContent: nil,
      role: "assistant"
    )
    return SessionRow(timestamp: timestamp, kind: .responseItem(payload))
  }

  private func thoughtRow(
    _ thought: ConversationRecord.Message.Thought,
    fallback: Date
  ) -> SessionRow? {
    let subject = thought.subject?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard let description = thought.description else { return nil }
    var body = description
    if !subject.isEmpty {
      body = "\(subject): \(description)"
    }
    guard !body.isEmpty else { return nil }
    let payload = EventMessagePayload(
      type: "agent_reasoning",
      message: body,
      kind: nil,
      text: body,
      info: nil,
      rateLimits: nil
    )
    return SessionRow(timestamp: parseDate(thought.timestamp) ?? fallback, kind: .eventMessage(payload))
  }

  private func tokenRow(
    _ tokens: ConversationRecord.Message.Tokens,
    timestamp: Date
  ) -> SessionRow? {
    let details: [String] = [
      tokens.input.flatMap { "input: \($0)" },
      tokens.output.flatMap { "output: \($0)" },
      tokens.cached.flatMap { "cached: \($0)" },
      tokens.thoughts.flatMap { "thoughts: \($0)" },
      tokens.tool.flatMap { "tool: \($0)" },
      tokens.total.flatMap { "total: \($0)" },
    ].compactMap { $0 }

    guard !details.isEmpty else { return nil }
    let text = details.joined(separator: ", ")
    let payload = EventMessagePayload(
      type: "token_count",
      message: text,
      kind: nil,
      text: text,
      info: nil,
      rateLimits: nil
    )
    return SessionRow(timestamp: timestamp, kind: .eventMessage(payload))
  }

  private func renderText(from value: JSONValue?) -> String? {
    guard let value else { return nil }
    switch value {
    case .string(let str):
      let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : str
    case .number(let number):
      return String(number)
    case .bool(let flag):
      return flag ? "true" : "false"
    case .array(let array):
      let rendered = array.compactMap { renderText(from: $0) }.joined(separator: "\n")
      return rendered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : rendered
    case .object(let object):
      let raw = object.mapValues { $0.toAnyValue() }
      guard
        JSONSerialization.isValidJSONObject(raw),
        let data = try? JSONSerialization.data(
          withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]),
        let text = String(data: data, encoding: .utf8)
      else {
        return nil
      }
      return text
    case .null:
      return nil
    }
  }

  private func resolveFileSize(for url: URL) -> UInt64? {
    if
      let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
      let size = values.fileSize
    {
      return UInt64(size)
    }
    return nil
  }

  private func defaultProjectPath(forHash hash: String) -> String {
    let realHome = SessionPreferencesStore.getRealUserHomeURL().path
    return "\(realHome)/.gemini/tmp/\(hash)"
  }

  // MARK: - Workspace heuristics
  private func inferWorkingDirectory(from messages: [ConversationRecord.Message]) -> String? {
    var candidates: [String] = []
    candidates.reserveCapacity(32)

    func append(paths: [String]) {
      guard !paths.isEmpty else { return }
      candidates.append(contentsOf: paths)
    }

    for message in messages {
      append(paths: absolutePaths(in: message.content))
      if let toolCalls = message.toolCalls {
        for call in toolCalls {
          append(paths: absolutePaths(in: call.args))
          append(paths: absolutePaths(in: call.result))
          if let display = call.resultDisplay {
            append(paths: absolutePaths(in: display))
          }
          if let description = call.description {
            append(paths: absolutePaths(in: description))
          }
        }
      }
    }

    let normalized = candidates.compactMap { canonicalAbsolutePath(from: $0) }
    guard !normalized.isEmpty else { return nil }
    guard let prefix = commonPathPrefix(for: normalized) else { return nil }
    return trimmedWorkspacePrefix(for: prefix)
  }

  private func absolutePaths(in value: JSONValue?) -> [String] {
    guard let value else { return [] }
    switch value {
    case .string(let text):
      return absolutePaths(in: text)
    case .array(let array):
      return array.flatMap { absolutePaths(in: $0) }
    case .object(let dict):
      return dict.values.flatMap { absolutePaths(in: $0) }
    case .number, .bool, .null:
      return []
    }
  }

  private func absolutePaths(in text: String) -> [String] {
    guard !text.isEmpty else { return [] }
    let nsText = text as NSString
    let range = NSRange(location: 0, length: nsText.length)
    var matches: [String] = []
    geminiAbsolutePathRegex.enumerateMatches(in: text, options: [], range: range) { result, _, _ in
      guard let result, result.range.location != NSNotFound else { return }
      var candidate = nsText.substring(with: result.range)
      candidate = candidate.trimmingCharacters(in: geminiPathTrimCharacters)
      guard !candidate.isEmpty else { return }
      matches.append(candidate)
    }
    return matches
  }

  private func canonicalAbsolutePath(from raw: String) -> String? {
    let expanded = (raw as NSString).expandingTildeInPath
    guard expanded.hasPrefix("/") else { return nil }
    var standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
    if standardized.count > 1 && standardized.hasSuffix("/") {
      standardized.removeLast()
    }
    return standardized
  }

  private func commonPathPrefix(for paths: [String]) -> String? {
    guard let first = paths.first else { return nil }
    var prefixComponents = Self.pathComponents(for: first)
    for path in paths.dropFirst() {
      let comps = Self.pathComponents(for: path)
      var next: [String] = []
      for (lhs, rhs) in zip(prefixComponents, comps) {
        if lhs == rhs {
          next.append(lhs)
        } else {
          break
        }
      }
      prefixComponents = next
      if prefixComponents.isEmpty { return nil }
    }
    guard !prefixComponents.isEmpty else { return nil }
    return "/" + prefixComponents.joined(separator: "/")
  }

  private static func pathComponents(for path: String) -> [String] {
    path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
  }

  private func trimmedWorkspacePrefix(for prefix: String) -> String? {
    guard prefix.count > 1 else { return nil }
    var path = prefix
    if path.hasSuffix("/") {
      path.removeLast()
    }
    guard !path.isEmpty else { return nil }
    let components = Self.pathComponents(for: path)
    if let last = components.last, last.contains("."), components.count > 1 {
      let dropped = components.dropLast()
      if dropped.isEmpty { return nil }
      return "/" + dropped.joined(separator: "/")
    }
    return "/" + components.joined(separator: "/")
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

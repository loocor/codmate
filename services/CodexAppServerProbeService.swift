import Foundation

/// Best-effort probe for Codex rate limits and account info via `codex app-server`.
///
/// This is intentionally lightweight and avoids creating Codex session logs, unlike starting
/// interactive sessions. It is used to show Codex quota windows (5h/weekly) even when no
/// recent session files are available.
actor CodexAppServerProbeService {
  struct Snapshot: Sendable {
    let fetchedAt: Date
    let primaryUsedPercent: Double?
    let primaryWindowMinutes: Int?
    let primaryResetAt: Date?
    let secondaryUsedPercent: Double?
    let secondaryWindowMinutes: Int?
    let secondaryResetAt: Date?
    let planType: String?
  }

  enum ProbeError: Swift.Error, LocalizedError {
    case codexNotFound
    case startFailed(String)
    case malformedResponse(String)
    case requestFailed(String)

    var errorDescription: String? {
      switch self {
      case .codexNotFound:
        return "Codex CLI not found on PATH."
      case .startFailed(let message):
        return "Failed to start codex app-server: \(message)"
      case .malformedResponse(let message):
        return "Malformed codex app-server response: \(message)"
      case .requestFailed(let message):
        return "Codex app-server request failed: \(message)"
      }
    }
  }

  private var cached: Snapshot?
  private var inFlight: Task<Snapshot, Error>?

  /// Returns cached data when it's fresh enough; otherwise starts a new probe.
  func fetchIfStale(maxAge: TimeInterval = 60) async throws -> Snapshot {
    if let cached {
      let age = Date().timeIntervalSince(cached.fetchedAt)
      if age >= 0, age <= maxAge { return cached }
    }
    if let inFlight {
      let fresh = try await inFlight.value
      self.cached = fresh
      return fresh
    }

    let task = Task { try await Self.fetchOnce() }
    self.inFlight = task
    defer { self.inFlight = nil }
    let fresh = try await task.value
    self.cached = fresh
    return fresh
  }

  /// Best-effort wrapper that never throws (used by UI refresh paths).
  func fetchIfStaleOrNil(maxAge: TimeInterval = 60) async -> Snapshot? {
    do {
      return try await fetchIfStale(maxAge: maxAge)
    } catch {
      return nil
    }
  }

  // MARK: - Probe implementation

  private static func fetchOnce() async throws -> Snapshot {
    let client = try CodexRPCClient()
    defer { client.shutdown() }

    try await client.initialize(clientName: "codmate", clientVersion: Bundle.main.shortVersionString)

    let rateLimits = try await client.fetchRateLimits().rateLimits
    let account = try? await client.fetchAccount()

    let fetchedAt = Date()
    let primary = Self.window(from: rateLimits.primary)
    let secondary = Self.window(from: rateLimits.secondary)
    let planType: String? = account?.account.flatMap { details in
      if case let .chatgpt(_, planType) = details { return planType } else { return nil }
    }

    return Snapshot(
      fetchedAt: fetchedAt,
      primaryUsedPercent: primary.usedPercent,
      primaryWindowMinutes: primary.windowMinutes,
      primaryResetAt: primary.resetsAt,
      secondaryUsedPercent: secondary.usedPercent,
      secondaryWindowMinutes: secondary.windowMinutes,
      secondaryResetAt: secondary.resetsAt,
      planType: planType
    )
  }

  private struct RateWindow: Sendable {
    let usedPercent: Double?
    let windowMinutes: Int?
    let resetsAt: Date?
  }

  private static func window(from rpc: RPCRateLimitWindow?) -> RateWindow {
    guard let rpc else {
      return RateWindow(usedPercent: nil, windowMinutes: nil, resetsAt: nil)
    }
    let resetsAt = rpc.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    return RateWindow(usedPercent: rpc.usedPercent, windowMinutes: rpc.windowDurationMins, resetsAt: resetsAt)
  }
}

// MARK: - Codex JSON-RPC client (local `codex app-server` process)

private struct RPCRateLimitsResponse: Decodable {
  let rateLimits: RPCRateLimitSnapshot
}

private struct RPCRateLimitSnapshot: Decodable {
  let primary: RPCRateLimitWindow?
  let secondary: RPCRateLimitWindow?
}

private struct RPCRateLimitWindow: Decodable {
  let usedPercent: Double
  let windowDurationMins: Int?
  let resetsAt: Int?
}

private struct RPCAccountResponse: Decodable {
  let account: RPCAccountDetails?
}

private enum RPCAccountDetails: Decodable {
  case apiKey
  case chatgpt(email: String, planType: String)

  enum CodingKeys: String, CodingKey {
    case type
    case email
    case planType
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)
    switch type.lowercased() {
    case "apikey":
      self = .apiKey
    case "chatgpt":
      let email = try container.decodeIfPresent(String.self, forKey: .email) ?? "unknown"
      let plan = try container.decodeIfPresent(String.self, forKey: .planType) ?? "unknown"
      self = .chatgpt(email: email, planType: plan)
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .type,
        in: container,
        debugDescription: "Unknown account type \(type)"
      )
    }
  }
}

private final class CodexRPCClient: @unchecked Sendable {
  private let process = Process()
  private let stdinPipe = Pipe()
  private let stdoutPipe = Pipe()
  private let stderrPipe = Pipe()
  private var nextID = 1

  init() throws {
    let env = Self.buildEnvironment()

    self.process.environment = env
    self.process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    self.process.arguments = [
      "codex",
      "-s", "read-only",
      "-a", "untrusted",
      "app-server",
    ]
    self.process.standardInput = self.stdinPipe
    self.process.standardOutput = self.stdoutPipe
    self.process.standardError = self.stderrPipe

    do {
      try self.process.run()
    } catch {
      throw CodexAppServerProbeService.ProbeError.startFailed(error.localizedDescription)
    }

    let stderrHandle = self.stderrPipe.fileHandleForReading
    stderrHandle.readabilityHandler = { handle in
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
        return
      }
      guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
      for line in text.split(whereSeparator: \.isNewline) {
        fputs("[codex stderr] \(line)\n", stderr)
      }
    }
  }

  func initialize(clientName: String, clientVersion: String) async throws {
    _ = try await request(
      method: "initialize",
      params: ["clientInfo": ["name": clientName, "version": clientVersion]]
    )
    try sendNotification(method: "initialized")
  }

  func fetchRateLimits() async throws -> RPCRateLimitsResponse {
    let message = try await request(method: "account/rateLimits/read")
    return try decodeResult(from: message)
  }

  func fetchAccount() async throws -> RPCAccountResponse {
    let message = try await request(method: "account/read")
    return try decodeResult(from: message)
  }

  func shutdown() {
    if self.process.isRunning {
      self.process.terminate()
    }
  }

  // MARK: - JSON-RPC helpers

  private func request(method: String, params: [String: Any]? = nil) async throws -> [String: Any] {
    let id = self.nextID
    self.nextID += 1
    try sendRequest(id: id, method: method, params: params)

    while true {
      let message = try await readNextMessage()

      if message["id"] == nil {
        continue
      }

      guard let messageID = jsonID(message["id"]), messageID == id else { continue }

      if let error = message["error"] as? [String: Any],
        let messageText = error["message"] as? String
      {
        throw CodexAppServerProbeService.ProbeError.requestFailed(messageText)
      }

      return message
    }
  }

  private func sendNotification(method: String, params: [String: Any]? = nil) throws {
    let paramsValue: Any = params ?? [:]
    try sendPayload(["method": method, "params": paramsValue])
  }

  private func sendRequest(id: Int, method: String, params: [String: Any]?) throws {
    let paramsValue: Any = params ?? [:]
    try sendPayload(["id": id, "method": method, "params": paramsValue])
  }

  private func sendPayload(_ payload: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: payload)
    self.stdinPipe.fileHandleForWriting.write(data)
    self.stdinPipe.fileHandleForWriting.write(Data([0x0A]))
  }

  private func readNextMessage() async throws -> [String: Any] {
    for try await lineData in self.stdoutPipe.fileHandleForReading.bytes.lines {
      if lineData.isEmpty { continue }
      let line = String(lineData)
      guard let data = line.data(using: .utf8) else { continue }
      if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
        return json
      }
    }
    throw CodexAppServerProbeService.ProbeError.malformedResponse("codex app-server closed stdout")
  }

  private func decodeResult<T: Decodable>(from message: [String: Any]) throws -> T {
    guard let result = message["result"] else {
      throw CodexAppServerProbeService.ProbeError.malformedResponse("missing result field")
    }
    let data = try JSONSerialization.data(withJSONObject: result)
    return try JSONDecoder().decode(T.self, from: data)
  }

  private func jsonID(_ value: Any?) -> Int? {
    switch value {
    case let int as Int:
      return int
    case let number as NSNumber:
      return number.intValue
    default:
      return nil
    }
  }

  private static func buildEnvironment() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let base = [
      "/opt/homebrew/bin",
      "/usr/local/bin",
      "/usr/bin",
      "/bin",
      "\(home)/.local/bin",
      "\(home)/.bun/bin",
    ].joined(separator: ":")
    if let current = env["PATH"], !current.isEmpty {
      env["PATH"] = base + ":" + current
    } else {
      env["PATH"] = base
    }
    env["NO_COLOR"] = "1"
    return env
  }
}

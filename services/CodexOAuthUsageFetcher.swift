import Foundation

// MARK: - Codex OAuth Credentials

/// OAuth credentials from Codex auth.json file
struct CodexOAuthCredentials: Sendable {
  let accessToken: String
  let refreshToken: String
  let idToken: String?
  let accountId: String?
  let lastRefresh: Date?

  var needsRefresh: Bool {
    guard let lastRefresh else { return true }
    // Tokens typically last 14 days; refresh after 8 days to be safe
    let eightDays: TimeInterval = 8 * 24 * 60 * 60
    return Date().timeIntervalSince(lastRefresh) > eightDays
  }
}

enum CodexOAuthCredentialsError: LocalizedError, Sendable {
  case notFound
  case decodeFailed(String)
  case missingTokens

  var errorDescription: String? {
    switch self {
    case .notFound:
      return "Codex auth.json not found. Run `codex` to log in."
    case .decodeFailed(let message):
      return "Failed to decode Codex credentials: \(message)"
    case .missingTokens:
      return "Codex auth.json exists but contains no tokens."
    }
  }
}

/// Storage for Codex OAuth credentials (reads/writes auth.json)
enum CodexOAuthCredentialsStore {
  private static var authFilePath: URL {
    let home = SessionPreferencesStore.getRealUserHomeURL()
    if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]?.trimmingCharacters(
      in: .whitespacesAndNewlines),
      !codexHome.isEmpty
    {
      return URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json")
    }
    return home.appendingPathComponent(".codex/auth.json")
  }

  static func load() throws -> CodexOAuthCredentials {
    let url = authFilePath
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw CodexOAuthCredentialsError.notFound
    }

    let data = try Data(contentsOf: url)
    return try parse(data: data)
  }

  static func parse(data: Data) throws -> CodexOAuthCredentials {
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw CodexOAuthCredentialsError.decodeFailed("Invalid JSON")
    }

    // Check for API key auth (non-OAuth)
    if let apiKey = json["OPENAI_API_KEY"] as? String,
       !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return CodexOAuthCredentials(
        accessToken: apiKey,
        refreshToken: "",
        idToken: nil,
        accountId: nil,
        lastRefresh: nil)
    }

    // Look for OAuth tokens
    guard let tokens = json["tokens"] as? [String: Any] else {
      throw CodexOAuthCredentialsError.missingTokens
    }
    guard let accessToken = tokens["access_token"] as? String,
          let refreshToken = tokens["refresh_token"] as? String,
          !accessToken.isEmpty
    else {
      throw CodexOAuthCredentialsError.missingTokens
    }

    let idToken = tokens["id_token"] as? String
    let accountId = tokens["account_id"] as? String
    let lastRefresh = parseLastRefresh(from: json["last_refresh"])

    return CodexOAuthCredentials(
      accessToken: accessToken,
      refreshToken: refreshToken,
      idToken: idToken,
      accountId: accountId,
      lastRefresh: lastRefresh)
  }

  static func save(_ credentials: CodexOAuthCredentials) throws {
    let url = authFilePath

    var json: [String: Any] = [:]
    if let data = try? Data(contentsOf: url),
       let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
      json = existing
    }

    var tokens: [String: Any] = [
      "access_token": credentials.accessToken,
      "refresh_token": credentials.refreshToken,
    ]
    if let idToken = credentials.idToken {
      tokens["id_token"] = idToken
    }
    if let accountId = credentials.accountId {
      tokens["account_id"] = accountId
    }

    json["tokens"] = tokens
    json["last_refresh"] = ISO8601DateFormatter().string(from: Date())

    let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
  }

  private static func parseLastRefresh(from raw: Any?) -> Date? {
    guard let value = raw as? String, !value.isEmpty else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }
}

// MARK: - Codex OAuth Usage Fetcher

/// Fetches Codex usage data directly from ChatGPT OAuth API
/// This is more reliable than the codex app-server JSON-RPC approach
enum CodexOAuthUsageFetcher {
  private static let defaultChatGPTBaseURL = "https://chatgpt.com/backend-api/"
  private static let chatGPTUsagePath = "/wham/usage"
  private static let codexUsagePath = "/api/codex/usage"

  enum FetchError: LocalizedError, Sendable {
    case unauthorized
    case invalidResponse
    case serverError(Int, String?)
    case networkError(Error)

    var errorDescription: String? {
      switch self {
      case .unauthorized:
        return "Codex OAuth token expired or invalid. Run `codex` to re-authenticate."
      case .invalidResponse:
        return "Invalid response from Codex usage API."
      case .serverError(let code, let message):
        if let message, !message.isEmpty {
          return "Codex API error \(code): \(message)"
        }
        return "Codex API error \(code)."
      case .networkError(let error):
        return "Network error: \(error.localizedDescription)"
      }
    }
  }

  struct UsageResponse: Decodable, Sendable {
    let planType: PlanType?
    let rateLimit: RateLimitDetails?
    let credits: CreditDetails?

    enum CodingKeys: String, CodingKey {
      case planType = "plan_type"
      case rateLimit = "rate_limit"
      case credits
    }

    enum PlanType: Sendable, Decodable, Equatable {
      case guest
      case free
      case go
      case plus
      case pro
      case freeWorkspace
      case team
      case business
      case education
      case quorum
      case k12
      case enterprise
      case edu
      case unknown(String)

      var rawValue: String {
        switch self {
        case .guest: "guest"
        case .free: "free"
        case .go: "go"
        case .plus: "plus"
        case .pro: "pro"
        case .freeWorkspace: "free_workspace"
        case .team: "team"
        case .business: "business"
        case .education: "education"
        case .quorum: "quorum"
        case .k12: "k12"
        case .enterprise: "enterprise"
        case .edu: "edu"
        case let .unknown(value): value
        }
      }

      init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value {
        case "guest": self = .guest
        case "free": self = .free
        case "go": self = .go
        case "plus": self = .plus
        case "pro": self = .pro
        case "free_workspace": self = .freeWorkspace
        case "team": self = .team
        case "business": self = .business
        case "education": self = .education
        case "quorum": self = .quorum
        case "k12": self = .k12
        case "enterprise": self = .enterprise
        case "edu": self = .edu
        default:
          self = .unknown(value)
        }
      }
    }

    struct RateLimitDetails: Decodable, Sendable {
      let primaryWindow: WindowSnapshot?
      let secondaryWindow: WindowSnapshot?

      enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
      }
    }

    struct WindowSnapshot: Decodable, Sendable {
      let usedPercent: Int
      let resetAt: Int
      let limitWindowSeconds: Int

      enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case resetAt = "reset_at"
        case limitWindowSeconds = "limit_window_seconds"
      }
    }

    struct CreditDetails: Decodable, Sendable {
      let hasCredits: Bool
      let unlimited: Bool
      let balance: Double?

      enum CodingKeys: String, CodingKey {
        case hasCredits = "has_credits"
        case unlimited
        case balance
      }

      init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasCredits = (try? container.decode(Bool.self, forKey: .hasCredits)) ?? false
        unlimited = (try? container.decode(Bool.self, forKey: .unlimited)) ?? false
        if let balance = try? container.decode(Double.self, forKey: .balance) {
          self.balance = balance
        } else if let balance = try? container.decode(String.self, forKey: .balance),
                  let value = Double(balance)
        {
          self.balance = value
        } else {
          balance = nil
        }
      }
    }
  }

  static func fetchUsage(accessToken: String, accountId: String?) async throws -> UsageResponse {
    var request = URLRequest(url: resolveUsageURL())
    request.httpMethod = "GET"
    request.timeoutInterval = 30
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("CodMate", forHTTPHeaderField: "User-Agent")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    if let accountId, !accountId.isEmpty {
      request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
    }

    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        throw FetchError.invalidResponse
      }

      switch http.statusCode {
      case 200...299:
        do {
          return try JSONDecoder().decode(UsageResponse.self, from: data)
        } catch {
          throw FetchError.invalidResponse
        }
      case 401, 403:
        throw FetchError.unauthorized
      default:
        let body = String(data: data, encoding: .utf8)
        throw FetchError.serverError(http.statusCode, body)
      }
    } catch let error as FetchError {
      throw error
    } catch {
      throw FetchError.networkError(error)
    }
  }

  /// Fetch usage and return the plan type directly
  static func fetchPlanType() async throws -> String? {
    let credentials = try CodexOAuthCredentialsStore.load()
    let response = try await fetchUsage(accessToken: credentials.accessToken, accountId: credentials.accountId)
    let planTypeRaw = response.planType?.rawValue
    return planTypeRaw
  }

  /// Check if OAuth credentials are available
  static func hasCredentials() -> Bool {
    (try? CodexOAuthCredentialsStore.load()) != nil
  }

  private static func resolveUsageURL() -> URL {
    resolveUsageURL(env: ProcessInfo.processInfo.environment, configContents: nil)
  }

  private static func resolveUsageURL(env: [String: String], configContents: String?) -> URL {
    let baseURL = resolveChatGPTBaseURL(env: env, configContents: configContents)
    let normalized = normalizeChatGPTBaseURL(baseURL)
    let path = normalized.contains("/backend-api") ? chatGPTUsagePath : codexUsagePath
    let full = normalized + path
    return URL(string: full) ?? URL(string: defaultChatGPTBaseURL + chatGPTUsagePath)!
  }

  private static func resolveChatGPTBaseURL(env: [String: String], configContents: String?) -> String {
    if let configContents, let parsed = parseChatGPTBaseURL(from: configContents) {
      return parsed
    }
    if let contents = loadConfigContents(env: env),
       let parsed = parseChatGPTBaseURL(from: contents)
    {
      return parsed
    }
    return defaultChatGPTBaseURL
  }

  private static func normalizeChatGPTBaseURL(_ value: String) -> String {
    var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { trimmed = defaultChatGPTBaseURL }
    while trimmed.hasSuffix("/") {
      trimmed.removeLast()
    }
    if trimmed.hasPrefix("https://chatgpt.com") || trimmed.hasPrefix("https://chat.openai.com"),
       !trimmed.contains("/backend-api")
    {
      trimmed += "/backend-api"
    }
    return trimmed
  }

  private static func parseChatGPTBaseURL(from contents: String) -> String? {
    for rawLine in contents.split(whereSeparator: \.isNewline) {
      let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: true).first
      let trimmed = line?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !trimmed.isEmpty else { continue }
      let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: true)
      guard parts.count == 2 else { continue }
      let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
      guard key == "chatgpt_base_url" else { continue }
      var value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
      if value.hasPrefix("\""), value.hasSuffix("\"") {
        value = String(value.dropFirst().dropLast())
      } else if value.hasPrefix("'"), value.hasSuffix("'") {
        value = String(value.dropFirst().dropLast())
      }
      return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return nil
  }

  private static func loadConfigContents(env: [String: String]) -> String? {
    let home = SessionPreferencesStore.getRealUserHomeURL()
    let codexHome = env["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let root = (codexHome?.isEmpty == false) ? URL(fileURLWithPath: codexHome!) : home
      .appendingPathComponent(".codex")
    let url = root.appendingPathComponent("config.toml")
    return try? String(contentsOf: url, encoding: .utf8)
  }
}

// MARK: - Plan type badge conversion

extension CodexOAuthUsageFetcher.UsageResponse.PlanType {
  /// Convert plan type to display badge
  var displayBadge: String? {
    switch self {
    case .free, .guest:
      return nil  // No badge for free users
    case .go:
      return "Go"
    case .plus:
      return "Plus"
    case .pro:
      return "Pro"
    case .team:
      return "Team"
    case .business, .enterprise:
      return "Ent"
    case .freeWorkspace:
      return nil
    case .education, .edu, .k12, .quorum:
      return "Edu"
    case .unknown(let value):
      // Show first letter capitalized for unknown types
      return value.isEmpty ? nil : value.prefix(1).uppercased() + value.dropFirst()
    }
  }
}

// MARK: - JWT-based plan type extraction (more reliable than API)

extension CodexOAuthUsageFetcher {
  /// Fetch plan type from JWT token in auth.json (primary, most reliable)
  /// This mirrors CodexBar's approach for consistency
  static func fetchPlanTypeFromJWT() -> String? {
    do {
      let credentials = try CodexOAuthCredentialsStore.load()
      guard let idToken = credentials.idToken, !idToken.isEmpty else {
        return nil
      }
      guard let payload = parseJWT(idToken) else {
        return nil
      }

      // Extract plan type from JWT payload (same fields as CodexBar)
      let authDict = payload["https://api.openai.com/auth"] as? [String: Any]
      let planFromAuth = authDict?["chatgpt_plan_type"] as? String
      let planFromRoot = payload["chatgpt_plan_type"] as? String
      let plan = planFromAuth ?? planFromRoot
      let trimmedPlan = plan?.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmedPlan
    } catch {
      return nil
    }
  }

  /// Parse JWT token to extract payload
  private static func parseJWT(_ token: String) -> [String: Any]? {
    let parts = token.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    let payloadPart = parts[1]

    var padded = String(payloadPart)
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    while padded.count % 4 != 0 {
      padded.append("=")
    }
    guard let data = Data(base64Encoded: padded) else { return nil }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    return json
  }
}

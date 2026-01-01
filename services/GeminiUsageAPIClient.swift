import Foundation
import Security

struct GeminiUsageAPIClient {
  enum ClientError: Error, LocalizedError {
    case credentialNotFound
    case keychainAccess(OSStatus)
    case malformedCredential
    case missingAccessToken
    case credentialExpired(Date)
    case projectNotFound
    case unsupportedAuthType(String)
    case requestFailed(Int)
    case emptyResponse
    case decodingFailed

    var errorDescription: String? {
      switch self {
      case .credentialNotFound:
        return "Gemini credential not found."
      case .keychainAccess(let status):
        return SecCopyErrorMessageString(status, nil) as String?
      case .malformedCredential:
        return "Gemini credential is invalid."
      case .missingAccessToken:
        return "Gemini credential is missing an access token."
      case .credentialExpired(let date):
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Gemini credential expired on \(formatter.string(from: date))."
      case .projectNotFound:
        return "Gemini project ID not found. For personal Google accounts, try running gemini CLI to complete onboarding. For workspace accounts, set GOOGLE_CLOUD_PROJECT."
      case .unsupportedAuthType(let authType):
        return "Gemini \(authType) auth not supported. Use Google account (OAuth) instead."
      case .requestFailed(let code):
        return "Gemini usage API returned status \(code)."
      case .emptyResponse:
        return "Gemini usage API returned no data."
      case .decodingFailed:
        return "Failed to decode Gemini usage response."
      }
    }
  }

  private struct CredentialEnvelope: Decodable {
    struct Token: Decodable {
      let accessToken: String
      let refreshToken: String?
      let expiresAt: TimeInterval?
      let tokenType: String?
      let idToken: String?

      enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expiresAt"  // Try camelCase first
        case tokenType = "token_type"
        case idToken = "id_token"
      }

      // Memberwise initializer (needed because we have custom init(from:))
      init(accessToken: String, refreshToken: String?, expiresAt: TimeInterval?, tokenType: String?, idToken: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.tokenType = tokenType
        self.idToken = idToken
      }

      init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        refreshToken = try? container.decode(String.self, forKey: .refreshToken)
        tokenType = try? container.decode(String.self, forKey: .tokenType)
        idToken = try? container.decode(String.self, forKey: .idToken)

        // Handle both expiresAt (camelCase) and expiry_date (snake_case)
        if let expiresAt = try? container.decode(TimeInterval.self, forKey: .expiresAt) {
          self.expiresAt = expiresAt
        } else if let expiryDate = try? decoder.container(keyedBy: LegacyCodingKeys.self).decode(TimeInterval.self, forKey: .expiryDate) {
          self.expiresAt = expiryDate
        } else {
          self.expiresAt = nil
        }
      }

      private enum LegacyCodingKeys: String, CodingKey {
        case expiryDate = "expiry_date"
      }
    }

    let serverName: String?
    let token: Token
    let updatedAt: TimeInterval?
  }

  private struct LoadCodeAssistResponse: Decodable {
    struct Tier: Decodable {
      let id: String?
      let name: String?
      let isDefault: Bool?
    }

    struct Project: Decodable {
      let id: String?
      let name: String?
    }

    let currentTier: Tier?
    let allowedTiers: [Tier]?
    let cloudaicompanionProject: String?
    let cloudaicompanionProjectObject: Project?

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)

      currentTier = try? container.decodeIfPresent(Tier.self, forKey: .currentTier)
      allowedTiers = try? container.decodeIfPresent([Tier].self, forKey: .allowedTiers)

      // Handle cloudaicompanionProject as string or object
      if let rawString = try? container.decodeIfPresent(String.self, forKey: .cloudaicompanionProject) {
        self.cloudaicompanionProject = rawString
        self.cloudaicompanionProjectObject = nil
      } else if let obj = try? container.decodeIfPresent(Project.self, forKey: .cloudaicompanionProject) {
        self.cloudaicompanionProject = obj.id ?? obj.name
        self.cloudaicompanionProjectObject = obj
      } else {
        self.cloudaicompanionProject = nil
        self.cloudaicompanionProjectObject = nil
      }
    }

    private enum CodingKeys: String, CodingKey {
      case currentTier
      case allowedTiers
      case cloudaicompanionProject
    }
  }

  private struct OnboardUserRequest: Encodable {
    let tierId: String
    let cloudaicompanionProject: String?
    let metadata: [String: String]
  }

  private struct OnboardUserResponse: Decodable {
    struct Project: Decodable {
      let id: String?
      let name: String?
    }

    struct ResponseData: Decodable {
      let cloudaicompanionProject: Project?
    }

    let done: Bool?
    let response: ResponseData?
  }

  private struct QuotaResponse: Decodable {
    struct Bucket: Decodable {
      let remainingAmount: String?
      let remainingFraction: Double?
      let resetTime: String?
      let tokenType: String?
      let modelId: String?
    }

    let buckets: [Bucket]?
  }

  private struct OAuthFile: Decodable {
    let access_token: String?
    let refresh_token: String?
    let expiry_date: TimeInterval?
    let id_token: String?
  }

  func fetchUsageStatus(now: Date = Date()) async throws -> GeminiUsageStatus {
    let home = SessionPreferencesStore.getRealUserHomeURL()
    let authType = currentAuthType(homeDirectory: home)
    switch authType {
    case .apiKey:
      throw ClientError.unsupportedAuthType("API key")
    case .vertexAI:
      throw ClientError.unsupportedAuthType("Vertex AI")
    case .oauthPersonal, .unknown:
      break
    }

    var credential = try fetchCredential()

    // Check token expiration and auto-refresh if needed
    if let expires = credential.token.expiresAt {
      let expiry = Date(timeIntervalSince1970: expires / 1000)
      if expiry.addingTimeInterval(-300) < now {
        NSLog("[GeminiUsage] Token expired at \(expiry), attempting refresh")

        // Try to refresh the token
        guard let refreshToken = credential.token.refreshToken else {
          NSLog("[GeminiUsage] No refresh token available")
          throw ClientError.credentialExpired(expiry)
        }

        do {
          let newToken = try await refreshAccessToken(refreshToken: refreshToken)
          credential = CredentialEnvelope(
            serverName: credential.serverName,
            token: newToken,
            updatedAt: credential.updatedAt
          )
          NSLog("[GeminiUsage] Token refreshed successfully")
        } catch {
          NSLog("[GeminiUsage] Token refresh failed: \(error.localizedDescription)")
          throw ClientError.credentialExpired(expiry)
        }
      }
    }

    guard !credential.token.accessToken.isEmpty else { throw ClientError.missingAccessToken }
    let token = credential.token.accessToken

    let projectId = try await resolveProjectId(token: token)
    if projectId == nil {
      NSLog("[GeminiUsage] No project ID detected; continuing without project")
    }
    let buckets = try await retrieveQuota(token: token, projectId: projectId)

    let claims = extractClaimsFromToken(credential.token.idToken)
    let userTier = await fetchUserTier(token: token)
    var planType: String?
    switch userTier {
    case .standard:
      planType = await detectPlanFromStorage(token: token) ?? "Pro"
    case .free:
      planType = claims.hostedDomain != nil ? "Workspace" : "Free"
    case .legacy:
      planType = "Legacy"
    case .none:
      planType = await detectPlanFromStorage(token: token) ?? detectPlanFromModels(buckets)
    }

    let status = GeminiUsageStatus(
      updatedAt: now,
      projectId: projectId,
      buckets: buckets,
      planType: planType
    )
    return status
  }

  // MARK: - Credential loading

  private func fetchCredential() throws -> CredentialEnvelope {
    if let file = fetchCredentialFromPlaintextFile() {
      return file
    }
    throw ClientError.credentialNotFound
  }

  private func fetchCredentialFromPlaintextFile() -> CredentialEnvelope? {
    let fm = FileManager.default
    let home = SessionPreferencesStore.getRealUserHomeURL()
    // Prioritize standard Gemini CLI credentials file
    let paths = [
      home.appendingPathComponent(".gemini/oauth_creds.json"),
      home.appendingPathComponent(".gemini/mcp-oauth-tokens-v2.json"),
      home.appendingPathComponent(".gemini/mcp-oauth-tokens.json")
    ]

    for url in paths {
      guard fm.fileExists(atPath: url.path) else { continue }
      if let data = try? Data(contentsOf: url) {
        // Try OAuthCredentials shape first
        if let envelope = try? JSONDecoder().decode(CredentialEnvelope.self, from: data) {
          return envelope
        }
        // Try legacy google creds (oauth_creds.json)
        if let legacy = try? JSONDecoder().decode(OAuthFile.self, from: data),
          let token = legacy.access_token
        {
          let expires = legacy.expiry_date
          let tokenObj = CredentialEnvelope.Token(
            accessToken: token,
            refreshToken: legacy.refresh_token,
            expiresAt: expires,
            tokenType: "Bearer",
            idToken: legacy.id_token
          )
          return CredentialEnvelope(serverName: "legacy", token: tokenObj, updatedAt: nil)
        }
      }
    }
    return nil
  }

  // MARK: - Network

  private func resolveProjectId(token: String) async throws -> String? {
    let envProject = ProcessInfo.processInfo.environment["GOOGLE_CLOUD_PROJECT"]
      ?? ProcessInfo.processInfo.environment["GOOGLE_CLOUD_PROJECT_ID"]

    if let discovered = try? await discoverGeminiProjectId(token: token) {
      return discovered
    }
    return envProject
  }

  private func onboardUser(
    token: String,
    tierId: String,
    cloudaicompanionProject: String?
  ) async throws -> String? {
    guard let url = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:onboardUser")
    else {
      return nil
    }

    var metadata: [String: String] = [
      "ideType": "IDE_UNSPECIFIED",
      "platform": "PLATFORM_UNSPECIFIED",
      "pluginType": "GEMINI"
    ]
    if let project = cloudaicompanionProject, !project.isEmpty {
      metadata["duetProject"] = project
    }

    let requestBody = OnboardUserRequest(
      tierId: tierId,
      cloudaicompanionProject: cloudaicompanionProject,
      metadata: metadata
    )

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 30

    guard let bodyData = try? JSONEncoder().encode(requestBody) else {
      throw ClientError.requestFailed(-1)
    }
    request.httpBody = bodyData

    // Poll until the long-running operation is complete (max 12 attempts = 60 seconds)
    let maxAttempts = 12
    var attempts = 0

    while attempts < maxAttempts {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        throw ClientError.requestFailed(-1)
      }
      guard (200..<300).contains(http.statusCode) else {
        throw ClientError.requestFailed(http.statusCode)
      }

      guard let result = try? JSONDecoder().decode(OnboardUserResponse.self, from: data) else {
        throw ClientError.decodingFailed
      }

      // Check if operation is complete
      if result.done == true {
        let projectId = result.response?.cloudaicompanionProject?.id
          ?? result.response?.cloudaicompanionProject?.name
        NSLog("[GeminiUsage] Onboarding completed, project ID: \(projectId ?? "nil")")
        return projectId
      }

      // Not done yet, wait and retry
      attempts += 1
      NSLog("[GeminiUsage] Onboarding not complete, attempt \(attempts)/\(maxAttempts), retrying in 5s...")
      if attempts < maxAttempts {
        try await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
      }
    }

    // Polling timeout
    NSLog("[GeminiUsage] Onboarding polling timeout after \(maxAttempts) attempts")
    throw ClientError.requestFailed(-2)
  }

  private func retrieveQuota(token: String, projectId: String?) async throws -> [GeminiUsageStatus.Bucket] {
    guard let url = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota") else {
      return []
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue(userAgent(), forHTTPHeaderField: "User-Agent")
    request.timeoutInterval = 10

    var body: [String: Any] = [:]
    if let projectId, !projectId.isEmpty {
      body["project"] = projectId
    }
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw ClientError.requestFailed(-1) }
    guard (200..<300).contains(http.statusCode) else { throw ClientError.requestFailed(http.statusCode) }

    // Debug: Log raw quota response
    if let rawJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      NSLog("[GeminiUsage] retrieveUserQuota response: \(rawJSON)")
    }

    guard let payload = try? JSONDecoder().decode(QuotaResponse.self, from: data) else {
      throw ClientError.decodingFailed
    }

    let buckets: [GeminiUsageStatus.Bucket] = (payload.buckets ?? []).map { bucket in
      let reset: Date? = bucket.resetTime.flatMap { resetTimeString in
        // Try parsing with fractional seconds first
        let formatterWithFractional = ISO8601DateFormatter()
        formatterWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatterWithFractional.date(from: resetTimeString) {
          NSLog("[GeminiUsage] Parsed resetTime with fractional seconds: \(resetTimeString) -> \(date)")
          return date
        }

        // Fallback: try without fractional seconds
        let formatterWithoutFractional = ISO8601DateFormatter()
        formatterWithoutFractional.formatOptions = [.withInternetDateTime]
        if let date = formatterWithoutFractional.date(from: resetTimeString) {
          NSLog("[GeminiUsage] Parsed resetTime without fractional seconds: \(resetTimeString) -> \(date)")
          return date
        }

        NSLog("[GeminiUsage] Failed to parse resetTime: \(resetTimeString)")
        return nil
      }

      return GeminiUsageStatus.Bucket(
        modelId: bucket.modelId,
        tokenType: bucket.tokenType,
        remainingFraction: bucket.remainingFraction,
        remainingAmount: bucket.remainingAmount,
        resetTime: reset
      )
    }

    NSLog("[GeminiUsage] Retrieved \(buckets.count) buckets, \(buckets.filter { $0.resetTime != nil }.count) have resetTime")
    return buckets
  }

  private func userAgent() -> String {
    let version = Bundle.main.shortVersionString
    let platform = ProcessInfo.processInfo.operatingSystemVersionString
    return "CodMate/\(version) (\(platform))"
  }

  // MARK: - Token Refresh

  private struct OAuthClientCredentials {
    let clientId: String
    let clientSecret: String
  }

  private func refreshAccessToken(refreshToken: String) async throws -> CredentialEnvelope.Token {
    guard let url = URL(string: "https://oauth2.googleapis.com/token") else {
      throw ClientError.decodingFailed
    }

    guard let oauthCreds = extractOAuthCredentials() else {
      NSLog("[GeminiUsage] Could not extract OAuth credentials from Gemini CLI")
      throw ClientError.decodingFailed
    }

    return try await refreshWithCredentials(
      clientId: oauthCreds.clientId,
      clientSecret: oauthCreds.clientSecret,
      refreshToken: refreshToken,
      url: url
    )
  }

  private func refreshWithCredentials(
    clientId: String,
    clientSecret: String,
    refreshToken: String,
    url: URL
  ) async throws -> CredentialEnvelope.Token {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 15

    let body = [
      "client_id=\(clientId)",
      "client_secret=\(clientSecret)",
      "refresh_token=\(refreshToken)",
      "grant_type=refresh_token",
    ].joined(separator: "&")
    request.httpBody = body.data(using: .utf8)

    let (data, response) = try await URLSession.shared.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ClientError.decodingFailed
    }

    guard httpResponse.statusCode == 200 else {
      NSLog("[GeminiUsage] Token refresh failed with status \(httpResponse.statusCode)")
      throw ClientError.requestFailed(httpResponse.statusCode)
    }

    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let newAccessToken = json["access_token"] as? String
    else {
      throw ClientError.decodingFailed
    }

    // Update local credentials file
    try updateStoredCredentials(json)

    NSLog("[GeminiUsage] Token refreshed successfully")

    // Construct new Token object
    let expiresIn = json["expires_in"] as? TimeInterval ?? 3600
    let newExpiresAt = Date().timeIntervalSince1970 * 1000 + expiresIn * 1000  // Convert to milliseconds

    return CredentialEnvelope.Token(
      accessToken: newAccessToken,
      refreshToken: refreshToken,  // refresh_token stays the same
      expiresAt: newExpiresAt,
      tokenType: json["token_type"] as? String,
      idToken: json["id_token"] as? String
    )
  }


  private func updateStoredCredentials(_ refreshResponse: [String: Any]) throws {
    let credsPaths = [
      "~/.gemini/oauth_creds.json",
      "~/.gemini/mcp-oauth-tokens-v2.json",
      "~/.gemini/mcp-oauth-tokens.json",
    ]

    for path in credsPaths {
      let expandedPath = (path as NSString).expandingTildeInPath
      let credsURL = URL(fileURLWithPath: expandedPath)

      guard FileManager.default.fileExists(atPath: expandedPath),
        let existingData = try? Data(contentsOf: credsURL),
        var json = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any]
      else {
        continue
      }

      // Update access_token and expiry time
      if let newAccessToken = refreshResponse["access_token"] as? String {
        json["access_token"] = newAccessToken

        if let expiresIn = refreshResponse["expires_in"] as? TimeInterval {
          let newExpiresAt = Date().timeIntervalSince1970 * 1000 + expiresIn * 1000
          // Update both field names for compatibility
          json["expiresAt"] = newExpiresAt
          json["expiry_date"] = newExpiresAt
        }

        // Also update id_token if present in response
        if let idToken = refreshResponse["id_token"] {
          json["id_token"] = idToken
        }

        // Write back to file
        let updatedData = try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted)
        try updatedData.write(to: credsURL, options: .atomic)
        NSLog("[GeminiUsage] Updated credentials file: \(path)")
        return
      }
    }

    NSLog("[GeminiUsage] Warning: Could not update any credentials file")
  }

  // MARK: - OAuth Credentials Extraction

  /// Extract OAuth credentials from installed Gemini CLI
  /// Follows CodexBar's approach: find gemini binary, resolve symlinks, locate oauth2.js
  private func extractOAuthCredentials() -> OAuthClientCredentials? {
    let fm = FileManager.default

    // Step 1: Find gemini binary using CodMate's CLIEnvironment
    let path = CLIEnvironment.resolvedPATHForCLI()
    guard let geminiPath = CLIEnvironment.resolveExecutablePath("gemini", path: path) else {
      NSLog("[GeminiUsage] Could not find gemini binary in PATH")
      return nil
    }

    // Step 2: Resolve symlinks to find actual installation directory
    var realPath = geminiPath
    if let resolved = try? fm.destinationOfSymbolicLink(atPath: geminiPath) {
      if resolved.hasPrefix("/") {
        realPath = resolved
      } else {
        realPath = (geminiPath as NSString).deletingLastPathComponent + "/" + resolved
      }
    }

    // Step 3: Navigate to gemini-cli package root
    // realPath might be: /opt/homebrew/lib/node_modules/@google/gemini-cli/dist/index.js
    // We need to get to: /opt/homebrew/lib/node_modules/@google/gemini-cli
    var baseDir = realPath

    // If realPath ends with .js, go up to package root (remove /dist/index.js or similar)
    if realPath.hasSuffix(".js") {
      // Remove filename
      baseDir = (realPath as NSString).deletingLastPathComponent
      // If we're in dist/, go up one more level to package root
      if baseDir.hasSuffix("/dist") {
        baseDir = (baseDir as NSString).deletingLastPathComponent
      }
    } else {
      // realPath is the binary, navigate from bin to package root
      let binDir = (realPath as NSString).deletingLastPathComponent
      baseDir = (binDir as NSString).deletingLastPathComponent
    }

    let oauthFile = "dist/src/code_assist/oauth2.js"
    let possiblePaths = [
      // Direct path from package root (most common for Homebrew)
      "\(baseDir)/node_modules/@google/gemini-cli-core/\(oauthFile)",

      // Alternative nested structures
      "\(baseDir)/libexec/lib/node_modules/@google/gemini-cli-core/\(oauthFile)",
      "\(baseDir)/lib/node_modules/@google/gemini-cli-core/\(oauthFile)",

      // Bun/npm sibling structure
      "\(baseDir)/../gemini-cli-core/\(oauthFile)",
    ]

    for path in possiblePaths {
      if let content = try? String(contentsOfFile: path, encoding: .utf8) {
        NSLog("[GeminiUsage] Found oauth2.js at: \(path)")
        if let creds = parseOAuthCredentials(from: content) {
          NSLog("[GeminiUsage] Successfully extracted OAuth credentials from Gemini CLI")
          return creds
        }
      }
    }

    NSLog("[GeminiUsage] Could not find oauth2.js in any expected location")
    return nil
  }

  /// Parse OAuth credentials from oauth2.js content
  /// Matches pattern: const OAUTH_CLIENT_ID = '...';
  private func parseOAuthCredentials(from content: String) -> OAuthClientCredentials? {
    // Match: const OAUTH_CLIENT_ID = '...';
    let clientIdPattern = #"OAUTH_CLIENT_ID\s*=\s*['"]([\w\-\.]+)['"]"#
    let secretPattern = #"OAUTH_CLIENT_SECRET\s*=\s*['"]([\w\-]+)['"]"#

    guard let clientIdRegex = try? NSRegularExpression(pattern: clientIdPattern),
          let secretRegex = try? NSRegularExpression(pattern: secretPattern)
    else {
      return nil
    }

    let range = NSRange(content.startIndex..., in: content)

    guard let clientIdMatch = clientIdRegex.firstMatch(in: content, range: range),
          let clientIdRange = Range(clientIdMatch.range(at: 1), in: content),
          let secretMatch = secretRegex.firstMatch(in: content, range: range),
          let secretRange = Range(secretMatch.range(at: 1), in: content)
    else {
      return nil
    }

    let clientId = String(content[clientIdRange])
    let clientSecret = String(content[secretRange])

    return OAuthClientCredentials(clientId: clientId, clientSecret: clientSecret)
  }

  // MARK: - Plan Detection

  /// Detect plan from Google Drive storage quota (most reliable method).
  /// 2 TB = AI Pro, 30 TB = AI Ultra
  private func detectPlanFromStorage(token: String) async -> String? {
    let endpoint = "https://www.googleapis.com/drive/v3/about?fields=storageQuota"
    guard let url = URL(string: endpoint) else { return nil }

    var request = URLRequest(url: url)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 15

    guard let (data, response) = try? await URLSession.shared.data(for: request),
          let httpResponse = response as? HTTPURLResponse,
          httpResponse.statusCode == 200
    else {
      return nil
    }

    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let storageQuota = json["storageQuota"] as? [String: Any],
          let limitStr = storageQuota["limit"] as? String,
          let limit = Int64(limitStr)
    else {
      return nil
    }

    // Storage limits for plan detection
    let storageLimit2TB: Int64 = 2_199_023_255_552
    let storageLimit30TB: Int64 = 32_985_348_833_280

    // Detect plan based on storage limit
    if limit >= storageLimit30TB {
      return "AI Ultra"
    } else if limit >= storageLimit2TB {
      return "AI Pro"
    }

    return nil
  }

  /// Detect plan tier based on model access. Users with Pro models have AI Pro or higher.
  private func detectPlanFromModels(_ buckets: [GeminiUsageStatus.Bucket]) -> String? {
    // If user has access to any "pro" models, they're on a paid tier (AI Pro, AI Ultra, etc.)
    let hasProModels = buckets.contains { bucket in
      bucket.modelId?.lowercased().contains("pro") == true
    }
    return hasProModels ? "AI Pro" : nil
  }

  // MARK: - Auth type & project discovery (CodexBar-aligned)

  private enum GeminiAuthType: String {
    case oauthPersonal = "oauth-personal"
    case apiKey = "api-key"
    case vertexAI = "vertex-ai"
    case unknown
  }

  private enum GeminiUserTierId: String {
    case free = "free-tier"
    case legacy = "legacy-tier"
    case standard = "standard-tier"
  }

  private func currentAuthType(homeDirectory: URL) -> GeminiAuthType {
    let settingsURL = homeDirectory.appendingPathComponent(".gemini/settings.json")
    guard let data = try? Data(contentsOf: settingsURL),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let security = json["security"] as? [String: Any],
          let auth = security["auth"] as? [String: Any],
          let selectedType = auth["selectedType"] as? String
    else {
      return .unknown
    }
    return GeminiAuthType(rawValue: selectedType) ?? .unknown
  }

  private func discoverGeminiProjectId(token: String) async throws -> String? {
    guard let url = URL(string: "https://cloudresourcemanager.googleapis.com/v1/projects") else {
      return nil
    }

    var request = URLRequest(url: url)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 10

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }

    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let projects = json["projects"] as? [[String: Any]]
    else {
      return nil
    }

    for project in projects {
      guard let projectId = project["projectId"] as? String else { continue }
      if projectId.hasPrefix("gen-lang-client") {
        return projectId
      }
      if let labels = project["labels"] as? [String: String],
         labels["generative-language"] != nil {
        return projectId
      }
    }

    return nil
  }

  private func fetchUserTier(token: String) async -> GeminiUserTierId? {
    guard let url = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist") else {
      return nil
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data("{\"metadata\":{\"ideType\":\"GEMINI_CLI\",\"pluginType\":\"GEMINI\"}}".utf8)
    request.timeoutInterval = 10

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await URLSession.shared.data(for: request)
    } catch {
      return nil
    }

    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }

    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let currentTier = json["currentTier"] as? [String: Any],
          let tierId = currentTier["id"] as? String
    else {
      return nil
    }
    return GeminiUserTierId(rawValue: tierId)
  }

  private struct TokenClaims {
    let email: String?
    let hostedDomain: String?
  }

  private func extractClaimsFromToken(_ idToken: String?) -> TokenClaims {
    guard let token = idToken else { return TokenClaims(email: nil, hostedDomain: nil) }
    let parts = token.components(separatedBy: ".")
    guard parts.count >= 2 else { return TokenClaims(email: nil, hostedDomain: nil) }

    var payload = parts[1]
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let remainder = payload.count % 4
    if remainder > 0 {
      payload += String(repeating: "=", count: 4 - remainder)
    }

    guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return TokenClaims(email: nil, hostedDomain: nil)
    }

    return TokenClaims(
      email: json["email"] as? String,
      hostedDomain: json["hd"] as? String
    )
  }
}

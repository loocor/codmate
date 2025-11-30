import Foundation
import Security
import CryptoKit

struct ClaudeUsageAPIClient {
    enum ClientError: Error, LocalizedError {
        case credentialNotFound
        case keychainAccessRestricted(OSStatus)
        case malformedCredential
        case missingAccessToken
        case credentialExpired(Date)
        case requestFailed(Int)
        case emptyResponse
        case decodingFailed

        var errorDescription: String? {
            switch self {
            case .credentialNotFound:
                return "Claude Code keychain entry not found."
            case .keychainAccessRestricted(let status):
                return SecCopyErrorMessageString(status, nil) as String? ?? "Keychain access denied."
            case .malformedCredential:
                return "Claude Code credential payload is invalid."
            case .missingAccessToken:
                return "Claude Code credential is missing an access token."
            case .credentialExpired(let date):
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                return "Claude Code credential expired on \(formatter.string(from: date)). Please sign in again."
            case .requestFailed(let code):
                return "Claude usage API returned status \(code)."
            case .emptyResponse:
                return "Claude usage API returned no data."
            case .decodingFailed:
                return "Failed to decode Claude usage response."
            }
        }
    }

    private struct CredentialEnvelope: Decodable {
        struct OAuth: Decodable {
            let accessToken: String
            let expiresAt: TimeInterval?

            enum CodingKeys: String, CodingKey {
                case accessToken
                case expiresAt
            }
        }

        let claudeAiOauth: OAuth
    }

    private struct UsageLimitsResponse: Decodable {
        struct Window: Decodable {
            let utilization: Double?
            let resetsAt: Date?

            enum CodingKeys: String, CodingKey {
                case utilization
                case resetsAt = "resets_at"
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                utilization = try container.decodeIfPresent(Double.self, forKey: .utilization)
                if let raw = try container.decodeIfPresent(String.self, forKey: .resetsAt) {
                    resetsAt = ClaudeUsageAPIClient.isoFormatter.date(from: raw)
                } else {
                    resetsAt = nil
                }
            }
        }

        let fiveHour: Window?
        let sevenDay: Window?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchUsageStatus(now: Date = Date()) async throws -> ClaudeUsageStatus {
        let credential = try fetchCredentialEnvelope()
        var sessionExpiresAt: Date? = nil
        if let expiresAt = credential.claudeAiOauth.expiresAt {
            // expiresAt is in milliseconds, convert to seconds
            let expiryDate = Date(timeIntervalSince1970: expiresAt / 1000)
            sessionExpiresAt = expiryDate
            if expiryDate < now {
                throw ClientError.credentialExpired(expiryDate)
            }
        }
        let token = credential.claudeAiOauth.accessToken
        let response = try await fetchUsageLimits(token: token)
        guard response.fiveHour != nil || response.sevenDay != nil else {
            throw ClientError.emptyResponse
        }

        let fiveHourWindowMinutes = 5.0 * 60.0
        let weeklyWindowMinutes = 7.0 * 24.0 * 60.0

        func minutesUsed(from window: UsageLimitsResponse.Window?, windowMinutes: Double) -> Double? {
            guard let utilization = window?.utilization else { return nil }
            let percent = max(0, min(utilization, 100))
            return (percent / 100.0) * windowMinutes
        }

        let status = ClaudeUsageStatus(
            updatedAt: now,
            modelName: nil,
            contextUsedTokens: nil,
            contextLimitTokens: nil,
            fiveHourUsedMinutes: minutesUsed(from: response.fiveHour, windowMinutes: fiveHourWindowMinutes),
            fiveHourWindowMinutes: fiveHourWindowMinutes,
            fiveHourResetAt: response.fiveHour?.resetsAt,
            weeklyUsedMinutes: minutesUsed(from: response.sevenDay, windowMinutes: weeklyWindowMinutes),
            weeklyWindowMinutes: weeklyWindowMinutes,
            weeklyResetAt: response.sevenDay?.resetsAt,
            sessionExpiresAt: sessionExpiresAt
        )

        return status
    }

    private func fetchCredentialEnvelope() throws -> CredentialEnvelope {
        if let credential = try fetchEnvelopeFromKeychain() {
            return credential
        }
        if let credential = fetchEnvelopeFromPlaintext() {
            return credential
        }
        throw ClientError.credentialNotFound
    }

    private func fetchEnvelopeFromKeychain() throws -> CredentialEnvelope? {
        let accountName = Self.keychainAccountName()
        var lastError: Error?
        for service in Self.candidateCredentialServiceNames() {
            do {
                if let envelope = try fetchEnvelope(service: service, account: accountName) {
                    return envelope
                }
            } catch let error as ClientError {
                lastError = error
            }
        }
        if let error = lastError {
            throw error
        }
        return nil
    }

    private func fetchEnvelope(service: String, account: String) throws -> CredentialEnvelope? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw ClientError.keychainAccessRestricted(status)
        }

        guard let data = item as? Data else {
            throw ClientError.malformedCredential
        }

        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(CredentialEnvelope.self, from: data) else {
            throw ClientError.malformedCredential
        }

        guard !envelope.claudeAiOauth.accessToken.isEmpty else {
            throw ClientError.missingAccessToken
        }

        return envelope
    }

    private func fetchUsageLimits(token: String) async throws -> UsageLimitsResponse {
        let base = ProcessInfo.processInfo.environment["ANTHROPIC_BASE_URL"] ?? "https://api.anthropic.com"
        let url: URL?
        if base.lowercased().hasSuffix("/api/oauth/usage") {
            url = URL(string: base)
        } else {
            url = URL(string: base)?.appendingPathComponent("api/oauth/usage")
        }
        guard let url else {
            throw ClientError.requestFailed(-1)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("CodMate/\(Bundle.main.shortVersionString)", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ClientError.requestFailed(-1)
        }
        guard (200..<300).contains(http.statusCode) else {
            NSLog("[ClaudeUsageAPI] HTTP error \(http.statusCode)")
            throw ClientError.requestFailed(http.statusCode)
        }

        do {
            return try JSONDecoder().decode(UsageLimitsResponse.self, from: data)
        } catch {
            NSLog("[ClaudeUsageAPI] Decoding failed: \(error)")
            throw ClientError.decodingFailed
        }
    }

    // MARK: - Credential helpers

    private static func candidateCredentialServiceNames() -> [String] {
        var names: [String] = []
        for oauth in candidateOauthSuffixes() {
            for hashSuffix in candidateHashSuffixes() {
                let value = "Claude Code\(oauth)-credentials\(hashSuffix)"
                if !names.contains(value) {
                    names.append(value)
                }
            }
        }
        return names
    }

    private static func candidateOauthSuffixes() -> [String] {
        let env = ProcessInfo.processInfo.environment
        if let explicit = env["CLAUDE_ENV"] ?? env["CLAUDE_CODE_ENV"], !explicit.isEmpty {
            return [oauthSuffix(for: explicit)]
        }
        return ["", "-staging-oauth", "-local-oauth"]
    }

    private static func oauthSuffix(for value: String) -> String {
        switch value.lowercased() {
        case "local": return "-local-oauth"
        case "staging": return "-staging-oauth"
        default: return ""
        }
    }

    private static func candidateHashSuffixes() -> [String] {
        var suffixes: [String] = [""]
        func appendUnique(_ value: String) {
            if !suffixes.contains(value) {
                suffixes.append(value)
            }
        }
        let env = ProcessInfo.processInfo.environment
        if let override = env["CLAUDE_CONFIG_DIR"], !override.isEmpty {
            appendUnique("-" + hashPrefix(for: override))
        }
        let defaultPath = SessionPreferencesStore.getRealUserHomeURL()
            .appendingPathComponent(".claude", isDirectory: true)
            .path
        appendUnique("-" + hashPrefix(for: defaultPath))
        return suffixes
    }

    private static func hashPrefix(for rawPath: String) -> String {
        let expanded = (rawPath as NSString).expandingTildeInPath
        let digest = SHA256.hash(data: Data(expanded.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(8))
    }

    private static func keychainAccountName() -> String {
        if let explicit = ProcessInfo.processInfo.environment["USER"], !explicit.isEmpty {
            return explicit
        }
        return NSUserName()
    }

    private func fetchEnvelopeFromPlaintext() -> CredentialEnvelope? {
        let fm = FileManager.default
        let configDir: URL
        if let override = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            configDir = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            configDir = SessionPreferencesStore.getRealUserHomeURL()
                .appendingPathComponent(".claude", isDirectory: true)
        }
        let fileURL = configDir.appendingPathComponent(".credentials.json", isDirectory: false)
        guard fm.fileExists(atPath: fileURL.path) else { return nil }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(CredentialEnvelope.self, from: data)
    }
}

private extension Bundle {
    var shortVersionString: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }
}

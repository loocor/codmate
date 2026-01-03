import Foundation

enum UnifiedProviderID {
  static let oauthPrefix = "oauth:"
  static let apiPrefix = "api:"
  static let legacyReroutePrefix = "local-reroute:"

  enum Parsed: Equatable {
    case oauth(LocalAuthProvider)
    case api(String)
    case legacyBuiltin(LocalServerBuiltInProvider)
    case legacyReroute(String)
    case unknown(String)
  }

  static func oauth(_ provider: LocalAuthProvider) -> String {
    "\(oauthPrefix)\(provider.rawValue)"
  }

  static func api(_ id: String) -> String {
    "\(apiPrefix)\(id)"
  }

  static func parse(_ raw: String) -> Parsed {
    if raw.hasPrefix(oauthPrefix) {
      let value = String(raw.dropFirst(oauthPrefix.count))
      if let provider = LocalAuthProvider(rawValue: value) {
        return .oauth(provider)
      }
      return .unknown(raw)
    }
    if raw.hasPrefix(apiPrefix) {
      let value = String(raw.dropFirst(apiPrefix.count))
      return .api(value)
    }
    if let builtin = LocalServerBuiltInProvider.from(providerId: raw) {
      return .legacyBuiltin(builtin)
    }
    if raw.hasPrefix(legacyReroutePrefix) {
      let value = String(raw.dropFirst(legacyReroutePrefix.count)).trimmingCharacters(
        in: .whitespacesAndNewlines)
      return .legacyReroute(value)
    }
    return .unknown(raw)
  }

  static func normalize(
    _ raw: String?,
    registryProviders: [ProvidersRegistryService.Provider]
  ) -> String? {
    guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
      return nil
    }
    switch parse(raw) {
    case .oauth:
      return raw
    case .api:
      return raw
    case .legacyBuiltin(let builtin):
      if let auth = authProvider(for: builtin) {
        return oauth(auth)
      }
      return nil
    case .legacyReroute(let label):
      if let resolved = resolveAPIProviderId(
        byLabel: label,
        registryProviders: registryProviders
      ) {
        return api(resolved)
      }
      return nil
    case .unknown(let value):
      if let match = registryProviders.first(where: { $0.id == value }) {
        return api(match.id)
      }
      if let match = registryProviders.first(where: {
        providerDisplayName($0).localizedCaseInsensitiveCompare(value) == .orderedSame
      }) {
        return api(match.id)
      }
      return nil
    }
  }

  static func authProvider(for builtin: LocalServerBuiltInProvider) -> LocalAuthProvider? {
    switch builtin {
    case .openai:
      return .codex
    case .anthropic:
      return .claude
    case .gemini:
      return .gemini
    case .antigravity:
      return .antigravity
    case .qwen:
      return .qwen
    }
  }

  static func resolveAPIProviderId(
    byLabel label: String,
    registryProviders: [ProvidersRegistryService.Provider]
  ) -> String? {
    let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else { return nil }
    if let match = registryProviders.first(where: {
      providerDisplayName($0).lowercased() == normalized
    }) {
      return match.id
    }
    if let match = registryProviders.first(where: { $0.id.lowercased() == normalized }) {
      return match.id
    }
    return nil
  }

  static func providerDisplayName(_ provider: ProvidersRegistryService.Provider) -> String {
    let name = provider.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return name.isEmpty ? provider.id : name
  }
}

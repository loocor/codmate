import Foundation
import SwiftUI

struct UnifiedProviderChoice: Identifiable, Hashable {
  enum Kind: String { case oauth, apiKey }
  let id: String
  let title: String
  let kind: Kind
  let isAvailable: Bool
  let availabilityHint: String?
}

struct UnifiedProviderSection: Identifiable, Hashable {
  let id: String
  let title: String
  let providers: [UnifiedProviderChoice]
}

@MainActor
final class UnifiedProviderCatalogModel: ObservableObject {
  @Published private(set) var sections: [UnifiedProviderSection] = []
  @Published private(set) var modelsByProviderId: [String: [String]] = [:]
  @Published private(set) var availabilityByProviderId: [String: String] = [:]
  @Published private(set) var kindByProviderId: [String: UnifiedProviderChoice.Kind] = [:]

  private var registryProviders: [ProvidersRegistryService.Provider] = []
  // Model ID to provider mapping (for reliable provider inference in autoProxy mode)
  private var modelToProviderMap: [String: String] = [:]
  // Rerouted models by label (for provider inference fallback)
  private var reroutedModelsByLabel: [String: [String]] = [:]

  func reload(preferences: SessionPreferencesStore, forceRefresh: Bool = false) async {
    let taskToken = AppLogger.shared.beginTask("Reloading provider catalog", source: "ProviderCatalog")
    let registry = ProvidersRegistryService()
    let providers = await registry.listProviders()
    registryProviders = providers
    AppLogger.shared.info("Loaded \(providers.count) providers from registry", source: "ProviderCatalog")

    // All providers now use Auto-Proxy mode through CLIProxyAPI
    // No separate rerouteBuiltIn/reroute3P switches - providers are enabled/disabled via the Providers list
    // OAuth is enabled at account level (oauthAccountsEnabled), not provider level
    let oauthAccountsEnabledSet = preferences.oauthAccountsEnabled
    let apiKeyEnabledSet = preferences.apiKeyProvidersEnabled
    let proxyRunning = CLIProxyService.shared.isRunning

    AppLogger.shared.info("Proxy running=\(proxyRunning), OAuth accounts enabled=\(oauthAccountsEnabledSet.count), API key enabled=\(apiKeyEnabledSet.count)", source: "ProviderCatalog")

    var localModels: [CLIProxyService.LocalModel] = []
    // Always fetch models if proxy is running, even if reroute is not enabled
    // This allows auto-proxy mode to show available models for selection
    if proxyRunning {
      localModels = await CLIProxyService.shared.fetchLocalModels(forceRefresh: forceRefresh)
      AppLogger.shared.info("Fetched \(localModels.count) models from CLIProxyAPI", source: "ProviderCatalog")
    } else {
      AppLogger.shared.warning("Skipping local model fetch: CLIProxy not running", source: "ProviderCatalog")
    }
    let mapped = mapLocalModels(localModels)

    var nextSections: [UnifiedProviderSection] = []
    var nextModels: [String: [String]] = [:]
    var availability: [String: String] = [:]
    var kinds: [String: UnifiedProviderChoice.Kind] = [:]

    // OAuth section - support multiple accounts per provider
    let oauthProviders = LocalAuthProvider.allCases.sorted {
      $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
    }
    var oauthChoices: [UnifiedProviderChoice] = []
    let oauthAccounts = CLIProxyService.shared.listOAuthAccounts()

    for provider in oauthProviders {
      let providerAccounts = oauthAccounts.filter { $0.provider == provider }

      if providerAccounts.isEmpty {
        // No accounts - show provider as unavailable
        let id = UnifiedProviderID.oauth(provider, accountId: nil)
        let hint = availabilityHintForOAuth(
          proxyRunning: proxyRunning,
          oauthEnabled: false,
          authAvailable: false,
          providerName: provider.displayName
        )
        let choice = UnifiedProviderChoice(
          id: id,
          title: provider.displayName,
          kind: .oauth,
          isAvailable: false,
          availabilityHint: hint
        )
        oauthChoices.append(choice)
        kinds[id] = .oauth
        nextModels[id] = []
        if let hint { availability[id] = hint }
      } else {
        // Multiple accounts - create one choice per account
        for account in providerAccounts.sorted(by: { ($0.email ?? "") < ($1.email ?? "") }) {
          let id = UnifiedProviderID.oauth(provider, accountId: account.id)
          // Account is available if proxy is running and account is enabled
          let accountEnabled = oauthAccountsEnabledSet.contains(account.id)
          let available = proxyRunning && accountEnabled
          let hint = availabilityHintForOAuth(
            proxyRunning: proxyRunning,
            oauthEnabled: accountEnabled,
            authAvailable: true,
            providerName: provider.displayName
          )
          let accountLabel = account.email ?? account.id
          let title = "\(provider.displayName) (\(accountLabel))"
          let choice = UnifiedProviderChoice(
            id: id,
            title: title,
            kind: .oauth,
            isAvailable: available,
            availabilityHint: available ? nil : hint
          )
          oauthChoices.append(choice)
          kinds[id] = .oauth
          if available && accountEnabled {
            // Use provider-level models (all accounts of same provider share models)
            // Only include models if account is enabled
            let providerBaseId = UnifiedProviderID.oauth(provider, accountId: nil)
            let models = sortModels(mapped.builtIn[providerBaseId] ?? [])
            nextModels[id] = models
            // Also store at provider level for backward compatibility
            if nextModels[providerBaseId] == nil {
              nextModels[providerBaseId] = models
            }
          } else {
            nextModels[id] = []
            if let hint { availability[id] = hint }
          }
        }
      }
    }

    // Sort all OAuth choices by title (provider name + account)
    oauthChoices.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

    if !oauthChoices.isEmpty {
      nextSections.append(
        UnifiedProviderSection(id: "oauth", title: "OAuth Providers", providers: oauthChoices)
      )
    }

    // API Key section
    let apiChoices: [UnifiedProviderChoice] = providers
      .sorted {
        UnifiedProviderID.providerDisplayName($0).localizedCaseInsensitiveCompare(
          UnifiedProviderID.providerDisplayName($1)) == .orderedAscending
      }
      .map { provider in
        let id = UnifiedProviderID.api(provider.id)
        let isEnabled = apiKeyEnabledSet.contains(provider.id)
        // Provider is available if proxy is running (all providers use Auto-Proxy mode)
        let available = proxyRunning
        let hint = availabilityHintForAPIKey(proxyRunning: proxyRunning)
        kinds[id] = .apiKey
        if proxyRunning && isEnabled {
          // Try multiple label variations to match models from CLIProxyAPI
          // CLIProxyAPI uses provider.name ?? provider.id as the name in config.yaml
          let providerName = provider.name ?? provider.id
          let displayName = UnifiedProviderID.providerDisplayName(provider)

          // Try normalized display name first
          var models: [String] = []
          let normalizedDisplayName = normalizeLabel(displayName)
          if let found = mapped.rerouted[normalizedDisplayName] {
            models = found
          } else {
            // Try normalized provider name (as used in syncThirdPartyProviders)
            let normalizedName = normalizeLabel(providerName)
            if let found = mapped.rerouted[normalizedName] {
              models = found
            } else {
              // Try normalized provider ID
              let normalizedId = normalizeLabel(provider.id)
              if let found = mapped.rerouted[normalizedId] {
                models = found
              } else {
                // Try all rerouted keys to find a match (fuzzy matching)
                for (key, modelList) in mapped.rerouted {
                  if key.contains(normalizedName) || normalizedName.contains(key) ||
                     key.contains(normalizedDisplayName) || normalizedDisplayName.contains(key) {
                    models.append(contentsOf: modelList)
                  }
                }
              }
            }
          }
          nextModels[id] = sortModels(Array(Set(models)))
        } else {
          // Provider is enabled but CLIProxyAPI not running or no models returned
          // Do not fallback to catalog - only show models actually available via CLIProxyAPI
          nextModels[id] = []
        }
        if !available, let hint { availability[id] = hint }
        return UnifiedProviderChoice(
          id: id,
          title: UnifiedProviderID.providerDisplayName(provider),
          kind: .apiKey,
          isAvailable: available,
          availabilityHint: available ? nil : hint
        )
      }
    if !apiChoices.isEmpty {
      nextSections.append(
        UnifiedProviderSection(id: "api", title: "API Key Providers", providers: apiChoices)
      )
    }

    // Add auto-proxy models: all models from CLI Proxy API
    // For auto-proxy mode, show all available models regardless of reroute/enabled settings
    // This allows users to see and select models even if they haven't configured reroute yet
    if proxyRunning {
      var allProxyModels = Set<String>()

      // Collect all OAuth provider models (only from enabled accounts)
      // Check if any account of this provider is enabled
      for provider in LocalAuthProvider.allCases {
        let providerBaseId = UnifiedProviderID.oauth(provider, accountId: nil)
        if let models = mapped.builtIn[providerBaseId], !models.isEmpty {
          // Check if any account of this provider is enabled
          let providerAccounts = oauthAccounts.filter { $0.provider == provider }
          let hasEnabledAccount = providerAccounts.contains { oauthAccountsEnabledSet.contains($0.id) }
          if hasEnabledAccount {
            allProxyModels.formUnion(models)
          }
        }
      }

      // Collect all API key provider models (only from enabled providers)
      AppLogger.shared.info("API key enabled providers: \(Array(apiKeyEnabledSet))", source: "ProviderCatalog")
      AppLogger.shared.info("Rerouted model labels: \(Array(mapped.rerouted.keys))", source: "ProviderCatalog")

      for provider in providers {
        let isEnabled = apiKeyEnabledSet.contains(provider.id)
        let providerName = provider.name ?? provider.id
        let displayName = UnifiedProviderID.providerDisplayName(provider)
        // Try multiple label variations
        let normalizedDisplayName = normalizeLabel(displayName)
        let normalizedName = normalizeLabel(providerName)
        let normalizedId = normalizeLabel(provider.id)

        // Debug: log all attempts
        AppLogger.shared.info("Provider \(provider.id): trying to match - displayName='\(normalizedDisplayName)', name='\(normalizedName)', id='\(normalizedId)'", source: "ProviderCatalog")

        var foundModels: [String] = []
        if let models = mapped.rerouted[normalizedDisplayName] {
          foundModels = models
          AppLogger.shared.info("Provider \(provider.id): matched by displayName '\(normalizedDisplayName)' -> \(models.count) models", source: "ProviderCatalog")
        } else if let models = mapped.rerouted[normalizedName] {
          foundModels = models
          AppLogger.shared.info("Provider \(provider.id): matched by name '\(normalizedName)' -> \(models.count) models", source: "ProviderCatalog")
        } else if let models = mapped.rerouted[normalizedId] {
          foundModels = models
          AppLogger.shared.info("Provider \(provider.id): matched by id '\(normalizedId)' -> \(models.count) models", source: "ProviderCatalog")
        } else {
          // Try fuzzy matching
          for (key, modelList) in mapped.rerouted {
            if key.contains(normalizedName) || normalizedName.contains(key) ||
               key.contains(normalizedDisplayName) || normalizedDisplayName.contains(key) {
              foundModels.append(contentsOf: modelList)
            }
          }
          if !foundModels.isEmpty {
            AppLogger.shared.info("Provider \(provider.id): matched by fuzzy -> \(foundModels.count) models", source: "ProviderCatalog")
          }
        }

        if !foundModels.isEmpty {
          if isEnabled {
            allProxyModels.formUnion(foundModels)
            AppLogger.shared.info("Provider \(provider.id): ADDED \(foundModels.count) models to auto-proxy (enabled)", source: "ProviderCatalog")
          } else {
            AppLogger.shared.info("Provider \(provider.id): SKIPPED \(foundModels.count) models (disabled)", source: "ProviderCatalog")
          }
        } else {
          AppLogger.shared.warning("Provider \(provider.id) (\(providerName)): NO models matched from rerouted labels", source: "ProviderCatalog")
        }
      }

      // Only include models from enabled providers - do not include models from disabled providers
      // This prevents showing models from providers that users have explicitly disabled
      let sortedModels = sortModels(Array(allProxyModels))
      AppLogger.shared.info("Auto-proxy: \(sortedModels.count) models (from enabled providers only)", source: "ProviderCatalog")
      nextModels[UnifiedProviderID.autoProxyId] = sortedModels
    } else {
      AppLogger.shared.warning("Auto-proxy models empty: CLIProxy not running", source: "ProviderCatalog")
      nextModels[UnifiedProviderID.autoProxyId] = []
    }

    sections = nextSections
    modelsByProviderId = nextModels
    availabilityByProviderId = availability
    kindByProviderId = kinds

    let autoProxyCount = nextModels[UnifiedProviderID.autoProxyId]?.count ?? 0
    AppLogger.shared.endTask(taskToken, message: "Catalog reloaded: \(nextSections.count) sections, auto-proxy=\(autoProxyCount) models", source: "ProviderCatalog")
  }

  func normalizeProviderId(_ raw: String?) -> String? {
    UnifiedProviderID.normalize(raw, registryProviders: registryProviders)
  }

  func models(for providerId: String?) -> [String] {
    guard let providerId else { return [] }
    // For OAuth accounts, models are shared at provider level
    let parsed = UnifiedProviderID.parse(providerId)
    if case .oauth(let provider, _) = parsed {
      let providerBaseId = UnifiedProviderID.oauth(provider, accountId: nil)
      return modelsByProviderId[providerBaseId] ?? modelsByProviderId[providerId] ?? []
    }
    return modelsByProviderId[providerId] ?? []
  }

  /// Returns sanitized models with both display names and original IDs
  func sanitizedModels(for providerId: String?) -> [ModelNameSanitizer.SanitizedModel] {
    let rawModels = models(for: providerId)
    return ModelNameSanitizer.sanitize(rawModels)
  }

  /// Returns the display name for a single model (sanitized)
  func displayName(for model: String) -> String {
    return ModelNameSanitizer.sanitizeSingle(model)
  }

  /// Resolves a display name back to the original model ID for a given provider
  func resolveModelId(displayName: String, providerId: String?) -> String? {
    let sanitized = sanitizedModels(for: providerId)
    return sanitized.first { $0.displayName == displayName }?.originalId
  }

  func isProviderAvailable(_ providerId: String?) -> Bool {
    guard let providerId else { return true }
    return availabilityByProviderId[providerId] == nil
  }

  func availabilityHint(for providerId: String?) -> String? {
    guard let providerId else { return nil }
    return availabilityByProviderId[providerId]
  }

  func sectionTitle(for providerId: String?) -> String? {
    guard let providerId, let kind = kindByProviderId[providerId] else { return nil }
    switch kind {
    case .oauth: return "OAuth Providers"
    case .apiKey: return "API Key Providers"
    }
  }

  /// Get provider title from provider ID
  func providerTitle(for providerId: String?) -> String? {
    guard let providerId else { return nil }
    // Search through sections to find the provider
    for section in sections {
      if let provider = section.providers.first(where: { $0.id == providerId }) {
        return provider.title
      }
    }
    // Fallback: parse provider ID and generate title
    let parsed = UnifiedProviderID.parse(providerId)
    switch parsed {
    case .oauth(let authProvider, let accountId):
      if let accountId = accountId, !accountId.isEmpty {
        return "\(authProvider.displayName) (\(accountId))"
      }
      return authProvider.displayName
    case .api(let apiId):
      // Try to find in registry
      if let provider = registryProviders.first(where: { $0.id == apiId }) {
        return UnifiedProviderID.providerDisplayName(provider)
      }
      return apiId
    case .autoProxy:
      return "Auto-Proxy (CliProxyAPI)"
    default:
      return nil
    }
  }

  /// Infer provider from model ID (useful when providerId is autoProxy)
  /// Returns the service provider display name (e.g., "AICodeWith", "OpenRouter") or OAuth provider name
  ///
  /// This method ONLY uses metadata (owned_by) - the single source of truth.
  /// No fallback, no pattern matching. Only recognize service providers, not manufacturers.
  func inferProviderFromModel(_ modelId: String) -> String? {
    // Only use metadata mapping built from LocalModel.owned_by
    if let providerId = modelToProviderMap[modelId] {
      let title = providerTitle(for: providerId)
      AppLogger.shared.info("[inferProvider] '\(modelId)' → metadata: providerId=\(providerId), title=\(title ?? "nil")", source: "ProviderCatalog")
      return title
    }

    // No fallback - if model is not in metadata map, return nil
    AppLogger.shared.warning("[inferProvider] '\(modelId)' → No metadata found, returning nil", source: "ProviderCatalog")
    return nil
  }

  // MARK: - Local model mapping
  private struct LocalModelMap {
    var builtIn: [String: [String]]
    var rerouted: [String: [String]]
  }

  private func mapLocalModels(_ models: [CLIProxyService.LocalModel]) -> LocalModelMap {
    var builtIn: [String: [String]] = [:]
    var rerouted: [String: [String]] = [:]
    var modelToProvider: [String: String] = [:]

    for provider in LocalAuthProvider.allCases {
      builtIn[UnifiedProviderID.oauth(provider)] = []
    }

    AppLogger.shared.info("Mapping \(models.count) models from CLIProxyAPI", source: "ProviderCatalog")
    var skippedModels: [(id: String, reason: String)] = []

    for model in models {
      // Debug: Log all OAuth models metadata for comparison
      if model.provider != nil || model.source != nil || model.owned_by != nil {
        let providerVal = model.provider ?? "nil"
        let sourceVal = model.source ?? "nil"
        let ownedByVal = model.owned_by ?? "nil"
        AppLogger.shared.info("[DEBUG] Model '\(model.id)' raw metadata: provider='\(providerVal)', source='\(sourceVal)', owned_by='\(ownedByVal)'", source: "ProviderCatalog")
      }

      if let builtin = builtInProvider(for: model),
        let auth = UnifiedProviderID.authProvider(for: builtin)
      {
        let id = UnifiedProviderID.oauth(auth)
        var list = builtIn[id] ?? []
        if !list.contains(model.id) { list.append(model.id) }
        builtIn[id] = list
        // Map model to provider for reliable inference
        modelToProvider[model.id] = id
        AppLogger.shared.info("Model '\(model.id)' → builtIn(\(builtin.rawValue)) via metadata=[\(model.provider ?? "nil"), \(model.source ?? "nil"), \(model.owned_by ?? "nil")]", source: "ProviderCatalog")
        continue
      }
      guard let label = rerouteProviderLabel(for: model) else {
        skippedModels.append((id: model.id, reason: "No label (provider=\(model.provider ?? "nil"), source=\(model.source ?? "nil"), owned_by=\(model.owned_by ?? "nil"))"))
        continue
      }
      // Debug: log rerouted model details
      let normalizedLabel = normalizeLabel(label)
      AppLogger.shared.info("Model '\(model.id)' → rerouted['\(label)'] (normalized: '\(normalizedLabel)') via metadata=[\(model.provider ?? "nil"), \(model.source ?? "nil"), \(model.owned_by ?? "nil")]", source: "ProviderCatalog")

      let key = normalizedLabel
      var list = rerouted[key] ?? []
      if !list.contains(model.id) { list.append(model.id) }
      rerouted[key] = list
      // For rerouted models, try to find the API provider ID
      // Try multiple matching strategies to handle different label formats
      var matchedProviderId: String? = nil
      if let apiProvider = findAPIProviderByLabel(label) {
        matchedProviderId = UnifiedProviderID.api(apiProvider.id)
      } else {
        // Try matching by provider name or ID directly
        for provider in registryProviders {
          let providerName = provider.name ?? provider.id
          let normalizedProviderName = normalizeLabel(providerName)
          let normalizedProviderId = normalizeLabel(provider.id)
          if key == normalizedProviderName || key == normalizedProviderId {
            matchedProviderId = UnifiedProviderID.api(provider.id)
            break
          }
        }
      }
      // Store the mapping (use virtual ID if no match found)
      if let matchedId = matchedProviderId {
        modelToProvider[model.id] = matchedId
      } else {
        // If provider not found in registry, create a virtual provider ID using the label
        // This handles cases where users configure openai-compatibility providers directly in CLIProxyAPI
        let virtualProviderId = UnifiedProviderID.api(label)
        modelToProvider[model.id] = virtualProviderId
      }
    }
    // Store the mapping for later use
    modelToProviderMap = modelToProvider
    // Store rerouted models by label for fallback inference
    reroutedModelsByLabel = rerouted

    // Log skipped models for debugging
    if !skippedModels.isEmpty {
      AppLogger.shared.warning("Skipped \(skippedModels.count) models without provider labels:", source: "ProviderCatalog")
      for (id, reason) in skippedModels.prefix(5) {
        AppLogger.shared.warning("  - '\(id)': \(reason)", source: "ProviderCatalog")
      }
      if skippedModels.count > 5 {
        AppLogger.shared.warning("  ... and \(skippedModels.count - 5) more", source: "ProviderCatalog")
      }
    }

    return LocalModelMap(builtIn: builtIn, rerouted: rerouted)
  }

  private func findAPIProviderByLabel(_ label: String) -> ProvidersRegistryService.Provider? {
    let normalized = normalizeLabel(label)
    // First, try to find in registry providers
    if let provider = registryProviders.first(where: { provider in
      let displayName = UnifiedProviderID.providerDisplayName(provider)
      return normalizeLabel(displayName) == normalized || normalizeLabel(provider.id) == normalized
    }) {
      return provider
    }
    // If not found, return nil (caller will create a virtual provider)
    return nil
  }

  private func builtInProvider(for model: CLIProxyService.LocalModel) -> LocalServerBuiltInProvider? {
    let hint = model.provider ?? model.source ?? model.owned_by
    if let hint,
      let provider = LocalServerBuiltInProvider.allCases.first(where: { $0.matchesOwnedBy(hint) })
    {
      return provider
    }

    // If owned_by is present but doesn't match any built-in provider,
    // this is a third-party provider - don't do pattern matching on model ID
    if let ownedBy = model.owned_by?.trimmingCharacters(in: .whitespacesAndNewlines),
       !ownedBy.isEmpty,
       !LocalServerBuiltInProvider.allCases.contains(where: { $0.matchesOwnedBy(ownedBy) }) {
      return nil
    }

    // Only do pattern matching if owned_by is nil or matched a built-in provider
    let modelId = model.id
    if let provider = LocalServerBuiltInProvider.allCases.first(where: { $0.matchesModelId(modelId) }) {
      return provider
    }
    return nil
  }

  private func rerouteProviderLabel(for model: CLIProxyService.LocalModel) -> String? {
    // Priority 1: Use cached provider name from config.yaml (most reliable)
    // This directly reads from our own config.yaml, no guessing needed
    if let cachedName = CLIProxyService.shared.getProviderName(for: model.id) {
      return cachedName
    }

    // Priority 2: Fall back to metadata fields (provider > source > owned_by)
    // CLIProxyAPI returns models with source field containing the provider name from config.yaml
    let hint = model.provider ?? model.source ?? model.owned_by
    let trimmed = hint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  private func normalizeLabel(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private func sortModels(_ list: [String]) -> [String] {
    list.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
  }

  private func availabilityHintForOAuth(
    proxyRunning: Bool,
    oauthEnabled: Bool,
    authAvailable: Bool,
    providerName: String
  ) -> String? {
    if !proxyRunning {
      return "CLI Proxy API isn't running. Start it in Providers → CLI Proxy API."
    }
    if !oauthEnabled {
      return "Enable this provider in Providers to use this option."
    }
    if !authAvailable {
      return "Sign in to \(providerName) in Providers to use this option."
    }
    return nil
  }

  private func availabilityHintForAPIKey(proxyRunning: Bool) -> String? {
    if !proxyRunning {
      return "CLI Proxy API isn't running. Start it in Providers → CLI Proxy API."
    }
    return nil
  }
}

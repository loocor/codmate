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

  func reload(preferences: SessionPreferencesStore, forceRefresh: Bool = false) async {
    let registry = ProvidersRegistryService()
    let providers = await registry.listProviders()
    registryProviders = providers

    let rerouteBuiltIn = preferences.localServerReroute
    let reroute3P = preferences.localServerReroute3P
    let oauthEnabledSet = preferences.oauthProvidersEnabled
    let proxyRunning = CLIProxyService.shared.isRunning

    var localModels: [CLIProxyService.LocalModel] = []
    if proxyRunning && (rerouteBuiltIn || reroute3P) {
      localModels = await CLIProxyService.shared.fetchLocalModels(forceRefresh: forceRefresh)
    }
    let mapped = mapLocalModels(localModels)

    var nextSections: [UnifiedProviderSection] = []
    var nextModels: [String: [String]] = [:]
    var availability: [String: String] = [:]
    var kinds: [String: UnifiedProviderChoice.Kind] = [:]

    // OAuth section
    let oauthProviders = LocalAuthProvider.allCases.sorted {
      $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
    }
    var oauthChoices: [UnifiedProviderChoice] = []
    for provider in oauthProviders {
      let id = UnifiedProviderID.oauth(provider)
      let isEnabled = oauthEnabledSet.contains(provider.rawValue)
      let hasAuth = CLIProxyService.shared.hasAuthToken(for: provider)
      let available = proxyRunning && rerouteBuiltIn && isEnabled && hasAuth
      let hint = availabilityHintForOAuth(
        proxyRunning: proxyRunning,
        rerouteBuiltIn: rerouteBuiltIn,
        oauthEnabled: isEnabled,
        authAvailable: hasAuth,
        providerName: provider.displayName
      )
      let choice = UnifiedProviderChoice(
        id: id,
        title: provider.displayName,
        kind: .oauth,
        isAvailable: available,
        availabilityHint: available ? nil : hint
      )
      oauthChoices.append(choice)
      kinds[id] = .oauth
      if available {
        nextModels[id] = sortModels(mapped.builtIn[id] ?? [])
      } else {
        nextModels[id] = []
        if let hint { availability[id] = hint }
      }
    }
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
        let available = !(reroute3P && !proxyRunning)
        let hint = availabilityHintForAPIKey(proxyRunning: proxyRunning, reroute3P: reroute3P)
        kinds[id] = .apiKey
        if reroute3P && proxyRunning {
          let label = normalizeLabel(UnifiedProviderID.providerDisplayName(provider))
          nextModels[id] = sortModels(mapped.rerouted[label] ?? [])
        } else {
          let ids = (provider.catalog?.models ?? []).map { $0.vendorModelId }
          nextModels[id] = sortModels(ids)
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

    sections = nextSections
    modelsByProviderId = nextModels
    availabilityByProviderId = availability
    kindByProviderId = kinds
  }

  func normalizeProviderId(_ raw: String?) -> String? {
    UnifiedProviderID.normalize(raw, registryProviders: registryProviders)
  }

  func models(for providerId: String?) -> [String] {
    guard let providerId else { return [] }
    return modelsByProviderId[providerId] ?? []
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

  // MARK: - Local model mapping
  private struct LocalModelMap {
    var builtIn: [String: [String]]
    var rerouted: [String: [String]]
  }

  private func mapLocalModels(_ models: [CLIProxyService.LocalModel]) -> LocalModelMap {
    var builtIn: [String: [String]] = [:]
    var rerouted: [String: [String]] = [:]

    for provider in LocalAuthProvider.allCases {
      builtIn[UnifiedProviderID.oauth(provider)] = []
    }

    for model in models {
      if let builtin = builtInProvider(for: model),
        let auth = UnifiedProviderID.authProvider(for: builtin)
      {
        let id = UnifiedProviderID.oauth(auth)
        var list = builtIn[id] ?? []
        if !list.contains(model.id) { list.append(model.id) }
        builtIn[id] = list
        continue
      }
      guard let label = rerouteProviderLabel(for: model) else { continue }
      let key = normalizeLabel(label)
      var list = rerouted[key] ?? []
      if !list.contains(model.id) { list.append(model.id) }
      rerouted[key] = list
    }
    return LocalModelMap(builtIn: builtIn, rerouted: rerouted)
  }

  private func builtInProvider(for model: CLIProxyService.LocalModel) -> LocalServerBuiltInProvider? {
    let hint = model.provider ?? model.source ?? model.owned_by
    if let hint,
      let provider = LocalServerBuiltInProvider.allCases.first(where: { $0.matchesOwnedBy(hint) })
    {
      return provider
    }
    let modelId = model.id
    if let provider = LocalServerBuiltInProvider.allCases.first(where: { $0.matchesModelId(modelId) }) {
      return provider
    }
    return nil
  }

  private func rerouteProviderLabel(for model: CLIProxyService.LocalModel) -> String? {
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
    rerouteBuiltIn: Bool,
    oauthEnabled: Bool,
    authAvailable: Bool,
    providerName: String
  ) -> String? {
    if !rerouteBuiltIn {
      return "Enable ReRoute for OAuth providers in Providers → ReRoute Control."
    }
    if !proxyRunning {
      return "CLI Proxy API isn't running. Start it in Providers → ReRoute Control."
    }
    if !oauthEnabled {
      return "Enable OAuth providers in Providers to use this option."
    }
    if !authAvailable {
      return "Sign in to \(providerName) in Providers to use this option."
    }
    return nil
  }

  private func availabilityHintForAPIKey(proxyRunning: Bool, reroute3P: Bool) -> String? {
    if reroute3P && !proxyRunning {
      return "CLI Proxy API isn't running. Start it in Providers → ReRoute Control."
    }
    return nil
  }
}

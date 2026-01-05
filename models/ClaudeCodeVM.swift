import Foundation
import SwiftUI
import AppKit

@MainActor
final class ClaudeCodeVM: ObservableObject {
    let builtinModels: [String] = [
        "claude-3-5-sonnet-latest",
        "claude-3-haiku-latest",
        "claude-3-opus-latest",
    ]
    @Published var providers: [ProvidersRegistryService.Provider] = []
    @Published var activeProviderId: String?
    enum LoginMethod: String, CaseIterable, Identifiable { case api, subscription; var id: String { rawValue } }
    @Published var loginMethod: LoginMethod = .api
    @Published var aliasDefault: String = ""
    @Published var aliasHaiku: String = ""
    @Published var aliasSonnet: String = ""
    @Published var aliasOpus: String = ""
    @Published var lastError: String?
    @Published var rawSettingsText: String = ""
    @Published var notificationsEnabled: Bool = false
    @Published var notificationBridgeHealthy: Bool = false
    @Published var notificationSelfTestResult: String? = nil

    private let registry = ProvidersRegistryService()
    private var saveDebounceTask: Task<Void, Never>? = nil
    private var applyProviderDebounceTask: Task<Void, Never>? = nil
    private var proxySelectionDebounceTask: Task<Void, Never>? = nil
    private var defaultAliasDebounceTask: Task<Void, Never>? = nil
    private var runtimeDebounceTask: Task<Void, Never>? = nil
    private var notificationDebounceTask: Task<Void, Never>? = nil

    func loadAll() async {
        let providerList = await registry.listProviders()
        let bindings = await registry.getBindings()
        await MainActor.run {
            self.providers = providerList
            self.activeProviderId = bindings.activeProvider?[ProvidersRegistryService.Consumer.claudeCode.rawValue]
            self.syncAliases()
            self.syncLoginMethod()
        }
        await loadNotificationSettings()
    }

    func loadProxyDefaults(preferences: SessionPreferencesStore) async {
        let settings = ClaudeSettingsService()
        let currentModel = await settings.currentModel()
        let env = await settings.envSnapshot()
        if preferences.claudeProxyModelId == nil {
            if let model = currentModel, !model.isEmpty {
                preferences.claudeProxyModelId = model
            } else if let envModel = env["ANTHROPIC_MODEL"] ?? env["ANTHROPIC_DEFAULT_SONNET_MODEL"]
                        ?? env["ANTHROPIC_DEFAULT_OPUS_MODEL"] ?? env["ANTHROPIC_DEFAULT_HAIKU_MODEL"],
                      !envModel.isEmpty {
                preferences.claudeProxyModelId = envModel
            }
        }
        if let providerId = preferences.claudeProxyProviderId {
            let existing = preferences.claudeProxyModelAliases[providerId] ?? [:]
            if existing.isEmpty {
                var aliases: [String: String] = [:]
                if let opus = env["ANTHROPIC_DEFAULT_OPUS_MODEL"] { aliases["opus"] = opus }
                if let sonnet = env["ANTHROPIC_DEFAULT_SONNET_MODEL"] { aliases["sonnet"] = sonnet }
                if let haiku = env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] { aliases["haiku"] = haiku }
                if !aliases.isEmpty {
                    var stored = preferences.claudeProxyModelAliases
                    stored[providerId] = aliases
                    preferences.claudeProxyModelAliases = stored
                }
            }
        }
    }

    func availableModels() -> [String] {
        guard let id = activeProviderId,
              let provider = providers.first(where: { $0.id == id })
        else { return [] }
        return (provider.catalog?.models ?? []).map { $0.vendorModelId }
    }

    func applyDefaultAlias(_ modelId: String) async {
        guard let id = activeProviderId else {
            await MainActor.run { self.aliasDefault = modelId }
            return
        }
        let providerList = await registry.listProviders()
        guard var provider = providerList.first(where: { $0.id == id }) else { return }
        var connector = provider.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue] ?? .init(
            baseURL: nil,
            wireAPI: nil,
            envKey: "ANTHROPIC_AUTH_TOKEN",
            loginMethod: nil,
            queryParams: nil,
            httpHeaders: nil,
            envHttpHeaders: nil,
            requestMaxRetries: nil,
            streamMaxRetries: nil,
            streamIdleTimeoutMs: nil,
            modelAliases: nil)
        var aliases = connector.modelAliases ?? [:]
        aliases["default"] = modelId
        connector.modelAliases = aliases
        provider.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue] = connector
        do {
            try await registry.upsertProvider(provider)
            await MainActor.run { self.aliasDefault = modelId; self.lastError = nil }
            // Persist to ~/.claude/settings.json → model only for third‑party providers
            if self.activeProviderId != nil {
                if SecurityScopedBookmarks.shared.isSandboxed {
                    let home = SessionPreferencesStore.getRealUserHomeURL()
                    _ = AuthorizationHub.shared.ensureDirectoryAccessOrPromptSync(directory: home, purpose: .generalAccess, message: "Authorize your Home folder to update Claude settings")
                }
                let settings = ClaudeSettingsService()
                try? await settings.setModel(modelId)
            }
        } catch { await MainActor.run { self.lastError = "Failed to set default model" } }
    }

    func tokenMissingForCurrentSelection() -> Bool {
        if loginMethod == .subscription { return false }
        let env = ProcessInfo.processInfo.environment
        if let id = activeProviderId,
           let provider = providers.first(where: { $0.id == id }) {
            let key = provider.envKey ?? provider.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue]?.envKey ?? "ANTHROPIC_AUTH_TOKEN"
            let val = env[key]
            return (val == nil || val?.isEmpty == true)
        }
        let val = env["ANTHROPIC_AUTH_TOKEN"]
        return (val == nil || val?.isEmpty == true)
    }

    func applyActiveProvider() async {
        do {
            try await registry.setActiveProvider(.claudeCode, providerId: activeProviderId)
            await MainActor.run { self.lastError = nil }
        } catch {
            await MainActor.run { self.lastError = "Failed to set active provider" }
        }
        await MainActor.run {
            self.syncAliases()
            self.syncLoginMethod()
        }
        // Decide persistence policy
        let isBuiltin = (activeProviderId == nil)
        // Built‑in provider → clear provider-specific keys (model/env base URL/forceLogin/token)
        if isBuiltin {
            if SecurityScopedBookmarks.shared.isSandboxed {
                let home = SessionPreferencesStore.getRealUserHomeURL()
                _ = AuthorizationHub.shared.ensureDirectoryAccessOrPromptSync(directory: home, purpose: .generalAccess)
            }
            let settings = ClaudeSettingsService()
            try? await settings.setModel(nil)
            try? await settings.setEnvBaseURL(nil)
            try? await settings.setForceLoginMethod(nil)
            try? await settings.setEnvToken(nil)
            return
        }

        if SecurityScopedBookmarks.shared.isSandboxed {
            let home = SessionPreferencesStore.getRealUserHomeURL()
            _ = AuthorizationHub.shared.ensureDirectoryAccessOrPromptSync(directory: home, purpose: .generalAccess)
        }
        let settings = ClaudeSettingsService()
        // Base URL only for third‑party providers
        let base = isBuiltin ? nil : selectedClaudeBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        try? await settings.setEnvBaseURL((base?.isEmpty == false) ? base : nil)
        // Force login only for API; remove for subscription
        if loginMethod == .api {
            try? await settings.setForceLoginMethod("console")
        } else {
            try? await settings.setForceLoginMethod(nil)
        }
        // Token only for API
        if loginMethod == .api {
            var token: String? = nil
            if let id = activeProviderId,
               let provider = providers.first(where: { $0.id == id }) {
                let conn = provider.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue]
                let keyName = provider.envKey ?? conn?.envKey ?? "ANTHROPIC_AUTH_TOKEN"
                let env = ProcessInfo.processInfo.environment
                if let val = env[keyName], !val.isEmpty {
                    token = val
                } else {
                    let looksLikeToken = keyName.lowercased().contains("sk-") || keyName.hasPrefix("eyJ") || keyName.contains(".")
                    if looksLikeToken { token = keyName }
                }
            }
            try? await settings.setEnvToken(token)
        } else {
            try? await settings.setEnvToken(nil)
        }
    }

    func applyProxySelection(
        providerId: String?,
        modelId: String?,
        preferences: SessionPreferencesStore
    ) async {
        if SecurityScopedBookmarks.shared.isSandboxed {
            let home = SessionPreferencesStore.getRealUserHomeURL()
            _ = AuthorizationHub.shared.ensureDirectoryAccessOrPromptSync(directory: home, purpose: .generalAccess)
        }
        let settings = ClaudeSettingsService()
        do {
            if providerId == nil {
                try await settings.setModel(nil)
                try await settings.setEnvBaseURL(nil)
                try await settings.setForceLoginMethod(nil)
                try await settings.setEnvToken(nil)
                try await settings.setEnvValues([
                    "ANTHROPIC_DEFAULT_OPUS_MODEL": nil,
                    "ANTHROPIC_DEFAULT_SONNET_MODEL": nil,
                    "ANTHROPIC_DEFAULT_HAIKU_MODEL": nil,
                    "ANTHROPIC_MODEL": nil,
                    "ANTHROPIC_SMALL_FAST_MODEL": nil
                ])
                await MainActor.run { self.lastError = nil }
                return
            }
            let port = preferences.localServerPort
            let baseURL = "http://127.0.0.1:\(port)"
            let trimmedModel = modelId?.trimmingCharacters(in: .whitespacesAndNewlines)
            let apiKey = CLIProxyService.shared.resolvePublicAPIKey()
            let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            try await settings.setEnvBaseURL(baseURL)
            try await settings.setForceLoginMethod(nil)
            try await settings.setEnvToken(trimmedKey.isEmpty ? nil : trimmedKey)
            let resolved = await resolveProxyAliases(
                providerId: providerId,
                selectedModel: trimmedModel,
                preferences: preferences
            )
            try await settings.setModel(resolved.defaultModel)
            try await settings.setEnvValues([
                "ANTHROPIC_DEFAULT_OPUS_MODEL": resolved.opus,
                "ANTHROPIC_DEFAULT_SONNET_MODEL": resolved.sonnet,
                "ANTHROPIC_DEFAULT_HAIKU_MODEL": resolved.haiku,
                "ANTHROPIC_MODEL": resolved.defaultModel,
                "ANTHROPIC_SMALL_FAST_MODEL": resolved.haiku ?? resolved.defaultModel
            ])
            await MainActor.run { self.lastError = nil }
        } catch {
            await MainActor.run {
                self.lastError = "Failed to apply CLI Proxy provider: \(error.localizedDescription)"
            }
        }
    }

    private struct ClaudeProxyAliasSet {
        var defaultModel: String?
        var opus: String?
        var sonnet: String?
        var haiku: String?
    }

    private func resolveProxyAliases(
        providerId: String?,
        selectedModel: String?,
        preferences: SessionPreferencesStore
    ) async -> ClaudeProxyAliasSet {
        let trimmedSelected = selectedModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        var defaultModel = (trimmedSelected?.isEmpty == false) ? trimmedSelected : nil

        let storedAliases = providerId.flatMap { preferences.claudeProxyModelAliases[$0] } ?? [:]
        var opus = storedAliases["opus"]
        var sonnet = storedAliases["sonnet"]
        var haiku = storedAliases["haiku"]

        var fallbackAliases: [String: String] = [:]

        if let providerId {
            switch UnifiedProviderID.parse(providerId) {
            case .oauth(let authProvider, _):
                fallbackAliases = await proxyAliasDefaults(
                    for: authProvider,
                    fallbackModel: defaultModel
                )
            case .api(let apiId):
                fallbackAliases = await registryAliasDefaults(
                    for: apiId
                )
            default:
                break
            }
        }

        if defaultModel == nil {
            defaultModel = fallbackAliases["default"]
                ?? fallbackAliases["sonnet"]
                ?? fallbackAliases["opus"]
                ?? fallbackAliases["haiku"]
        }

        if opus == nil { opus = fallbackAliases["opus"] ?? defaultModel }
        if sonnet == nil { sonnet = fallbackAliases["sonnet"] ?? defaultModel }
        if haiku == nil { haiku = fallbackAliases["haiku"] ?? defaultModel }

        return ClaudeProxyAliasSet(
            defaultModel: defaultModel,
            opus: opus,
            sonnet: sonnet,
            haiku: haiku
        )
    }

    private func proxyAliasDefaults(
        for provider: LocalAuthProvider,
        fallbackModel: String?
    ) async -> [String: String] {
        let trimmedSelected = fallbackModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = (trimmedSelected?.isEmpty == false) ? trimmedSelected : nil
        var models: [String] = []
        if let target = builtInProvider(for: provider), CLIProxyService.shared.isRunning {
            let localModels = await CLIProxyService.shared.fetchLocalModels()
            models = localModels.compactMap { model in
                let candidate = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !candidate.isEmpty else { return nil }
                if builtInProvider(for: model) == target {
                    return candidate
                }
                return nil
            }
        }

        let preferred = fallback ?? selectDefaultModel(from: models)
        let opus = selectModel(from: models, tokens: ["opus"]) ?? preferred
        let sonnet = selectModel(from: models, tokens: ["sonnet"]) ?? preferred
        let haiku = selectModel(from: models, tokens: ["haiku", "flash", "lite", "mini"]) ?? preferred

        var out: [String: String] = [:]
        if let preferred { out["default"] = preferred }
        if let opus { out["opus"] = opus }
        if let sonnet { out["sonnet"] = sonnet }
        if let haiku { out["haiku"] = haiku }
        return out
    }

    private func registryAliasDefaults(for providerId: String) async -> [String: String] {
        let providers = await registry.listAllProviders()
        guard let provider = providers.first(where: { $0.id == providerId }) else { return [:] }
        let connector = provider.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue]
        let aliases = connector?.modelAliases ?? [:]
        var out: [String: String] = [:]
        if let def = aliases["default"] { out["default"] = def }
        if let opus = aliases["opus"] { out["opus"] = opus }
        if let sonnet = aliases["sonnet"] { out["sonnet"] = sonnet }
        if let haiku = aliases["haiku"] { out["haiku"] = haiku }
        if let rec = provider.recommended?.defaultModelFor?[ProvidersRegistryService.Consumer.claudeCode.rawValue],
           out["default"] == nil {
            out["default"] = rec
        }
        if out["default"] == nil,
           let first = provider.catalog?.models?.first?.vendorModelId {
            out["default"] = first
        }
        return out
    }

    private func selectDefaultModel(from models: [String]) -> String? {
        if let match = selectModel(from: models, tokens: ["sonnet", "opus", "haiku"]) { return match }
        if let match = selectModel(from: models, tokens: ["pro", "latest", "preview"]) { return match }
        return models.first
    }

    private func selectModel(from models: [String], tokens: [String]) -> String? {
        guard !models.isEmpty else { return nil }
        for token in tokens {
            if let match = models.first(where: { $0.localizedCaseInsensitiveContains(token) }) {
                return match
            }
        }
        return nil
    }

    private func builtInProvider(for provider: LocalAuthProvider) -> LocalServerBuiltInProvider? {
        switch provider {
        case .codex: return .openai
        case .claude: return .anthropic
        case .gemini: return .gemini
        case .antigravity: return .antigravity
        case .qwen: return .qwen
        }
    }

    private func builtInProvider(for model: CLIProxyService.LocalModel) -> LocalServerBuiltInProvider? {
        let hint = model.provider ?? model.source ?? model.owned_by
        if let hint, let provider = LocalServerBuiltInProvider.allCases.first(where: { $0.matchesOwnedBy(hint) }) {
            return provider
        }
        let modelId = model.id
        if let provider = LocalServerBuiltInProvider.allCases.first(where: { $0.matchesModelId(modelId) }) {
            return provider
        }
        return nil
    }

    func save() async {
        guard let id = activeProviderId else { return }
        let providerList = await registry.listAllProviders()
        guard var provider = providerList.first(where: { $0.id == id }) else { return }
        var connector = provider.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue] ?? .init(
            baseURL: nil,
            wireAPI: nil,
            envKey: "ANTHROPIC_AUTH_TOKEN",
            queryParams: nil,
            httpHeaders: nil,
            envHttpHeaders: nil,
            requestMaxRetries: nil,
            streamMaxRetries: nil,
            streamIdleTimeoutMs: nil,
            modelAliases: nil)

        var aliases: [String: String] = [:]
        func assign(_ key: String, _ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { aliases[key] = trimmed }
        }
        assign("default", aliasDefault)
        assign("haiku", aliasHaiku)
        assign("sonnet", aliasSonnet)
        assign("opus", aliasOpus)

        connector.modelAliases = aliases.isEmpty ? nil : aliases
        provider.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue] = connector

        do {
            try await registry.upsertProvider(provider)
            await MainActor.run { self.lastError = nil }
            // Persist model only for third‑party providers
            if self.activeProviderId != nil {
                if SecurityScopedBookmarks.shared.isSandboxed {
                    let home = SessionPreferencesStore.getRealUserHomeURL()
                    _ = AuthorizationHub.shared.ensureDirectoryAccessOrPromptSync(directory: home, purpose: .generalAccess)
                }
                let settings = ClaudeSettingsService()
                let m = aliasDefault.trimmingCharacters(in: .whitespacesAndNewlines)
                try? await settings.setModel(m.isEmpty ? nil : m)
            }
            await loadAll()
        } catch {
            await MainActor.run { self.lastError = "Failed to save aliases" }
        }
    }

    func scheduleSaveDebounced(delayMs: UInt64 = 300) {
        // Cancel any in-flight debounce task and schedule a new one
        saveDebounceTask?.cancel()
        saveDebounceTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: delayMs * 1_000_000)
            } catch { return }
            if Task.isCancelled { return }
            await self.save()
        }
    }

    // MARK: - Runtime settings writer
    func scheduleApplyRuntimeSettings(_ preferences: SessionPreferencesStore, delayMs: UInt64 = 250) {
        runtimeDebounceTask?.cancel()
        runtimeDebounceTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: delayMs * 1_000_000) } catch { return }
            if Task.isCancelled { return }
            await self.applyRuntimeSettings(preferences)
        }
    }

    func applyRuntimeSettings(_ preferences: SessionPreferencesStore) async {
        if SecurityScopedBookmarks.shared.isSandboxed {
            let home = SessionPreferencesStore.getRealUserHomeURL()
            _ = AuthorizationHub.shared.ensureDirectoryAccessOrPromptSync(directory: home, purpose: .generalAccess)
        }
        let settings = ClaudeSettingsService()
        let addDirs: [String]? = {
            let raw = preferences.claudeAddDirs.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty { return nil }
            return raw.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map { String($0) }
        }()
        let runtime = ClaudeSettingsService.Runtime(
            permissionMode: preferences.claudePermissionMode.rawValue,
            skipPermissions: preferences.claudeSkipPermissions,
            allowSkipPermissions: preferences.claudeAllowSkipPermissions,
            debug: preferences.claudeDebug,
            debugFilter: preferences.claudeDebugFilter,
            verbose: preferences.claudeVerbose,
            ide: preferences.claudeIDE,
            strictMCP: preferences.claudeStrictMCP,
            fallbackModel: preferences.claudeFallbackModel,
            allowedTools: preferences.claudeAllowedTools,
            disallowedTools: preferences.claudeDisallowedTools,
            addDirs: addDirs
        )
        try? await settings.applyRuntime(runtime)
    }

    func loadNotificationSettings() async {
        let settings = ClaudeSettingsService()
        let status = await settings.codMateNotificationHooksStatus()
        await MainActor.run {
            let healthy = status.permissionHookInstalled && status.completionHookInstalled
            self.notificationsEnabled = healthy
            self.notificationBridgeHealthy = healthy
            if !healthy {
                self.notificationSelfTestResult = nil
            }
        }
    }

    private func syncAliases() {
        guard let id = activeProviderId,
              let provider = providers.first(where: { $0.id == id })
        else {
            aliasDefault = ""
            aliasHaiku = ""
            aliasSonnet = ""
            aliasOpus = ""
            return
        }
        let connector = provider.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue]
        let aliases = connector?.modelAliases ?? [:]
        let recommended = provider.recommended?.defaultModelFor?[ProvidersRegistryService.Consumer.claudeCode.rawValue]
        aliasDefault = aliases["default"] ?? recommended ?? ""
        aliasHaiku = aliases["haiku"] ?? ""
        aliasSonnet = aliases["sonnet"] ?? ""
        aliasOpus = aliases["opus"] ?? ""
    }

    private func syncLoginMethod() {
        // Built-in (nil provider) defaults to subscription; third-party defaults to api
        guard let id = activeProviderId,
              let provider = providers.first(where: { $0.id == id }) else {
            loginMethod = .subscription
            return
        }
        let connector = provider.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue]
        if let lm = connector?.loginMethod, lm.lowercased() == "subscription" {
            loginMethod = .subscription
        } else {
            loginMethod = .api
        }
    }

    func setLoginMethod(_ method: LoginMethod) async {
        await MainActor.run { self.loginMethod = method }
        // Persist to registry for active provider (if any). Built-in (nil) has no connector; nothing to write.
        guard let id = activeProviderId else { return }
        let list = await registry.listProviders()
        guard var p = list.first(where: { $0.id == id }) else { return }
        var conn = p.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue] ?? .init(
            baseURL: nil, wireAPI: nil, envKey: nil, loginMethod: nil,
            queryParams: nil, httpHeaders: nil, envHttpHeaders: nil,
            requestMaxRetries: nil, streamMaxRetries: nil, streamIdleTimeoutMs: nil,
            modelAliases: nil)
        conn.loginMethod = method.rawValue
        // Restore default env key for API login if absent (prefer provider-level key)
        if method == .api && (p.envKey == nil || p.envKey?.isEmpty == true) {
            p.envKey = "ANTHROPIC_AUTH_TOKEN"
        }
        if method == .subscription {
            // No need to store token env mapping; leave as-is but it will be ignored at launch.
        }
        p.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue] = conn
        do {
            try await registry.upsertProvider(p)
            // Persist to settings: only when API; subscription removes forced key and token
            if SecurityScopedBookmarks.shared.isSandboxed {
                let home = SessionPreferencesStore.getRealUserHomeURL()
                _ = AuthorizationHub.shared.ensureDirectoryAccessOrPromptSync(directory: home, purpose: .generalAccess)
            }
            let settings = ClaudeSettingsService()
            if method == .api {
                try? await settings.setForceLoginMethod("console")
                var token: String? = nil
                let env = ProcessInfo.processInfo.environment
                let keyName = p.envKey ?? p.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue]?.envKey ?? "ANTHROPIC_AUTH_TOKEN"
                if let val = env[keyName], !val.isEmpty {
                    token = val
                } else {
                    let looksLikeToken = keyName.lowercased().contains("sk-") || keyName.hasPrefix("eyJ") || keyName.contains(".")
                    if looksLikeToken { token = keyName }
                }
                try? await settings.setEnvToken(token)
            } else {
                try? await settings.setForceLoginMethod(nil)
                try? await settings.setEnvToken(nil)
            }
        } catch {
            await MainActor.run { self.lastError = "Failed to save login method" }
        }
    }

    private func applyNotificationSettings() async {
        if SecurityScopedBookmarks.shared.isSandboxed {
            let home = SessionPreferencesStore.getRealUserHomeURL()
            _ = AuthorizationHub.shared.ensureDirectoryAccessOrPromptSync(
                directory: home,
                purpose: .generalAccess,
                message: "Authorize ~/.claude to update Claude notifications"
            )
        }
        let settings = ClaudeSettingsService()
        do {
            try await settings.setCodMateNotificationHooks(enabled: notificationsEnabled)
            await loadNotificationSettings()
        } catch {
            await MainActor.run { self.lastError = "Failed to update Claude notifications" }
        }
    }

    func runNotificationSelfTest() async {
        notificationSelfTestResult = nil
        var comps = URLComponents()
        comps.scheme = "codmate"
        comps.host = "notify"
        let title = "CodMate"
        let body = "Claude notifications self-test"
        var items = [
            URLQueryItem(name: "source", value: "claude"),
            URLQueryItem(name: "event", value: "test")
        ]
        if let titleData = title.data(using: .utf8) {
            items.append(URLQueryItem(name: "title64", value: titleData.base64EncodedString()))
        }
        if let bodyData = body.data(using: .utf8) {
            items.append(URLQueryItem(name: "body64", value: bodyData.base64EncodedString()))
        }
        comps.queryItems = items
        guard let url = comps.url else {
            notificationSelfTestResult = "Invalid test URL"
            return
        }
        let success = NSWorkspace.shared.open(url)
        notificationSelfTestResult = success ? "Sent (check Notification Center)" : "Failed to open codmate:// URL"
    }

    // MARK: - Debounced operations
    func scheduleApplyActiveProviderDebounced(delayMs: UInt64 = 300) {
        applyProviderDebounceTask?.cancel()
        applyProviderDebounceTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: delayMs * 1_000_000) } catch { return }
            if Task.isCancelled { return }
            await self.applyActiveProvider()
        }
    }

    func scheduleApplyProxySelectionDebounced(
        providerId: String?,
        modelId: String?,
        preferences: SessionPreferencesStore,
        delayMs: UInt64 = 300
    ) {
        proxySelectionDebounceTask?.cancel()
        proxySelectionDebounceTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: delayMs * 1_000_000) } catch { return }
            if Task.isCancelled { return }
            await self.applyProxySelection(
                providerId: providerId,
                modelId: modelId,
                preferences: preferences
            )
        }
    }

    func scheduleApplyDefaultAliasDebounced(_ modelId: String, delayMs: UInt64 = 300) {
        defaultAliasDebounceTask?.cancel()
        defaultAliasDebounceTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: delayMs * 1_000_000) } catch { return }
            if Task.isCancelled { return }
            await self.applyDefaultAlias(modelId)
        }
    }

    func scheduleApplyNotificationSettingsDebounced(delayMs: UInt64 = 250) {
        notificationDebounceTask?.cancel()
        notificationDebounceTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: delayMs * 1_000_000) } catch { return }
            if Task.isCancelled { return }
            await self.applyNotificationSettings()
        }
    }

    // MARK: - Raw settings helpers
    func settingsFileURL() -> URL {
        SessionPreferencesStore.getRealUserHomeURL()
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    func reloadRawSettings() async {
        let url = settingsFileURL()
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        await MainActor.run { self.rawSettingsText = text }
    }

    func openSettingsInEditor() {
        Task { @MainActor in
            NSWorkspace.shared.open(self.settingsFileURL())
        }
    }
}

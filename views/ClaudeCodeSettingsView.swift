import SwiftUI
import AppKit
import Combine

struct ClaudeCodeSettingsView: View {
    @ObservedObject var vm: ClaudeCodeVM
    @ObservedObject var preferences: SessionPreferencesStore
    @StateObject private var providerCatalog = UnifiedProviderCatalogModel()
    @State private var providerModels: [String] = []
    @State private var showModelMappingEditor = false
    @State private var modelMappingProviderId: String?
    @State private var modelMappingDefault: String?
    @State private var modelMappingAliases: [String: String] = [:]
    @State private var lastProviderId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Claude Code Settings")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Configure provider, model aliases, and review launch environment.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Link(destination: URL(string: "https://docs.claude.com/en/docs/claude-code/settings")!) {
                    Label("Docs", systemImage: "questionmark.circle").labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
            }

            Group {
                if #available(macOS 15.0, *) {
                    TabView {
                        Tab("Provider", systemImage: "server.rack") { SettingsTabContent { providerPane } }
                        Tab("Runtime", systemImage: "gearshape.2") { SettingsTabContent { runtimePane } }
                        Tab("Notifications", systemImage: "bell") { SettingsTabContent { notificationsPane } }
                        Tab("Raw Config", systemImage: "doc.text") { SettingsTabContent { rawPane } }
                    }
                } else {
                    TabView {
                        SettingsTabContent { providerPane }
                            .tabItem { Label("Provider", systemImage: "server.rack") }
                        SettingsTabContent { runtimePane }
                            .tabItem { Label("Runtime", systemImage: "gearshape.2") }
                        SettingsTabContent { notificationsPane }
                            .tabItem { Label("Notifications", systemImage: "bell") }
                        SettingsTabContent { rawPane }
                            .tabItem { Label("Raw Config", systemImage: "doc.text") }
                    }
                }
            }
            .padding(.bottom, 16)
        }
        .task {
            await vm.loadAll()
            await vm.loadProxyDefaults(preferences: preferences)
            await reloadProxyCatalog()
        }
        .onChange(of: preferences.localServerReroute) { _ in
            Task { await reloadProxyCatalog() }
        }
        .onChange(of: preferences.localServerReroute3P) { _ in
            Task { await reloadProxyCatalog() }
        }
        .onChange(of: preferences.oauthProvidersEnabled) { _ in
            Task { await reloadProxyCatalog() }
        }
        .onChange(of: CLIProxyService.shared.isRunning) { _ in
            Task { await reloadProxyCatalog() }
        }
        .sheet(isPresented: $showModelMappingEditor) {
            ClaudeModelMappingSheet(
                availableModels: providerModels,
                defaultModel: modelMappingDefault,
                aliases: modelMappingAliases,
                onSave: { newDefault, newAliases in
                    saveModelMappings(defaultModel: newDefault, aliases: newAliases)
                },
                onAutoFill: { selectedDefault in
                    autoFillMappings(selectedDefault: selectedDefault)
                }
            )
        }
    }

    // MARK: - Provider
    private var providerPane: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
            GridRow {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Active Provider", systemImage: "server.rack")
                        .font(.subheadline).fontWeight(.medium)
                    Text("Choose an OAuth or API key provider via CLI Proxy API.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                UnifiedProviderPickerView(
                    sections: providerCatalog.sections,
                    models: providerModels,
                    modelSectionTitle: providerCatalog.sectionTitle(for: preferences.claudeProxyProviderId),
                    includeAuto: true,
                    autoTitle: "Auto (CLI built-in)",
                    includeDefaultModel: true,
                    defaultModelTitle: "(default)",
                    providerUnavailableHint: providerCatalog.availabilityHint(
                        for: preferences.claudeProxyProviderId),
                    disableModels: preferences.claudeProxyProviderId == nil
                        || !providerCatalog.isProviderAvailable(preferences.claudeProxyProviderId),
                    showModelPicker: false,
                    providerId: $preferences.claudeProxyProviderId,
                    modelId: $preferences.claudeProxyModelId
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
                .onChange(of: preferences.claudeProxyProviderId) { _ in
                    normalizeProxySelection()
                    if preferences.claudeProxyProviderId == nil {
                        Task { await reloadProxyCatalog(forceRefresh: true) }
                    }
                    vm.scheduleApplyProxySelectionDebounced(
                        providerId: preferences.claudeProxyProviderId,
                        modelId: preferences.claudeProxyModelId,
                        preferences: preferences
                    )
                }
                .onChange(of: preferences.claudeProxyModelId) { _ in
                    vm.scheduleApplyProxySelectionDebounced(
                        providerId: preferences.claudeProxyProviderId,
                        modelId: preferences.claudeProxyModelId,
                        preferences: preferences
                    )
                }
            }
            gridDivider
            GridRow {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Model List", systemImage: "list.bullet")
                        .font(.subheadline).fontWeight(.medium)
                    Text("Pick a default model and map Claude tiers to model IDs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                UnifiedProviderPickerView(
                    sections: providerCatalog.sections,
                    models: providerModels,
                    modelSectionTitle: providerCatalog.sectionTitle(for: preferences.claudeProxyProviderId),
                    includeAuto: false,
                    autoTitle: "Auto (CLI built-in)",
                    includeDefaultModel: true,
                    defaultModelTitle: "(default)",
                    providerUnavailableHint: nil,
                    disableModels: preferences.claudeProxyProviderId == nil
                        || !providerCatalog.isProviderAvailable(preferences.claudeProxyProviderId),
                    showProviderPicker: false,
                    onEditModels: canEditModelMappings ? { presentModelMappingEditor() } : nil,
                    editModelsHelp: "Edit model mappings",
                    providerId: $preferences.claudeProxyProviderId,
                    modelId: $preferences.claudeProxyModelId
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    // MARK: - Models / Aliases
    // modelsPane removed; Provider pane now includes the default model picker like Codex

    // MARK: - Raw Config (read-only; toolbar mirrors Codex)
    private var notificationsPane: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
            GridRow {
                VStack(alignment: .leading, spacing: 2) {
                    Label("macOS Notifications", systemImage: "bell")
                        .font(.subheadline).fontWeight(.medium)
                    Text("Forward Claude Code permission and completion hooks to macOS via codmate://notify.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("", isOn: $vm.notificationsEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .onChange(of: vm.notificationsEnabled) { _ in
                        vm.scheduleApplyNotificationSettingsDebounced()
                    }
            }
            gridDivider
            GridRow {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Hook Commands", systemImage: "link")
                        .font(.subheadline).fontWeight(.medium)
                    Text("/usr/bin/open -g codmate://notify?source=claude&event=permission&title64=…&body64=…")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("/usr/bin/open -g codmate://notify?source=claude&event=complete&title64=…&body64=…")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("Titles/bodies are base64-encoded to avoid shell escaping issues.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            gridDivider
            GridRow {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Self-test", systemImage: "checkmark.seal")
                        .font(.subheadline).fontWeight(.medium)
                    Text("Sends a codmate:// test URL to verify notification routing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    if vm.notificationBridgeHealthy {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    Button("Send Test") { Task { await vm.runNotificationSelfTest() } }
                        .controlSize(.small)
                    if let result = vm.notificationSelfTestResult {
                        Text(result).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var rawPane: some View {
        let displayText = vm.rawSettingsText
        
        return ZStack(alignment: .topTrailing) {
            ScrollView {
                Text(displayText.isEmpty ? "(empty settings.json)" : displayText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            HStack(spacing: 8) {
                Button { Task { await vm.reloadRawSettings() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reload")
                .buttonStyle(.borderless)
                Button { vm.openSettingsInEditor() } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help("Open in default editor")
                .buttonStyle(.borderless)
            }
        }
        .task { await vm.reloadRawSettings() }
    }
    
    private func buildRawConfigText() -> String {
        // Prefer showing the canonical user settings file in full
        let settingsURL = SessionPreferencesStore.getRealUserHomeURL()
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")
        
        if let fileText = try? String(contentsOf: settingsURL, encoding: .utf8) {
            return fileText
        }
        
        // Fallback: build preview from current settings
        var lines = vm.launchEnvPreview()
        
        // Append launch/runtime flags preview
        lines.append("\n# Launch flags preview")
        lines.append("permission-mode=\(preferences.claudePermissionMode.rawValue)")
        lines.append("sandbox=\(preferences.defaultResumeSandboxMode.rawValue)")
        lines.append("approvals=\(preferences.defaultResumeApprovalPolicy.rawValue)")
        
        // Debug info
        if preferences.claudeDebug {
            lines.append("debug=true filter=\(preferences.claudeDebugFilter)")
        } else {
            lines.append("debug=false")
        }
        
        lines.append("verbose=\(preferences.claudeVerbose ? "true" : "false")")
        lines.append("ide=\(preferences.claudeIDE ? "true" : "false")")
        lines.append("strictMCP=\(preferences.claudeStrictMCP ? "true" : "false")")
        
        // Tools configuration
        let allowedTools = preferences.claudeAllowedTools.trimmingCharacters(in: .whitespaces)
        if !allowedTools.isEmpty {
            lines.append("allowed-tools=\(allowedTools)")
        }
        
        let disallowedTools = preferences.claudeDisallowedTools.trimmingCharacters(in: .whitespaces)
        if !disallowedTools.isEmpty {
            lines.append("disallowed-tools=\(disallowedTools)")
        }
        
        let fallbackModel = preferences.claudeFallbackModel.trimmingCharacters(in: .whitespaces)
        if !fallbackModel.isEmpty {
            lines.append("fallback-model=\(fallbackModel)")
        }
        
        // Build example command
        let exampleCommand = buildExampleCommand()
        lines.append("\n# Example command")
        lines.append(exampleCommand)
        
        return lines.joined(separator: "\n")
    }
    
    private func buildExampleCommand() -> String {
        var example: [String] = ["claude"]
        
        // Permission mode
        if preferences.claudePermissionMode.rawValue != "default" {
            example.append("--permission-mode \(preferences.claudePermissionMode.rawValue)")
        }
        
        // Debug/Verbose
        if preferences.claudeDebug {
            let debugFilter = preferences.claudeDebugFilter.trimmingCharacters(in: .whitespaces)
            if !debugFilter.isEmpty {
                example.append("--debug \(debugFilter)")
            } else {
                example.append("--debug")
            }
        }
        
        if preferences.claudeVerbose {
            example.append("--verbose")
        }
        
        // Tools
        let allowedTools = preferences.claudeAllowedTools.trimmingCharacters(in: .whitespaces)
        if !allowedTools.isEmpty {
            example.append("--allowed-tools \"\(allowedTools)\"")
        }
        
        let disallowedTools = preferences.claudeDisallowedTools.trimmingCharacters(in: .whitespaces)
        if !disallowedTools.isEmpty {
            example.append("--disallowed-tools \"\(disallowedTools)\"")
        }
        
        // IDE
        if preferences.claudeIDE {
            example.append("--ide")
        }
        
        // Fallback model
        let fallbackModel = preferences.claudeFallbackModel.trimmingCharacters(in: .whitespaces)
        if !fallbackModel.isEmpty {
            example.append("--fallback-model \(fallbackModel)")
        }
        
        return example.joined(separator: " ")
    }

    // MARK: - Runtime (Claude-native)
    private var runtimePane: some View {
        runtimePaneGrid
            .onReceive(preferences.objectWillChange) { _ in
                Task { vm.scheduleApplyRuntimeSettings(preferences) }
            }
    }
    
    private var runtimePaneGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
            // Claude-native permission mode
            GridRow {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Permission Mode", systemImage: "hand.raised")
                        .font(.subheadline).fontWeight(.medium)
                    Text("Affects edit confirmations and planning.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Picker("", selection: $preferences.claudePermissionMode) {
                    ForEach(ClaudePermissionMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            gridDivider
            // Dangerous permission skips (explicit)
            GridRow {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Skip Permissions (Dangerous)", systemImage: "exclamationmark.triangle")
                        .font(.subheadline).fontWeight(.medium)
                    Text("Bypass permission prompts; use with caution.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Enable", isOn: $preferences.claudeSkipPermissions)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            gridDivider
            GridRow {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Allow Skip Permissions", systemImage: "checkmark.shield")
                        .font(.subheadline).fontWeight(.medium)
                    Text("Permit using the dangerous skip flag.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Enable", isOn: $preferences.claudeAllowSkipPermissions)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            // Removed: Unsandboxed commands toggle (no official CLI/setting key)
            gridDivider
            GridRow {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Debug", systemImage: "ladybug")
                        .font(.subheadline).fontWeight(.medium)
                    Text("Enable debug output; optional category filter.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Toggle("Enable", isOn: $preferences.claudeDebug)
                    TextField("api,hooks", text: $preferences.claudeDebugFilter)
                        .frame(width: 220)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            gridDivider
            GridRow {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Verbose Output", systemImage: "text.alignleft")
                        .font(.subheadline).fontWeight(.medium)
                    Text("Override verbose mode from config.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Enable", isOn: $preferences.claudeVerbose)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            gridDivider
            GridRow {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Allowed Tools", systemImage: "checkmark.circle")
                        .font(.subheadline).fontWeight(.medium)
                    Text("Comma or space-separated tool names.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                TextField("Bash(git:*), Edit", text: $preferences.claudeAllowedTools)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            gridDivider
            GridRow {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Disallowed Tools", systemImage: "xmark.circle")
                        .font(.subheadline).fontWeight(.medium)
                    Text("Comma or space-separated tool names to block.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                TextField("Bash(rm:*), Edit", text: $preferences.claudeDisallowedTools)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            gridDivider
            GridRow {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Other", systemImage: "ellipsis.circle")
                        .font(.subheadline).fontWeight(.medium)
                    Text("Additional runtime options.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 16) {
                    Toggle("IDE auto-connect", isOn: $preferences.claudeIDE)
                    Toggle("Strict MCP config", isOn: $preferences.claudeStrictMCP)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            gridDivider
            GridRow {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Fallback Model", systemImage: "arrow.down.circle")
                        .font(.subheadline).fontWeight(.medium)
                    Text("Optional model when default is overloaded (print mode).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                TextField("haiku", text: $preferences.claudeFallbackModel)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private func reloadProxyCatalog(forceRefresh: Bool = false) async {
        await providerCatalog.reload(preferences: preferences, forceRefresh: forceRefresh)
        normalizeProxySelection()
    }

    private func normalizeProxySelection() {
        let normalized = providerCatalog.normalizeProviderId(preferences.claudeProxyProviderId)
        if normalized != preferences.claudeProxyProviderId {
            preferences.claudeProxyProviderId = normalized
        }
        let providerChanged = lastProviderId != nil && lastProviderId != preferences.claudeProxyProviderId
        lastProviderId = preferences.claudeProxyProviderId
        guard let providerId = preferences.claudeProxyProviderId else {
            providerModels = []
            preferences.claudeProxyModelId = nil
            return
        }
        providerModels = providerCatalog.models(for: providerId)
        if providerChanged {
            preferences.claudeProxyModelId = nil
            return
        }
        guard !providerModels.isEmpty else {
            return
        }
    }

    private var canEditModelMappings: Bool {
        preferences.claudeProxyProviderId != nil
    }

    private func presentModelMappingEditor() {
        guard let providerId = preferences.claudeProxyProviderId else { return }
        modelMappingProviderId = providerId
        modelMappingDefault = preferences.claudeProxyModelId
        modelMappingAliases = preferences.claudeProxyModelAliases[providerId] ?? [:]
        showModelMappingEditor = true
    }

    private func saveModelMappings(defaultModel: String?, aliases: [String: String]) {
        guard let providerId = modelMappingProviderId else { return }
        preferences.claudeProxyModelId = defaultModel
        var stored = preferences.claudeProxyModelAliases
        if aliases.isEmpty {
            stored.removeValue(forKey: providerId)
        } else {
            stored[providerId] = aliases
        }
        preferences.claudeProxyModelAliases = stored
        vm.scheduleApplyProxySelectionDebounced(
            providerId: preferences.claudeProxyProviderId,
            modelId: preferences.claudeProxyModelId,
            preferences: preferences
        )
    }

    private func autoFillMappings(selectedDefault: String?) -> [String: String] {
        let models = providerModels
        let trimmedDefault = selectedDefault?.trimmingCharacters(in: .whitespacesAndNewlines)
        let preferred = (trimmedDefault?.isEmpty == false) ? trimmedDefault : selectDefaultModel(from: models)
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

    // aliasPicker removed
}

private struct SettingsCard<Content: View>: View {
    let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(10)
            .background(Color(nsColor: .separatorColor).opacity(0.35))
            .cornerRadius(10)
    }
}

private func settingsCard<Content: View>(@ViewBuilder _ content: @escaping () -> Content) -> some View {
    SettingsCard(content: content)
}

private var gridDivider: some View { Divider().opacity(0.5) }

// MARK: - Runtime Settings Change Handler
// Removed complex onChange modifier due to type-checker performance; using a single
// onReceive(preferences.objectWillChange) above to debounce runtime writes.

extension ClaudeCodeVM {
    var selectedClaudeBaseURL: String? {
        guard let id = activeProviderId,
              let p = providers.first(where: { $0.id == id }) else { return nil }
        return p.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue]?.baseURL
    }
    var selectedClaudeEnvKey: String? {
        guard let id = activeProviderId,
              let p = providers.first(where: { $0.id == id }) else { return nil }
        return p.envKey ?? p.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue]?.envKey ?? "ANTHROPIC_AUTH_TOKEN"
    }

    func launchEnvPreview() -> [String] {
        var lines: [String] = [
            "# Environment variables applied when launching Claude",
        ]
        if let base = selectedClaudeBaseURL, !base.isEmpty {
            lines.append("export ANTHROPIC_BASE_URL=\(base)")
        } else {
            lines.append("# ANTHROPIC_BASE_URL not set (uses tool default)")
        }
        if !(activeProviderId == nil && loginMethod == .subscription) {
            let key = selectedClaudeEnvKey ?? "ANTHROPIC_AUTH_TOKEN"
            lines.append("export ANTHROPIC_AUTH_TOKEN=$\(key)")
        } else {
            lines.append("# Using Claude subscription login; no token env injected")
        }
        // Aliases (only when a third‑party provider is selected)
        if activeProviderId != nil {
            if !aliasOpus.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append("export ANTHROPIC_DEFAULT_OPUS_MODEL=\(aliasOpus)")
            }
            if !aliasSonnet.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append("export ANTHROPIC_DEFAULT_SONNET_MODEL=\(aliasSonnet)")
            }
            if !aliasHaiku.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append("export ANTHROPIC_DEFAULT_HAIKU_MODEL=\(aliasHaiku)")
            }
            if !aliasDefault.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append("export ANTHROPIC_MODEL=\(aliasDefault)")
            }
            if !aliasHaiku.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append("export ANTHROPIC_SMALL_FAST_MODEL=\(aliasHaiku)")
            }
        }
        return lines
    }
}

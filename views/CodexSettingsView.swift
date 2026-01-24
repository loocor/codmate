import SwiftUI

struct CodexSettingsView: View {
    @ObservedObject var codexVM: CodexVM
    @ObservedObject var preferences: SessionPreferencesStore
    @FocusState private var isEnvSetPairsFocused: Bool
    @State private var envSetPairsLastValue = ""
    @StateObject private var providerCatalog = UnifiedProviderCatalogModel()
    @State private var providerModels: [String] = []
    @State private var lastProviderId: String?
    @State private var showDisableBlockedAlert = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header for visual consistency with other settings pages
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Codex Settings")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text(
                        "Configure Codex CLI: providers, runtime defaults, features, and privacy."
                    )
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                }
                Spacer(minLength: 8)
                Link(
                    destination: URL(string: "https://developers.openai.com/codex/cli")!
                ) {
                    Label("Docs", systemImage: "questionmark.circle")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
            }

            GroupBox {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Enable Codex CLI", systemImage: "power")
                            .font(.subheadline).fontWeight(.medium)
                        Text("Turning this off hides Codex UI, stops session scans, and makes settings read-only.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: codexEnabledBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                .padding(10)
            }
            // Tabs (Remote Hosts is a top-level page, not a Codex sub-tab)
            Group {
                if #available(macOS 15.0, *) {
                    TabView {
                        Tab("Provider", systemImage: "server.rack") { providerPane }
                        Tab("Runtime", systemImage: "gearshape.2") { runtimePane }
                        Tab("Sessions", systemImage: "folder.badge.gearshape") { sessionsPane }
                        Tab("Features", systemImage: "wand.and.stars") { featuresPane }
                        Tab("Privacy", systemImage: "lock.shield") { privacyPane }
                        Tab("Raw Config", systemImage: "doc.text") { rawConfigPane }
                    }
                } else {
                    TabView {
                        providerPane
                            .tabItem { Label("Provider", systemImage: "server.rack") }
                        runtimePane
                            .tabItem { Label("Runtime", systemImage: "gearshape.2") }
                        sessionsPane
                            .tabItem { Label("Sessions", systemImage: "folder.badge.gearshape") }
                        featuresPane
                            .tabItem { Label("Features", systemImage: "wand.and.stars") }
                        privacyPane
                            .tabItem { Label("Privacy", systemImage: "lock.shield") }
                        rawConfigPane
                            .tabItem { Label("Raw Config", systemImage: "doc.text") }
                    }
                }
            }
            .controlSize(.regular)
            .padding(.bottom, 16)
            .disabled(!preferences.cliCodexEnabled)
            .opacity(preferences.cliCodexEnabled ? 1.0 : 0.6)
        }
        .alert("At least one CLI must remain enabled.", isPresented: $showDisableBlockedAlert) {
            Button("OK", role: .cancel) {}
        }
    }

    private var codexEnabledBinding: Binding<Bool> {
        Binding(
            get: { preferences.cliCodexEnabled },
            set: { newValue in
                if preferences.setCLIEnabled(.codex, enabled: newValue) == false {
                    showDisableBlockedAlert = true
                }
            }
        )
    }

    // MARK: - Provider Pane
    private var providerPane: some View {
        let content = providerPaneContent
        return SettingsTabContent {
            content
        }
        .task {
            await codexVM.loadProxyDefaults(preferences: preferences)
            await reloadProxyCatalog()
        }
        // Removed rerouteBuiltIn/reroute3P onChange handlers - all providers now use Auto-Proxy mode
        .onChange(of: preferences.oauthProvidersEnabled) { _ in
            Task { await reloadProxyCatalog() }
        }
        .onChange(of: preferences.apiKeyProvidersEnabled) { _ in
            Task { await reloadProxyCatalog() }
        }
        .onChange(of: CLIProxyService.shared.isRunning) { _ in
            Task { await reloadProxyCatalog() }
        }
    }

    private var providerPaneContent: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
            GridRow {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Active Provider", systemImage: "server.rack")
                        .font(.subheadline).fontWeight(.medium)
                    Text("Use built-in provider or route through CLI Proxy API.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SimpleProviderPicker(providerId: $preferences.codexProxyProviderId)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .onChange(of: preferences.codexProxyProviderId) { _ in
                        normalizeProxySelection()
                        if preferences.codexProxyProviderId == nil {
                            Task { await reloadProxyCatalog(forceRefresh: true) }
                        }
                        codexVM.scheduleApplyProxySelectionDebounced(
                            providerId: preferences.codexProxyProviderId,
                            modelId: preferences.codexProxyModelId,
                            preferences: preferences
                        )
                    }
            }
            gridDivider
            GridRow {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Model List", systemImage: "list.bullet")
                        .font(.subheadline).fontWeight(.medium)
                    Text("Select a default model from the available models.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SimpleModelPicker(
                    models: providerModels,
                    isDisabled: preferences.codexProxyProviderId == nil
                        || !providerCatalog.isProviderAvailable(preferences.codexProxyProviderId),
                    providerId: preferences.codexProxyProviderId,
                    providerCatalog: providerCatalog,
                    modelId: $preferences.codexProxyModelId
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
                .onChange(of: preferences.codexProxyModelId) { _ in
                    codexVM.scheduleApplyProxySelectionDebounced(
                        providerId: preferences.codexProxyProviderId,
                        modelId: preferences.codexProxyModelId,
                        preferences: preferences
                    )
                }
            }
            // Base URL and API Key Env rows are hidden to reduce redundancy
        }
    }

    // MARK: - Runtime Pane
    private var runtimePane: some View {
        SettingsTabContent {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                        GridRow {
                            VStack(alignment: .leading, spacing: 2) {
                                Label("Reasoning Effort", systemImage: "brain")
                                    .font(.subheadline).fontWeight(.medium)
                                Text("Controls depth of reasoning for supported models.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Picker("", selection: $codexVM.reasoningEffort) {
                                ForEach(CodexVM.ReasoningEffort.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .labelsHidden()
                            .onChange(of: codexVM.reasoningEffort) { _ in codexVM.scheduleApplyReasoningDebounced() }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        gridDivider
                        GridRow {
                            VStack(alignment: .leading, spacing: 2) {
                                Label("Reasoning Summary", systemImage: "text.bubble")
                                    .font(.subheadline).fontWeight(.medium)
                                Text("Summary verbosity for reasoning-capable models.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Picker("", selection: $codexVM.reasoningSummary) {
                                ForEach(CodexVM.ReasoningSummary.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .labelsHidden()
                            .onChange(of: codexVM.reasoningSummary) { _ in codexVM.scheduleApplyReasoningDebounced() }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        gridDivider
                        GridRow {
                            VStack(alignment: .leading, spacing: 2) {
                                Label("Verbosity", systemImage: "text.alignleft")
                                    .font(.subheadline).fontWeight(.medium)
                                Text("Text output verbosity for GPT‑5 family (Responses API).")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Picker("", selection: $codexVM.modelVerbosity) {
                                ForEach(CodexVM.ModelVerbosity.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .labelsHidden()
                            .onChange(of: codexVM.modelVerbosity) { _ in codexVM.scheduleApplyReasoningDebounced() }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        gridDivider
                        GridRow {
                            VStack(alignment: .leading, spacing: 2) {
                                Label("Sandbox", systemImage: "lock.shield")
                                    .font(.subheadline).fontWeight(.medium)
                                Text("Default sandbox for sessions launched from CodMate only.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Picker("", selection: $codexVM.sandboxMode) {
                                ForEach(SandboxMode.allCases) { Text($0.title).tag($0) }
                            }
                            .labelsHidden()
                            .onChange(of: codexVM.sandboxMode) { newValue in
                                codexVM.scheduleApplySandboxDebounced()
                                preferences.defaultResumeSandboxMode = newValue
                            }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        gridDivider
                        GridRow {
                            VStack(alignment: .leading, spacing: 2) {
                                Label("Approval Policy", systemImage: "hand.raised")
                                    .font(.subheadline).fontWeight(.medium)
                                Text("Default approval prompts for sessions launched from CodMate only.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Picker("", selection: $codexVM.approvalPolicy) {
                                ForEach(ApprovalPolicy.allCases) { Text($0.title).tag($0) }
                            }
                            .labelsHidden()
                            .onChange(of: codexVM.approvalPolicy) { newValue in
                                codexVM.scheduleApplyApprovalDebounced()
                                preferences.defaultResumeApprovalPolicy = newValue
                            }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        gridDivider
                        GridRow {
                            VStack(alignment: .leading, spacing: 2) {
                                Label("Auto-assign new sessions to same project", systemImage: "folder.badge.plus")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Text(
                                    "When starting New from detail, auto-assign the created session to that project."
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            }
                                Toggle("", isOn: $preferences.autoAssignNewToSameProject)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
        }
    }

    // MARK: - Sessions Pane
    private var sessionsPane: some View {
        SettingsTabContent {
            SessionsPathPane(preferences: preferences, fixedKind: .codex)
        }
    }

    // MARK: - Features Pane
    private var featuresPane: some View {
        SettingsTabContent {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Feature Flags", systemImage: "wand.and.stars")
                            .font(.subheadline).fontWeight(.medium)
                        Text("Inspect codex CLI features and override individual flags.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 8) {
                        Button {
                            Task { await codexVM.loadFeatures() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .controlSize(.small)
                        .disabled(codexVM.featuresLoading)
                        if codexVM.featuresLoading {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                if let err = codexVM.featureError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
                if codexVM.featureFlags.isEmpty {
                    Text(codexVM.featuresLoading ? "Loading features…" : "No features reported by codex CLI.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    let stageWidth: CGFloat = 120
                    let overrideWidth: CGFloat = 180
                    let flags = codexVM.featureFlags
                    VStack(spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Feature")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("Stage")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: stageWidth, alignment: .leading)
                            Text("Override")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: overrideWidth, alignment: .trailing)
                        }
                        Divider()
                        ForEach(Array(flags.enumerated()), id: \.element.id) { index, feature in
                            HStack(alignment: .center, spacing: 12) {
                                Text(feature.name)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Text(feature.stage.capitalized)
                                    .font(.subheadline)
                                    .frame(width: stageWidth, alignment: .leading)
                                Toggle("", isOn: overrideToggleBinding(for: feature))
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                                    .frame(width: overrideWidth, alignment: .trailing)
                                    .disabled(codexVM.featuresLoading)
                            }
                            if index < flags.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Privacy Pane
    private var privacyPane: some View {
        SettingsTabContent {
            VStack(alignment: .leading, spacing: 16) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                    GridRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Inherit", systemImage: "arrow.down.circle")
                                .font(.subheadline).fontWeight(.medium)
                            Text("Start from full, core, or empty environment.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Picker("", selection: $codexVM.envInherit) {
                            ForEach(["all", "core", "none"], id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    gridDivider
                    GridRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Ignore default excludes", systemImage: "eye.slash")
                                .font(.subheadline).fontWeight(.medium)
                            Text("Keep vars containing KEY/SECRET/TOKEN unless unchecked.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Toggle("", isOn: $codexVM.envIgnoreDefaults)
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    gridDivider
                    GridRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Include Only", systemImage: "checklist")
                                .font(.subheadline).fontWeight(.medium)
                            Text("Whitelist patterns (comma separated). Example: PATH, HOME")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        TextField("PATH, HOME", text: $codexVM.envIncludeOnly)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    gridDivider
                    GridRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Exclude", systemImage: "xmark.circle")
                                .font(.subheadline).fontWeight(.medium)
                            Text("Blacklist patterns (comma separated). Example: AWS_*, AZURE_*")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        TextField("AWS_*, AZURE_*", text: $codexVM.envExclude)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    gridDivider
                    GridRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Set Variables", systemImage: "key")
                                .font(.subheadline).fontWeight(.medium)
                            Text("KEY=VALUE per line. These override inherited values.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ZStack(alignment: .bottomTrailing) {
                            TextEditor(text: $codexVM.envSetPairs)
                                .font(.system(.body, design: .monospaced))
                                .frame(minHeight: 90)
                                .focused($isEnvSetPairsFocused)
                            if isEnvSetPairsFocused {
                                HStack(spacing: 8) {
                                    if codexVM.lastError != nil {
                                        Text(codexVM.lastError!)
                                            .foregroundStyle(.red)
                                            .font(.caption)
                                    }
                                    Button("Save Environment Policy") {
                                        envSetPairsLastValue = codexVM.envSetPairs
                                        isEnvSetPairsFocused = false
                                        Task { await codexVM.applyEnvPolicy() }
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.primary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .onAppear {
                            envSetPairsLastValue = codexVM.envSetPairs
                        }
                    }
                }

                Divider()

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                    GridRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Hide Agent Reasoning", systemImage: "eye.slash")
                                .font(.subheadline).fontWeight(.medium)
                            Text("Suppress reasoning events in TUI and exec outputs.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Toggle("", isOn: $codexVM.hideAgentReasoning)
                            .labelsHidden()
                            .onChange(of: codexVM.hideAgentReasoning) { _ in codexVM.scheduleApplyHideReasoningDebounced() }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    gridDivider
                    GridRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Show Raw Reasoning", systemImage: "eye")
                                .font(.subheadline).fontWeight(.medium)
                            Text(
                                "Expose raw chain-of-thought when provider supports it (use with caution)."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        Toggle("", isOn: $codexVM.showRawAgentReasoning)
                            .labelsHidden()
                            .onChange(of: codexVM.showRawAgentReasoning) { _ in codexVM.scheduleApplyShowRawReasoningDebounced() }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: - Raw Config Pane
    private var rawConfigPane: some View {
        SettingsTabContent {
            ZStack(alignment: .topTrailing) {
                ScrollView {
                    Text(
                        codexVM.rawConfigText.isEmpty
                            ? "(empty config.toml)" : codexVM.rawConfigText
                    )
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                HStack(spacing: 8) {
                    Button {
                        Task { await codexVM.reloadRawConfig() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Reload")
                    .buttonStyle(.borderless)
                    Button {
                        codexVM.openConfigInEditor()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .help("Open in default editor")
                    .buttonStyle(.borderless)
                }
            }
            .task { await codexVM.reloadRawConfig() }
        }
    }

    // MARK: - Helper Views

    // codexTabContent has been replaced by the shared SettingsTabContent component

    private func reloadProxyCatalog(forceRefresh: Bool = false) async {
        await providerCatalog.reload(preferences: preferences, forceRefresh: forceRefresh)
        normalizeProxySelection()
    }

    private func normalizeProxySelection() {
        let normalized = providerCatalog.normalizeProviderId(preferences.codexProxyProviderId)
        if normalized != preferences.codexProxyProviderId {
            preferences.codexProxyProviderId = normalized
        }
        let providerChanged = lastProviderId != nil && lastProviderId != preferences.codexProxyProviderId
        lastProviderId = preferences.codexProxyProviderId
        guard let providerId = preferences.codexProxyProviderId else {
            providerModels = []
            preferences.codexProxyModelId = nil
            return
        }
        providerModels = providerCatalog.models(for: providerId)
        if providerChanged {
            preferences.codexProxyModelId = nil
            return
        }
        guard !providerModels.isEmpty else {
            return
        }
    }

    @ViewBuilder
    private var gridDivider: some View {
        Divider()
    }

    private func overrideToggleBinding(for feature: CodexVM.FeatureFlag) -> Binding<Bool> {
        Binding(
            get: {
                guard let live = codexVM.featureFlags.first(where: { $0.id == feature.id }) else {
                    return feature.defaultEnabled
                }
                switch live.overrideState {
                case .inherit: return live.defaultEnabled
                case .forceOn: return true
                case .forceOff: return false
                }
            },
            set: { newValue in
                guard let live = codexVM.featureFlags.first(where: { $0.id == feature.id }) else {
                    codexVM.setFeatureOverride(
                        name: feature.name,
                        state: newValue == feature.defaultEnabled ? .inherit : (newValue ? .forceOn : .forceOff)
                    )
                    return
                }
                let desired: CodexVM.FeatureOverrideState
                if newValue == live.defaultEnabled {
                    desired = .inherit
                } else {
                    desired = newValue ? .forceOn : .forceOff
                }
                codexVM.setFeatureOverride(name: live.name, state: desired)
            }
        )
    }
}

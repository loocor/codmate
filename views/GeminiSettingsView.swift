import SwiftUI

struct GeminiSettingsView: View {
  @ObservedObject var vm: GeminiVM
  @ObservedObject var preferences: SessionPreferencesStore
  @StateObject private var providerCatalog = UnifiedProviderCatalogModel()
  @State private var providerModels: [String] = []
  @State private var showModelEditor = false
  @State private var modelEditorProviderId: String?
  @State private var modelEditorModels: [String] = []
  @State private var modelEditorAutoModels: [String] = []
  @State private var lastProviderId: String?

  private let docsURL = URL(string: "https://geminicli.com/docs/cli/settings/")!

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      Group {
        if #available(macOS 15.0, *) {
          TabView {
            Tab("Provider", systemImage: "server.rack") { providerTab }
            Tab("General", systemImage: "gearshape") { generalTab }
            Tab("Runtime", systemImage: "gauge") { runtimeTab }
            Tab("Model", systemImage: "cpu") { modelTab }
            Tab("Notifications", systemImage: "bell") { notificationsTab }
            Tab("Raw Config", systemImage: "doc.text") { rawTab }
          }
        } else {
          TabView {
            providerTab
              .tabItem { Label("Provider", systemImage: "server.rack") }
            generalTab
              .tabItem { Label("General", systemImage: "gearshape") }
            runtimeTab
              .tabItem { Label("Runtime", systemImage: "gauge") }
            modelTab
              .tabItem { Label("Model", systemImage: "cpu") }
            notificationsTab
              .tabItem { Label("Notifications", systemImage: "bell") }
            rawTab
              .tabItem { Label("Raw Config", systemImage: "doc.text") }
          }
        }
      }
      .controlSize(.regular)
    }
    .padding(.bottom, 16)
    .task {
      await vm.loadIfNeeded()
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
    .sheet(isPresented: $showModelEditor) {
      ModelListEditorSheet(
        title: "Gemini Provider Models",
        description: "Choose which models appear for this provider. Leave empty to fall back to the default list.",
        availableModels: modelEditorAutoModels,
        models: modelEditorModels,
        onSave: { saveModelOverrides($0) },
        onReset: { clearModelOverrides() }
      )
    }
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Gemini CLI Settings")
          .font(.title2)
          .fontWeight(.bold)
        Text("Configure Gemini CLI defaults: features, models, and raw settings.json.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Link(destination: docsURL) {
        Label("Docs", systemImage: "questionmark.circle")
          .labelStyle(.iconOnly)
      }
      .buttonStyle(.plain)
    }
  }

  private func reloadProxyCatalog(forceRefresh: Bool = false) async {
    await providerCatalog.reload(preferences: preferences, forceRefresh: forceRefresh)
    normalizeProxySelection()
  }

  private func normalizeProxySelection() {
    let normalized = providerCatalog.normalizeProviderId(preferences.geminiProxyProviderId)
    if normalized != preferences.geminiProxyProviderId {
      preferences.geminiProxyProviderId = normalized
    }
    let providerChanged = lastProviderId != nil && lastProviderId != preferences.geminiProxyProviderId
    lastProviderId = preferences.geminiProxyProviderId
    guard let providerId = preferences.geminiProxyProviderId else {
      providerModels = []
      preferences.geminiProxyModelId = nil
      return
    }
    let autoModels = providerCatalog.models(for: providerId)
    if let override = preferences.geminiProxyModelOverrides[providerId], !override.isEmpty {
      providerModels = override
    } else {
      providerModels = autoModels
    }
    if providerChanged {
      preferences.geminiProxyModelId = nil
      return
    }
    guard !providerModels.isEmpty else {
      return
    }
  }

  private var canEditModels: Bool {
    preferences.geminiProxyProviderId != nil
  }

  private func presentModelEditor() {
    guard let providerId = preferences.geminiProxyProviderId else { return }
    modelEditorProviderId = providerId
    modelEditorAutoModels = providerCatalog.models(for: providerId)
    if let override = preferences.geminiProxyModelOverrides[providerId], !override.isEmpty {
      modelEditorModels = override
    } else {
      modelEditorModels = modelEditorAutoModels
    }
    showModelEditor = true
  }

  private func saveModelOverrides(_ models: [String]) {
    guard let providerId = modelEditorProviderId else { return }
    var overrides = preferences.geminiProxyModelOverrides
    if models.isEmpty {
      overrides.removeValue(forKey: providerId)
    } else {
      overrides[providerId] = models
    }
    preferences.geminiProxyModelOverrides = overrides
    normalizeProxySelection()
  }

  private func clearModelOverrides() {
    guard let providerId = modelEditorProviderId else { return }
    var overrides = preferences.geminiProxyModelOverrides
    overrides.removeValue(forKey: providerId)
    preferences.geminiProxyModelOverrides = overrides
    normalizeProxySelection()
  }

  private var generalTab: some View {
    SettingsTabContent {
      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
        GridRow {
          VStack(alignment: .leading, spacing: 2) {
            Label("Preview Features", systemImage: "wand.and.stars")
              .font(.subheadline).fontWeight(.medium)
            Text("Enable experimental features like preview models.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Toggle("", isOn: $vm.previewFeatures)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .onChange(of: vm.previewFeatures) { _ in vm.applyPreviewFeaturesChange() }
        }
        dividerRow
        GridRow {
          VStack(alignment: .leading, spacing: 2) {
            Label("Prompt Completion", systemImage: "text.cursor")
              .font(.subheadline).fontWeight(.medium)
            Text("Show inline command suggestions while typing.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Toggle("", isOn: $vm.enablePromptCompletion)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .onChange(of: vm.enablePromptCompletion) { _ in vm.applyPromptCompletionChange() }
        }
        dividerRow
        GridRow {
          VStack(alignment: .leading, spacing: 2) {
            Label("Vim Mode", systemImage: "keyboard")
              .font(.subheadline).fontWeight(.medium)
            Text("Use Vim keybindings inside Gemini CLI.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Toggle("", isOn: $vm.vimMode)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .onChange(of: vm.vimMode) { _ in vm.applyVimModeChange() }
        }
        dividerRow
        GridRow {
          VStack(alignment: .leading, spacing: 2) {
            Label("Disable Auto Update", systemImage: "stop.circle")
              .font(.subheadline).fontWeight(.medium)
            Text("Prevent Gemini CLI from auto-updating itself.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Toggle("", isOn: $vm.disableAutoUpdate)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .onChange(of: vm.disableAutoUpdate) { _ in vm.applyDisableAutoUpdateChange() }
        }
        dividerRow
        GridRow {
          VStack(alignment: .leading, spacing: 2) {
            Label("Session Retention", systemImage: "trash")
              .font(.subheadline).fontWeight(.medium)
            Text("Automatically clean up old sessions when enabled.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Toggle("", isOn: $vm.sessionRetentionEnabled)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .onChange(of: vm.sessionRetentionEnabled) { _ in vm.applySessionRetentionChange() }
        }
        if let error = vm.lastError {
          dividerRow
          GridRow {
            Text("")
            Text(error)
              .font(.caption)
              .foregroundStyle(.red)
              .frame(maxWidth: .infinity, alignment: .trailing)
          }
        }
      }
    }
  }

  private var providerTab: some View {
    SettingsTabContent {
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
            modelSectionTitle: providerCatalog.sectionTitle(for: preferences.geminiProxyProviderId),
            includeAuto: true,
            autoTitle: "Auto (CLI built-in)",
            includeDefaultModel: true,
            defaultModelTitle: "(default)",
            providerUnavailableHint: providerCatalog.availabilityHint(
              for: preferences.geminiProxyProviderId),
            disableModels: preferences.geminiProxyProviderId == nil
              || !providerCatalog.isProviderAvailable(preferences.geminiProxyProviderId),
            showModelPicker: false,
            providerId: $preferences.geminiProxyProviderId,
            modelId: $preferences.geminiProxyModelId
          )
          .frame(maxWidth: .infinity, alignment: .trailing)
          .onChange(of: preferences.geminiProxyProviderId) { _ in
            normalizeProxySelection()
            if preferences.geminiProxyProviderId == nil {
              Task { await reloadProxyCatalog(forceRefresh: true) }
            }
          }
          .onChange(of: preferences.geminiProxyModelId) { _ in
            // Stored for future use; Gemini CLI model selection stays in Model tab.
          }
        }
        dividerRow
        GridRow {
          VStack(alignment: .leading, spacing: 2) {
            Label("Model List", systemImage: "list.bullet")
              .font(.subheadline).fontWeight(.medium)
            Text("Pick a default model and manage the provider’s model list.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          UnifiedProviderPickerView(
            sections: providerCatalog.sections,
            models: providerModels,
            modelSectionTitle: providerCatalog.sectionTitle(for: preferences.geminiProxyProviderId),
            includeAuto: false,
            autoTitle: "Auto (CLI built-in)",
            includeDefaultModel: true,
            defaultModelTitle: "(default)",
            providerUnavailableHint: nil,
            disableModels: preferences.geminiProxyProviderId == nil
              || !providerCatalog.isProviderAvailable(preferences.geminiProxyProviderId),
            showProviderPicker: false,
            onEditModels: canEditModels ? { presentModelEditor() } : nil,
            editModelsHelp: "Edit model list",
            providerId: $preferences.geminiProxyProviderId,
            modelId: $preferences.geminiProxyModelId
          )
          .frame(maxWidth: .infinity, alignment: .trailing)
        }
        GridRow {
          Text("")
          Text("Gemini CLI model selection stays in the Model tab.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
      }
    }
  }

  private var runtimeTab: some View {
    SettingsTabContent {
      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
        GridRow {
          VStack(alignment: .leading, spacing: 2) {
            Label("Sandbox Mode", systemImage: "lock.shield")
              .font(.subheadline).fontWeight(.medium)
            Text("Controls Gemini CLI sandbox defaults for new sessions.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Picker("", selection: $preferences.defaultResumeSandboxMode) {
            ForEach(SandboxMode.allCases) { Text($0.title).tag($0) }
          }
          .labelsHidden()
          .frame(maxWidth: .infinity, alignment: .trailing)
        }
        dividerRow
        GridRow {
          VStack(alignment: .leading, spacing: 2) {
            Label("Approval Policy", systemImage: "hand.raised")
              .font(.subheadline).fontWeight(.medium)
            Text("Set the default automation level when launching Gemini CLI.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Picker("", selection: $preferences.defaultResumeApprovalPolicy) {
            ForEach(ApprovalPolicy.allCases) { Text($0.title).tag($0) }
          }
          .labelsHidden()
          .frame(maxWidth: .infinity, alignment: .trailing)
        }
      }
    }
  }

  private var modelTab: some View {
    SettingsTabContent {
      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
        GridRow {
          VStack(alignment: .leading, spacing: 2) {
            Label("Model", systemImage: "cpu")
              .font(.subheadline).fontWeight(.medium)
            Text("Choose the model alias to use when launching Gemini CLI.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Picker("", selection: $vm.selectedModelId) {
            ForEach(vm.modelOptions) { option in
              Text(option.title).tag(option.value)
            }
          }
          .labelsHidden()
          .frame(maxWidth: .infinity, alignment: .trailing)
          .onChange(of: vm.selectedModelId) { _ in vm.applyModelSelectionChange() }
        }
        if let selection = vm.selectedModelId,
          let descriptor = vm.modelOptions.first(where: { $0.value == selection })?.subtitle
        {
          GridRow {
            Text("")
            Text(descriptor)
              .font(.caption)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .trailing)
          }
        } else if let descriptor = vm.modelOptions.first(where: { $0.value == nil })?.subtitle {
          GridRow {
            Text("")
            Text(descriptor)
              .font(.caption)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .trailing)
          }
        }
        dividerRow
        GridRow {
          VStack(alignment: .leading, spacing: 2) {
            Label("Max Session Turns", systemImage: "arrow.counterclockwise")
              .font(.subheadline).fontWeight(.medium)
            Text("Number of turns kept in memory (-1 keeps everything).")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Stepper(value: $vm.maxSessionTurns, in: -1...10_000, step: 1) {
            Text(vm.maxSessionTurns < 0 ? "Unlimited (-1)" : "\(vm.maxSessionTurns)")
          }
          .frame(maxWidth: .infinity, alignment: .trailing)
          .onChange(of: vm.maxSessionTurns) { _ in vm.applyMaxSessionTurnsChange() }
        }
        dividerRow
        GridRow {
          VStack(alignment: .leading, spacing: 2) {
            Label("Compression Threshold", systemImage: "arrow.down.circle")
              .font(.subheadline).fontWeight(.medium)
            Text("Fraction of context usage that triggers compression.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          VStack(alignment: .trailing, spacing: 6) {
            Slider(value: $vm.compressionThreshold, in: 0...1, step: 0.05)
              .frame(maxWidth: 240)
              .onChange(of: vm.compressionThreshold) { _ in vm.applyCompressionThresholdChange() }
            Text("\(vm.compressionThreshold, format: .number.precision(.fractionLength(2)))")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .trailing)
        }
        dividerRow
        GridRow {
          VStack(alignment: .leading, spacing: 2) {
            Label("Skip Next Speaker Check", systemImage: "checkmark.circle.badge.xmark")
              .font(.subheadline).fontWeight(.medium)
            Text("Bypass the next speaker role verification step.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Toggle("", isOn: $vm.skipNextSpeakerCheck)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .onChange(of: vm.skipNextSpeakerCheck) { _ in vm.applySkipNextSpeakerChange() }
        }
        if let error = vm.lastError {
          dividerRow
          GridRow {
            Text("")
            Text(error)
              .font(.caption)
              .foregroundStyle(.red)
              .frame(maxWidth: .infinity, alignment: .trailing)
          }
        }
      }
    }
  }

  private var notificationsTab: some View {
    SettingsTabContent {
      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
        GridRow {
          VStack(alignment: .leading, spacing: 2) {
            Label("System Notifications", systemImage: "bell")
              .font(.subheadline).fontWeight(.medium)
            Text("Forward Gemini permission prompts to macOS via codmate://notify.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Toggle("", isOn: $vm.notificationsEnabled)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .onChange(of: vm.notificationsEnabled) { _ in vm.scheduleApplyNotificationSettingsDebounced() }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        dividerRow
        GridRow {
          VStack(alignment: .leading, spacing: 2) {
            Label("Self-test", systemImage: "checkmark.seal")
              .font(.subheadline).fontWeight(.medium)
            Text("Send a sample event through the notify bridge.")
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
            Button("Run Self-test") { Task { await vm.runNotificationSelfTest() } }
              .controlSize(.small)
            if let result = vm.notificationSelfTestResult {
              Text(result).font(.caption).foregroundStyle(.secondary)
            }
          }
          .frame(maxWidth: .infinity, alignment: .trailing)
        }
      }
    }
  }

  private var rawTab: some View {
    SettingsTabContent {
      ZStack(alignment: .topTrailing) {
        ScrollView {
          Text(vm.rawSettingsText.isEmpty ? "(settings.json not found or empty)" : vm.rawSettingsText)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        HStack(spacing: 8) {
          Button {
            Task { await vm.refreshSettings(); await vm.reloadRawSettings() }
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .help("Reload settings")
          .buttonStyle(.borderless)
          Button {
            vm.openSettingsInEditor()
          } label: {
            Image(systemName: "square.and.pencil")
          }
          .help("Reveal settings.json")
          .buttonStyle(.borderless)
        }
      }
    }
  }

  @ViewBuilder
  private var dividerRow: some View {
    GridRow { Divider().gridCellColumns(2) }
  }
}

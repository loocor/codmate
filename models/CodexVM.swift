import Foundation
import SwiftUI

@MainActor
final class CodexVM: ObservableObject {
  let builtinModels: [String] = ["gpt-5.1", "gpt-5.1-codex", "gpt-5.1-codex-max", "gpt-5.1-codex-mini"]
  enum ReasoningEffort: String, CaseIterable, Identifiable {
    case minimal, low, medium, high
    var id: String { rawValue }
  }
  enum ReasoningSummary: String, CaseIterable, Identifiable {
    case auto, concise, detailed, none
    var id: String { rawValue }
  }
  enum ModelVerbosity: String, CaseIterable, Identifiable {
    case low, medium, high
    var id: String { rawValue }
  }
  enum OtelKind: String, Identifiable {
    case http, grpc
    var id: String { rawValue }
  }

  // Providers
  @Published var providers: [CodexProvider] = []
  @Published var activeProviderId: String?
  @Published var registryProviders: [ProvidersRegistryService.Provider] = []
  @Published var registryActiveProviderId: String?
  @Published var showProviderEditor = false
  @Published var providerDraft: CodexProvider = .init(
    id: "", name: nil, baseURL: nil, envKey: nil, wireAPI: nil, queryParamsRaw: nil,
    httpHeadersRaw: nil, envHttpHeadersRaw: nil, requestMaxRetries: nil, streamMaxRetries: nil,
    streamIdleTimeoutMs: nil, managedByCodMate: true)
  private var editingExistingId: String? = nil
  var editingKindIsNew: Bool { editingExistingId == nil }
  @Published var showDeleteAlert: Bool = false
  @Published var deleteTargetId: String? = nil

  // Runtime
  @Published var model: String = ""
  @Published var reasoningEffort: ReasoningEffort = .medium
  @Published var reasoningSummary: ReasoningSummary = .auto
  @Published var modelVerbosity: ModelVerbosity = .medium
  @Published var sandboxMode: SandboxMode = .workspaceWrite
  @Published var approvalPolicy: ApprovalPolicy = .onRequest
  @Published var runtimeDirty = false

  // Notifications
  @Published var tuiNotifications: Bool = false
  @Published var systemNotifications: Bool = false
  @Published var notifyBridgePath: String?
  @Published var rawConfigText: String = ""

  // Privacy
  @Published var envInherit: String = "all"
  @Published var envIgnoreDefaults: Bool = false
  @Published var envIncludeOnly: String = ""
  @Published var envExclude: String = ""
  @Published var envSetPairs: String = ""
  @Published var hideAgentReasoning: Bool = false
  @Published var showRawAgentReasoning: Bool = false
  @Published var fileOpener: String = "vscode"
  // OTEL
  @Published var otelEnabled: Bool = false
  @Published var otelKind: OtelKind = .http
  @Published var otelEndpoint: String = ""

  @Published var lastError: String?

  private let service = CodexConfigService()
  private let providersRegistry = ProvidersRegistryService()
  // Debounce tasks
  private var debounceProviderTask: Task<Void, Never>? = nil
  private var debounceModelTask: Task<Void, Never>? = nil
  private var debounceReasoningTask: Task<Void, Never>? = nil
  private var debounceTuiNotifTask: Task<Void, Never>? = nil
  private var debounceSysNotifTask: Task<Void, Never>? = nil
  private var debounceHideReasoningTask: Task<Void, Never>? = nil
  private var debounceShowReasoningTask: Task<Void, Never>? = nil
  // Preset helper
  enum ProviderPreset { case k2, glm, deepseek }
  @Published var providerKeyApplyURL: String? = nil

  func loadAll() async {
    await loadProviders()
    await loadRuntime()
    await loadRegistryBindings()
    await loadNotifications()
    await loadPrivacy()
    await reloadRawConfig()
  }

  func loadProviders() async {
    providers = await service.listProviders()
    activeProviderId = await service.activeProvider()
  }

  func loadRegistryBindings() async {
    // Align with Claude Code: only show user-configured providers,
    // not bundled templates, to avoid confusing, incomplete entries.
    registryProviders = await providersRegistry.listProviders()
    let bindings = await providersRegistry.getBindings()
    registryActiveProviderId =
      bindings.activeProvider?[
        ProvidersRegistryService.Consumer.codex.rawValue]
    if let defaultModel = bindings.defaultModel?[
      ProvidersRegistryService.Consumer.codex.rawValue], !defaultModel.isEmpty
    {
      model = defaultModel
    } else if registryActiveProviderId == nil {
      model = builtinModels.first ?? "gpt-5.1-codex-mini"
    }
    normalizeBuiltinModelIfNeeded()
  }

  // MARK: - Debounced schedulers
  private func schedule(
    _ taskRef: inout Task<Void, Never>?, delayMs: UInt64 = 300,
    action: @escaping @MainActor () async -> Void
  ) {
    taskRef?.cancel()
    taskRef = Task { [weak self] in
      guard self != nil else { return }
      do { try await Task.sleep(nanoseconds: delayMs * 1_000_000) } catch { return }
      if Task.isCancelled { return }
      await action()
    }
  }

  func scheduleApplyRegistryProviderSelectionDebounced() {
    schedule(&debounceProviderTask) { [weak self] in
      guard let self else { return }
      await self.applyRegistryProviderSelection()
    }
  }
  func scheduleApplyModelDebounced() {
    schedule(&debounceModelTask) { [weak self] in
      guard let self else { return }
      await self.applyModel()
    }
  }
  func scheduleApplyReasoningDebounced() {
    schedule(&debounceReasoningTask) { [weak self] in
      guard let self else { return }
      await self.applyReasoning()
    }
  }
  func scheduleApplyTuiNotificationsDebounced() {
    schedule(&debounceTuiNotifTask) { [weak self] in
      guard let self else { return }
      await self.applyTuiNotifications()
    }
  }
  func scheduleApplySystemNotificationsDebounced() {
    schedule(&debounceSysNotifTask) { [weak self] in
      guard let self else { return }
      await self.applySystemNotifications()
    }
  }
  func scheduleApplyHideReasoningDebounced() {
    schedule(&debounceHideReasoningTask) { [weak self] in
      guard let self else { return }
      await self.applyHideReasoning()
    }
  }
  func scheduleApplyShowRawReasoningDebounced() {
    schedule(&debounceShowReasoningTask) { [weak self] in
      guard let self else { return }
      await self.applyShowRawReasoning()
    }
  }

  func presentAddProvider() {
    editingExistingId = nil
    providerDraft = .init(
      id: "", name: nil, baseURL: nil, envKey: nil, wireAPI: nil, queryParamsRaw: nil,
      httpHeadersRaw: nil, envHttpHeadersRaw: nil, requestMaxRetries: nil,
      streamMaxRetries: nil, streamIdleTimeoutMs: nil, managedByCodMate: true)
    providerKeyApplyURL = nil
    showProviderEditor = true
  }

  func presentAddProviderPreset(_ preset: ProviderPreset) {
    editingExistingId = nil
    switch preset {
    case .k2:
      providerDraft = .init(
        id: "", name: "K2", baseURL: "https://api.moonshot.cn/v1", envKey: nil,
        wireAPI: "responses", queryParamsRaw: nil, httpHeadersRaw: nil,
        envHttpHeadersRaw: nil,
        requestMaxRetries: nil, streamMaxRetries: nil, streamIdleTimeoutMs: nil,
        managedByCodMate: true)
      providerKeyApplyURL = "https://platform.moonshot.cn/console/api-keys"
    case .glm:
      providerDraft = .init(
        id: "", name: "GLM", baseURL: "https://open.bigmodel.cn/api/paas/v4/", envKey: nil,
        wireAPI: "responses", queryParamsRaw: nil, httpHeadersRaw: nil,
        envHttpHeadersRaw: nil,
        requestMaxRetries: nil, streamMaxRetries: nil, streamIdleTimeoutMs: nil,
        managedByCodMate: true)
      providerKeyApplyURL = "https://bigmodel.cn/usercenter/proj-mgmt/apikeys"
    case .deepseek:
      providerDraft = .init(
        id: "", name: "DeepSeek", baseURL: "https://api.deepseek.com/v1", envKey: nil,
        wireAPI: "responses", queryParamsRaw: nil, httpHeadersRaw: nil,
        envHttpHeadersRaw: nil,
        requestMaxRetries: nil, streamMaxRetries: nil, streamIdleTimeoutMs: nil,
        managedByCodMate: true)
      providerKeyApplyURL = "https://platform.deepseek.com/api_keys"
    }
    showProviderEditor = true
  }

  func presentEditProvider(_ p: CodexProvider) {
    editingExistingId = p.id
    providerDraft = p
    switch p.id.lowercased() {
    case "k2": providerKeyApplyURL = "https://platform.moonshot.cn/console/api-keys"
    case "glm": providerKeyApplyURL = "https://bigmodel.cn/usercenter/proj-mgmt/apikeys"
    case "deepseek": providerKeyApplyURL = "https://platform.deepseek.com/api_keys"
    default: providerKeyApplyURL = nil
    }
    showProviderEditor = true
  }

  func dismissEditor() { showProviderEditor = false }

  func saveProviderDraft() async {
    lastError = nil
    do {
      var provider = providerDraft
      // Trim and normalize
      func norm(_ s: String?) -> String? {
        let t = s?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : t
      }
      provider.name = norm(provider.name)
      provider.baseURL = norm(provider.baseURL)
      provider.envKey = norm(provider.envKey)
      // wire_api must be one of: responses, chat. If empty → nil; if invalid → keep as-is (user intent), but presets default to responses.
      if let w = norm(provider.wireAPI) {
        let lw = w.lowercased()
        provider.wireAPI = (lw == "responses" || lw == "chat") ? lw : w
      } else {
        provider.wireAPI = nil
      }
      provider.queryParamsRaw = norm(provider.queryParamsRaw)
      provider.httpHeadersRaw = norm(provider.httpHeadersRaw)
      provider.envHttpHeadersRaw = norm(provider.envHttpHeadersRaw)

      // Basic validation: require at least a base URL or name
      if provider.baseURL == nil && provider.name == nil {
        lastError = "Please enter at least a Name or Base URL."
        return
      }

      if editingKindIsNew {
        // Determine id: prefer existing non-empty id, otherwise slugify name/base
        let proposed = norm(provider.id) ?? provider.name ?? provider.baseURL ?? "provider"
        let baseSlug = Self.slugify(proposed)
        var candidate = baseSlug.isEmpty ? "provider" : baseSlug
        var n = 2
        while providers.contains(where: { $0.id == candidate }) {
          candidate = "\(baseSlug)-\(n)"
          n += 1
        }
        provider.id = candidate
      } else {
        provider.id = editingExistingId ?? provider.id
      }
      try await service.upsertProvider(provider)
      showProviderEditor = false
      await loadProviders()
    } catch {
      lastError = "Failed to save provider: \(error.localizedDescription)"
    }
  }

  func deleteProvider(id: String) {
    Task { [weak self] in
      do {
        try await self?.service.deleteProvider(id: id)
        await self?.loadProviders()
      } catch {
        await MainActor.run {
          self?.lastError = "Delete failed: \(error.localizedDescription)"
        }
      }
    }
  }

  func requestDeleteProvider(id: String) {
    deleteTargetId = id
    showDeleteAlert = true
  }
  func cancelDelete() {
    showDeleteAlert = false
    deleteTargetId = nil
  }
  func confirmDelete() async {
    guard let id = deleteTargetId else { return }
    deleteProvider(id: id)
    await MainActor.run {
      self.showDeleteAlert = false
      self.deleteTargetId = nil
    }
  }

  func applyActiveProvider() async {
    do { try await service.setActiveProvider(activeProviderId) } catch {
      lastError = "Failed to set active provider"
    }
  }

  func deleteEditingProviderViaEditor() async {
    guard let id = editingExistingId else { return }
    do {
      try await service.deleteProvider(id: id)
      await loadProviders()
      await MainActor.run { self.showProviderEditor = false }
    } catch {
      await MainActor.run { self.lastError = "Delete failed: \(error.localizedDescription)" }
    }
  }

  // Runtime
  func loadRuntime() async {
    model = await service.getTopLevelString("model") ?? model
    if let e = await service.getTopLevelString("model_reasoning_effort"),
      let v = ReasoningEffort(rawValue: e)
    {
      reasoningEffort = v
    }
    if let s = await service.getTopLevelString("model_reasoning_summary"),
      let v = ReasoningSummary(rawValue: s)
    {
      reasoningSummary = v
    }
    if let v = await service.getTopLevelString("model_verbosity"),
      let mv = ModelVerbosity(rawValue: v)
    {
      modelVerbosity = mv
    }
    if let s = await service.getTopLevelString("sandbox_mode"),
      let sm = SandboxMode(rawValue: s)
    {
      sandboxMode = sm
    }
    if let a = await service.getTopLevelString("approval_policy"),
      let ap = ApprovalPolicy(rawValue: a)
    {
      approvalPolicy = ap
    }
  }

  func applyModel() async {
    let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
    let value = trimmed.isEmpty ? nil : trimmed
    model = trimmed
    do {
      try await service.setTopLevelString("model", value: value)
      try await providersRegistry.setDefaultModel(
        .codex, modelId: value)
      runtimeDirty = false
    } catch {
      lastError = "Save failed"
    }
  }

  func selectedRegistryProvider() -> ProvidersRegistryService.Provider? {
    guard let id = registryActiveProviderId else { return nil }
    return registryProviders.first(where: { $0.id == id })
  }

  func modelsForActiveRegistryProvider() -> [String] {
    guard let provider = selectedRegistryProvider() else { return [] }
    let ids = (provider.catalog?.models ?? []).map { $0.vendorModelId }
    var seen = Set<String>()
    return ids.compactMap { id in
      let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      if seen.insert(trimmed).inserted { return trimmed }
      return nil
    }
  }

  func registryDisplayName(for provider: ProvidersRegistryService.Provider) -> String {
    if let name = provider.name, !name.isEmpty { return name }
    return provider.id
  }

  func applyRegistryProviderSelection() async {
    do {
      try await providersRegistry.setActiveProvider(
        .codex, providerId: registryActiveProviderId)
      if let provider = selectedRegistryProvider() {
        try await service.applyProviderFromRegistry(provider)
        if let recommended = provider.recommended?.defaultModelFor?[
          ProvidersRegistryService.Consumer.codex.rawValue],
          !recommended.isEmpty
        {
          model = recommended
        } else if let first = provider.catalog?.models?.first?.vendorModelId {
          model = first
        }
      } else {
        try await service.applyProviderFromRegistry(nil)
        model = builtinModels.first ?? "gpt-5.1-codex-mini"
      }
      await applyModel()
    } catch {
      lastError = "Failed to apply provider"
    }
    await loadRegistryBindings()
  }

  private func normalizeBuiltinModelIfNeeded() {
    guard registryActiveProviderId == nil else { return }
    if !builtinModels.contains(model) {
      model = builtinModels.first ?? "gpt-5.1-codex-mini"
    }
  }
  func applyReasoning() async {
    do {
      try await service.setTopLevelString(
        "model_reasoning_effort", value: reasoningEffort.rawValue)
      try await service.setTopLevelString(
        "model_reasoning_summary", value: reasoningSummary.rawValue)
      try await service.setTopLevelString("model_verbosity", value: modelVerbosity.rawValue)
    } catch { lastError = "Save failed" }
  }
  func applySandbox() async {
    do { try await service.setSandboxMode(sandboxMode.rawValue) } catch {
      lastError = "Save failed"
    }
  }
  func applyApproval() async {
    do { try await service.setApprovalPolicy(approvalPolicy.rawValue) } catch {
      lastError = "Save failed"
    }
  }

  // Notifications
  @Published var notifySelfTestResult: String? = nil
  @Published var notifyBridgeHealthy: Bool = false
  func loadNotifications() async {
    tuiNotifications = await service.getTuiNotifications()
    let arr = await service.getNotifyArray()
    if let bridge = arr.first {
      // If the configured bridge is missing or not executable, try to reinstall silently.
      if FileManager.default.isExecutableFile(atPath: bridge) {
        systemNotifications = true
        notifyBridgePath = bridge
        notifyBridgeHealthy = true
      } else {
        if let url = try? await service.ensureNotifyBridgeInstalled() {
          notifyBridgePath = url.path
          systemNotifications = true
          _ = try? await service.setNotifyArray([url.path])
          notifyBridgeHealthy = FileManager.default.isExecutableFile(atPath: url.path)
        } else {
          systemNotifications = false
          notifyBridgePath = nil
          notifyBridgeHealthy = false
        }
      }
    } else {
      systemNotifications = false
      notifyBridgePath = nil
      notifyBridgeHealthy = false
    }
  }
  func applyTuiNotifications() async {
    do { try await service.setTuiNotifications(tuiNotifications) } catch {
      lastError = "Failed to save TUI notifications"
    }
  }
  func applySystemNotifications() async {
    do {
      if systemNotifications {
        let url = try await service.ensureNotifyBridgeInstalled()
        notifyBridgePath = url.path
        try await service.setNotifyArray([url.path])
        notifyBridgeHealthy = FileManager.default.isExecutableFile(atPath: url.path)
      } else {
        notifyBridgePath = nil
        try await service.setNotifyArray(nil)
        notifyBridgeHealthy = false
      }
    } catch { lastError = "Failed to configure system notifications" }
  }

  // Run a local self-test of the notify bridge; returns true on success
  func runNotifySelfTest() async {
    notifySelfTestResult = nil
    // Always reinstall to ensure the latest bridge content (marker + escaping fixes)
    let path: String =
      (try? await service.ensureNotifyBridgeInstalled().path) ?? (notifyBridgePath ?? "")
    guard !path.isEmpty else {
      notifySelfTestResult = "Bridge path unavailable"
      return
    }
    let payload =
      #"{"type":"agent-turn-complete","last-assistant-message":"Self-test: turn done","thread-id":"codmate-selftest"}"#
    do {
      let proc = Process()
      proc.executableURL = URL(fileURLWithPath: path)
      proc.arguments = [payload, "--self-test"]
      let outPipe = Pipe()
      proc.standardOutput = outPipe
      proc.standardError = Pipe()
      try proc.run()
      proc.waitUntilExit()
      let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
      let outStr = String(data: outData, encoding: .utf8) ?? ""
      if proc.terminationStatus == 0 {
        if outStr.contains("__CODMATE_NOTIFIED__") {
          // Success: show a lightweight status to avoid a "no feedback" experience
          await SystemNotifier.shared.notify(title: "CodMate", body: "Notifications self-test sent")
          notifySelfTestResult = "Sent (check Notification Center)"
        } else {
          notifySelfTestResult =
            "Bridge ran, but no notifier accepted (check Focus/Do Not Disturb / permissions)"
        }
      } else {
        notifySelfTestResult = "Exited with status \(proc.terminationStatus)"
      }
    } catch {
      notifySelfTestResult = "Failed to run bridge"
    }
  }

  // Privacy
  func loadPrivacy() async {
    _ = await service.sanitizeQuotedBooleans()
    let p = await service.getShellEnvironmentPolicy()
    envInherit = p.inherit ?? envInherit
    envIgnoreDefaults = p.ignoreDefaultExcludes ?? envIgnoreDefaults
    envIncludeOnly = (p.includeOnly ?? []).joined(separator: ", ")
    envExclude = (p.exclude ?? []).joined(separator: ", ")
    envSetPairs = (p.set ?? [:]).map { "\($0.key)=\($0.value)" }.sorted().joined(
      separator: "\n")
    hideAgentReasoning = await service.getBool("hide_agent_reasoning")
    showRawAgentReasoning = await service.getBool("show_raw_agent_reasoning")
    fileOpener = await service.getTopLevelString("file_opener") ?? fileOpener

    let oc = await service.getOtelConfig()
    otelEnabled = oc.exporterKind != .none
    otelKind = (oc.exporterKind == .otlpGrpc) ? .grpc : .http
    otelEndpoint = oc.endpoint ?? ""
  }

  func applyEnvPolicy() async {
    var dict: [String: String] = [:]
    for line in envSetPairs.split(separator: "\n") {
      let s = String(line)
      guard let eq = s.firstIndex(of: "=") else { continue }
      let k = String(s[..<eq]).trimmingCharacters(in: .whitespaces)
      let v = String(s[s.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
      if !k.isEmpty { dict[k] = v }
    }
    let policy = CodexConfigService.ShellEnvironmentPolicy(
      inherit: envInherit,
      ignoreDefaultExcludes: envIgnoreDefaults,
      includeOnly: tokens(envIncludeOnly),
      exclude: tokens(envExclude),
      set: dict.isEmpty ? nil : dict
    )
    do { try await service.setShellEnvironmentPolicy(policy) } catch {
      lastError = "Failed to save env policy"
    }
  }
  func applyHideReasoning() async {
    do { try await service.setBool("hide_agent_reasoning", hideAgentReasoning) } catch {
      lastError = "Failed"
    }
  }
  func applyShowRawReasoning() async {
    do { try await service.setBool("show_raw_agent_reasoning", showRawAgentReasoning) } catch {
      lastError = "Failed"
    }
  }
  func applyFileOpener() async {
    do { try await service.setFileOpener(fileOpener) } catch { lastError = "Failed" }
  }
  func applyOtel() async {
    let kind: CodexConfigService.OtelExporterKind =
      otelEnabled ? (otelKind == .grpc ? .otlpGrpc : .otlpHttp) : .none
    let cfg = CodexConfigService.OtelConfig(
      environment: nil, exporterKind: kind, endpoint: otelEndpoint)
    do { try await service.setOtelConfig(cfg) } catch { lastError = "Failed to save OTEL" }
  }

  private func tokens(_ s: String) -> [String]? {
    let arr = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter {
      !$0.isEmpty
    }
    return arr.isEmpty ? nil : arr
  }
  // Raw config helpers
  func reloadRawConfig() async { rawConfigText = await service.readRawConfigText() }
  func openConfigInEditor() {
    Task { @MainActor in
      let url = await service.configFileURL()
      NSWorkspace.shared.open(url)
    }
  }
  private static func slugify(_ s: String) -> String {
    let lower = s.lowercased()
    let mapped = lower.map { c -> Character in
      if c.isLetter || c.isNumber { return c }
      return "-"
    }
    var collapsed: [Character] = []
    var lastDash = false
    for ch in mapped {
      if ch == "-" {
        if !lastDash {
          collapsed.append(ch)
          lastDash = true
        }
      } else {
        collapsed.append(ch)
        lastDash = false
      }
    }
    while collapsed.first == "-" { collapsed.removeFirst() }
    while collapsed.last == "-" { collapsed.removeLast() }
    let s2 = String(collapsed)
    return s2.isEmpty ? "provider" : s2
  }
}

import SwiftUI
import AppKit
import Network

struct ProvidersSettingsView: View {
  @ObservedObject var preferences: SessionPreferencesStore
  @StateObject private var vm = ProvidersVM()
  @StateObject private var proxyService = CLIProxyService.shared
  @State private var pendingDeleteId: String?
  @State private var pendingDeleteName: String?
  @State private var oauthInfoProvider: LocalAuthProvider?
  @State private var oauthStatus: [LocalAuthProvider: Bool] = [:]
  @State private var oauthLoginInProgress: LocalAuthProvider?
  @State private var oauthAutoStartFailed: Bool = false
  @State private var localModels: [CLIProxyService.LocalModel] = []
  @State private var localIP: String = "127.0.0.1"
  @State private var publicAPIKey: String = ""

  private let minPublicKeyLength = 36

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      Group {
        if #available(macOS 15.0, *) {
          TabView {
            Tab("Providers", systemImage: "server.rack") {
              SettingsTabContent {
                providersList
              }
            }
            Tab("ReRoute", systemImage: "arrow.triangle.2.circlepath") {
              SettingsTabContent {
                proxyCapabilitiesSection
              }
            }
          }
        } else {
          TabView {
            SettingsTabContent {
              providersList
            }
            .tabItem { Label("Providers", systemImage: "server.rack") }
            SettingsTabContent {
              proxyCapabilitiesSection
            }
            .tabItem { Label("ReRoute", systemImage: "arrow.triangle.2.circlepath") }
          }
        }
      }
      .controlSize(.regular)
      .padding(.bottom, 16)
    }
    .sheet(
      isPresented: Binding(
        get: { vm.showEditor },
        set: { newValue in
          vm.showEditor = newValue
          if !newValue {
            // Reset new provider state when sheet closes
            vm.isNewProvider = false
          }
        }
      )
    ) { ProviderEditorSheet(vm: vm) }
    .sheet(item: $oauthInfoProvider) { provider in
      OAuthProviderInfoSheet(
        provider: provider,
        isLoggedIn: oauthStatus[provider] == true,
        models: modelsForOAuthProvider(provider),
        onLogin: { startOAuthLogin(provider) },
        onLogout: {
          proxyService.logout(provider: provider)
          refreshOAuthStatus()
        }
      )
    }
    .sheet(item: $proxyService.loginPrompt) { prompt in
      LoginPromptSheet(
        prompt: prompt,
        onSubmit: { input in
          proxyService.submitLoginInput(input)
          proxyService.loginPrompt = nil
        },
        onCancel: {
          proxyService.loginPrompt = nil
        },
        onStop: {
          proxyService.cancelLogin()
          proxyService.loginPrompt = nil
        }
      )
    }
    .codmatePresentationSizingIfAvailable()
    .task {
      await vm.loadAll()
      await vm.loadTemplates()
      getLocalIPAddress()
      loadPublicKey()
      refreshOAuthStatus()
      await refreshLocalModels()
      ensureServiceRunningIfNeeded()
    }
    .onChange(of: preferences.localServerEnabled) { enabled in
      if enabled {
        ensureServiceRunningIfNeeded(force: true)
      }
    }
    .onChange(of: preferences.localServerReroute) { enabled in
      if enabled {
        ensureServiceRunningIfNeeded(force: true)
      }
    }
    .onChange(of: preferences.localServerReroute3P) { enabled in
      if enabled {
        ensureServiceRunningIfNeeded(force: true)
      }
      Task {
        if enabled {
          await proxyService.syncThirdPartyProviders()
        }
        await refreshLocalModels()
      }
    }
    .onChange(of: preferences.oauthProvidersEnabled) { _ in
      refreshOAuthStatus()
      Task { await refreshLocalModels() }
      ensureServiceRunningIfNeeded()
    }
    .onChange(of: proxyService.isRunning) { running in
      if running { oauthAutoStartFailed = false }
      Task { await refreshLocalModels() }
    }
    .confirmationDialog(
      "Delete Provider",
      isPresented: Binding(
        get: { pendingDeleteId != nil },
        set: {
          if !$0 {
            pendingDeleteId = nil
            pendingDeleteName = nil
          }
        }
      ),
      titleVisibility: .visible
    ) {
      Button("Delete", role: .destructive) {
        if let id = pendingDeleteId {
          Task { await vm.delete(id: id) }
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      if let name = pendingDeleteName {
        Text("Are you sure you want to delete \"\(name)\"? This action cannot be undone.")
      } else {
        Text("Are you sure you want to delete this provider? This action cannot be undone.")
      }
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Providers")
        .font(.title2)
        .fontWeight(.bold)
      Text("Manage API key and OAuth providers for Codex and Claude Code.")
        .font(.subheadline)
        .foregroundColor(.secondary)
    }
  }

  private var providersList: some View {
    VStack(alignment: .leading, spacing: 20) {
      VStack(alignment: .leading, spacing: 10) {
        Text("OAuth").font(.headline).fontWeight(.semibold)
        settingsCard {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(LocalAuthProvider.allCases.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }.enumerated()), id: \.element) { index, provider in
              if index > 0 {
                Divider()
                  .padding(.vertical, 4)
              }
              HStack(alignment: .center, spacing: 0) {
                HStack(alignment: .center, spacing: 8) {
                  LocalAuthProviderIconView(provider: provider, size: 16, cornerRadius: 4)
                  Text(provider.displayName)
                    .font(.body.weight(.medium))
                }
                .frame(minWidth: 140, alignment: .leading)

                Spacer(minLength: 16)

                oauthStatusBadge(provider)
                  .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                  if oauthStatus[provider] == true {
                    Task {
                      ensureServiceRunningIfNeeded(force: true)
                      await refreshLocalModels()
                      await MainActor.run { oauthInfoProvider = provider }
                    }
                  } else {
                    startOAuthLogin(provider)
                  }
                } label: {
                  Image(systemName: oauthStatus[provider] == true ? "info.circle" : "person.crop.circle.badge.plus")
                    .font(.body)
                }
                .buttonStyle(.borderless)
                .help(oauthStatus[provider] == true ? "View models and manage session" : "Sign in")
              }
              .padding(.vertical, 10)
            }
          }
        }
      }

      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text("API Key").font(.headline).fontWeight(.semibold)
          Spacer()
          Menu {
            Section("API Key") {
              if vm.templates.isEmpty {
                Text("No templates found")
              } else {
                ForEach(vm.templates, id: \.id) { t in
                  Button(t.name?.isEmpty == false ? t.name! : t.id) { vm.startFromTemplate(t) }
                }
                Divider()
              }
              Button("Other…") { vm.startNewProvider() }
            }
          } label: {
            Label("Add", systemImage: "plus")
          }
        }
        if !vm.providers.isEmpty {
          settingsCard {
            ScrollView {
              VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(vm.providers.enumerated()), id: \.element.id) { index, p in
                  if index > 0 {
                    Divider()
                      .padding(.vertical, 4)
                  }
                  HStack(alignment: .center, spacing: 0) {
                    HStack(alignment: .center, spacing: 8) {
                      APIKeyProviderIconView(
                        provider: p,
                        size: 16,
                        cornerRadius: 4,
                        isSelected: vm.activeCodexProviderId == p.id
                      )
                      .frame(width: 20)
                      Text(p.name?.isEmpty == false ? p.name! : p.id)
                        .font(.body.weight(.medium))
                    }
                    .frame(minWidth: 140, alignment: .leading)

                    Spacer(minLength: 16)

                    VStack(alignment: .leading, spacing: 2) {
                      endpointBlock(
                        label: "Codex",
                        value: p.connectors[ProvidersRegistryService.Consumer.codex.rawValue]?.baseURL
                      )
                      endpointBlock(
                        label: "Claude",
                        value: p.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue]?
                          .baseURL
                      )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                      vm.selectedId = p.id
                      vm.showEditor = true
                    } label: {
                      Image(systemName: "pencil")
                        .font(.body)
                    }
                    .buttonStyle(.borderless)
                    .help("Edit provider")
                  }
                  .padding(.vertical, 4)
                  .contextMenu {
                    Button("Edit…") {
                      vm.showEditor = true
                      vm.selectedId = p.id
                    }
                    Divider()
                    Button(role: .destructive) {
                      pendingDeleteId = p.id
                      pendingDeleteName = p.name?.isEmpty == false ? p.name : p.id
                    } label: {
                      Text("Delete")
                    }
                  }
                }
              }
            }
          }
        } else {
          settingsCard {
            VStack(spacing: 12) {
              Image(systemName: "key")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
              Text("No API Key Providers")
                .font(.subheadline)
                .fontWeight(.medium)
              Text("Click Add to configure an API key provider")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 120)
            .padding(.vertical, 20)
          }
        }
      }
    }
  }

  private var proxyCapabilitiesSection: some View {
    VStack(alignment: .leading, spacing: 20) {
      // 1. Reroute Control
      VStack(alignment: .leading, spacing: 10) {
        Text("Reroute Control").font(.headline).fontWeight(.semibold)
        settingsCard {
          Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
            GridRow {
              VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                  Image(systemName: "bolt.horizontal")
                    .frame(width: 16, alignment: .leading)
                  Text("CLI Proxy API")
                    .font(.subheadline).fontWeight(.medium)
                }
                Text("Service status for OAuth and reroute")
                  .font(.caption).foregroundColor(.secondary)
                  .padding(.leading, 22)
              }
              HStack(spacing: 8) {
                statusPill(proxyService.isRunning ? "Running" : "Stopped",
                           active: proxyService.isRunning)
                Button("Restart") { restartProxyService() }
                  .buttonStyle(.bordered)
                if showDebugControls {
                  Button("Start") { startProxyService() }
                    .buttonStyle(.bordered)
                  Button("Stop") { proxyService.stop() }
                    .buttonStyle(.bordered)
                    .disabled(!proxyService.isRunning)
                }
              }
              .frame(maxWidth: .infinity, alignment: .trailing)
            }

            gridDivider
            GridRow {
              VStack(alignment: .leading, spacing: 2) {
                Label("ReRoute API Key Providers", systemImage: "arrow.triangle.2.circlepath")
                  .font(.subheadline).fontWeight(.medium)
                Text("Route API key providers through CLI Proxy API so models match proxy results.")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
                Text("Temporarily disabled while we finalize this flow.")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
              Toggle("", isOn: $preferences.localServerReroute3P)
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .disabled(true)
            }
          }
        }
      }

      // 2. Public Access
      VStack(alignment: .leading, spacing: 10) {
        Text("Public Access").font(.headline).fontWeight(.semibold)
        settingsCard {
          Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
            GridRow {
              VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                  Image(systemName: "network")
                    .frame(width: 16, alignment: .leading)
                  Text("Public Access")
                    .font(.subheadline).fontWeight(.medium)
                }
                Text("Expose a unified API endpoint for all providers")
                  .font(.caption).foregroundColor(.secondary)
                  .padding(.leading, 22)
              }
              Toggle("", isOn: $preferences.localServerEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            if preferences.localServerEnabled {
              gridDivider
              GridRow {
                VStack(alignment: .leading, spacing: 0) {
                  HStack(spacing: 6) {
                    Image(systemName: "link")
                      .frame(width: 16, alignment: .leading)
                    Text("Public URL")
                      .font(.subheadline).fontWeight(.medium)
                  }
                  Text("Publicly accessible server URL")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.leading, 22)
                }
                HStack(spacing: 4) {
                  Text("http://\(localIP):")
                    .font(.system(.caption, design: .monospaced))
                  TextField("Port", value: $preferences.localServerPort, formatter: NumberFormatter())
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 80)
                  Button(action: {
                    copyToClipboard("http://\(localIP):\(String(preferences.localServerPort))")
                  }) {
                    Image(systemName: "doc.on.doc")
                  }
                  .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
              }

              gridDivider
              GridRow {
                VStack(alignment: .leading, spacing: 0) {
                  HStack(spacing: 6) {
                    Image(systemName: "key")
                      .frame(width: 16, alignment: .leading)
                    Text("Public Key")
                      .font(.subheadline).fontWeight(.medium)
                  }
                  Text("API key for public access authentication")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.leading, 22)
                }
                VStack(alignment: .trailing, spacing: 4) {
                  HStack(spacing: 6) {
                    Button(action: regeneratePublicKey) {
                      Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    HStack(spacing: 4) {
                      TextField("Key", text: $publicAPIKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                        .onChange(of: publicAPIKey) { newValue in
                          let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                          guard trimmed.count >= minPublicKeyLength else { return }
                          proxyService.updatePublicAPIKey(trimmed)
                        }
                      Button(action: { copyToClipboard(publicAPIKey) }) {
                        Image(systemName: "doc.on.doc")
                      }
                      .buttonStyle(.plain)
                    }
                    .frame(width: 320)
                  }
                  if publicAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).count < minPublicKeyLength {
                    Text("Minimum \(minPublicKeyLength) characters")
                      .font(.caption)
                      .foregroundColor(.red)
                  }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
              }
            }
          }
        }
      }

      // 3. Config Reference
      VStack(alignment: .leading, spacing: 10) {
        Text("Config Reference").font(.headline).fontWeight(.semibold)
        settingsCard {
          Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
            GridRow {
              VStack(alignment: .leading, spacing: 2) {
                Label("GitHub Repository", systemImage: "square.stack.3d.up")
                  .font(.subheadline).fontWeight(.medium)
                Text("CLIProxyAPI source code repository")
                  .font(.caption).foregroundColor(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
              HStack(spacing: 6) {
                Link(destination: URL(string: "https://github.com/router-for-me/CLIProxyAPI")!) {
                  HStack(spacing: 6) {
                    Text("https://github.com/router-for-me/CLIProxyAPI")
                      .font(.system(.caption, design: .monospaced))
                      .foregroundColor(.secondary)
                    Image(systemName: "arrow.up.right.square")
                      .font(.system(size: 12))
                      .foregroundColor(.secondary)
                      .opacity(0.6)
                  }
                }
              }
              .frame(maxWidth: .infinity, alignment: .trailing)
            }

            gridDivider

            GridRow {
              VStack(alignment: .leading, spacing: 2) {
                Label("Documentation", systemImage: "book")
                  .font(.subheadline).fontWeight(.medium)
                Text("CLIProxyAPI official documentation")
                  .font(.caption).foregroundColor(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
              HStack(spacing: 6) {
                Link(destination: URL(string: "https://help.router-for.me/")!) {
                  HStack(spacing: 6) {
                    Text("https://help.router-for.me/")
                      .font(.system(.caption, design: .monospaced))
                      .foregroundColor(.secondary)
                    Image(systemName: "arrow.up.right.square")
                      .font(.system(size: 12))
                      .foregroundColor(.secondary)
                      .opacity(0.6)
                  }
                }
              }
              .frame(maxWidth: .infinity, alignment: .trailing)
            }
          }
        }
      }
    }
  }

  @ViewBuilder
  private func endpointBlock(label: String, value: String?) -> some View {
    HStack(spacing: 6) {
      Text("\(label):")
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(width: 50, alignment: .leading)
      Text((value?.isEmpty == false) ? value! : "—")
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }

  private func startOAuthLogin(_ provider: LocalAuthProvider) {
    guard oauthLoginInProgress == nil else { return }
    if proxyService.hasAuthToken(for: provider) {
      preferences.oauthProvidersEnabled.insert(provider.rawValue)
      refreshOAuthStatus()
      ensureServiceRunningIfNeeded(force: true)
      return
    }
    oauthLoginInProgress = provider
    Task {
      defer {
        Task { @MainActor in
          oauthLoginInProgress = nil
          refreshOAuthStatus()
        }
      }
      do {
        try await proxyService.login(provider: provider)
        _ = await MainActor.run {
          preferences.oauthProvidersEnabled.insert(provider.rawValue)
        }
        await refreshLocalModels()
        ensureServiceRunningIfNeeded(force: true)
      } catch {
        if error is CancellationError { return }
      }
    }
  }

  @ViewBuilder
  private func oauthMenuLabel(_ provider: LocalAuthProvider) -> some View {
    HStack(spacing: 6) {
      LocalAuthProviderIconView(provider: provider, size: 14, cornerRadius: 3)
        .frame(width: 16, height: 16, alignment: .center)
        .clipped()
      Text(provider.displayName)
    }
  }

  @ViewBuilder
  private func providersSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 6) {
        content()
      }
    }
  }

  @ViewBuilder
  private func oauthStatusBadge(_ provider: LocalAuthProvider) -> some View {
    if oauthLoginInProgress == provider {
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text("Logging in…").font(.caption)
      }
      .foregroundStyle(.secondary)
    } else if oauthStatus[provider] == true {
      Text("Logged in").font(.caption)
    } else {
      Text("Not logged in").font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func refreshOAuthStatus() {
    var next: [LocalAuthProvider: Bool] = [:]
    for provider in LocalAuthProvider.allCases {
      next[provider] = proxyService.hasAuthToken(for: provider)
    }
    oauthStatus = next
  }

  private func ensureServiceRunningIfNeeded(force: Bool = false) {
    let hasLoggedInOAuth = oauthStatus.values.contains(true)
    let shouldEnsure =
      force
      || hasLoggedInOAuth
      || preferences.localServerEnabled
      || preferences.localServerReroute
      || preferences.localServerReroute3P
    guard shouldEnsure else { return }
    guard !proxyService.isRunning else { return }
    oauthAutoStartFailed = false
    Task {
      do {
        try await proxyService.start()
        await MainActor.run { oauthAutoStartFailed = false }
      } catch {
        await MainActor.run { oauthAutoStartFailed = true }
      }
    }
  }

  private func restartProxyService() {
    Task {
      if proxyService.isRunning {
        proxyService.stop()
        try? await Task.sleep(nanoseconds: 500_000_000)
      }
      try? await proxyService.start()
    }
  }

  private func startProxyService() {
    Task { try? await proxyService.start() }
  }

  private var showDebugControls: Bool {
    !proxyService.isRunning && oauthAutoStartFailed
  }

  private func statusPill(_ text: String, active: Bool) -> some View {
    Text(text)
      .font(.caption)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(active ? Color.green.opacity(0.15) : Color.secondary.opacity(0.12))
      .foregroundStyle(active ? Color.green : Color.secondary)
      .clipShape(Capsule())
  }

  private func refreshLocalModels() async {
    localModels = await proxyService.fetchLocalModels()
  }


  private func modelsForOAuthProvider(_ provider: LocalAuthProvider) -> [String] {
    guard let target = builtInProvider(for: provider) else { return [] }
    var seen: Set<String> = []
    var ids: [String] = []
    for model in localModels {
      if builtInProvider(for: model) == target {
        if !seen.contains(model.id) {
          seen.insert(model.id)
          ids.append(model.id)
        }
      }
    }
    return ids.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
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

  private var gridDivider: some View {
    Divider()
  }

  private func getLocalIPAddress() {
    var address: String?
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    if getifaddrs(&ifaddr) == 0 {
      var ptr = ifaddr
      while ptr != nil {
        defer { ptr = ptr?.pointee.ifa_next }

        let interface = ptr?.pointee
        let addrFamily = interface?.ifa_addr.pointee.sa_family
        if addrFamily == UInt8(AF_INET) {
          let name = String(cString: (interface?.ifa_name)!)
          if name == "en0" || name.starts(with: "en") {
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(interface?.ifa_addr, socklen_t((interface?.ifa_addr.pointee.sa_len)!), &hostname, socklen_t(hostname.count), nil, socklen_t(0), NI_NUMERICHOST)
            address = String(cString: hostname)
          }
        }
      }
      freeifaddrs(ifaddr)
    }

    localIP = address ?? "127.0.0.1"
  }

  private func loadPublicKey() {
    let key = proxyService.resolvePublicAPIKey()
    publicAPIKey = key
    proxyService.updatePublicAPIKey(key)
  }

  private func regeneratePublicKey() {
    let generated = proxyService.generatePublicAPIKey(length: minPublicKeyLength)
    publicAPIKey = generated
    proxyService.updatePublicAPIKey(generated)
  }

  private func copyToClipboard(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }

  // MARK: - Helper Views

  @ViewBuilder
  private func settingsCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      content()
    }
    .padding(10)
    .background(Color(nsColor: .separatorColor).opacity(0.35))
    .cornerRadius(10)
  }

  // old tab panes removed to keep Providers view pure. Editing happens in a sheet.

  private var bindingsPane: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        GroupBox("Codex") {
          Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
            GridRow {
              Text("Active Provider").font(.subheadline).fontWeight(.medium)
              Picker("", selection: $vm.activeCodexProviderId) {
                Text("(Built‑in)").tag(String?.none)
                ForEach(vm.providers, id: \.id) { p in
                  Text(p.name?.isEmpty == false ? p.name! : p.id).tag(String?(p.id))
                }
              }
              .labelsHidden()
              .frame(maxWidth: .infinity, alignment: .trailing)
              .onChange(of: vm.activeCodexProviderId) { newVal in
                Task { await vm.applyActiveCodexProvider(newVal) }
              }
            }
            GridRow {
              Text("Default Model").font(.subheadline).fontWeight(.medium)
              HStack(spacing: 8) {
                TextField("gpt-5.2-codex", text: $vm.defaultCodexModel)
                  .onSubmit { Task { await vm.applyDefaultCodexModel() } }
                let ids = vm.catalogModelIdsForActiveCodex()
                if !ids.isEmpty {
                  Menu {
                    ForEach(ids, id: \.self) { mid in
                      Button(mid) {
                        vm.defaultCodexModel = mid
                        Task { await vm.applyDefaultCodexModel() }
                      }
                    }
                  } label: {
                    Label("From Catalog", systemImage: "chevron.down")
                  }
                }
              }
              .frame(maxWidth: .infinity, alignment: .trailing)
            }
          }
        }
        GroupBox("Claude Code") {
          Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
            GridRow {
              Text("Active Provider").font(.subheadline).fontWeight(.medium)
              Picker("", selection: $vm.activeClaudeProviderId) {
                Text("(None)").tag(String?.none)
                ForEach(vm.providers, id: \.id) { p in
                  Text(p.name?.isEmpty == false ? p.name! : p.id).tag(String?(p.id))
                }
              }
              .labelsHidden()
              .frame(maxWidth: .infinity, alignment: .trailing)
              .onChange(of: vm.activeClaudeProviderId) { newVal in
                Task { await vm.applyActiveClaudeProvider(newVal) }
              }
            }
          }
        }
        Text(vm.lastError ?? "").foregroundStyle(.red)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 8)
    }
  }

}

// MARK: - Editor Sheet (Standard vs Advanced)
private struct ProviderEditorSheet: View {
  @ObservedObject var vm: ProvidersVM
  @Environment(\.dismiss) private var dismiss
  @State private var selectedTab: EditorTab = .basic
  @State private var isTesting: Bool = false
  @State private var selectedModelRowIDs: Set<UUID> = []
  @State private var showDeleteSelectedModelsAlert: Bool = false

  private enum EditorTab { case basic, models }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .firstTextBaseline) {
        Text(vm.isNewProvider ? "New Provider" : "Edit Provider").font(.title3).fontWeight(
          .semibold)
        Spacer()
      }
      TabView(selection: $selectedTab) {
        SettingsTabContent { basicTab }
          .tabItem { Label("Basic", systemImage: "slider.horizontal.3") }
          .tag(EditorTab.basic)
        SettingsTabContent { modelsTab }
          .tabItem { Label("Models", systemImage: "list.bullet.rectangle") }
          .tag(EditorTab.models)
      }
      .frame(minHeight: 260)
      if selectedTab == .basic {
        if let result = vm.testResultText, !result.isEmpty {
          Text(result)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if let error = vm.lastError, !error.isEmpty {
          Text(error).foregroundStyle(.red)
        }
      }
      HStack {
        if selectedTab == .basic {
          Button {
            if !isTesting {
              isTesting = true
              Task {
                await vm.testEditingFields()
                isTesting = false
              }
            }
          } label: {
            if isTesting { ProgressView().controlSize(.small) } else { Text("Test") }
          }
          .buttonStyle(.bordered)
          .disabled(isTesting)
        }
        Spacer()
        Button("Cancel") { dismiss() }
        Button("Save") {
          Task {
            if await vm.saveEditing() {
              dismiss()
            }
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!vm.canSave)
      }
    }
    .padding(16)
    .frame(
      minWidth: 640,
      idealWidth: 760,
      maxWidth: .infinity,
      minHeight: 360,
      idealHeight: 420,
      maxHeight: .infinity,
      alignment: .topLeading
    )
    .frame(maxHeight: .infinity, alignment: .topLeading)
    .onAppear { vm.loadModelRowsFromSelected() }
  }

  private var basicTab: some View {
    VStack(alignment: .leading, spacing: 12) {
      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
        GridRow {
          VStack(alignment: .leading, spacing: 4) {
            Text("Name").font(.subheadline).fontWeight(.medium)
            Text("Display label shown in lists.").font(.caption).foregroundStyle(.secondary)
          }
          TextField("Provider name", text: vm.binding(for: \.providerName))
        }
        GridRow {
          VStack(alignment: .leading, spacing: 4) {
            Text("Codex Base URL").font(.subheadline).fontWeight(.medium)
            Text("OpenAI-compatible endpoint").font(.caption).foregroundStyle(.secondary)
          }
          TextField("https://api.example.com/v1", text: vm.binding(for: \.codexBaseURL))
        }
        GridRow {
          VStack(alignment: .leading, spacing: 4) {
            Text("Claude Base URL").font(.subheadline).fontWeight(.medium)
            Text("Anthropic-compatible endpoint").font(.caption).foregroundStyle(.secondary)
          }
          TextField("https://gateway.example.com/anthropic", text: vm.binding(for: \.claudeBaseURL))
        }
        GridRow {
          VStack(alignment: .leading, spacing: 4) {
            Text("API Key Env").font(.subheadline).fontWeight(.medium)
            Text("Environment variable name")
              .font(.caption).foregroundStyle(.secondary)
          }
          HStack {
            TextField("OPENAI_API_KEY", text: vm.binding(for: \.codexEnvKey))
            if let keyURL = vm.providerKeyURL {
              Link("Get Key", destination: keyURL)
                .font(.caption)
                .help("Open provider API key management page")
            }
          }
        }
        GridRow {
          VStack(alignment: .leading, spacing: 4) {
            Text("Wire API").font(.subheadline).fontWeight(.medium)
            Text("Protocol for Codex CLI")
              .font(.caption).foregroundStyle(.secondary)
          }
          Picker("", selection: vm.binding(for: \.codexWireAPI)) {
            Text("Chat").tag("chat")
            Text("Responses").tag("responses")
          }
          .pickerStyle(.segmented)
        }
      }
      if let docs = vm.providerDocsURL {
        Link("View API documentation", destination: docs)
          .font(.caption)
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  private var modelsTab: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Models").font(.subheadline).fontWeight(.medium)
        Spacer()
        HStack(spacing: 0) {
          Button {
            vm.addModelRow()
          } label: {
            Text("+")
              .frame(width: 18, height: 16)
          }
          .buttonStyle(.bordered)

          Button {
            if !selectedModelRowIDs.isEmpty { showDeleteSelectedModelsAlert = true }
          } label: {
            Text("–")
              .frame(width: 18, height: 16)
          }
          .buttonStyle(.bordered)
          .disabled(selectedModelRowIDs.isEmpty)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
      }
      Table(vm.modelRows, selection: $selectedModelRowIDs) {
        TableColumn("Default") { row in
          Toggle(
            "",
            isOn: Binding(
              get: { vm.defaultModelRowID == row.id },
              set: { isOn in
                vm.setDefaultModelRow(rowID: isOn ? row.id : nil, modelId: isOn ? row.modelId : nil)
              }
            )
          )
          .labelsHidden()
          .controlSize(.small)
          .disabled(row.modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.width(50)

        TableColumn("Model ID") { row in
          if let binding = vm.bindingModelId(for: row.id) {
            TextField("vendor model id", text: binding)
              .onChange(of: binding.wrappedValue) { newValue in
                vm.handleModelIDChange(for: row.id, newValue: newValue)
              }
          }
        }.width(min: 120, ideal: 200)

        TableColumn("Reasoning") { row in
          if let b = vm.bindingBool(for: row.id, keyPath: \.reasoning) {
            Toggle("", isOn: b).labelsHidden().controlSize(.small)
          }
        }.width(60)

        TableColumn("Tool Use") { row in
          if let b = vm.bindingBool(for: row.id, keyPath: \.toolUse) {
            Toggle("", isOn: b).labelsHidden().controlSize(.small)
          }
        }.width(50)

        TableColumn("Vision") { row in
          if let b = vm.bindingBool(for: row.id, keyPath: \.vision) {
            Toggle("", isOn: b).labelsHidden().controlSize(.small)
          }
        }.width(50)

        TableColumn("Long Ctx") { row in
          if let b = vm.bindingBool(for: row.id, keyPath: \.longContext) {
            Toggle("", isOn: b).labelsHidden().controlSize(.small)
          }
        }.width(60)

      }
      .environment(\.defaultMinListRowHeight, 26)
      .controlSize(.small)
    }
    .alert("Delete selected models?", isPresented: $showDeleteSelectedModelsAlert) {
      Button("Delete", role: .destructive) {
        for id in selectedModelRowIDs { vm.deleteModelRow(rowKey: id) }
        selectedModelRowIDs.removeAll()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This action cannot be undone.")
    }
  }

}

private struct OAuthProviderInfoSheet: View {
  let provider: LocalAuthProvider
  let isLoggedIn: Bool
  let models: [String]
  let onLogin: () -> Void
  let onLogout: () -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        LocalAuthProviderIconView(provider: provider, size: 20, cornerRadius: 4)
        Text(provider.displayName)
          .font(.headline)
        Spacer()
        Text(isLoggedIn ? "Logged in" : "Not logged in")
          .font(.caption)
          .foregroundStyle(isLoggedIn ? Color.green : Color.secondary)
      }

      if isLoggedIn {
        if models.isEmpty {
          Text("No models detected yet. Make sure CLI Proxy API is running.")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          VStack(alignment: .leading, spacing: 6) {
            Text("Available Models")
              .font(.subheadline)
              .fontWeight(.medium)
            ScrollView {
              VStack(alignment: .leading, spacing: 4) {
                ForEach(models, id: \.self) { model in
                  Text(model)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
          }
        }
      } else {
        Text("Sign in to view available models for this provider.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Divider()

      HStack {
        Button("Close") { dismiss() }
          .buttonStyle(.plain)
        Spacer()
        if isLoggedIn {
          Button("Sign Out") { onLogout() }
            .buttonStyle(.bordered)
        } else {
          Button("Upstream Login") { onLogin() }
            .buttonStyle(.borderedProminent)
        }
      }
    }
    .padding(16)
    .frame(width: 460)
  }
}

private struct LoginPromptSheet: View {
  let prompt: CLIProxyService.LoginPrompt
  let onSubmit: (String) -> Void
  let onCancel: () -> Void
  let onStop: () -> Void

  @State private var input: String = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("\(prompt.provider.displayName) Login")
        .font(.headline)
      Text(prompt.message)
        .font(.subheadline)
        .foregroundColor(.secondary)
      if prompt.provider == .codex {
        Text("If the browser already shows “Authentication Successful”, you can keep waiting—no paste needed.")
          .font(.caption)
          .foregroundColor(.secondary)
      }
      TextField("Paste here", text: $input)
        .textFieldStyle(.roundedBorder)
        .font(.system(.body, design: .monospaced))
      HStack {
        Button("Paste") { pasteFromClipboard() }
        Spacer()
        Button("Keep Waiting") { onCancel() }
        Button("Stop Login") { onStop() }
        Button("Submit") { onSubmit(input.trimmingCharacters(in: .whitespacesAndNewlines)) }
          .buttonStyle(.borderedProminent)
      }
    }
    .padding(16)
    .frame(width: 420)
  }

  private func pasteFromClipboard() {
    let pasteboard = NSPasteboard.general
    if let value = pasteboard.string(forType: .string) {
      input = value
    }
  }
}

// MARK: - ViewModel (Codex-first)
@MainActor
final class ProvidersVM: ObservableObject {

  @Published var providers: [ProvidersRegistryService.Provider] = []
  @Published var selectedId: String? = nil {
    didSet {
      guard selectedId != oldValue else { return }
      Task { @MainActor in
        syncEditingFieldsFromSelected()
        loadModelRowsFromSelected()
        testResultText = nil
      }
    }
  }

  // Connection fields
  @Published var providerName: String = ""
  @Published var codexBaseURL: String = ""
  @Published var codexEnvKey: String = "OPENAI_API_KEY"
  @Published var codexWireAPI: String = "chat"
  @Published var claudeBaseURL: String = ""
  @Published var canSave: Bool = false

  @Published var activeCodexProviderId: String? = nil
  @Published var defaultCodexModel: String = ""
  @Published var activeClaudeProviderId: String? = nil

  @Published var lastError: String? = nil
  @Published var testResultText: String? = nil
  @Published var showEditor: Bool = false
  @Published var isNewProvider: Bool = false

  @Published var providerKeyURL: URL? = nil
  @Published var providerDocsURL: URL? = nil

  private let registry = ProvidersRegistryService()
  private let codex = CodexConfigService()
  @Published var templates: [ProvidersRegistryService.Provider] = []

  func loadAll() async {
    await registry.migrateFromCodexIfNeeded(codex: codex)
    await reload()
  }

  func loadTemplates() async {
    let list = await registry.listBundledProviders()
    func display(_ p: ProvidersRegistryService.Provider) -> String {
      (p.name?.isEmpty == false ? p.name! : p.id).lowercased()
    }
    let sorted = list.sorted { display($0) < display($1) }
    await MainActor.run { templates = sorted }
  }

  func reload() async {
    // Only show user-added providers in list to avoid confusion
    let list = await registry.listProviders()
    providers = list
    let bindings = await registry.getBindings()
    activeCodexProviderId =
      bindings.activeProvider?[ProvidersRegistryService.Consumer.codex.rawValue]
    defaultCodexModel =
      bindings.defaultModel?[ProvidersRegistryService.Consumer.codex.rawValue] ?? ""
    activeClaudeProviderId =
      bindings.activeProvider?[ProvidersRegistryService.Consumer.claudeCode.rawValue]

    // If current selectedId is not in the list anymore, select the first one or clear
    if let currentId = selectedId, !list.contains(where: { $0.id == currentId }) {
      selectedId = list.first?.id
    } else if selectedId == nil {
      selectedId = list.first?.id
    }

    syncEditingFieldsFromSelected()
    loadModelRowsFromSelected()
  }

  private func syncEditingFieldsFromSelected() {
    guard let sel = selectedId, let provider = providers.first(where: { $0.id == sel }) else {
      DispatchQueue.main.async {
        self.providerName = ""
        self.codexBaseURL = ""
        self.codexEnvKey = "OPENAI_API_KEY"
        self.codexWireAPI = "chat"
        self.claudeBaseURL = ""
        self.defaultModelId = nil
        self.recomputeCanSave()
      }
      return
    }
    let name = provider.name ?? ""
    let codexConnector = provider.connectors[ProvidersRegistryService.Consumer.codex.rawValue]
    let claudeConnector = provider.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue]
    let codexBase = codexConnector?.baseURL ?? ""
    let envKey =
      provider.envKey ?? codexConnector?.envKey ?? claudeConnector?.envKey ?? "OPENAI_API_KEY"
    let wireAPI = normalizedWireAPI(codexConnector?.wireAPI)
    let claudeBase = claudeConnector?.baseURL ?? ""

    DispatchQueue.main.async {
      self.providerName = name
      self.codexBaseURL = codexBase
      self.codexEnvKey = envKey
      self.codexWireAPI = wireAPI
      self.claudeBaseURL = claudeBase
      // For prebuilt-like providers, supply Get Key / Docs links by matching templates by baseURL
      self.applyTemplateMetadataForCurrent(provider: provider)
      self.recomputeCanSave()
    }
  }

  func editingProviderBinding() -> ProvidersRegistryService.Provider? {
    guard let sel = selectedId else { return nil }
    return providers.first(where: { $0.id == sel })
  }

  // MARK: - Models directory editing
  struct ModelRow: Identifiable, Hashable {
    var key: UUID = UUID()
    var id: UUID { key }
    var modelId: String
    var reasoning: Bool
    var toolUse: Bool
    var vision: Bool
    var longContext: Bool
  }
  @Published var modelRows: [ModelRow] = []
  @Published var defaultModelId: String?
  @Published var defaultModelRowID: UUID? = nil

  func loadModelRowsFromSelected() {
    // When creating from a template, modelRows are already seeded; avoid clearing.
    if isNewProvider { return }
    guard let sel = selectedId, let p = providers.first(where: { $0.id == sel }) else {
      DispatchQueue.main.async {
        self.modelRows = []
      }
      return
    }
    let rows: [ModelRow] = (p.catalog?.models ?? []).map { me in
      let c = me.caps
      return ModelRow(
        modelId: me.vendorModelId,
        reasoning: c?.reasoning ?? false,
        toolUse: c?.tool_use ?? false,
        vision: c?.vision ?? false,
        longContext: c?.long_context ?? false
      )
    }

    let matchingRow = providerDefaultModel(from: p).flatMap { model in
      rows.first(where: { $0.modelId == model })
    }
    let firstNonEmpty = rows.first(where: { !$0.modelId.isEmpty })

    DispatchQueue.main.async {
      self.modelRows = rows
      if let match = matchingRow {
        self.defaultModelRowID = match.id
        self.defaultModelId = match.modelId
      } else if let first = firstNonEmpty {
        self.defaultModelRowID = first.id
        self.defaultModelId = first.modelId
      } else {
        self.defaultModelRowID = nil
        self.defaultModelId = nil
      }
      self.normalizeDefaultSelection()
    }
  }

  // MARK: - Bindings for Table cells
  func indexForRow(_ id: UUID) -> Int? { modelRows.firstIndex(where: { $0.id == id }) }

  func bindingModelId(for id: UUID) -> Binding<String>? {
    guard let idx = indexForRow(id) else { return nil }
    return Binding<String>(
      get: { self.modelRows[idx].modelId },
      set: { newVal in
        self.modelRows[idx].modelId = newVal
        self.handleModelIDChange(for: id, newValue: newVal)
      }
    )
  }

  func bindingBool(for id: UUID, keyPath: WritableKeyPath<ModelRow, Bool>) -> Binding<Bool>? {
    guard let idx = indexForRow(id) else { return nil }
    return Binding<Bool>(
      get: { self.modelRows[idx][keyPath: keyPath] },
      set: { newVal in self.modelRows[idx][keyPath: keyPath] = newVal }
    )
  }

  private func providerDefaultModel(from provider: ProvidersRegistryService.Provider) -> String? {
    if let recommended = provider.recommended?.defaultModelFor?[
      ProvidersRegistryService.Consumer.codex.rawValue], !recommended.isEmpty
    {
      return recommended
    }
    if let alias = provider.connectors[ProvidersRegistryService.Consumer.codex.rawValue]?
      .modelAliases?["default"], !alias.isEmpty
    {
      return alias
    }
    if let first = provider.catalog?.models?.first?.vendorModelId {
      return first
    }
    return nil
  }

  func setDefaultModelRow(rowID: UUID?, modelId: String?) {
    defaultModelRowID = rowID
    let trimmed = modelId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    defaultModelId = trimmed.isEmpty ? nil : trimmed
    normalizeDefaultSelection()
  }

  func handleModelIDChange(for rowID: UUID, newValue: String) {
    guard defaultModelRowID == rowID else { return }
    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
    defaultModelId = trimmed.isEmpty ? nil : trimmed
    normalizeDefaultSelection()
  }

  private func normalizeDefaultSelection() {
    if modelRows.isEmpty {
      DispatchQueue.main.async {
        self.defaultModelRowID = nil
        self.defaultModelId = nil
      }
      return
    }
    if let rowID = defaultModelRowID,
      let current = modelRows.first(where: { $0.id == rowID }),
      !current.modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      DispatchQueue.main.async {
        self.defaultModelId = current.modelId.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      return
    }
    if let defined = defaultModelId,
      let match = modelRows.first(where: { $0.modelId == defined })
    {
      DispatchQueue.main.async {
        self.defaultModelRowID = match.id
        self.defaultModelId = match.modelId
      }
      return
    }
    if let fallback = modelRows.first(where: {
      !$0.modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }) {
      DispatchQueue.main.async {
        self.defaultModelRowID = fallback.id
        self.defaultModelId = fallback.modelId.trimmingCharacters(in: .whitespacesAndNewlines)
      }
    } else {
      DispatchQueue.main.async {
        self.defaultModelRowID = nil
        self.defaultModelId = nil
      }
    }
  }

  private func resolvedDefaultModel(from models: [ProvidersRegistryService.ModelEntry]) -> String? {
    let ids = models.map { $0.vendorModelId }
    if let current = defaultModelId?.trimmingCharacters(in: .whitespacesAndNewlines),
      !current.isEmpty, ids.contains(current)
    {
      return current
    }
    return ids.first
  }

  func addModelRow() {
    let row = ModelRow(
      modelId: "", reasoning: false, toolUse: false, vision: false, longContext: false)
    modelRows.append(row)
    normalizeDefaultSelection()
  }
  func deleteModelRow(rowKey: UUID) {
    modelRows.removeAll { $0.id == rowKey }
    normalizeDefaultSelection()
  }

  func binding(for keyPath: ReferenceWritableKeyPath<ProvidersVM, String>) -> Binding<String> {
    Binding<String>(
      get: { self[keyPath: keyPath] },
      set: { newVal in
        self[keyPath: keyPath] = newVal
        self.recomputeCanSave()
        self.testResultText = nil
      })
  }

  private func normalizedWireAPI(_ value: String?) -> String {
    let lowered = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    switch lowered {
    case "responses": return "responses"
    default: return "chat"
    }
  }

  // Preset helpers removed; providers are now sourced from bundled providers.json

  private func recomputeCanSave() {
    let codex = codexBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let claude = claudeBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let env = codexEnvKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let newValue = !env.isEmpty && (!codex.isEmpty || !claude.isEmpty)
    DispatchQueue.main.async {
      self.canSave = newValue
    }
  }

  @discardableResult
  func saveEditing() async -> Bool {
    lastError = nil
    guard let sel = selectedId else {
      lastError = "No provider selected"
      return false
    }

    // Handle new provider creation
    if isNewProvider {
      return await saveNewProvider()
    }

    guard var p = providers.first(where: { $0.id == sel }) else {
      lastError = "Missing provider"
      return false
    }
    let trimmedName = providerName.trimmingCharacters(in: .whitespacesAndNewlines)
    p.name = trimmedName.isEmpty ? nil : trimmedName
    var conn =
      p.connectors[ProvidersRegistryService.Consumer.codex.rawValue]
      ?? .init(
        baseURL: nil, wireAPI: nil, envKey: nil, queryParams: nil, httpHeaders: nil,
        envHttpHeaders: nil, requestMaxRetries: nil, streamMaxRetries: nil,
        streamIdleTimeoutMs: nil, modelAliases: nil)
    let trimmedCodexBase = codexBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedEnv = codexEnvKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedWire = normalizedWireAPI(codexWireAPI)
    conn.baseURL = trimmedCodexBase.isEmpty ? nil : trimmedCodexBase
    // Use provider-level envKey; avoid duplicating at connector level
    p.envKey = trimmedEnv.isEmpty ? nil : trimmedEnv
    conn.envKey = nil
    conn.wireAPI = normalizedWire
    p.connectors[ProvidersRegistryService.Consumer.codex.rawValue] = conn
    var cconn =
      p.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue]
      ?? .init(
        baseURL: nil, wireAPI: nil, envKey: nil, queryParams: nil, httpHeaders: nil,
        envHttpHeaders: nil, requestMaxRetries: nil, streamMaxRetries: nil,
        streamIdleTimeoutMs: nil, modelAliases: nil)
    let trimmedClaudeBase = claudeBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    cconn.baseURL = trimmedClaudeBase.isEmpty ? nil : trimmedClaudeBase
    cconn.envKey = nil
    p.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue] = cconn
    let cleanedModels: [ProvidersRegistryService.ModelEntry] = modelRows.compactMap { r in
      let trimmed = r.modelId.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { return nil }
      let caps = ProvidersRegistryService.ModelCaps(
        reasoning: r.reasoning, tool_use: r.toolUse, vision: r.vision, long_context: r.longContext,
        code_tuned: nil, tps_hint: nil, max_output_tokens: nil
      )
      return ProvidersRegistryService.ModelEntry(vendorModelId: trimmed, caps: caps, aliases: nil)
    }
    p.catalog =
      cleanedModels.isEmpty ? nil : ProvidersRegistryService.Catalog(models: cleanedModels)
    normalizeDefaultSelection()
    let defaultModel = resolvedDefaultModel(from: cleanedModels)
    defaultModelId = defaultModel
    var updatedRecommended: ProvidersRegistryService.Recommended?
    if var recommended = p.recommended {
      var defaults = recommended.defaultModelFor ?? [:]
      let codexKey = ProvidersRegistryService.Consumer.codex.rawValue
      let claudeKey = ProvidersRegistryService.Consumer.claudeCode.rawValue
      if let defaultModel {
        defaults[codexKey] = defaultModel
        defaults[claudeKey] = defaultModel
      } else {
        defaults.removeValue(forKey: codexKey)
        defaults.removeValue(forKey: claudeKey)
      }
      recommended.defaultModelFor = defaults.isEmpty ? nil : defaults
      updatedRecommended = recommended.defaultModelFor == nil ? nil : recommended
    } else if let defaultModel {
      updatedRecommended = ProvidersRegistryService.Recommended(defaultModelFor: [
        ProvidersRegistryService.Consumer.codex.rawValue: defaultModel,
        ProvidersRegistryService.Consumer.claudeCode.rawValue: defaultModel,
      ])
    }
    p.recommended = updatedRecommended
    do {
      try await registry.upsertProvider(p)
      if activeCodexProviderId == p.id {
        try await registry.setDefaultModel(.codex, modelId: defaultModel)
        do {
          try await codex.setTopLevelString("model", value: defaultModel)
        } catch {
          lastError = "Failed to write model to Codex config"
        }
      }
      if activeClaudeProviderId == p.id {
        try await registry.setDefaultModel(.claudeCode, modelId: defaultModel)
      }
      await syncActiveCodexProviderIfNeeded(with: p)
      await reload()
      return true
    } catch {
      lastError = "Save failed: \(error.localizedDescription)"
      return false
    }
  }

  private func saveNewProvider() async -> Bool {
    let trimmedName = providerName.trimmingCharacters(in: .whitespacesAndNewlines)
    let list = await registry.listAllProviders()
    let baseSlug = slugify(trimmedName.isEmpty ? "provider" : trimmedName)
    var candidate = baseSlug
    var n = 2
    while list.contains(where: { $0.id == candidate }) {
      candidate = "\(baseSlug)-\(n)"
      n += 1
    }

    var connectors: [String: ProvidersRegistryService.Connector] = [:]
    let trimmedCodexBase = codexBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedEnv = codexEnvKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedWire = normalizedWireAPI(codexWireAPI)

    if !trimmedCodexBase.isEmpty || !trimmedEnv.isEmpty {
      connectors[ProvidersRegistryService.Consumer.codex.rawValue] = .init(
        baseURL: trimmedCodexBase.isEmpty ? nil : trimmedCodexBase,
        wireAPI: normalizedWire,
        envKey: nil,
        queryParams: nil, httpHeaders: nil, envHttpHeaders: nil,
        requestMaxRetries: nil, streamMaxRetries: nil, streamIdleTimeoutMs: nil, modelAliases: nil
      )
    }

    let trimmedClaudeBase = claudeBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedClaudeBase.isEmpty || !trimmedEnv.isEmpty {
      let cconn = ProvidersRegistryService.Connector(
        baseURL: trimmedClaudeBase.isEmpty ? nil : trimmedClaudeBase,
        wireAPI: nil,
        envKey: nil,
        queryParams: nil, httpHeaders: nil, envHttpHeaders: nil,
        requestMaxRetries: nil, streamMaxRetries: nil, streamIdleTimeoutMs: nil, modelAliases: nil
      )
      connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue] = cconn
    }

    let cleanedModels: [ProvidersRegistryService.ModelEntry] = modelRows.compactMap { r in
      let trimmed = r.modelId.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { return nil }
      let caps = ProvidersRegistryService.ModelCaps(
        reasoning: r.reasoning, tool_use: r.toolUse, vision: r.vision, long_context: r.longContext,
        code_tuned: nil, tps_hint: nil, max_output_tokens: nil
      )
      return ProvidersRegistryService.ModelEntry(vendorModelId: trimmed, caps: caps, aliases: nil)
    }

    let catalog =
      cleanedModels.isEmpty ? nil : ProvidersRegistryService.Catalog(models: cleanedModels)
    normalizeDefaultSelection()
    let defaultModel = resolvedDefaultModel(from: cleanedModels)
    defaultModelId = defaultModel
    var recommended: ProvidersRegistryService.Recommended?
    if let defaultModel {
      recommended = ProvidersRegistryService.Recommended(defaultModelFor: [
        ProvidersRegistryService.Consumer.codex.rawValue: defaultModel,
        ProvidersRegistryService.Consumer.claudeCode.rawValue: defaultModel,
      ])
    }

    var provider = ProvidersRegistryService.Provider(
      id: candidate,
      name: trimmedName.isEmpty ? nil : trimmedName,
      class: "openai-compatible",
      managedByCodMate: true,
      envKey: trimmedEnv.isEmpty ? nil : trimmedEnv,
      connectors: connectors,
      catalog: catalog,
      recommended: recommended
    )
    // Clear connector-level envKey to avoid duplication; prefer provider-level envKey
    for key in [
      ProvidersRegistryService.Consumer.codex.rawValue,
      ProvidersRegistryService.Consumer.claudeCode.rawValue,
    ] {
      if var c = provider.connectors[key] {
        c.envKey = nil
        provider.connectors[key] = c
      }
    }

    do {
      try await registry.upsertProvider(provider)
      await syncActiveCodexProviderIfNeeded(with: provider)
      isNewProvider = false
      await reload()
      selectedId = candidate
      return true
    } catch {
      lastError = "Save failed: \(error.localizedDescription)"
      return false
    }
  }

  // MARK: - Test editing fields (before save)
  func testEditingFields() async {
    lastError = nil
    testResultText = nil
    let codexURL = codexBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let claudeURL = claudeBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !codexURL.isEmpty || !claudeURL.isEmpty else {
      testResultText = "No URLs to test"
      return
    }
    var lines: [String] = []
    if !codexURL.isEmpty {
      let result = await evaluateEndpoint(label: "Codex", urlString: codexURL)
      lines.append(formattedLine(for: result))
    }
    if !claudeURL.isEmpty {
      let result = await evaluateEndpoint(label: "Claude", urlString: claudeURL)
      lines.append(formattedLine(for: result))
    }
    testResultText = lines.isEmpty ? "No URLs to test" : lines.joined(separator: "\n")
  }

  // Catalog helpers
  func catalogModelIdsForActiveCodex() -> [String] {
    let ap = activeCodexProviderId
    guard let id = ap, let p = providers.first(where: { $0.id == id }) else { return [] }
    return (p.catalog?.models ?? []).map { $0.vendorModelId }
  }

  func setActiveCodexProvider(_ id: String?) async {
    do { try await registry.setActiveProvider(.codex, providerId: id) } catch {
      lastError = "Failed to set active: \(error.localizedDescription)"
    }
    await reload()
  }

  func applyActiveCodexProvider(_ id: String?) async {
    do {
      try await registry.setActiveProvider(.codex, providerId: id)
      if let id, let provider = providers.first(where: { $0.id == id }) {
        try await codex.applyProviderFromRegistry(provider)
      } else {
        try await codex.applyProviderFromRegistry(nil)
      }
    } catch {
      lastError = "Failed to apply active provider to Codex"
    }
    await reload()
  }

  func applyActiveClaudeProvider(_ id: String?) async {
    do {
      try await registry.setActiveProvider(.claudeCode, providerId: id)
    } catch {
      lastError = "Failed to apply active provider to Claude Code"
    }
    await reload()
  }

  func applyDefaultCodexModel() async {
    do {
      try await registry.setDefaultModel(
        .codex, modelId: defaultCodexModel.isEmpty ? nil : defaultCodexModel)
      try await codex.setTopLevelString(
        "model", value: defaultCodexModel.isEmpty ? nil : defaultCodexModel)
    } catch { lastError = "Failed to apply default model to Codex" }
    await reload()
  }

  func delete(id: String) async {
    do {
      try await registry.deleteProvider(id: id)
      if activeCodexProviderId == id {
        try await registry.setActiveProvider(.codex, providerId: nil)
        try await registry.setDefaultModel(.codex, modelId: nil)
        await syncActiveCodexProviderIfNeeded(with: nil)
      }
    } catch {
      lastError = "Delete failed: \(error.localizedDescription)"
    }
    await reload()
  }

  func addOther() { startNewProvider() }

  func startNewProvider() {
    isNewProvider = true
    selectedId = "new-provider-temp"
    // Empty for custom provider
    providerName = ""
    codexBaseURL = ""
    codexEnvKey = "OPENAI_API_KEY"
    codexWireAPI = "chat"
    claudeBaseURL = ""

    modelRows = []
    defaultModelId = nil
    defaultModelRowID = nil
    testResultText = nil
    lastError = nil
    recomputeCanSave()
    showEditor = true
  }

  func startFromTemplate(_ t: ProvidersRegistryService.Provider) {
    isNewProvider = true
    selectedId = "new-provider-temp"
    providerName = t.name ?? t.id
    let codexConnector = t.connectors[ProvidersRegistryService.Consumer.codex.rawValue]
    let claudeConnector = t.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue]
    codexBaseURL = codexConnector?.baseURL ?? ""
    codexWireAPI = normalizedWireAPI(codexConnector?.wireAPI)
    claudeBaseURL = claudeConnector?.baseURL ?? ""
    codexEnvKey = t.envKey ?? "OPENAI_API_KEY"
    // Seed catalog into rows
    modelRows = (t.catalog?.models ?? []).map { me in
      let c = me.caps
      return ModelRow(
        modelId: me.vendorModelId,
        reasoning: c?.reasoning ?? false,
        toolUse: c?.tool_use ?? false,
        vision: c?.vision ?? false,
        longContext: c?.long_context ?? false
      )
    }
    if let def = providerDefaultModel(from: t),
      let match = modelRows.first(where: { $0.modelId == def })
    {
      defaultModelRowID = match.id
      defaultModelId = match.modelId
    } else {
      defaultModelRowID = modelRows.first?.id
      defaultModelId = modelRows.first?.modelId
    }
    testResultText = nil
    lastError = nil
    // Provide helpful links on template
    applyTemplateMetadataFor(template: t)
    recomputeCanSave()
    showEditor = true
  }

  private func applyTemplateMetadataFor(template: ProvidersRegistryService.Provider) {
    let keyURL: URL? = if let s = template.keyURL, let url = URL(string: s) { url } else { nil }
    let docsURL: URL? = if let s = template.docsURL, let url = URL(string: s) { url } else { nil }

    DispatchQueue.main.async {
      self.providerKeyURL = keyURL
      self.providerDocsURL = docsURL
    }
  }

  private func applyTemplateMetadataForCurrent(provider: ProvidersRegistryService.Provider) {
    // Match by baseURL to a bundled template to surface links
    let codexBase =
      provider.connectors[ProvidersRegistryService.Consumer.codex.rawValue]?.baseURL?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let claudeBase =
      provider.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue]?.baseURL?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if let t = templates.first(where: {
      ($0.connectors[ProvidersRegistryService.Consumer.codex.rawValue]?.baseURL?.trimmingCharacters(
        in: .whitespacesAndNewlines) ?? "") == codexBase
        || ($0.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue]?.baseURL?
          .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") == claudeBase
    }) {
      applyTemplateMetadataFor(template: t)
    } else {
      DispatchQueue.main.async {
        self.providerKeyURL = nil
        self.providerDocsURL = nil
      }
    }
  }

  private func slugify(_ s: String) -> String {
    let lower = s.lowercased()
    let mapped = lower.map { (c: Character) -> Character in (c.isLetter || c.isNumber) ? c : "-" }
    var out: [Character] = []
    var lastDash = false
    for ch in mapped {
      if ch == "-" {
        if !lastDash {
          out.append(ch)
          lastDash = true
        }
      } else {
        out.append(ch)
        lastDash = false
      }
    }
    while out.first == "-" { out.removeFirst() }
    while out.last == "-" { out.removeLast() }
    return out.isEmpty ? "provider" : String(out)
  }

  private func syncActiveCodexProviderIfNeeded(with provider: ProvidersRegistryService.Provider?)
    async
  {
    let targetId = provider?.id
    if targetId == activeCodexProviderId || (provider == nil && activeCodexProviderId != nil) {
      do {
        try await codex.applyProviderFromRegistry(provider)
      } catch {
        await MainActor.run { self.lastError = "Failed to sync provider to Codex config" }
      }
    }
  }

  private struct EndpointCheck {
    let message: String
    let ok: Bool
    let statusCode: Int
  }

  private func directAPIKeyValue() -> String? {
    // Heuristic: accept direct tokens for quick testing when user pasted a key here
    // Recognize common patterns like OpenAI (sk-...), JWT-like (eyJ... or with dots),
    // or any long mixed-case string without underscores.
    let trimmed = codexEnvKey.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return nil }
    if trimmed.hasPrefix("sk-") { return trimmed }
    if trimmed.hasPrefix("eyJ") { return trimmed }  // JWT-style
    if trimmed.contains(".") && trimmed.count >= 20 { return trimmed }
    return nil
  }

  private func evaluateEndpoint(label: String, urlString: String) async -> EndpointCheck {
    guard let baseURL = URL(string: urlString) else {
      return EndpointCheck(message: "\(label): invalid URL", ok: false, statusCode: -1)
    }
    var attempts: [URL] = [baseURL]
    attempts.append(baseURL.appendingPathComponent("models"))
    attempts.append(baseURL.appendingPathComponent("status"))
    let lower = baseURL.absoluteString.lowercased()
    if lower.contains("anthropic") {
      attempts.append(baseURL.appendingPathComponent("messages"))
    } else {
      let wire = normalizedWireAPI(codexWireAPI)
      if wire == "chat" {
        attempts.append(baseURL.appendingPathComponent("chat/completions"))
      } else {
        attempts.append(baseURL.appendingPathComponent("responses"))
      }
    }
    var last = EndpointCheck(message: "\(label): request failed", ok: false, statusCode: -1)
    let token = directAPIKeyValue()
    for candidate in attempts {
      var req = URLRequest(url: candidate)
      req.httpMethod = "GET"
      if lower.contains("anthropic") {
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
      }
      if let token {
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      }
      do {
        let (_, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let isMessagesProbe = candidate.path.lowercased().contains("/messages")
        let isChatProbe =
          candidate.path.lowercased().contains("/chat/completions")
          || candidate.path.lowercased().contains("/responses")
        let allow404 =
          (isMessagesProbe && lower.contains("anthropic") && code == 404)
          || (isChatProbe && code == 404)  // Some vendors return 404 on GET for chat endpoints
        let ok = (200...299).contains(code) || code == 401 || code == 403 || code == 405 || allow404
        let message = "\(label): HTTP \(code) \(ok ? "(reachable)" : "(unexpected)")"
        let result = EndpointCheck(message: message, ok: ok, statusCode: code)
        if ok { return result }
        last = result
      } catch {
        last = EndpointCheck(
          message: "\(label): \(error.localizedDescription)", ok: false, statusCode: -1)
      }
    }
    return last
  }

  private func formattedLine(for result: EndpointCheck) -> String {
    var line = result.message
    guard !result.ok else { return line }
    switch result.statusCode {
    case 401, 403:
      line += " – Check the API key or token permissions."
    case 404:
      line +=
        " – Verify the base URL and wire API. Some vendors return 404 for a GET on the base path; Codex requires the chat endpoints to be reachable."
      if let docs = providerDocsURL {
        line += " Docs: \(docs.absoluteString)"
      }
    default:
      if let docs = providerDocsURL {
        line += " – See docs: \(docs.absoluteString)"
      }
    }
    return line
  }

}

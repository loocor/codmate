import AppKit
import Network
import SwiftUI

struct ProvidersSettingsView: View {
    @ObservedObject var preferences: SessionPreferencesStore
    @StateObject private var vm = ProvidersVM()
    @StateObject private var proxyService = CLIProxyService.shared
    @State private var pendingDeleteId: String?
    @State private var pendingDeleteName: String?
    @State private var pendingDeleteAccount: CLIProxyService.OAuthAccount?
    @State private var oauthInfoAccount: CLIProxyService.OAuthAccount?
    @State private var oauthLoginProvider: LocalAuthProvider?
    @State private var oauthAutoStartFailed: Bool = false
    @State private var pendingOAuthProvider: LocalAuthProvider?
    @State private var showOAuthRiskWarning: Bool = false
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
                        Tab("Advanced", systemImage: "gearshape.2") {
                            SettingsTabContent {
                                cliProxyAdvancedSection
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
                        SettingsTabContent {
                            cliProxyAdvancedSection
                        }
                        .tabItem { Label("Advanced", systemImage: "gearshape.2") }
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
                        // Clear test results when closing editor
                        vm.testResults = [:]
                        vm.testResultText = nil
                    }
                }
            )
        ) { ProviderEditorSheet(vm: vm, preferences: preferences) }
        .sheet(item: $oauthInfoAccount) { account in
            let accounts = proxyService.listOAuthAccounts().filter {
                $0.provider == account.provider
            }
            OAuthProviderInfoSheet(
                provider: account.provider,
                isLoggedIn: !accounts.isEmpty,
                accounts: accounts,
                selectedAccount: account,
                initialModels: modelsForOAuthProvider(account.provider),
                onLogin: { oauthLoginProvider = account.provider },
                onLogout: { account in
                    proxyService.deleteOAuthAccount(account)
                    refreshOAuthStatus()
                }
            )
        }
        .sheet(item: $oauthLoginProvider) { provider in
            OAuthLoginSheet(
                provider: provider,
                onDone: {
                    oauthLoginProvider = nil
                    Task {
                        await vm.refreshOAuthAccounts()
                        await refreshLocalModels()
                        ensureServiceRunningIfNeeded(force: true)
                    }
                },
                onCancel: {
                    proxyService.cancelLogin()
                    oauthLoginProvider = nil
                }
            )
        }
        .sheet(
            item: Binding(
                get: {
                    proxyService.loginPrompt != nil && oauthLoginProvider != nil
                        ? proxyService.loginPrompt : nil
                },
                set: { _ in proxyService.loginPrompt = nil }
            )
        ) { prompt in
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
        .alert("OAuth Provider Authorization Risk Warning", isPresented: $showOAuthRiskWarning) {
            Button("I Understand and Accept the Risk", role: .destructive) {
                confirmOAuthLogin()
            }
            Button("Cancel", role: .cancel) {
                pendingOAuthProvider = nil
            }
        } message: {
            Text(
                """
                Adding OAuth providers requires separate authorization through CLIProxyAPI, which is isolated from CodMate's main CLI authorization.

                ⚠️ **Potential Risks:**
                • Account suspension or termination by the provider
                • Violation of provider terms of service
                • Loss of access to services

                By proceeding, you acknowledge that you understand these risks and will use this feature at your own discretion.

                **Note:** The ability to add OAuth providers may be partially or fully removed in future versions of CodMate.
                """)
        }
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
        // Removed rerouteBuiltIn/reroute3P onChange handlers - all providers now use Auto-Proxy mode
        .onChange(of: preferences.oauthProvidersEnabled) { _ in
            refreshOAuthStatus()
            Task { await refreshLocalModels() }
            ensureServiceRunningIfNeeded()
        }
        .onChange(of: preferences.apiKeyProvidersEnabled) { _ in
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
                    Task { await vm.delete(id: id, preferences: preferences) }
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
        .confirmationDialog(
            "Sign Out",
            isPresented: Binding(
                get: { pendingDeleteAccount != nil },
                set: { if !$0 { pendingDeleteAccount = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) {
                if let account = pendingDeleteAccount {
                    Task { await vm.deleteOAuthAccount(account) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let email = pendingDeleteAccount?.email {
                Text("Are you sure you want to sign out \"\(email)\"? Credentials will be removed.")
            } else {
                Text("Are you sure you want to sign out? Credentials will be removed.")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Providers Settings")
                .font(.title2)
                .fontWeight(.bold)
            Text("Manage API key and OAuth providers for Codex and Claude Code.")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    // Computed properties for sorted providers
    private var sortedOAuthProviders: [LocalAuthProvider] {
        LocalAuthProvider.allCases.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private var sortedTemplates: [ProvidersRegistryService.Provider] {
        vm.templates.sorted {
            let name0 = ($0.name?.isEmpty == false ? $0.name! : $0.id).lowercased()
            let name1 = ($1.name?.isEmpty == false ? $1.name! : $1.id).lowercased()
            return name0.localizedCaseInsensitiveCompare(name1) == .orderedAscending
        }
    }

    private var providersList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // OAuth Section
                VStack(alignment: .leading, spacing: 10) {
                    Text("OAuth").font(.headline).fontWeight(.semibold)

                    if !vm.oauthAccounts.isEmpty {
                        settingsCard {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(vm.oauthAccounts.enumerated()), id: \.element.id) {
                                    index, account in
                                    if index > 0 {
                                        Divider().padding(.vertical, 4)
                                    }
                                    HStack(alignment: .center, spacing: 0) {
                                        // Left: Icon + Name
                                        HStack(alignment: .center, spacing: 8) {
                                            LocalAuthProviderIconView(
                                                provider: account.provider, size: 16,
                                                cornerRadius: 4
                                            )
                                            .frame(width: 20)
                                            Text(account.provider.displayName)
                                                .font(.body.weight(.medium))
                                        }
                                        .frame(minWidth: 140, alignment: .leading)

                                        Spacer(minLength: 16)

                                        // Center: Email/Status
                                        VStack(alignment: .leading, spacing: 2) {
                                            if let email = account.email, !email.isEmpty {
                                                Text(email)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            Text("Logged In")
                                                .font(.caption2)
                                                .foregroundStyle(.green)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                        // Right: Info + Toggle
                                        Button {
                                            oauthInfoAccount = account
                                        } label: {
                                            Image(systemName: "info.circle")
                                                .font(.body)
                                        }
                                        .buttonStyle(.borderless)
                                        .help("View details")

                                        Toggle("", isOn: bindingForOAuthAccount(account: account))
                                            .toggleStyle(.switch)
                                            .labelsHidden()
                                            .controlSize(.small)
                                            .padding(.leading, 8)
                                    }
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                                    .contextMenu {
                                        Button {
                                            oauthInfoAccount = account
                                        } label: {
                                            Text("Info")
                                        }
                                        Divider()
                                        Button(role: .destructive) {
                                            pendingDeleteAccount = account
                                        } label: {
                                            Text("Sign Out")
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        settingsCard {
                            VStack(spacing: 12) {
                                Image(systemName: "person.crop.circle.badge.plus")
                                    .font(.system(size: 32))
                                    .foregroundStyle(.secondary)
                                Text("No OAuth Accounts")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Text("Click + to add an account")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 100)
                            .padding(.vertical, 20)
                        }
                    }

                    // OAuth Add Button (Right aligned below list)
                    HStack {
                        Spacer()
                        ProviderAddMenu(
                            title: "Add OAuth Account",
                            helpText: "Add OAuth Account",
                            items: sortedOAuthProviders.map { provider in
                                ProviderMenuItem(
                                    id: provider.id,
                                    name: provider.displayName,
                                    icon: .oauth(provider),
                                    action: { startOAuthLogin(provider) }
                                )
                            }
                        )
                    }

                }

                // API Key Section
                VStack(alignment: .leading, spacing: 10) {
                    Text("API Key").font(.headline).fontWeight(.semibold)

                    if !vm.providers.isEmpty {
                        settingsCard {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(vm.providers.enumerated()), id: \.element.id) {
                                    index, p in
                                    if index > 0 {
                                        Divider().padding(.vertical, 4)
                                    }
                                    HStack(alignment: .center, spacing: 0) {
                                        // Left: Icon + Name
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
                                                value: p.connectors[
                                                    ProvidersRegistryService.Consumer.codex.rawValue
                                                ]?
                                                .baseURL
                                            )
                                            endpointBlock(
                                                label: "Claude",
                                                value: p.connectors[
                                                    ProvidersRegistryService.Consumer.claudeCode
                                                        .rawValue]?
                                                    .baseURL
                                            )
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                        // Right: Edit + Toggle
                                        Button {
                                            vm.selectedId = p.id
                                            vm.showEditor = true
                                        } label: {
                                            Image(systemName: "pencil")
                                                .font(.body)
                                        }
                                        .buttonStyle(.borderless)
                                        .help("Edit provider")

                                        Toggle("", isOn: bindingForAPIKeyProvider(providerId: p.id))
                                            .toggleStyle(.switch)
                                            .labelsHidden()
                                            .controlSize(.small)
                                            .padding(.leading, 8)
                                    }
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                                    .contextMenu {
                                        Button("Edit…") {
                                            vm.showEditor = true
                                            vm.selectedId = p.id
                                        }
                                        Divider()
                                        Button(role: .destructive) {
                                            pendingDeleteId = p.id
                                            pendingDeleteName =
                                                p.name?.isEmpty == false ? p.name : p.id
                                        } label: {
                                            Text("Delete")
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
                                Text("Click + to configure an API key provider")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 100)
                            .padding(.vertical, 20)
                        }
                    }

                    // API Key Add Button (Right aligned below list)
                    HStack {
                        Spacer()
                        ProviderAddMenu(
                            title: "Add API Key Provider",
                            helpText: "Add API Key Provider",
                            items: sortedTemplates.map { template in
                                ProviderMenuItem(
                                    id: template.id,
                                    name: template.name?.isEmpty == false
                                        ? template.name! : template.id,
                                    icon: .apiKey(template),
                                    action: { vm.startFromTemplate(template) }
                                )
                            },
                            emptyMessage: "No templates found",
                            customAction: ("Custom…", { vm.startNewProvider() })
                        )
                    }
                }
            }
            .padding(.bottom, 20)
        }
    }

    private var proxyCapabilitiesSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            // 1. CLI Proxy API Status
            VStack(alignment: .leading, spacing: 10) {
                Text("CLI Proxy API").font(.headline).fontWeight(.semibold)
                settingsCard {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                        GridRow {
                            VStack(alignment: .leading, spacing: 0) {
                                HStack(spacing: 6) {
                                    Image(systemName: "bolt.horizontal")
                                        .frame(width: 16, alignment: .leading)
                                    Text("Service Status")
                                        .font(.subheadline).fontWeight(.medium)
                                }
                                Text(
                                    "All providers are routed through CLI Proxy API when enabled in the Providers list above."
                                )
                                .font(.caption).foregroundColor(.secondary)
                                .padding(.leading, 22)
                            }
                            HStack(spacing: 8) {
                                statusPill(
                                    proxyService.isRunning ? "Running" : "Stopped",
                                    active: proxyService.isRunning)
                                if proxyService.isRunning {
                                    Button("Restart") {
                                        restartProxyService()
                                    }
                                    .buttonStyle(.bordered)
                                } else {
                                    Button("Start") {
                                        startProxyService()
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(!proxyService.isBinaryInstalled)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }

                        gridDivider
                        GridRow {
                            VStack(alignment: .leading, spacing: 0) {
                                HStack(spacing: 6) {
                                    Image(systemName: "number")
                                        .frame(width: 16, alignment: .leading)
                                    Text("Port")
                                        .font(.subheadline).fontWeight(.medium)
                                }
                                Text("Server port number for CLI Proxy API")
                                    .font(.caption).foregroundColor(.secondary)
                                    .padding(.leading, 22)
                            }
                            TextField(
                                "Port", value: $preferences.localServerPort,
                                formatter: NumberFormatter()
                            )
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 80)
                            .frame(maxWidth: .infinity, alignment: .trailing)
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
                                HStack(spacing: 6) {
                                    Text("http://\(localIP):\(String(preferences.localServerPort))")
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                    Button(action: {
                                        copyToClipboard(
                                            "http://\(localIP):\(String(preferences.localServerPort))"
                                        )
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
                                                    let trimmed = newValue.trimmingCharacters(
                                                        in: .whitespacesAndNewlines)
                                                    guard trimmed.count >= minPublicKeyLength else {
                                                        return
                                                    }
                                                    proxyService.updatePublicAPIKey(trimmed)
                                                }
                                            Button(action: { copyToClipboard(publicAPIKey) }) {
                                                Image(systemName: "doc.on.doc")
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        .frame(width: 320)
                                    }
                                    if publicAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
                                        .count
                                        < minPublicKeyLength
                                    {
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
                                Link(
                                    destination: URL(
                                        string: "https://github.com/router-for-me/CLIProxyAPI")!
                                ) {
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

    private var cliProxyAdvancedSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            // CLI Proxy API Installation & Diagnostics
            VStack(alignment: .leading, spacing: 10) {
                Text("Advanced").font(.headline).fontWeight(.semibold)
                settingsCard {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                        // Conflict warning (only show if there's a conflict)
                        if let warning = proxyService.conflictWarning {
                            GridRow {
                                HStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.orange)
                                    Text(warning)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .gridCellColumns(3)
                            }

                            gridDivider
                        }

                        GridRow {
                            VStack(alignment: .leading, spacing: 0) {
                                Label("Binary Location", systemImage: "app.badge")
                                    .font(.subheadline).fontWeight(.medium)
                                Text("CLIProxyAPI binary executable path")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Text(proxyService.binaryFilePath)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .onTapGesture(count: 2) {
                                    revealCLIProxyBinaryInFinder()
                                }
                                .help("Double-click to reveal in Finder")
                            HStack(spacing: 8) {
                                if proxyService.isInstalling {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                        .frame(width: 14, height: 14)
                                    Text("Installing")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                } else {
                                    Button(cliProxyActionButtonTitle) {
                                        Task {
                                            if proxyService.binarySource == .homebrew {
                                                try? await proxyService.brewUpgrade()
                                            } else {
                                                try? await proxyService.install()
                                            }
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(cliProxyActionButtonColor)
                                }
                            }
                            .frame(width: 90, alignment: .trailing)
                            .disabled(proxyService.isInstalling)
                        }

                        gridDivider

                        GridRow {
                            VStack(alignment: .leading, spacing: 0) {
                                Label("Config File", systemImage: "doc.text")
                                    .font(.subheadline).fontWeight(.medium)
                                Text("CLIProxyAPI configuration file")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Text(cliProxyConfigFilePath)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Button("Reveal") { revealCLIProxyConfigInFinder() }
                                .buttonStyle(.bordered)
                                .frame(width: 90, alignment: .trailing)
                        }

                        gridDivider

                        GridRow {
                            VStack(alignment: .leading, spacing: 0) {
                                Label("Auth Directory", systemImage: "folder")
                                    .font(.subheadline).fontWeight(.medium)
                                Text("OAuth credential storage")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Text(cliProxyAuthDirPath)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Button("Reveal") { revealCLIProxyAuthDirInFinder() }
                                .buttonStyle(.bordered)
                                .frame(width: 90, alignment: .trailing)
                        }

                        gridDivider

                        GridRow {
                            VStack(alignment: .leading, spacing: 0) {
                                Label("Logs", systemImage: "doc.plaintext")
                                    .font(.subheadline).fontWeight(.medium)
                                Text("CLIProxyAPI log files directory")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Text(cliProxyLogsPath)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Button("Reveal") { revealCLIProxyLogsInFinder() }
                                .buttonStyle(.bordered)
                                .frame(width: 90, alignment: .trailing)
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
        guard oauthLoginProvider == nil else { return }
        // Show risk warning before starting OAuth login
        pendingOAuthProvider = provider
        showOAuthRiskWarning = true
    }

    private func confirmOAuthLogin() {
        guard let provider = pendingOAuthProvider else { return }
        pendingOAuthProvider = nil
        oauthLoginProvider = provider
    }

    @ViewBuilder
    private func oauthStatusBadge(_ provider: LocalAuthProvider, isLoggedIn: Bool) -> some View {
        if isLoggedIn {
            Text("Logged In").font(.caption).foregroundStyle(.green)
        } else {
            Text("Logged Out").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func refreshOAuthStatus() {
        Task { await vm.refreshOAuthAccounts() }
    }

    private func ensureServiceRunningIfNeeded(force: Bool = false) {
        let hasLoggedInOAuth = !vm.oauthAccounts.isEmpty
        let hasEnabledProviders = !vm.oauthAccounts.isEmpty || !vm.providers.isEmpty
        let shouldEnsure =
            force
            || hasLoggedInOAuth
            || preferences.localServerEnabled
            || hasEnabledProviders
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
        localModels = await proxyService.fetchLocalModels(forceRefresh: true)
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

    private func builtInProvider(for model: CLIProxyService.LocalModel)
        -> LocalServerBuiltInProvider?
    {
        let hint = model.provider ?? model.source ?? model.owned_by
        if let hint,
            let provider = LocalServerBuiltInProvider.allCases.first(where: {
                $0.matchesOwnedBy(hint)
            })
        {
            return provider
        }
        let modelId = model.id
        if let provider = LocalServerBuiltInProvider.allCases.first(where: {
            $0.matchesModelId(modelId)
        }) {
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
                        getnameinfo(
                            interface?.ifa_addr, socklen_t((interface?.ifa_addr.pointee.sa_len)!),
                            &hostname,
                            socklen_t(hostname.count), nil, socklen_t(0), NI_NUMERICHOST)
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

    // MARK: - CLI Proxy API Path Helpers
    private var cliProxyConfigFilePath: String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let configPath = appSupport.appendingPathComponent("CodMate/config.yaml")
        return configPath.path
    }

    private var cliProxyAuthDirPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".codmate/auth").path
    }

    private var cliProxyLogsPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".codmate/auth/logs").path
    }

    private var cliProxyBinarySourceDescription: String {
        switch proxyService.binarySource {
        case .none:
            return "No binary detected"
        case .homebrew:
            return "Homebrew installation (managed via brew services)"
        case .codmate:
            return "CodMate built-in installation"
        case .other:
            return "Other installation (potential conflicts)"
        }
    }

    private var cliProxyBinarySourceLabel: String {
        switch proxyService.binarySource {
        case .none:
            return "Not Detected"
        case .homebrew:
            return "Homebrew"
        case .codmate:
            return "CodMate"
        case .other:
            return "Other"
        }
    }

    private var cliProxyBinarySourceColor: Color {
        switch proxyService.binarySource {
        case .none:
            return .secondary
        case .homebrew:
            return .green
        case .codmate:
            return .blue
        case .other:
            return .orange
        }
    }

    private var cliProxyActionButtonTitle: String {
        switch proxyService.binarySource {
        case .none:
            return "Install"
        case .homebrew:
            return proxyService.isBinaryInstalled ? "Upgrade" : "Install"
        case .codmate:
            return proxyService.isBinaryInstalled ? "Reinstall" : "Install"
        case .other:
            return proxyService.isBinaryInstalled ? "Reinstall" : "Install"
        }
    }

    private var cliProxyActionButtonColor: Color {
        switch proxyService.binarySource {
        case .none:
            return .blue
        case .homebrew:
            return .green
        case .codmate:
            return proxyService.isBinaryInstalled ? .red : .blue
        case .other:
            return proxyService.isBinaryInstalled ? .red : .blue
        }
    }

    private func revealCLIProxyConfigInFinder() {
        let url = URL(fileURLWithPath: cliProxyConfigFilePath)
        NSWorkspace.shared.selectFile(
            url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    }

    private func revealCLIProxyAuthDirInFinder() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let authPath = home.appendingPathComponent(".codmate/auth")
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: authPath.path)
    }

    private func revealCLIProxyLogsInFinder() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let logsPath = home.appendingPathComponent(".codmate/auth/logs")
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: logsPath.path)
    }

    private func revealCLIProxyBinaryInFinder() {
        let url = URL(fileURLWithPath: proxyService.binaryFilePath)
        NSWorkspace.shared.selectFile(
            url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
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
                                    Text(p.name?.isEmpty == false ? p.name! : p.id).tag(
                                        String?(p.id))
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
                                    Text(p.name?.isEmpty == false ? p.name! : p.id).tag(
                                        String?(p.id))
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

    private func bindingForOAuthAccount(account: CLIProxyService.OAuthAccount) -> Binding<Bool> {
        Binding(
            get: { preferences.oauthAccountsEnabled.contains(account.id) },
            set: { newValue in
                var enabled = preferences.oauthAccountsEnabled
                if newValue {
                    enabled.insert(account.id)
                } else {
                    enabled.remove(account.id)
                }
                preferences.oauthAccountsEnabled = enabled

                // Note: CLI Proxy API's Management API does not provide an endpoint to enable/disable auth files
                // The enabled/disabled state is managed locally via oauthAccountsEnabled setting
                // CLIProxyAPI will load all auth files, and CodMate filters which ones to use based on local settings
            }
        )
    }

    private func bindingForAPIKeyProvider(providerId: String) -> Binding<Bool> {
        Binding(
            get: { preferences.apiKeyProvidersEnabled.contains(providerId) },
            set: { newValue in
                var enabled = preferences.apiKeyProvidersEnabled
                if newValue {
                    enabled.insert(providerId)
                } else {
                    enabled.remove(providerId)
                }
                preferences.apiKeyProvidersEnabled = enabled

                // Sync third-party providers to CLIProxyAPI config
                // Only enabled providers will be written to config.yaml
                Task {
                    await CLIProxyService.shared.syncThirdPartyProviders(
                        enabledProviderIds: enabled)
                    // Refresh local models immediately after config sync
                    await self.refreshLocalModels()
                }
            }
        )
    }

}

// MARK: - Editor Sheet (Standard vs Advanced)
private struct ProviderEditorSheet: View {
    @ObservedObject var vm: ProvidersVM
    @ObservedObject var preferences: SessionPreferencesStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: EditorTab = .basic
    @State private var isTesting: Bool = false
    @State private var selectedModelRowIDs: Set<UUID> = []
    @State private var showDeleteSelectedModelsAlert: Bool = false
    @State private var showAPIKey: Bool = false

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
                // Enhanced test results UI
                if !vm.testResults.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(vm.testResults.keys.sorted()), id: \.self) { endpoint in
                            if let result = vm.testResults[endpoint] {
                                TestResultCard(label: endpoint, result: result)
                            }
                        }
                    }
                    .padding(.top, 8)
                } else if let text = vm.testResultText, !text.isEmpty {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let error = vm.lastError, !error.isEmpty {
                    Text(error).foregroundStyle(.red).font(.caption)
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
                        if await vm.saveEditing(preferences: preferences) {
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
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .onAppear { vm.loadModelRowsFromSelected() }
    }

    private var basicTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                // Icon picker (only for user-created providers, not bundled/preset providers)
                // Bundled providers (Anthropic, DeepSeek, GLM, K2, MiniMax, OpenAI, OpenRouter) use preset brand icons
                if vm.isNewProvider
                    || (!vm.isEditingBundledProvider()
                        && vm.editingProviderBinding()?.managedByCodMate == true)
                {
                    GridRow {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Icon").font(.subheadline).fontWeight(.medium)
                            Text(
                                vm.presetIconName != nil
                                    ? "Provider configured icon"
                                    : "SF Symbol icon for this provider"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        iconPickerView
                    }
                }
                GridRow {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Name").font(.subheadline).fontWeight(.medium)
                        Text("Display label shown in lists.").font(.caption).foregroundStyle(
                            .secondary)
                    }
                    TextField("Provider name", text: vm.binding(for: \.providerName))
                }
                GridRow {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Codex Base URL").font(.subheadline).fontWeight(.medium)
                        Text("OpenAI-compatible endpoint").font(.caption).foregroundStyle(
                            .secondary)
                    }
                    TextField("https://api.example.com/v1", text: vm.binding(for: \.codexBaseURL))
                }
                GridRow {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Claude Base URL").font(.subheadline).fontWeight(.medium)
                        Text("Anthropic-compatible endpoint").font(.caption).foregroundStyle(
                            .secondary)
                    }
                    TextField(
                        "https://gateway.example.com/anthropic",
                        text: vm.binding(for: \.claudeBaseURL))
                }
                GridRow {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("API Key Env").font(.subheadline).fontWeight(.medium)
                        Text("Environment variable name")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Group {
                            if showAPIKey {
                                TextField("OPENAI_API_KEY", text: vm.binding(for: \.codexEnvKey))
                            } else {
                                SecureField("OPENAI_API_KEY", text: vm.binding(for: \.codexEnvKey))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .trailing) {
                            Button {
                                showAPIKey.toggle()
                            } label: {
                                Image(systemName: showAPIKey ? "eye.slash.fill" : "eye.fill")
                                    .foregroundStyle(.secondary)
                                    .font(.body)
                            }
                            .buttonStyle(.plain)
                            .help(showAPIKey ? "Hide API key" : "Show API key")
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background {
                                // 添加背景确保图标在文本之上清晰可见
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                            }
                            .zIndex(1)
                        }
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

    @State private var showIconPicker = false

    private var iconPickerView: some View {
        HStack(spacing: 8) {
            // If preset icon exists, show read-only icon display
            if vm.presetIconName != nil {
                if let presetIconName = vm.presetIconName,
                    let nsImage = ProviderIconThemeHelper.menuImage(
                        named: presetIconName, size: NSSize(width: 18, height: 18))
                {
                    Image(nsImage: nsImage)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 18, height: 18)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                        )
                }
            } else {
                // Icon display button (only for custom providers)
                Button {
                    showIconPicker = true
                } label: {
                    HStack(spacing: 6) {
                        // Custom SF Symbol icon
                        if let iconName = vm.customIcon
                            ?? defaultIconForProviderName(vm.providerName)
                        {
                            Image(systemName: iconName)
                                .font(.system(size: 18))
                                .frame(width: 18, height: 18)
                        }
                        // Fallback: Empty circle
                        else {
                            Circle()
                                .fill(Color.secondary.opacity(0.2))
                                .frame(width: 18, height: 18)
                        }
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showIconPicker, arrowEdge: .bottom) {
                    iconPickerPopover
                }
            }
        }
    }

    private var iconPickerPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Select Icon")
                .font(.headline)
                .padding(.top, 16)

            Divider()

            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(40), spacing: 8), count: 6), spacing: 8
            ) {
                ForEach(sfSymbolsIndices, id: \.self) { iconName in
                    Button {
                        vm.customIcon = iconName
                        vm.presetIconName = nil  // Clear preset icon when user selects custom SF Symbol
                        showIconPicker = false
                    } label: {
                        Image(systemName: iconName)
                            .font(.system(size: 24))
                            .frame(width: 40, height: 40)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(height: 280)
        }
        .frame(width: 350)
        .padding(.bottom, 16)
        .padding(.horizontal, 16)
    }

    // SF Symbols indices (letter-based icons)
    private var sfSymbolsIndices: [String] {
        let letters = "abcdefghijklmnopqrstuvwxyz"
        return letters.map { "\($0).circle.fill" }
    }

    // Generate default icon from first letter of provider name
    private func defaultIconForProviderName(_ name: String) -> String? {
        guard let firstChar = name.lowercased().first, firstChar.isLetter else {
            return nil
        }
        return "\(firstChar).circle.fill"
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
                                vm.setDefaultModelRow(
                                    rowID: isOn ? row.id : nil, modelId: isOn ? row.modelId : nil)
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
    let accounts: [CLIProxyService.OAuthAccount]
    let selectedAccount: CLIProxyService.OAuthAccount
    let initialModels: [String]
    let onLogin: () -> Void
    let onLogout: (CLIProxyService.OAuthAccount) -> Void

    @StateObject private var proxyService = CLIProxyService.shared
    @State private var models: [String] = []
    @State private var isRefreshing: Bool = false
    @State private var accountInfo: AccountInfo?
    @State private var isHoveringModels: Bool = false
    @Environment(\.dismiss) private var dismiss

    struct AccountInfo {
        let email: String?
        let planType: String?
        let planChecked: Bool
        let accountType: String?
        let organization: String?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                LocalAuthProviderIconView(provider: provider, size: 20, cornerRadius: 4)
                Text(provider.displayName)
                    .font(.headline)
                Spacer()
                if isLoggedIn {
                    Button {
                        refreshModels()
                    } label: {
                        if isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.body)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isRefreshing)
                    .help("Refresh models")
                } else {
                    Text("Not logged in")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if isLoggedIn {
                // Account Status Section
                if let info = accountInfo {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Account Status")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        VStack(alignment: .leading, spacing: 4) {
                            if let email = info.email {
                                HStack(spacing: 4) {
                                    Text("Email:")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(email)
                                        .font(.caption)
                                }
                            }
                            if let planType = info.planType, !planType.isEmpty {
                                HStack(spacing: 4) {
                                    Text("Plan:")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(planType)
                                        .font(.caption)
                                        .fontWeight(.medium)
                                        .foregroundStyle(.primary)
                                }
                            } else {
                                // Show "Loading..." or "Unknown" if plan is being fetched
                                HStack(spacing: 4) {
                                    Text("Plan:")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(info.planChecked ? "Unknown" : "Checking...")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .italic()
                                }
                            }
                            if let accountType = info.accountType {
                                HStack(spacing: 4) {
                                    Text("Type:")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(accountType)
                                        .font(.caption)
                                }
                            }
                            if let org = info.organization {
                                HStack(spacing: 4) {
                                    Text("Organization:")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(org)
                                        .font(.caption)
                                }
                            }
                        }
                    }
                    Divider()
                }

                // Models Section
                if models.isEmpty {
                    Text("No models detected yet. Make sure CLI Proxy API is running.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Available Models")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Spacer()
                        }
                        ZStack(alignment: .topTrailing) {
                            ScrollView {
                                Text(models.joined(separator: "\n"))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.trailing, isHoveringModels ? 28 : 0)
                            }
                            .frame(maxHeight: 200)

                            if isHoveringModels {
                                Button {
                                    copyModelsToClipboard()
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Copy all models to clipboard")
                                .padding(4)
                            }
                        }
                        .onHover { hovering in
                            isHoveringModels = hovering
                        }
                    }
                }
            } else {
                Text("Sign in to view available models for this provider.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                if isLoggedIn {
                    Button("Sign Out") {
                        // Use the selected account instead of always using the first one
                        onLogout(selectedAccount)
                    }
                    .buttonStyle(.bordered)
                    .focusable(false)
                } else {
                    Button("Upstream Login") { onLogin() }
                        .buttonStyle(.borderedProminent)
                        .focusable(false)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.plain)
                    .focusable(false)
            }
        }
        .padding(16)
        .frame(width: 460)
        .focusable(false)
        .onAppear {
            models = initialModels
            loadAccountInfo()
        }
    }

    private func copyModelsToClipboard() {
        let modelsText = models.joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(modelsText, forType: .string)
    }

    private func refreshModels() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            let refreshedModels = await proxyService.fetchLocalModels(forceRefresh: true)
            await MainActor.run {
                // Filter models for this provider
                guard let target = builtInProvider(for: provider) else {
                    isRefreshing = false
                    return
                }
                var seen: Set<String> = []
                var ids: [String] = []
                for model in refreshedModels {
                    if builtInProvider(for: model) == target {
                        if !seen.contains(model.id) {
                            seen.insert(model.id)
                            ids.append(model.id)
                        }
                    }
                }
                models = ids.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                // Also refresh account info in case it changed
                loadAccountInfo()
                isRefreshing = false
            }
        }
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

    private func builtInProvider(for model: CLIProxyService.LocalModel)
        -> LocalServerBuiltInProvider?
    {
        let ownedBy = (model.owned_by ?? "").lowercased()
        let provider = (model.provider ?? "").lowercased()
        let source = (model.source ?? "").lowercased()

        for builtIn in LocalServerBuiltInProvider.allCases {
            if builtIn.matchesOwnedBy(ownedBy) || builtIn.matchesOwnedBy(provider)
                || builtIn.matchesOwnedBy(source)
            {
                return builtIn
            }
        }
        return nil
    }

    private func loadAccountInfo() {
        // Use the selected account instead of always using the first one
        let account = selectedAccount

        // Try to extract more info from the account file
        var email: String? = account.email
        var planType: String?
        var accountType: String?
        var organization: String?

        if let data = try? Data(contentsOf: URL(fileURLWithPath: account.filePath)),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {

            // Extract email if not already set
            if email == nil {
                email =
                    json["email"] as? String
                    ?? json["user_email"] as? String
                    ?? json["account"] as? String
                    ?? json["user"] as? String
            }

            // Try to extract plan/subscription info (provider-specific)
            switch provider {
            case .claude:
                // Claude might have plan info in the token or account data
                if let plan = json["plan"] as? String ?? json["plan_type"] as? String ?? json[
                    "subscription"] as? String
                {
                    planType = plan
                }
                if let org = json["organization"] as? String ?? json["org_id"] as? String {
                    organization = org
                }
            case .codex:
                // Codex/OpenAI might have plan info
                if let plan = json["plan"] as? String ?? json["plan_type"] as? String {
                    planType = plan
                }
                accountType = json["account_type"] as? String
            case .gemini:
                // Gemini might have account info
                if let plan = json["plan"] as? String ?? json["tier"] as? String {
                    planType = plan
                }
            default:
                break
            }
        }

        // Always try to fetch plan type via API (more reliable)
        accountInfo = AccountInfo(
            email: email,
            planType: planType,
            planChecked: planType != nil,
            accountType: accountType,
            organization: organization
        )

        // Fetch plan type from API in background
        Task {
            await fetchPlanTypeFromAPI(account: account, email: email)
        }
    }

    private func fetchPlanTypeFromAPI(account: CLIProxyService.OAuthAccount, email: String?) async {
        // Use CLI Proxy API management endpoint to fetch account info
        guard let authFileInfo = await proxyService.fetchAuthFileInfo(for: account.filename) else {
            await MainActor.run {
                accountInfo = AccountInfo(
                    email: accountInfo?.email ?? email,
                    planType: accountInfo?.planType,
                    planChecked: true,
                    accountType: accountInfo?.accountType,
                    organization: accountInfo?.organization
                )
            }
            return
        }

        await MainActor.run {
            accountInfo = AccountInfo(
                email: accountInfo?.email ?? email ?? authFileInfo.email,
                planType: authFileInfo.consolidatedPlan,
                planChecked: true,
                accountType: authFileInfo.consolidatedAccountType,
                organization: authFileInfo.organization
            )
        }
    }
}

private struct OAuthLoginSheet: View {
    let provider: LocalAuthProvider
    let onDone: () -> Void
    let onCancel: () -> Void

    @StateObject private var proxyService = CLIProxyService.shared
    @State private var loginState: LoginState = .idle
    @State private var loginError: String?
    @State private var loginTask: Task<Void, Never>?
    @State private var checkAccountTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    enum LoginState {
        case idle
        case loggingIn
        case needsInput
        case success
        case failed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                LocalAuthProviderIconView(provider: provider, size: 20, cornerRadius: 4)
                Text(provider.displayName)
                    .font(.headline)
                Spacer()
                statusIndicator
            }

            statusMessage

            if case .needsInput = loginState {
                if let prompt = proxyService.loginPrompt {
                    Text(prompt.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }

            if let error = loginError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.top, 4)
            }

            Divider()

            HStack {
                if loginState == .failed {
                    Button("Retry") {
                        loginError = nil
                        startLogin()
                    }
                    .buttonStyle(.bordered)
                    .focusable(false)
                }
                Spacer()
                if loginState == .success {
                    Button("Done") {
                        onDone()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .focusable(false)
                } else {
                    Button("Cancel Login") {
                        onCancel()
                        dismiss()
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                }
            }
        }
        .padding(16)
        .frame(width: 460)
        .focusable(false)
        .onAppear {
            startLogin()
            startAccountCheck()
        }
        .onDisappear {
            loginTask?.cancel()
            checkAccountTask?.cancel()
        }
        .onChange(of: proxyService.loginPrompt) { prompt in
            if prompt != nil && loginState == .loggingIn {
                loginState = .needsInput
            }
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch loginState {
        case .idle, .loggingIn:
            ProgressView()
                .controlSize(.small)
        case .needsInput:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var statusMessage: some View {
        switch loginState {
        case .idle, .loggingIn:
            Text("Logging in to \(provider.displayName)...")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .needsInput:
            Text("Please complete the login in the browser or provide the required input.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .success:
            Text("Login successful. Click Done to add this account.")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed:
            Text("Login failed. You can retry or cancel.")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func startLogin() {
        guard loginState != .loggingIn else { return }
        loginState = .loggingIn
        loginError = nil

        loginTask = Task {
            do {
                try await proxyService.login(provider: provider)
                // Login completed, checkAccountTask will verify success
            } catch is CancellationError {
                await MainActor.run {
                    if loginState == .loggingIn {
                        loginState = .idle
                    }
                }
            } catch {
                await MainActor.run {
                    loginState = .failed
                    loginError = error.localizedDescription
                }
            }
        }
    }

    private func startAccountCheck() {
        checkAccountTask = Task {
            // Record initial account files before login starts
            let initialFiles = Set(
                proxyService.listOAuthAccounts()
                    .filter { $0.provider == provider }
                    .map { $0.filename })

            // Wait 1 second to allow hideAuthFiles to execute
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)

                let currentFiles = Set(
                    proxyService.listOAuthAccounts()
                        .filter { $0.provider == provider }
                        .map { $0.filename })

                // Detect new files or account count increase
                let hasNewFiles = !currentFiles.subtracting(initialFiles).isEmpty
                let countIncreased = currentFiles.count > initialFiles.count

                if (hasNewFiles || countIncreased) && loginState != .success {
                    await MainActor.run {
                        loginState = .success
                        loginError = nil
                    }
                    break
                }
            }
        }
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
                Text(
                    "If the browser already shows “Authentication Successful”, you can keep waiting—no paste needed."
                )
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

// MARK: - Testing Support Types
struct ProviderTestResult {
    let success: Bool
    let layers: [TestLayerResult]
    let summary: String
    let detailedLogs: [String]
}

struct TestLayerResult: Identifiable {
    let id = UUID()
    enum Layer: String {
        case connectivity = "Connectivity"
        case authentication = "Authentication"
        case apiCall = "API Call"
    }

    let layer: Layer
    let status: TestStatus
    let message: String
    let details: String?
    let httpCode: Int?
    let responsePreview: String?
    let durationMs: Int

    var icon: String {
        switch status {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        case .skipped: return "minus.circle.fill"
        }
    }

    var color: Color {
        switch status {
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        case .skipped: return .secondary
        }
    }
}

enum TestStatus {
    case success
    case warning
    case error
    case skipped
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
                testResults = [:]
            }
        }
    }

    // Connection fields
    @Published var providerName: String = ""
    @Published var customIcon: String? = nil  // SF Symbol name for custom providers
    @Published var presetIconName: String? = nil  // Preset PNG icon name for bundled providers (e.g., "DeepSeekIcon")
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
    @Published var testResults: [String: ProviderTestResult] = [:]
    @Published var isTestingEndpoint: [String: Bool] = [:]
    @Published var showEditor: Bool = false
    @Published var isNewProvider: Bool = false

    @Published var providerKeyURL: URL? = nil
    @Published var providerDocsURL: URL? = nil

    @Published var oauthAccounts: [CLIProxyService.OAuthAccount] = []

    private let registry = ProvidersRegistryService()
    private let codex = CodexConfigService()
    @Published var templates: [ProvidersRegistryService.Provider] = []

    func loadAll() async {
        await registry.migrateFromCodexIfNeeded(codex: codex)
        await reload()
        await refreshOAuthAccounts()
    }

    func loadTemplates() async {
        let list = await registry.listBundledProviders()
        // Sorting is handled by sortedTemplates computed property to avoid duplication
        await MainActor.run { templates = list }
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

    func refreshOAuthAccounts() async {
        let accounts = CLIProxyService.shared.listOAuthAccounts()
        await MainActor.run {
            self.oauthAccounts = accounts.sorted {
                if $0.provider.displayName != $1.provider.displayName {
                    return $0.provider.displayName < $1.provider.displayName
                }
                return ($0.email ?? "") < ($1.email ?? "")
            }
        }
    }

    func deleteOAuthAccount(_ account: CLIProxyService.OAuthAccount) async {
        CLIProxyService.shared.deleteOAuthAccount(account)
        await refreshOAuthAccounts()
    }

    private func syncEditingFieldsFromSelected() {
        guard let sel = selectedId, let provider = providers.first(where: { $0.id == sel }) else {
            DispatchQueue.main.async {
                self.providerName = ""
                self.customIcon = nil
                self.presetIconName = nil
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
        let icon = provider.customIcon
        let codexConnector = provider.connectors[ProvidersRegistryService.Consumer.codex.rawValue]
        let claudeConnector = provider.connectors[
            ProvidersRegistryService.Consumer.claudeCode.rawValue]
        let codexBase = codexConnector?.baseURL ?? ""
        let envKey =
            provider.envKey ?? codexConnector?.envKey ?? claudeConnector?.envKey ?? "OPENAI_API_KEY"
        let wireAPI = normalizedWireAPI(codexConnector?.wireAPI)
        let claudeBase = claudeConnector?.baseURL ?? ""
        // Check if this provider has a preset icon
        let presetIcon = ProviderIconResource.iconName(for: provider)

        DispatchQueue.main.async {
            self.providerName = name
            self.customIcon = icon
            self.presetIconName = presetIcon
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

    /// Check if the currently editing provider is a bundled (preset) provider
    /// Bundled providers have preset brand icons and should not allow custom icon selection
    func isEditingBundledProvider() -> Bool {
        guard let sel = selectedId else { return false }
        // Check if this provider ID exists in bundled templates
        return templates.contains(where: { $0.id == sel })
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
                self.defaultModelId = current.modelId.trimmingCharacters(
                    in: .whitespacesAndNewlines)
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
                self.defaultModelId = fallback.modelId.trimmingCharacters(
                    in: .whitespacesAndNewlines)
            }
        } else {
            DispatchQueue.main.async {
                self.defaultModelRowID = nil
                self.defaultModelId = nil
            }
        }
    }

    private func resolvedDefaultModel(from models: [ProvidersRegistryService.ModelEntry]) -> String?
    {
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
    func saveEditing(preferences: SessionPreferencesStore) async -> Bool {
        lastError = nil
        guard let sel = selectedId else {
            lastError = "No provider selected"
            return false
        }

        // Handle new provider creation
        if isNewProvider {
            return await saveNewProvider(preferences: preferences)
        }

        guard var p = providers.first(where: { $0.id == sel }) else {
            lastError = "Missing provider"
            return false
        }
        let trimmedName = providerName.trimmingCharacters(in: .whitespacesAndNewlines)
        p.name = trimmedName.isEmpty ? nil : trimmedName
        // Save customIcon (only for user-created providers)
        if p.managedByCodMate {
            p.customIcon = customIcon
        }
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
                reasoning: r.reasoning, tool_use: r.toolUse, vision: r.vision,
                long_context: r.longContext,
                code_tuned: nil, tps_hint: nil, max_output_tokens: nil
            )
            return ProvidersRegistryService.ModelEntry(
                vendorModelId: trimmed, caps: caps, aliases: nil)
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

            // Sync to config.yaml if this API Key provider is enabled
            if preferences.apiKeyProvidersEnabled.contains(p.id) {
                await CLIProxyService.shared.syncThirdPartyProviders(
                    enabledProviderIds: preferences.apiKeyProvidersEnabled)
            }

            await reload()
            return true
        } catch {
            lastError = "Save failed: \(error.localizedDescription)"
            return false
        }
    }

    private func saveNewProvider(preferences: SessionPreferencesStore) async -> Bool {
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
                requestMaxRetries: nil, streamMaxRetries: nil, streamIdleTimeoutMs: nil,
                modelAliases: nil
            )
        }

        let trimmedClaudeBase = claudeBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedClaudeBase.isEmpty || !trimmedEnv.isEmpty {
            let cconn = ProvidersRegistryService.Connector(
                baseURL: trimmedClaudeBase.isEmpty ? nil : trimmedClaudeBase,
                wireAPI: nil,
                envKey: nil,
                queryParams: nil, httpHeaders: nil, envHttpHeaders: nil,
                requestMaxRetries: nil, streamMaxRetries: nil, streamIdleTimeoutMs: nil,
                modelAliases: nil
            )
            connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue] = cconn
        }

        let cleanedModels: [ProvidersRegistryService.ModelEntry] = modelRows.compactMap { r in
            let trimmed = r.modelId.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            let caps = ProvidersRegistryService.ModelCaps(
                reasoning: r.reasoning, tool_use: r.toolUse, vision: r.vision,
                long_context: r.longContext,
                code_tuned: nil, tps_hint: nil, max_output_tokens: nil
            )
            return ProvidersRegistryService.ModelEntry(
                vendorModelId: trimmed, caps: caps, aliases: nil)
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
            recommended: recommended,
            customIcon: customIcon  // User-created providers can have custom icons
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

            // Sync to config.yaml if this API Key provider is enabled
            if preferences.apiKeyProvidersEnabled.contains(provider.id) {
                await CLIProxyService.shared.syncThirdPartyProviders(
                    enabledProviderIds: preferences.apiKeyProvidersEnabled)
            }

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
        testResults = [:]

        let providerName = providerName.isEmpty ? "Provider" : providerName
        let taskToken = StatusBarLogStore.shared.beginTask(
            "Testing \(providerName) configuration...",
            level: .info,
            source: "Provider Test"
        )

        let codexURL = codexBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let claudeURL = claudeBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !codexURL.isEmpty || !claudeURL.isEmpty else {
            testResultText = "No endpoints configured"
            StatusBarLogStore.shared.endTask(
                taskToken,
                message: "Test skipped: No URLs configured",
                level: .warning,
                source: "Provider Test"
            )
            return
        }

        StatusBarLogStore.shared.post(
            "Starting layered connectivity test for \(providerName)",
            level: .info,
            source: "Provider Test"
        )

        // Test each configured endpoint
        var results: [(String, ProviderTestResult)] = []

        if !codexURL.isEmpty {
            await MainActor.run { isTestingEndpoint["codex"] = true }
            let result = await testEndpointLayered(
                label: "Codex",
                urlString: codexURL,
                consumer: .codex,
                providerName: providerName
            )
            results.append(("Codex", result))
            await MainActor.run { isTestingEndpoint["codex"] = false }
        }

        if !claudeURL.isEmpty {
            await MainActor.run { isTestingEndpoint["claude"] = true }
            let result = await testEndpointLayered(
                label: "Claude",
                urlString: claudeURL,
                consumer: .claudeCode,
                providerName: providerName
            )
            results.append(("Claude", result))
            await MainActor.run { isTestingEndpoint["claude"] = false }
        }

        // Store results
        for (label, result) in results {
            testResults[label] = result
        }

        // Generate summary
        let allSuccess = results.allSatisfy { $0.1.success }
        let summaryLines = results.map { "\($0.0): \($0.1.summary)" }
        testResultText = summaryLines.joined(separator: "\n")

        StatusBarLogStore.shared.endTask(
            taskToken,
            message: allSuccess ? "All tests passed" : "Some tests encountered issues",
            level: allSuccess ? .success : .warning,
            source: "Provider Test"
        )
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

    func delete(id: String, preferences: SessionPreferencesStore) async {
        do {
            try await registry.deleteProvider(id: id)
            if activeCodexProviderId == id {
                try await registry.setActiveProvider(.codex, providerId: nil)
                try await registry.setDefaultModel(.codex, modelId: nil)
                await syncActiveCodexProviderIfNeeded(with: nil)
            }

            // Remove from enabled set and sync to config.yaml
            var enabled = preferences.apiKeyProvidersEnabled
            if enabled.remove(id) != nil {
                preferences.apiKeyProvidersEnabled = enabled
                await CLIProxyService.shared.syncThirdPartyProviders(enabledProviderIds: enabled)
            }
        } catch {
            lastError = "Delete failed: \(error.localizedDescription)"
        }
        await reload()
    }

    func addOther() { startNewProvider() }

    // Randomly select an icon from available SF Symbols
    private func randomIcon() -> String {
        let letters = "abcdefghijklmnopqrstuvwxyz"
        let icons = letters.map { "\($0).circle.fill" }
        return icons.randomElement() ?? icons[0]
    }

    func startNewProvider() {
        isNewProvider = true
        selectedId = "new-provider-temp"
        // Empty for custom provider
        providerName = ""
        presetIconName = nil
        customIcon = randomIcon()  // Randomly select an icon on initialization
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
        // Use the same icon matching logic as menu items
        if let presetIcon = ProviderIconResource.iconName(for: t) {
            // Preset provider with Assets.xcassets icon
            presetIconName = presetIcon
            customIcon = nil
        } else {
            // Custom provider, use random SF Symbol
            presetIconName = nil
            customIcon = randomIcon()
        }
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
        let docsURL: URL? =
            if let s = template.docsURL, let url = URL(string: s) { url } else { nil }

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
            ($0.connectors[ProvidersRegistryService.Consumer.codex.rawValue]?.baseURL?
                .trimmingCharacters(
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
        let mapped = lower.map { (c: Character) -> Character in (c.isLetter || c.isNumber) ? c : "-"
        }
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

    private enum APIKeySource {
        case direct
        case environment
        case none
    }

    private func resolveAPIKey() -> (value: String?, source: APIKeySource) {
        let trimmed = codexEnvKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, .none) }

        // Try as environment variable first
        if let envValue = ProcessInfo.processInfo.environment[trimmed], !envValue.isEmpty {
            return (envValue, .environment)
        }

        // Check if it's a direct token
        // OpenAI: sk-... (but not Anthropic)
        if trimmed.hasPrefix("sk-") && !trimmed.hasPrefix("sk-ant-") {
            return (trimmed, .direct)
        }

        // Anthropic: sk-ant-...
        if trimmed.hasPrefix("sk-ant-") {
            return (trimmed, .direct)
        }

        // JWT-style: eyJ...
        if trimmed.hasPrefix("eyJ") {
            return (trimmed, .direct)
        }

        // Generic token with dots (JWT pattern)
        if trimmed.contains(".") && trimmed.count >= 30 {
            return (trimmed, .direct)
        }

        // Alphanumeric keys (length validation)
        let isAlphanumeric = trimmed.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
        }
        if isAlphanumeric && trimmed.count >= 20 {
            return (trimmed, .direct)
        }

        return (nil, .none)
    }

    // MARK: - Layered Testing Implementation

    private func testEndpointLayered(
        label: String,
        urlString: String,
        consumer: ProvidersRegistryService.Consumer,
        providerName: String
    ) async -> ProviderTestResult {
        var layers: [TestLayerResult] = []

        // Resolve configuration
        guard let baseURL = URL(string: urlString) else {
            let result = TestLayerResult(
                layer: .connectivity,
                status: .error,
                message: "Invalid URL format",
                details: "The base URL '\(urlString)' is not a valid URL",
                httpCode: nil,
                responsePreview: nil,
                durationMs: 0
            )
            return ProviderTestResult(
                success: false,
                layers: [result],
                summary: "Invalid URL",
                detailedLogs: ["Invalid URL format: \(urlString)"]
            )
        }

        let keyInfo = resolveAPIKey()
        let provider = editingProviderBinding()
        let connector = provider?.connectors[consumer.rawValue]
        let providerClass = (provider?.class ?? "openai-compatible").lowercased()
        let wireAPI = normalizedWireAPI(connector?.wireAPI)

        StatusBarLogStore.shared.post(
            "\(label): Configuration - Class: \(providerClass), Wire: \(wireAPI), Auth: \(keyInfo.value != nil ? "present" : "missing")",
            level: .info,
            source: "Provider Test"
        )

        // Layer 1: Basic Connectivity
        StatusBarLogStore.shared.post(
            "\(label): [L1] Testing network connectivity...",
            level: .info,
            source: "Provider Test"
        )

        let connectivityResult = await testConnectivity(
            label: label,
            baseURL: baseURL,
            apiKey: keyInfo.value
        )
        layers.append(connectivityResult)

        guard connectivityResult.status != .error else {
            return ProviderTestResult(
                success: false,
                layers: layers,
                summary: "Network connectivity failed",
                detailedLogs: [connectivityResult.message]
            )
        }

        // Layer 2: Authentication & Endpoint Discovery
        StatusBarLogStore.shared.post(
            "\(label): [L2] Testing authentication and endpoints...",
            level: .info,
            source: "Provider Test"
        )

        let authResult = await testAuthentication(
            label: label,
            baseURL: baseURL,
            providerClass: providerClass,
            wireAPI: wireAPI,
            apiKey: keyInfo.value
        )
        layers.append(authResult)

        // Determine overall success
        let hasErrors = layers.contains { $0.status == .error }
        let allSuccess = layers.allSatisfy { $0.status == .success }
        let hasWarnings = layers.contains { $0.status == .warning }

        let summary: String
        if allSuccess {
            summary = "All checks passed"
        } else if hasErrors {
            summary = "Failed - see details"
        } else if hasWarnings {
            summary = "Reachable with warnings"
        } else {
            summary = "Partial success"
        }

        return ProviderTestResult(
            success: !hasErrors,
            layers: layers,
            summary: summary,
            detailedLogs: layers.map { "\($0.layer.rawValue): \($0.message)" }
        )
    }

    private func testConnectivity(
        label: String,
        baseURL: URL,
        apiKey: String?
    ) async -> TestLayerResult {
        let startTime = Date()

        var request = URLRequest(url: baseURL, timeoutInterval: 5)
        request.httpMethod = "HEAD"

        if let key = apiKey {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let duration = Int(Date().timeIntervalSince(startTime) * 1000)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1

            StatusBarLogStore.shared.post(
                "\(label): [L1] Connectivity OK (HTTP \(statusCode), \(duration)ms)",
                level: .success,
                source: "Provider Test"
            )

            return TestLayerResult(
                layer: .connectivity,
                status: .success,
                message: "Server reachable",
                details: "Base URL responds to requests",
                httpCode: statusCode,
                responsePreview: nil,
                durationMs: duration
            )
        } catch {
            let duration = Int(Date().timeIntervalSince(startTime) * 1000)

            StatusBarLogStore.shared.post(
                "\(label): [L1] Connectivity failed: \(error.localizedDescription)",
                level: .error,
                source: "Provider Test"
            )

            return TestLayerResult(
                layer: .connectivity,
                status: .error,
                message: "Cannot connect to server",
                details: error.localizedDescription,
                httpCode: -1,
                responsePreview: nil,
                durationMs: duration
            )
        }
    }

    private func testAuthentication(
        label: String,
        baseURL: URL,
        providerClass: String,
        wireAPI: String,
        apiKey: String?
    ) async -> TestLayerResult {
        let startTime = Date()

        // Choose appropriate endpoint based on provider class
        let testPath: String
        let method: String

        if providerClass == "anthropic" {
            testPath = "messages"
            method = "HEAD"  // Minimal check
        } else {
            testPath = "models"
            method = "GET"
        }

        // Build URL with proper versioning
        let testURL: URL
        if providerClass == "anthropic" {
            testURL = anthropicEndpoint(baseURL: baseURL.absoluteString, path: testPath)
        } else {
            testURL = openAIEndpoint(baseURL: baseURL.absoluteString, path: testPath)
        }

        var request = URLRequest(url: testURL, timeoutInterval: 8)
        request.httpMethod = method

        if providerClass == "anthropic" {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }

        if let key = apiKey {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let duration = Int(Date().timeIntervalSince(startTime) * 1000)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8)

            let result = evaluateAuthResponse(
                label: label,
                statusCode: statusCode,
                responseBody: body,
                providerClass: providerClass,
                method: method,
                apiKeyPresent: apiKey != nil,
                durationMs: duration
            )

            return result
        } catch {
            let duration = Int(Date().timeIntervalSince(startTime) * 1000)

            StatusBarLogStore.shared.post(
                "\(label): [L2] Request failed: \(error.localizedDescription)",
                level: .error,
                source: "Provider Test"
            )

            return TestLayerResult(
                layer: .authentication,
                status: .error,
                message: "Request failed",
                details: error.localizedDescription,
                httpCode: -1,
                responsePreview: nil,
                durationMs: duration
            )
        }
    }

    private func evaluateAuthResponse(
        label: String,
        statusCode: Int,
        responseBody: String?,
        providerClass: String,
        method: String,
        apiKeyPresent: Bool,
        durationMs: Int
    ) -> TestLayerResult {
        var status: TestStatus
        var message: String
        var details: String?

        switch statusCode {
        case 200:
            status = .success
            message = "Endpoint accessible and authenticated"
            details = "Successfully connected to \(providerClass) API"
            StatusBarLogStore.shared.post(
                "\(label): [L2] ✓ Authentication successful (HTTP 200, \(durationMs)ms)",
                level: .success,
                source: "Provider Test"
            )

        case 401:
            status = .error
            message = "Authentication failed"
            var suggestions = ["Check API key validity"]

            if !apiKeyPresent {
                suggestions.append("No API key provided")
            }

            if providerClass == "anthropic" {
                suggestions.append("Anthropic keys start with 'sk-ant-'")
            } else {
                suggestions.append("OpenAI keys start with 'sk-'")
            }

            // Try to extract error details
            if let body = responseBody,
                let errorInfo = parseErrorResponse(body)
            {
                message = "Authentication failed: \(errorInfo.message)"
                suggestions.append(contentsOf: errorInfo.suggestions)
            }

            details = suggestions.joined(separator: "; ")
            StatusBarLogStore.shared.post(
                "\(label): [L2] ✗ Authentication failed (HTTP 401)",
                level: .error,
                source: "Provider Test"
            )

        case 403:
            status = .error
            message = "Access forbidden"
            var suggestions = ["API key lacks required permissions", "Check account status"]

            if let body = responseBody,
                let errorInfo = parseErrorResponse(body)
            {
                message = "Access forbidden: \(errorInfo.message)"
                suggestions.append(contentsOf: errorInfo.suggestions)
            }

            details = suggestions.joined(separator: "; ")
            StatusBarLogStore.shared.post(
                "\(label): [L2] ✗ Access forbidden (HTTP 403)",
                level: .error,
                source: "Provider Test"
            )

        case 404:
            status = .error
            message = "Endpoint not found"
            let suggestions = [
                "Base URL may be incorrect",
                providerClass == "anthropic"
                    ? "Anthropic uses /v1/messages" : "OpenAI uses /v1/chat/completions",
            ]
            details = suggestions.joined(separator: "; ")
            StatusBarLogStore.shared.post(
                "\(label): [L2] ✗ Endpoint not found (HTTP 404)",
                level: .error,
                source: "Provider Test"
            )

        case 405:
            // Method not allowed - acceptable for HEAD requests
            if method == "HEAD" {
                status = .success
                message = "Endpoint exists (HEAD not supported)"
                details = "Server doesn't support HEAD but endpoint is valid"
                StatusBarLogStore.shared.post(
                    "\(label): [L2] ✓ Endpoint exists (HTTP 405 for HEAD is OK)",
                    level: .success,
                    source: "Provider Test"
                )
            } else {
                status = .warning
                message = "Method not allowed"
                details = "Endpoint exists but \(method) not supported"
                StatusBarLogStore.shared.post(
                    "\(label): [L2] ⚠ Method not allowed (HTTP 405)",
                    level: .warning,
                    source: "Provider Test"
                )
            }

        case 400:
            status = .warning
            message = "Bad request format"
            details =
                "Endpoint reachable but request parameters invalid (acceptable for GET /models)"
            StatusBarLogStore.shared.post(
                "\(label): [L2] ⚠ Bad request (HTTP 400, endpoint reachable)",
                level: .warning,
                source: "Provider Test"
            )

        default:
            status = .error
            message = "Unexpected status code: \(statusCode)"
            details = nil
            StatusBarLogStore.shared.post(
                "\(label): [L2] ✗ Unexpected response (HTTP \(statusCode))",
                level: .error,
                source: "Provider Test"
            )
        }

        return TestLayerResult(
            layer: .authentication,
            status: status,
            message: message,
            details: details,
            httpCode: statusCode,
            responsePreview: responseBody?.prefix(200).description,
            durationMs: durationMs
        )
    }

    private func parseErrorResponse(_ body: String) -> (message: String, suggestions: [String])? {
        guard let data = body.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        var message = ""
        var suggestions: [String] = []

        // OpenAI format
        if let error = json["error"] as? [String: Any] {
            message = error["message"] as? String ?? "Unknown error"
            if let code = error["code"] as? String {
                switch code {
                case "invalid_api_key":
                    suggestions.append("API key is invalid or malformed")
                case "insufficient_quota":
                    suggestions.append("Account quota exceeded")
                case "model_not_found":
                    suggestions.append("Requested model not available")
                default:
                    break
                }
            }
        }
        // Anthropic format
        else if json["type"] as? String == "error",
            let error = json["error"] as? [String: Any]
        {
            message = error["message"] as? String ?? "Unknown error"
        }
        // Generic
        else if let msg = json["message"] as? String ?? json["error"] as? String {
            message = msg
        }

        return message.isEmpty ? nil : (message, suggestions)
    }

    // URL construction helpers
    private func openAIEndpoint(baseURL: String, path: String) -> URL {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix("/") { base.removeLast() }

        // Check if base already has version suffix
        if base.lowercased().hasSuffix("/v1") || hasNumericVersionSuffix(base) {
            return URL(string: base + "/" + path)!
        } else {
            return URL(string: base + "/v1/" + path)!
        }
    }

    private func anthropicEndpoint(baseURL: String, path: String) -> URL {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix("/") { base.removeLast() }

        if base.lowercased().hasSuffix("/v1") {
            return URL(string: base + "/" + path)!
        } else {
            return URL(string: base + "/v1/" + path)!
        }
    }

    private func hasNumericVersionSuffix(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        let parts = url.path.split(separator: "/")
        guard let last = parts.last else { return false }
        let s = String(last).lowercased()
        if s.hasPrefix("v") {
            let digits = s.dropFirst()
            return !digits.isEmpty && digits.allSatisfy { $0.isNumber }
        }
        return false
    }

    private func evaluateEndpoint(
        label: String,
        urlString: String,
        providerName: String = "Provider",
        consumer: ProvidersRegistryService.Consumer
    ) async -> EndpointCheck {
        guard let baseURL = URL(string: urlString) else {
            StatusBarLogStore.shared.post(
                "\(label): Invalid URL format: \(urlString)",
                level: .error,
                source: "Provider Test"
            )
            return EndpointCheck(message: "\(label): invalid URL", ok: false, statusCode: -1)
        }

        StatusBarLogStore.shared.post(
            "\(label): Base URL configured: \(baseURL.absoluteString)",
            level: .info,
            source: "Provider Test"
        )

        let keyInfo = resolveAPIKey()
        if keyInfo.value != nil {
            let source = keyInfo.source == .environment ? "environment variable" : "direct input"
            StatusBarLogStore.shared.post(
                "\(label): API key detected (from \(source))",
                level: .info,
                source: "Provider Test"
            )
        } else {
            StatusBarLogStore.shared.post(
                "\(label): No API key found, testing without authentication",
                level: .warning,
                source: "Provider Test"
            )
        }

        let lower = baseURL.absoluteString.lowercased()
        let isAnthropicEndpoint = consumer == .claudeCode || lower.contains("anthropic")

        // Get provider configuration for this consumer
        let provider = editingProviderBinding()
        let connector = provider?.connectors[consumer.rawValue]
        _ = normalizedWireAPI(
            connector?.wireAPI ?? (consumer == .codex ? codexWireAPI : nil))

        // Test endpoint connectivity: Try GET /models endpoint
        let modelsURL = baseURL.appendingPathComponent("models")
        StatusBarLogStore.shared.post(
            "\(label): [GET] Testing /models endpoint: \(modelsURL.absoluteString)",
            level: .info,
            source: "Provider Test"
        )

        let getModelsResult = await testSingleEndpoint(
            label: label,
            url: modelsURL,
            token: keyInfo.value,
            isAnthropic: isAnthropicEndpoint,
            method: "GET"
        )

        // Determine result based on status code
        if getModelsResult.statusCode == 200 {
            StatusBarLogStore.shared.post(
                "\(label): Endpoint reachable, API key valid (GET /models: 200)",
                level: .success,
                source: "Provider Test"
            )
            return EndpointCheck(
                message: "\(label): HTTP 200 (reachable)",
                ok: true,
                statusCode: 200
            )
        } else if getModelsResult.statusCode == 401 || getModelsResult.statusCode == 403 {
            StatusBarLogStore.shared.post(
                "\(label): Endpoint reachable but API key invalid (GET /models: \(getModelsResult.statusCode))",
                level: .warning,
                source: "Provider Test"
            )
            return EndpointCheck(
                message: "\(label): HTTP \(getModelsResult.statusCode) (API key issue)",
                ok: false,
                statusCode: getModelsResult.statusCode
            )
        } else if getModelsResult.statusCode == 400 || getModelsResult.statusCode == 404
            || getModelsResult.statusCode == 405
        {
            // Endpoint exists but doesn't support GET - this is acceptable for many providers
            StatusBarLogStore.shared.post(
                "\(label): Endpoint reachable (GET /models: \(getModelsResult.statusCode), endpoint may not support GET)",
                level: .info,
                source: "Provider Test"
            )
            return EndpointCheck(
                message: "\(label): HTTP \(getModelsResult.statusCode) (reachable)",
                ok: true,  // Consider reachable if endpoint responds (even with 400/404/405)
                statusCode: getModelsResult.statusCode
            )
        } else {
            StatusBarLogStore.shared.post(
                "\(label): Endpoint test failed (GET /models: \(getModelsResult.statusCode))",
                level: .error,
                source: "Provider Test"
            )
            return EndpointCheck(
                message: "\(label): HTTP \(getModelsResult.statusCode) (unexpected)",
                ok: false,
                statusCode: getModelsResult.statusCode
            )
        }
    }

    private func testSingleEndpoint(
        label: String,
        url: URL,
        token: String?,
        isAnthropic: Bool,
        method: String = "GET"
    ) async -> EndpointCheck {
        var req = URLRequest(url: url)
        req.httpMethod = method
        if isAnthropic {
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        if let token {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let startTime = Date()
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let elapsed = Date().timeIntervalSince(startTime)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1

            // Target is 200 status code
            let ok = code == 200

            let statusLevel: StatusBarLogLevel = ok ? .success : .warning
            let statusMsg = ok ? "HTTP \(code) (success)" : "HTTP \(code) (expected 200)"
            StatusBarLogStore.shared.post(
                "\(label): [\(method)] \(url.absoluteString) → \(statusMsg) [\(String(format: "%.2f", elapsed * 1000))ms]",
                level: statusLevel,
                source: "Provider Test"
            )

            return EndpointCheck(
                message: "\(label): [\(method)] HTTP \(code)", ok: ok, statusCode: code)
        } catch {
            let elapsed = Date().timeIntervalSince(startTime)
            StatusBarLogStore.shared.post(
                "\(label): [\(method)] \(url.absoluteString) → Error: \(error.localizedDescription) [\(String(format: "%.2f", elapsed * 1000))ms]",
                level: .error,
                source: "Provider Test"
            )
            return EndpointCheck(
                message: "\(label): [\(method)] \(error.localizedDescription)", ok: false,
                statusCode: -1)
        }
    }

    private func selectModelForTesting(
        consumer: ProvidersRegistryService.Consumer,
        provider: ProvidersRegistryService.Provider?
    ) -> String? {
        // Priority 1: Use recommended model for this consumer
        if let provider = provider,
            let recommended = provider.recommended?.defaultModelFor?[consumer.rawValue],
            !recommended.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return recommended
        }

        // Priority 2: Filter models by consumer and select
        let availableModels = modelRows.filter {
            !$0.modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        if consumer == .codex {
            // For Codex: exclude anthropic/ models, prefer others
            let codexModels = availableModels.filter {
                !$0.modelId.lowercased().hasPrefix("anthropic/")
            }
            if let defaultModel = defaultModelId, !defaultModel.isEmpty,
                codexModels.contains(where: { $0.modelId == defaultModel })
            {
                return defaultModel
            }
            return codexModels.first?.modelId ?? availableModels.first?.modelId
        } else {
            // For Claude: prefer anthropic/ models
            let claudeModels = availableModels.filter {
                $0.modelId.lowercased().hasPrefix("anthropic/")
            }
            if let defaultModel = defaultModelId, !defaultModel.isEmpty,
                claudeModels.contains(where: { $0.modelId == defaultModel })
                    || availableModels.contains(where: { $0.modelId == defaultModel })
            {
                return defaultModel
            }
            return claudeModels.first?.modelId ?? availableModels.first?.modelId
        }
    }

    private func testModelAPI(
        label: String,
        baseURL: URL,
        model: String,
        token: String?,
        isAnthropic: Bool,
        wireAPI: String
    ) async -> EndpointCheck {
        let endpointPath =
            isAnthropic ? "messages" : (wireAPI == "chat" ? "chat/completions" : "responses")
        let testURL = baseURL.appendingPathComponent(endpointPath)

        StatusBarLogStore.shared.post(
            "\(label): [POST] Testing model API endpoint: \(testURL.absoluteString)",
            level: .info,
            source: "Provider Test"
        )

        var req = URLRequest(url: testURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if isAnthropic {
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        if let token {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        // Prepare request body based on API type
        var body: [String: Any] = [:]
        if isAnthropic {
            body = [
                "model": model,
                "max_tokens": 10,
                "messages": [
                    ["role": "user", "content": "test"]
                ],
            ]
        } else if wireAPI == "chat" {
            body = [
                "model": model,
                "messages": [
                    ["role": "user", "content": "test"]
                ],
                "max_tokens": 10,
            ]
        } else {
            body = [
                "model": model,
                "input": [
                    [
                        "role": "user",
                        "content": [["type": "text", "text": "test"]],
                    ]
                ],
                "max_output_tokens": 10,
            ]
        }

        let startTime = Date()
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: body)
            req.httpBody = jsonData

            let (_, resp) = try await URLSession.shared.data(for: req)
            let elapsed = Date().timeIntervalSince(startTime)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1

            // Target is 200 status code
            let ok = code == 200

            let statusLevel: StatusBarLogLevel = ok ? .success : .warning
            let statusMsg = ok ? "HTTP \(code) (success)" : "HTTP \(code) (expected 200)"
            StatusBarLogStore.shared.post(
                "\(label): [POST] Model '\(model)' API test → \(statusMsg) [\(String(format: "%.2f", elapsed * 1000))ms]",
                level: statusLevel,
                source: "Provider Test"
            )

            return EndpointCheck(
                message: "\(label): [POST] Model API test HTTP \(code)",
                ok: ok,
                statusCode: code
            )
        } catch {
            let elapsed = Date().timeIntervalSince(startTime)
            StatusBarLogStore.shared.post(
                "\(label): [POST] Model '\(model)' API test → Error: \(error.localizedDescription) [\(String(format: "%.2f", elapsed * 1000))ms]",
                level: .error,
                source: "Provider Test"
            )
            return EndpointCheck(
                message: "\(label): [POST] Model API test error: \(error.localizedDescription)",
                ok: false,
                statusCode: -1
            )
        }
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

// MARK: - Provider Menu Components

private struct ProviderMenuItem {
    let id: String
    let name: String
    let icon: ProviderIconType
    let action: () -> Void
}

private enum ProviderIconType {
    case oauth(LocalAuthProvider)
    case apiKey(ProvidersRegistryService.Provider)
}

private struct ProviderAddMenu: View {
    let title: String
    let helpText: String
    let items: [ProviderMenuItem]
    var emptyMessage: String? = nil
    var customAction: (String, () -> Void)? = nil

    var body: some View {
        Menu {
            Text(title)
            if items.isEmpty {
                if let emptyMessage {
                    Text(emptyMessage)
                }
            } else {
                ForEach(items, id: \.id) { item in
                    Button(action: item.action) {
                        HStack {
                            ProviderMenuIconView(icon: item.icon, size: 16, cornerRadius: 3)
                            Text(item.name)
                        }
                    }
                }
                if customAction != nil {
                    Divider()
                }
            }
            if let (label, action) = customAction {
                Button(label, action: action)
            }
        } label: {
            Image(systemName: "plus")
                .font(.body)
                .frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(helpText)
    }
}

private struct ProviderMenuIconView: View {
    let icon: ProviderIconType
    var size: CGFloat = 16
    var cornerRadius: CGFloat = 3

    var body: some View {
        Group {
            switch icon {
            case .oauth(let provider):
                let iconName = iconNameForOAuthProvider(provider)
                if let nsImage = ProviderIconThemeHelper.menuImage(
                    named: iconName, size: NSSize(width: size, height: size))
                {
                    Image(nsImage: nsImage)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size, height: size)
                } else {
                    LocalAuthProviderIconView(
                        provider: provider, size: size, cornerRadius: cornerRadius)
                }
            case .apiKey(let provider):
                if let iconName = iconNameForAPIProvider(provider),
                    let nsImage = ProviderIconThemeHelper.menuImage(
                        named: iconName, size: NSSize(width: size, height: size))
                {
                    Image(nsImage: nsImage)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size, height: size)
                } else {
                    APIKeyProviderIconView(
                        provider: provider, size: size, cornerRadius: cornerRadius)
                }
            }
        }
    }

    private func iconNameForOAuthProvider(_ provider: LocalAuthProvider) -> String {
        switch provider {
        case .codex: return "ChatGPTIcon"
        case .claude: return "ClaudeIcon"
        case .gemini: return "GeminiIcon"
        case .antigravity: return "AntigravityIcon"
        case .qwen: return "QwenIcon"
        }
    }

    private func iconNameForAPIProvider(_ provider: ProvidersRegistryService.Provider) -> String? {
        // Use unified icon resource library helper
        return ProviderIconResource.iconName(for: provider)
    }
}

// MARK: - Test Result UI Components
private struct TestResultCard: View {
    let label: String
    let result: ProviderTestResult
    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            Button {
                withAnimation { isExpanded.toggle() }
            } label: {
                HStack {
                    Image(
                        systemName: result.success
                            ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(result.success ? .green : .orange)
                    Text(label)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    Text(result.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            // Expandable details
            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(result.layers) { layer in
                        LayerResultRow(layer: layer)
                    }
                }
                .padding(.leading, 24)
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
    }
}

private struct LayerResultRow: View {
    let layer: TestLayerResult
    @State private var showDetails: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: layer.icon)
                    .font(.caption)
                    .foregroundStyle(layer.color)
                Text(layer.layer.rawValue)
                    .font(.caption)
                    .fontWeight(.medium)
                Text("•")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(layer.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let code = layer.httpCode {
                    Text("(HTTP \(code))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if layer.details != nil {
                    Button {
                        showDetails.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }

            if showDetails, let details = layer.details {
                Text(details)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
                    .padding(.top, 2)
            }
        }
    }
}

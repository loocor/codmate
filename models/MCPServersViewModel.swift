import Foundation
import SwiftUI

@available(macOS 15.0, *)
@MainActor
final class MCPServersViewModel: ObservableObject {
    enum Tab: Hashable { case importWizard, servers, advanced }

    // UI state
    @Published var activeTab: Tab = .importWizard
    @Published var importText: String = ""
    @Published var importError: String? = nil
    @Published var isParsing: Bool = false
    @Published var drafts: [MCPServerDraft] = []

    @Published var servers: [MCPServer] = []
    @Published var selectedServerName: String? = nil
    @Published var errorMessage: String? = nil
    @Published var testInProgress: Bool = false
    @Published var testMessage: String? = nil
    private var testTask: Task<Void, Never>? = nil

    // Editor/Form state
    @Published var isEditingExisting: Bool = false
    @Published var originalName: String? = nil
    @Published var formName: String = ""
    @Published var formKind: MCPServerKind = .stdio
    @Published var formURL: String = ""
    @Published var formCommand: String = ""
    @Published var formArgs: String = ""               // space-separated
    @Published var formArgsJSONText: String = "[]"      // JSON array
    @Published var formArgsUseJSON: Bool = false
    @Published var formEnvText: String = ""            // key=value per line
    @Published var formEnvJSONText: String = "{}"       // JSON object
    @Published var formEnvUseJSON: Bool = false
    @Published var formHeadersText: String = ""        // key=value per line
    @Published var formHeadersJSONText: String = "{}"   // JSON object
    @Published var formHeadersUseJSON: Bool = false
    @Published var formEnabled: Bool = true
    @Published var formTargetsCodex: Bool = true
    @Published var formTargetsClaude: Bool = true
    @Published var formTargetsGemini: Bool = true

    private let store = MCPServersStore()
    private let tester = MCPQuickTestService()

    func loadText(_ text: String) {
        importText = text
        parseImportText()
    }

    func clearImport() {
        importText = ""
        drafts = []
        importError = nil
        isParsing = false
    }

    func loadServers() async {
        if SecurityScopedBookmarks.shared.isSandboxed {
            let home = SessionPreferencesStore.getRealUserHomeURL()
            let codmate = home.appendingPathComponent(".codmate", isDirectory: true)
            AuthorizationHub.shared.ensureDirectoryAccessOrPrompt(directory: codmate, purpose: .generalAccess, message: "Authorize ~/.codmate to read MCP servers")
        }
        let list = await store.list()
        self.servers = list

        // Auto-select first server if none selected (matching Providers behavior)
        if let currentName = selectedServerName, !list.contains(where: { $0.name == currentName }) {
            selectedServerName = list.first?.name
        } else if selectedServerName == nil {
            selectedServerName = list.first?.name
        }
    }

    func startNewForm() {
        isEditingExisting = false
        originalName = nil
        formName = ""
        formKind = .stdio
        formURL = ""
        formCommand = ""
        formArgs = ""
        formArgsJSONText = "[]"
        formArgsUseJSON = false
        formEnvText = ""
        formEnvJSONText = "{}"
        formEnvUseJSON = false
        formHeadersText = ""
        formHeadersJSONText = "{}"
        formHeadersUseJSON = false
        formEnabled = true
        formTargetsCodex = true
        formTargetsClaude = true
        formTargetsGemini = true
        testMessage = nil
    }

    func startEditForm(from server: MCPServer) {
        isEditingExisting = true
        originalName = server.name
        formName = server.name
        formKind = server.kind
        formURL = server.url ?? ""
        formCommand = server.command ?? ""
        let argsArr = server.args ?? []
        formArgs = argsArr.joined(separator: "\n")
        formArgsJSONText = (try? Self.jsonString(argsArr)) ?? "[]"
        formArgsUseJSON = false
        formEnvText = Self.serializePairs(server.env)
        formEnvJSONText = (try? Self.jsonString(server.env ?? [:])) ?? "{}"
        formEnvUseJSON = false
        formHeadersText = Self.serializePairs(server.headers)
        formHeadersJSONText = (try? Self.jsonString(server.headers ?? [:])) ?? "{}"
        formHeadersUseJSON = false
        formEnabled = server.enabled
        let targets = server.targets ?? MCPServerTargets()
        formTargetsCodex = targets.codex
        formTargetsClaude = targets.claude
        formTargetsGemini = targets.gemini
        testMessage = nil
    }

    func formCanSave() -> Bool {
        !formName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func parsePairs(_ text: String) -> [String: String]? {
        let lines = text.split(separator: "\n")
        var dict: [String: String] = [:]
        for line in lines {
            let raw = line.trimmingCharacters(in: .whitespaces)
            if raw.isEmpty { continue }
            if let eq = raw.firstIndex(of: "=") {
                let k = String(raw[..<eq]).trimmingCharacters(in: .whitespaces)
                let v = String(raw[raw.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                if !k.isEmpty { dict[k] = v }
            }
        }
        return dict.isEmpty ? nil : dict
    }

    private static func serializePairs(_ dict: [String: String]?) -> String {
        guard let dict, !dict.isEmpty else { return "" }
        return dict.keys.sorted().map { "\($0)=\(dict[$0]!)" }.joined(separator: "\n")
    }

    private static func jsonString<T: Encodable>(_ value: T) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        let data = try enc.encode(AnyEncodable(value))
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func parseJSONStringDict(_ text: String) -> [String: String]? {
        guard let data = text.data(using: .utf8) else { return nil }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var out: [String: String] = [:]
            for (k, v) in obj { out[k] = String(describing: v) }
            return out.isEmpty ? nil : out
        }
        if let obj = try? JSONDecoder().decode([String: String].self, from: data) { return obj }
        return nil
    }

    private static func parseJSONStringArray(_ text: String) -> [String]? {
        guard let data = text.data(using: .utf8) else { return nil }
        if let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            let out = arr.map { String(describing: $0) }
            return out
        }
        if let arr = try? JSONDecoder().decode([String].self, from: data) { return arr }
        return nil
    }

    private func buildServerFromForm() -> MCPServer {
        let trimmedName = formName.trimmingCharacters(in: .whitespacesAndNewlines)
        let args: [String] = formArgsUseJSON
            ? (Self.parseJSONStringArray(formArgsJSONText) ?? [])
            : formArgs
                .split(whereSeparator: { $0.isWhitespace })
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        let env: [String: String]? = formEnvUseJSON
            ? Self.parseJSONStringDict(formEnvJSONText)
            : Self.parsePairs(formEnvText)
        let headers: [String: String]? = formHeadersUseJSON
            ? Self.parseJSONStringDict(formHeadersJSONText)
            : Self.parsePairs(formHeadersText)
        return MCPServer(
            name: trimmedName,
            kind: formKind,
            command: formCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : formCommand,
            args: args.isEmpty ? nil : args,
            env: env,
            url: formURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : formURL,
            headers: headers,
            meta: nil,
            enabled: formEnabled,
            capabilities: servers.first(where: { $0.name == originalName ?? formName })?.capabilities ?? [],
            targets: MCPServerTargets(
                codex: formTargetsCodex,
                claude: formTargetsClaude,
                gemini: formTargetsGemini
            )
        )
    }

    // JSON preview of the current form as a single server object (without capabilities)
    func formJSONPreview() -> String {
        let obj = buildServerFromForm()
        struct Preview: Encodable {
            let name: String
            let kind: MCPServerKind
            let command: String?
            let args: [String]?
            let env: [String: String]?
            let url: String?
            let headers: [String: String]?
            let meta: MCPServerMeta?
            let enabled: Bool
        }
        let preview = Preview(name: obj.name, kind: obj.kind, command: obj.command, args: obj.args, env: obj.env, url: obj.url, headers: obj.headers, meta: obj.meta, enabled: obj.enabled)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        if let data = try? enc.encode(preview), let s = String(data: data, encoding: .utf8) { return s }
        return "{}"
    }

    func saveForm() async -> Bool {
        guard formCanSave() else { return false }
        let item = buildServerFromForm()
        do {
            if SecurityScopedBookmarks.shared.isSandboxed {
                let home = SessionPreferencesStore.getRealUserHomeURL()
                let codmate = home.appendingPathComponent(".codmate", isDirectory: true)
                let codex = home.appendingPathComponent(".codex", isDirectory: true)
                _ = AuthorizationHub.shared.ensureDirectoryAccessOrPromptSync(directory: codmate, purpose: .generalAccess, message: "Authorize ~/.codmate to save MCP servers")
                _ = AuthorizationHub.shared.ensureDirectoryAccessOrPromptSync(directory: codex, purpose: .generalAccess, message: "Authorize ~/.codex to update Codex config")
                _ = AuthorizationHub.shared.ensureDirectoryAccessOrPromptSync(directory: home, purpose: .generalAccess, message: "Authorize your Home folder to update Claude config")
            }
            if isEditingExisting, let original = originalName, original != item.name {
                // Rename: remove old record first to avoid duplicate entries
                try await store.delete(name: original)
            }
            try await store.upsert(item)
            await loadServers()
            await applyEnabledServersToAllProviders()
            originalName = item.name
            isEditingExisting = true
            return true
        } catch {
            errorMessage = "Failed to save: \(error.localizedDescription)"
            return false
        }
    }

    func deleteServer(named name: String) async {
        do {
            try await store.delete(name: name)
            await loadServers()
            await applyEnabledServersToAllProviders()
        } catch {
            errorMessage = "Failed to delete: \(error.localizedDescription)"
        }
    }

    func parseImportText() {
        let trimmed = importText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            importError = nil
            drafts = []
            isParsing = false
            return
        }
        isParsing = true
        importError = nil
        Task.detached {
            do {
                let ds = try UniImportMCPNormalizer.parseText(trimmed)
                await MainActor.run {
                    self.drafts = ds
                    self.importError = ds.isEmpty ? "No servers detected" : nil
                    // Autofill the form with the first detected draft in New mode
                    if !self.isEditingExisting, let first = ds.first {
                        self.applyDraftToForm(first)
                    }
                }
            } catch {
                await MainActor.run {
                    self.drafts = []
                    self.importError = (error as? LocalizedError)?.errorDescription ?? "Failed to parse input"
                }
            }
            await MainActor.run { self.isParsing = false }
        }
    }

    private func applyDraftToForm(_ d: MCPServerDraft) {
        formName = (d.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        formKind = d.kind
        formURL = d.url ?? ""
        formCommand = d.command ?? ""
        if let arr = d.args, !arr.isEmpty {
            formArgs = arr.joined(separator: "\n")
            formArgsJSONText = (try? Self.jsonString(arr)) ?? formArgsJSONText
        }
        formEnvText = Self.serializePairs(d.env)
        formEnvJSONText = (try? Self.jsonString(d.env ?? [:])) ?? formEnvJSONText
        formHeadersText = Self.serializePairs(d.headers)
        formHeadersJSONText = (try? Self.jsonString(d.headers ?? [:])) ?? formHeadersJSONText
        formEnabled = true
    }

    // MARK: - Quick Test (lightweight)
    func testCurrentForm() async {
        testInProgress = true
        testMessage = nil
        defer { testInProgress = false }
        let server = buildServerFromForm()
        let result = await tester.test(server: server, timeoutSeconds: 6)
        switch result {
        case .success(let r):
            let name = r.serverName?.isEmpty == false ? " to \(r.serverName!)" : ""
            var parts: [String] = []
            if r.hasTools { parts.append("Tools \(r.tools)") }
            if r.hasPrompts { parts.append("Prompts \(r.prompts)") }
            if r.hasResources { parts.append("Resources \(r.resources)") }
            if r.models > 0 { parts.append("Models \(r.models)") }
            testMessage = "Connected\(name) — " + (parts.isEmpty ? "(no declared capabilities)" : parts.joined(separator: ", "))
        case .failure(let e):
            let reason = (e as MCPQuickTestError).errorDescription ?? "failed"
            testMessage = "Unreachable — \(reason)"
        }
    }

    func startTest() {
        testTask?.cancel()
        testTask = Task { await self.testCurrentForm() }
    }

    func cancelTest() {
        testTask?.cancel()
        Task { await tester.cancelActive() }
        testInProgress = false
        testMessage = "Cancelled"
    }

    func importDrafts() async {
        guard !drafts.isEmpty else { return }
        do {
            var incoming: [MCPServer] = []
            for d in drafts {
                let name = d.name ?? "imported-server"
                let srv = MCPServer(
                    name: name,
                    kind: d.kind,
                    command: d.command,
                    args: d.args,
                    env: d.env,
                    url: d.url,
                    headers: d.headers,
                    meta: d.meta,
                    enabled: true,
                    capabilities: [],
                    targets: MCPServerTargets()
                )
                incoming.append(srv)
            }
            if SecurityScopedBookmarks.shared.isSandboxed {
                let home = SessionPreferencesStore.getRealUserHomeURL()
                let codmate = home.appendingPathComponent(".codmate", isDirectory: true)
                let codex = home.appendingPathComponent(".codex", isDirectory: true)
                _ = AuthorizationHub.shared.ensureDirectoryAccessOrPromptSync(directory: codmate, purpose: .generalAccess, message: "Authorize ~/.codmate to save MCP servers")
                _ = AuthorizationHub.shared.ensureDirectoryAccessOrPromptSync(directory: codex, purpose: .generalAccess, message: "Authorize ~/.codex to update Codex config")
                _ = AuthorizationHub.shared.ensureDirectoryAccessOrPromptSync(directory: home, purpose: .generalAccess, message: "Authorize your Home folder to update Claude config")
            }
            try await store.upsertMany(incoming)
            await loadServers()
            // Apply enabled servers into Codex config.toml
            await applyEnabledServersToAllProviders()
            // Reset import UI
            drafts = []
            importText = ""
            importError = nil
        } catch {
            errorMessage = "Failed to save servers: \(error.localizedDescription)"
        }
    }

    func setServerEnabled(_ server: MCPServer, _ enabled: Bool) async {
        do {
            if SecurityScopedBookmarks.shared.isSandboxed {
                let home = SessionPreferencesStore.getRealUserHomeURL()
                let codmate = home.appendingPathComponent(".codmate", isDirectory: true)
                let codex = home.appendingPathComponent(".codex", isDirectory: true)
                _ = AuthorizationHub.shared.ensureDirectoryAccessOrPromptSync(directory: codmate, purpose: .generalAccess)
                _ = AuthorizationHub.shared.ensureDirectoryAccessOrPromptSync(directory: codex, purpose: .generalAccess)
                _ = AuthorizationHub.shared.ensureDirectoryAccessOrPromptSync(directory: home, purpose: .generalAccess)
            }
            try await store.setEnabled(name: server.name, enabled: enabled)
            await loadServers()
            await applyEnabledServersToAllProviders()
        } catch {
            errorMessage = "Failed to update: \(error.localizedDescription)"
        }
    }

    func setCapabilityEnabled(_ server: MCPServer, _ cap: MCPCapability, _ enabled: Bool) async {
        do {
            if SecurityScopedBookmarks.shared.isSandboxed {
                let home = SessionPreferencesStore.getRealUserHomeURL()
                let codmate = home.appendingPathComponent(".codmate", isDirectory: true)
                let codex = home.appendingPathComponent(".codex", isDirectory: true)
                _ = AuthorizationHub.shared.ensureDirectoryAccessOrPromptSync(directory: codmate, purpose: .generalAccess)
                _ = AuthorizationHub.shared.ensureDirectoryAccessOrPromptSync(directory: codex, purpose: .generalAccess)
                _ = AuthorizationHub.shared.ensureDirectoryAccessOrPromptSync(directory: home, purpose: .generalAccess)
            }
            try await store.setCapabilityEnabled(name: server.name, capability: cap.name, enabled: enabled)
            await loadServers()
            await applyEnabledServersToAllProviders()
        } catch {
            errorMessage = "Failed to update: \(error.localizedDescription)"
        }
    }

    func isServerEnabled(_ server: MCPServer, for target: MCPServerTarget) -> Bool {
        server.isEnabled(for: target)
    }

    func setServerTargetEnabled(_ server: MCPServer, target: MCPServerTarget, enabled: Bool) async {
        do {
            if SecurityScopedBookmarks.shared.isSandboxed {
                let home = SessionPreferencesStore.getRealUserHomeURL()
                let codmate = home.appendingPathComponent(".codmate", isDirectory: true)
                let codex = home.appendingPathComponent(".codex", isDirectory: true)
                _ = AuthorizationHub.shared.ensureDirectoryAccessOrPromptSync(directory: codmate, purpose: .generalAccess)
                _ = AuthorizationHub.shared.ensureDirectoryAccessOrPromptSync(directory: codex, purpose: .generalAccess)
                _ = AuthorizationHub.shared.ensureDirectoryAccessOrPromptSync(directory: home, purpose: .generalAccess)
            }
            var updated = server.withTargets { targets in
                targets.setEnabled(enabled, for: target)
            }
            // Preserve existing capabilities/enabled flag
            updated.enabled = server.enabled
            try await store.upsert(updated)
            await loadServers()
            await applyEnabledServersToAllProviders()
        } catch {
            errorMessage = "Failed to update: \(error.localizedDescription)"
        }
    }

    // Stub for capability discovery via MCP Swift SDK (to be integrated)
    func refreshCapabilities(for server: MCPServer) async {
        // TODO: Integrate MCP Swift SDK handshake and tools discovery
        // For MVP, keep existing capabilities untouched.
        await loadServers()
        await applyEnabledServersToAllProviders()
    }

    private func applyEnabledServersToAllProviders() async {
        let list = await store.list()

        // 1. Codex
        let codex = CodexConfigService()
        try? await codex.applyMCPServers(list)

        // 2. Claude Code (User settings export)
        try? await store.exportEnabledForClaudeConfig(servers: list)

        // 3. Gemini CLI
        let gemini = GeminiSettingsService()
        try? await gemini.applyMCPServers(list)
    }
}

// A tiny type eraser to help JSONEncoder with generic values
private struct AnyEncodable: Encodable {
    private let encodeImpl: (Encoder) throws -> Void
    init<T: Encodable>(_ value: T) { encodeImpl = value.encode }
    func encode(to encoder: Encoder) throws { try encodeImpl(encoder) }
}

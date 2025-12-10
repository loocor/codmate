import Foundation

// MARK: - Models

public struct CodexProvider: Identifiable, Equatable, Sendable {
    public var id: String                // table id, e.g., "openai"
    public var name: String?             // display name
    public var baseURL: String?
    public var envKey: String?
    public var wireAPI: String?
    public var queryParamsRaw: String?   // raw TOML for query_params
    public var httpHeadersRaw: String?   // raw TOML for http_headers
    public var envHttpHeadersRaw: String?// raw TOML for env_http_headers
    public var requestMaxRetries: Int?
    public var streamMaxRetries: Int?
    public var streamIdleTimeoutMs: Int?
    public var managedByCodMate: Bool    // true when block contains our marker
}

// MARK: - Service

actor CodexConfigService {
    struct Paths {
        let home: URL
        let configURL: URL

        static func `default`(fileManager: FileManager = .default) -> Paths {
            // Use real user home (not sandbox container) so Codex CLI can read the config
            let userHome = SessionPreferencesStore.getRealUserHomeURL()
            let home = userHome.appendingPathComponent(".codex", isDirectory: true)
            return Paths(home: home, configURL: home.appendingPathComponent("config.toml", isDirectory: false))
        }
    }

    private let paths: Paths
    private let fm: FileManager

    init(paths: Paths = .default(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fm = fileManager
    }

    // MARK: - Diagnostics models
    struct ProviderDiagnostics: Sendable {
        var configPath: String
        var providers: [CodexProvider]
        var headerCounts: [String: Int]   // id -> occurrences in raw file
        var duplicateIDs: [String]
        var strayManagedBodies: Int       // bodies without header likely left behind
        var canonicalRegion: String       // canonical providers region text (not applied)
    }

    // MARK: Public API (phase 1)

    func listProviders() -> [CodexProvider] {
        let text = (try? String(contentsOf: paths.configURL, encoding: .utf8)) ?? ""
        return parseProviders(from: text)
    }

    func activeProvider() -> String? {
        let text = (try? String(contentsOf: paths.configURL, encoding: .utf8)) ?? ""
        return parseTopLevelString(key: "model_provider", from: text)
    }

    func setActiveProvider(_ id: String?) throws {
        var text = (try? String(contentsOf: paths.configURL, encoding: .utf8)) ?? ""
        text = upsertTopLevelString(key: "model_provider", value: id, in: text)
        try writeConfig(text)
    }

    func upsertProvider(_ provider: CodexProvider) throws {
        let text = (try? String(contentsOf: paths.configURL, encoding: .utf8)) ?? ""
        // Build new providers array based on current parsed providers (deduped by id)
        var current = parseProviders(from: text)
        if let idx = current.firstIndex(where: { $0.id == provider.id }) {
            current[idx] = provider
        } else {
            current.append(provider)
        }
        let rewritten = rewriteProvidersRegion(in: text, with: current)
        try writeConfig(rewritten)
    }

    func deleteProvider(id: String) throws {
        let text = (try? String(contentsOf: paths.configURL, encoding: .utf8)) ?? ""
        var current = parseProviders(from: text)
        current.removeAll { $0.id == id }
        let rewritten = rewriteProvidersRegion(in: text, with: current)
        try writeConfig(rewritten)
    }

    func replaceProviders(with providers: [CodexProvider]) throws {
        var text = (try? String(contentsOf: paths.configURL, encoding: .utf8)) ?? ""
        text = rewriteProvidersRegion(in: text, with: providers)
        try writeConfig(text)
    }

    func applyProviderFromRegistry(_ provider: ProvidersRegistryService.Provider?) throws {
        if let provider {
            guard
                let connector = provider.connectors[ProvidersRegistryService.Consumer.codex.rawValue]
            else {
                try replaceProviders(with: [])
                try setActiveProvider(nil)
                return
            }
            var envKeyValue = provider.envKey ?? connector.envKey
            var headerMap = connector.httpHeaders ?? [:]
            if let v = envKeyValue {
                let lower = v.lowercased()
                let looksLikeToken = lower.contains("sk-") || v.hasPrefix("eyJ") || v.contains(".")
                if looksLikeToken {
                    envKeyValue = nil
                    headerMap["Authorization"] = v.hasPrefix("Bearer ") ? v : "Bearer \(v)"
                }
            }
            let codexProvider = CodexProvider(
                id: provider.id,
                name: provider.name,
                baseURL: connector.baseURL,
                envKey: envKeyValue,
                wireAPI: (connector.wireAPI?.lowercased() == "responses") ? "responses" : "chat",
                queryParamsRaw: connector.queryParams.map { renderInlineTable($0) },
                httpHeadersRaw: headerMap.isEmpty ? nil : renderInlineTable(headerMap),
                envHttpHeadersRaw: connector.envHttpHeaders.map { renderInlineTable($0) },
                requestMaxRetries: connector.requestMaxRetries,
                streamMaxRetries: connector.streamMaxRetries,
                streamIdleTimeoutMs: connector.streamIdleTimeoutMs,
                managedByCodMate: provider.managedByCodMate
            )
            try replaceProviders(with: [codexProvider])
            try setActiveProvider(provider.id)
        } else {
            try replaceProviders(with: [])
            try setActiveProvider(nil)
        }
    }

    // MARK: - Runtime: model, reasoning, sandbox, approvals

    func getTopLevelString(_ key: String) -> String? {
        let text = (try? String(contentsOf: paths.configURL, encoding: .utf8)) ?? ""
        return parseTopLevelString(key: key, from: text)
    }

    func setTopLevelString(_ key: String, value: String?) throws {
        var text = (try? String(contentsOf: paths.configURL, encoding: .utf8)) ?? ""
        text = upsertTopLevelString(key: key, value: value, in: text)
        try writeConfig(text)
    }

    func setSandboxMode(_ mode: String?) throws { try setTopLevelString("sandbox_mode", value: mode) }
    func setApprovalPolicy(_ policy: String?) throws { try setTopLevelString("approval_policy", value: policy) }

    // MARK: - Features overrides

    func featureOverrides() -> [String: Bool] {
        let text = (try? String(contentsOf: paths.configURL, encoding: .utf8)) ?? ""
        return parseFeatureOverrides(from: text)
    }

    func setFeatureOverride(name: String, value: Bool?) throws {
        var text = (try? String(contentsOf: paths.configURL, encoding: .utf8)) ?? ""
        var overrides = parseFeatureOverrides(from: text)
        if let value {
            overrides[name] = value
        } else {
            overrides.removeValue(forKey: name)
        }
        text = rewriteFeaturesBlock(in: text, overrides: overrides)
        try writeConfig(text)
    }

    // MARK: - TUI notifications and notify bridge

    func getTuiNotifications() -> Bool {
        let text = (try? String(contentsOf: paths.configURL, encoding: .utf8)) ?? ""
        return (parseTableKeyValue(table: "[tui]", key: "notifications", from: text) ?? "false")
            .trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    func setTuiNotifications(_ enabled: Bool) throws {
        var text = (try? String(contentsOf: paths.configURL, encoding: .utf8)) ?? ""
        text = upsertTableKeyValue(table: "[tui]", key: "notifications", valueText: enabled ? "true" : "false", in: text)
        try writeConfig(text)
    }

    func getNotifyArray() -> [String] {
        let text = (try? String(contentsOf: paths.configURL, encoding: .utf8)) ?? ""
        if let v = parseTopLevelArray(key: "notify", from: text) { return v }
        return []
    }

    func setNotifyArray(_ arr: [String]?) throws {
        var text = (try? String(contentsOf: paths.configURL, encoding: .utf8)) ?? ""
        text = upsertTopLevelArray(key: "notify", values: arr, in: text)
        try writeConfig(text)
    }

    func ensureNotifyBridgeInstalled() throws -> URL {
        let bin = paths.home.deletingLastPathComponent()
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("CodMate", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let target = bin.appendingPathComponent("codmate-notify")
        guard let bundled = Self.bundledNotifyBinaryURL() else {
            if fm.fileExists(atPath: target.path) {
                return target
            }
            throw NSError(domain: "CodMate", code: -1, userInfo: [NSLocalizedDescriptionKey: "Bundled codmate-notify helper not found"])
        }
        if fm.fileExists(atPath: target.path) {
            try? fm.removeItem(at: target)
        }
        try fm.copyItem(at: bundled, to: target)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        return target
    }

    private static func bundledNotifyBinaryURL() -> URL? {
        #if os(macOS)
            if let url = Bundle.main.url(forResource: "codmate-notify", withExtension: nil, subdirectory: "bin") {
                return url
            }
            return Bundle.main.url(forResource: "codmate-notify", withExtension: nil)
        #else
            return nil
        #endif
    }

    // MARK: - Raw config helpers
    func configFileURL() -> URL { paths.configURL }
    func readRawConfigText() -> String {
        (try? String(contentsOf: paths.configURL, encoding: .utf8)) ?? ""
    }

    // MARK: - Providers Diagnostics
    func diagnoseProviders() -> ProviderDiagnostics {
        let raw = (try? String(contentsOf: paths.configURL, encoding: .utf8)) ?? ""
        let list = parseProviders(from: raw)
        var counts: [String: Int] = [:]
        // Count headers occurrences
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if let id = matchProviderHeader(t) { counts[id, default: 0] += 1 }
        }
        let dups = counts.filter { $0.value > 1 }.map { $0.key }.sorted()
        let stray = countStrayProviderBodies(in: raw)
        // Build canonical region (with leading blank line per style)
        var canonical = raw
        canonical = rewriteProvidersRegion(in: canonical, with: list)
        let region: String = {
            // extract only the appended canonical region portion by rebuilding from empty baseline
            var s = ""
            for p in list {
                if !s.hasSuffix("\n\n") { if !s.isEmpty { s += "\n" } else { s += "\n\n" } }
                s += "[model_providers.\(p.id)]\n"
                s += renderProviderBody(p)
                s += "\n"
            }
            return s
        }()
        return ProviderDiagnostics(
            configPath: paths.configURL.path,
            providers: list,
            headerCounts: counts,
            duplicateIDs: dups,
            strayManagedBodies: stray,
            canonicalRegion: region
        )
    }

    // MARK: - MCP Servers (managed region)
    private let mcpBeginMarker = "# codmate-mcp begin"
    private let mcpEndMarker = "# codmate-mcp end"

    func applyMCPServers(_ servers: [MCPServer]) throws {
        var text = (try? String(contentsOf: paths.configURL, encoding: .utf8)) ?? ""
        // Strip previous managed region if present
        if let begin = text.range(of: mcpBeginMarker), let end = text.range(of: mcpEndMarker) {
            text.removeSubrange(begin.lowerBound..<(end.upperBound))
        }
        // Normalize trailing whitespace/newlines to avoid accumulating blank lines
        while let last = text.last, last == "\n" || last == "\r" || last == "\t" || last == " " {
            text.removeLast()
        }
        // Build new region with enabled servers only
        let enabled = servers.enabledServers(for: .codex)
        guard !enabled.isEmpty else {
            try writeConfig(text)
            return
        }
        // Ensure at most a single empty line before the managed block
        var region = (text.isEmpty ? "" : "\n\n") + "\(mcpBeginMarker)\n"
        for s in enabled {
            // Single canonical block per server: [mcp_servers.<name>]
            var body: [String] = []
            body.append("kind = \"\(s.kind.rawValue)\"")
            if let url = s.url, !url.isEmpty { body.append("url = \"\(url)\"") }
            if let cmd = s.command, !cmd.isEmpty { body.append("command = \"\(cmd)\"") }
            if let args = s.args, !args.isEmpty {
                let quoted = args.map { "\"\($0)\"" }.joined(separator: ", ")
                body.append("args = [ \(quoted) ]")
            }
            if let env = s.env, !env.isEmpty { body.append("env = \(renderInlineTable(env))") }
            if let headers = s.headers, !headers.isEmpty { body.append("headers = \(renderInlineTable(headers))") }
            region += "[mcp_servers.\(s.name)]\n" + body.joined(separator: "\n") + "\n\n"
        }
        region += "\(mcpEndMarker)\n"
        text += region
        try writeConfig(text)
    }

    // MARK: - Privacy: shell_environment_policy

    struct ShellEnvironmentPolicy {
        var inherit: String? // all|core|none
        var ignoreDefaultExcludes: Bool?
        var includeOnly: [String]?
        var exclude: [String]?
        var set: [String:String]?
    }

    func getShellEnvironmentPolicy() -> ShellEnvironmentPolicy {
        let text = (try? String(contentsOf: paths.configURL, encoding: .utf8)) ?? ""
        let body = parseTableBody(table: "[shell_environment_policy]", from: text)
        var policy = ShellEnvironmentPolicy(inherit: nil, ignoreDefaultExcludes: nil, includeOnly: nil, exclude: nil, set: nil)
        for line in body {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { continue }
            let key = t[..<eq].trimmingCharacters(in: .whitespaces)
            let value = String(t[t.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "inherit": policy.inherit = unquote(value)
            case "ignore_default_excludes": policy.ignoreDefaultExcludes = (value == "true")
            case "include_only": policy.includeOnly = parseArrayLiteral(value)
            case "exclude": policy.exclude = parseArrayLiteral(value)
            case "set": policy.set = parseInlineTable(value)
            default: break
            }
        }
        return policy
    }

    func setShellEnvironmentPolicy(_ p: ShellEnvironmentPolicy) throws {
        var body: [String] = ["# managed-by=codmate"]
        if let v = p.inherit { body.append("inherit = \"\(v)\"") }
        if let v = p.ignoreDefaultExcludes { body.append("ignore_default_excludes = \(v ? "true" : "false")") }
        if let v = p.includeOnly { body.append("include_only = \(renderArrayLiteral(v))") }
        if let v = p.exclude { body.append("exclude = \(renderArrayLiteral(v))") }
        if let v = p.set, !v.isEmpty { body.append("set = \(renderInlineTable(v))") }
        var text = (try? String(contentsOf: paths.configURL, encoding: .utf8)) ?? ""
        text = replaceTableBlock(header: "[shell_environment_policy]", body: body.joined(separator: "\n") + "\n", in: text)
        try writeConfig(text)
    }

    // MARK: - Privacy: reasoning toggles & file opener

    func getBool(_ key: String) -> Bool {
        let text = (try? String(contentsOf: paths.configURL, encoding: .utf8)) ?? ""
        let val = parseTopLevelString(key: key, from: text) ?? "false"
        return val == "true"
    }

    func setBool(_ key: String, _ value: Bool) throws {
        var text = (try? String(contentsOf: paths.configURL, encoding: .utf8)) ?? ""
        text = upsertTopLevelBool(key: key, value: value, in: text)
        try writeConfig(text)
    }

    func setFileOpener(_ opener: String?) throws { try setTopLevelString("file_opener", value: opener) }

    // MARK: - Privacy: OTEL (simplified)

    enum OtelExporterKind: String { case none, otlpHttp = "otlp-http", otlpGrpc = "otlp-grpc" }
    struct OtelConfig { var environment: String?; var exporterKind: OtelExporterKind; var endpoint: String? }

    func getOtelConfig() -> OtelConfig {
        let text = (try? String(contentsOf: paths.configURL, encoding: .utf8)) ?? ""
        let body = parseTableBody(table: "[otel]", from: text)
        var env: String?; var kind: OtelExporterKind = .none; var endpoint: String? = nil
        for raw in body {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("environment") {
                if let eq = line.firstIndex(of: "=") {
                    env = unquote(String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces))
                }
            }
            if line.hasPrefix("exporter") {
                if line.contains("otlp-http") { kind = .otlpHttp }
                else if line.contains("otlp-grpc") { kind = .otlpGrpc }
                else if line.contains("none") { kind = .none }
                if let e = extractInlineEndpoint(from: line) { endpoint = e }
            }
        }
        return OtelConfig(environment: env, exporterKind: kind, endpoint: endpoint)
    }

    func setOtelConfig(_ oc: OtelConfig) throws {
        var lines: [String] = ["# managed-by=codmate"]
        if let env = oc.environment, !env.isEmpty { lines.append("environment = \"\(env)\"") }
        switch oc.exporterKind {
        case .none:
            lines.append("exporter = \"none\"")
        case .otlpHttp:
            let endpoint = oc.endpoint ?? ""
            lines.append("exporter = { otlp-http = { endpoint = \"\(endpoint)\", protocol = \"binary\" } }")
        case .otlpGrpc:
            let endpoint = oc.endpoint ?? ""
            lines.append("exporter = { otlp-grpc = { endpoint = \"\(endpoint)\" } }")
        }
        var text = (try? String(contentsOf: paths.configURL, encoding: .utf8)) ?? ""
        text = replaceTableBlock(header: "[otel]", body: lines.joined(separator: "\n") + "\n", in: text)
        try writeConfig(text)
    }

    // MARK: - File IO helpers

    private func writeConfig(_ text: String) throws {
        try fm.createDirectory(at: paths.home, withIntermediateDirectories: true)
        // Backup existing
        if fm.fileExists(atPath: paths.configURL.path) {
            let bak = paths.home.appendingPathComponent("config.toml.bak")
            try? fm.removeItem(at: bak)
            try fm.copyItem(at: paths.configURL, to: bak)
        }
        try text.write(to: paths.configURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Parsing (naïve, line-based; tolerant by design)

    private func parseProviders(from text: String) -> [CodexProvider] {
        // Parse and deduplicate by id. If the same id appears multiple times,
        // keep the LAST occurrence in the file (common when blocks were rewritten).
        var map: [String: CodexProvider] = [:]
        var order: [String] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if let id = matchProviderHeader(line) {
                var j = i + 1
                var body: [String] = []
                while j < lines.count {
                    let l = lines[j]
                    if l.trimmingCharacters(in: .whitespaces).hasPrefix("[") { break }
                    body.append(l)
                    j += 1
                }
                let p = parseProviderBody(id: id, body: body)
                map[id] = p
                if !order.contains(id) { order.append(id) }
                i = j
                continue
            }
            i += 1
        }

        return order.compactMap { map[$0] }
    }

    private func matchProviderHeader(_ line: String) -> String? {
        // [model_providers.<id>]
        guard line.hasPrefix("[model_providers.") && line.hasSuffix("]") else { return nil }
        let start = "[model_providers.".count
        let endIndex = line.index(before: line.endIndex)
        let id = String(line[line.index(line.startIndex, offsetBy: start)..<endIndex])
        return id.trimmingCharacters(in: .whitespaces)
    }

    private func parseProviderBody(id: String, body: [String]) -> CodexProvider {
        var p = CodexProvider(id: id, name: nil, baseURL: nil, envKey: nil, wireAPI: nil,
                              queryParamsRaw: nil, httpHeadersRaw: nil, envHttpHeadersRaw: nil,
                              requestMaxRetries: nil, streamMaxRetries: nil, streamIdleTimeoutMs: nil,
                              managedByCodMate: false)
        for raw in body {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.contains("managed-by=codmate") { p.managedByCodMate = true }
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)

            switch key {
            case "name": p.name = unquote(value)
            case "base_url": p.baseURL = unquote(value)
            case "env_key": p.envKey = unquote(value)
            case "wire_api": p.wireAPI = unquote(value)
            case "query_params": p.queryParamsRaw = value
            case "http_headers": p.httpHeadersRaw = value
            case "env_http_headers": p.envHttpHeadersRaw = value
            case "request_max_retries": p.requestMaxRetries = Int(value.filter { !$0.isWhitespace })
            case "stream_max_retries": p.streamMaxRetries = Int(value.filter { !$0.isWhitespace })
            case "stream_idle_timeout_ms": p.streamIdleTimeoutMs = Int(value.filter { !$0.isWhitespace })
            default: break
            }
        }
        return p
    }

    private func unquote(_ v: String) -> String {
        var s = v.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("\"") && s.hasSuffix("\"") { s.removeFirst(); s.removeLast() }
        return s
    }

    private func parseTopLevelString(key: String, from text: String) -> String? {
        // naive: find first line starting with key =
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(key + " ") || line.hasPrefix(key + "=") else { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            return unquote(value)
        }
        return nil
    }

    private func parseTopLevelArray(key: String, from text: String) -> [String]? {
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(key + " ") || line.hasPrefix(key + "=") else { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            return parseArrayLiteral(value)
        }
        return nil
    }

    // MARK: - Writing helpers

    private func upsertTopLevelString(key: String, value: String?, in text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var found = false
        for i in lines.indices {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(key + " ") || t.hasPrefix(key + "=") {
                if let value {
                    lines[i] = "\(key) = \"\(value)\""
                } else {
                    lines.remove(at: i)
                }
                found = true
                break
            }
        }
        if !found, let value {
            // insert near top (before first table)
            var insertIndex = lines.count
            for (idx, l) in lines.enumerated() where l.trimmingCharacters(in: .whitespaces).hasPrefix("[") {
                insertIndex = idx
                break
            }
            lines.insert("\(key) = \"\(value)\"", at: insertIndex)
        }
        return lines.joined(separator: "\n")
    }

    private func upsertTopLevelBool(key: String, value: Bool, in text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var found = false
        for i in lines.indices {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(key + " ") || t.hasPrefix(key + "=") {
                lines[i] = "\(key) = \(value ? "true" : "false")"
                found = true
                break
            }
        }
        if !found {
            var insertIndex = lines.count
            for (idx, l) in lines.enumerated() where l.trimmingCharacters(in: .whitespaces).hasPrefix("[") {
                insertIndex = idx
                break
            }
            lines.insert("\(key) = \(value ? "true" : "false")", at: insertIndex)
        }
        return lines.joined(separator: "\n")
    }

    private func upsertTopLevelArray(key: String, values: [String]?, in text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var foundIndex: Int? = nil
        for i in lines.indices {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(key + " ") || t.hasPrefix(key + "=") { foundIndex = i; break }
        }
        if let arr = values {
            let literal = renderArrayLiteral(arr)
            if let i = foundIndex {
                lines[i] = "\(key) = \(literal)"
            } else {
                var insertIndex = lines.count
                for (idx, l) in lines.enumerated() where l.trimmingCharacters(in: .whitespaces).hasPrefix("[") { insertIndex = idx; break }
                lines.insert("\(key) = \(literal)", at: insertIndex)
            }
        } else if let i = foundIndex {
            lines.remove(at: i)
        }
        return lines.joined(separator: "\n")
    }

    private func upsertProviderBlock(_ p: CodexProvider, in text: String) -> String {
        let header = "[model_providers.\(p.id)]"
        let body = renderProviderBody(p)
        return replaceTableBlock(header: header, body: body, in: text)
    }

    private func removeProviderBlock(id: String, in text: String) -> String {
        // Remove ALL occurrences of the provider block with this id to avoid leftovers
        let header = "[model_providers.\(id)]"
        var result = text
        while true {
            let newText = replaceTableBlock(header: header, body: nil, in: result)
            if newText == result { break }
            result = newText
        }
        return result
    }

    private func replaceTableBlock(header: String, body: String?, in text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var start: Int? = nil
        var end: Int? = nil
        for (idx, raw) in lines.enumerated() {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t == header { start = idx; continue }
            if start != nil && (t.hasPrefix("[") || t == mcpBeginMarker || t == mcpEndMarker) {
                end = idx
                break
            }
        }

        if let start {
            let stop = end ?? lines.count
            if let body {
                var newBlock = [header]
                newBlock.append(contentsOf: body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
                lines.replaceSubrange(start..<stop, with: newBlock)
            } else {
                lines.removeSubrange(start..<(end ?? lines.count))
            }
        } else if let body {
            var newBlock = [header]
            newBlock.append(contentsOf: body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
            if let idx = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }) {
                lines.insert(contentsOf: newBlock + [""], at: idx + 1)
            } else {
                if !lines.isEmpty { lines.append("") }
                lines.append(contentsOf: newBlock)
                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }

    private func renderProviderBody(_ p: CodexProvider) -> String {
        var out: [String] = []
        out.append("# managed-by=codmate")
        if let name = p.name { out.append("name = \"\(name)\"") }
        if let baseURL = p.baseURL, !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append("base_url = \"\(baseURL)\"")
        }
        if let envKey = p.envKey, !envKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append("env_key = \"\(envKey)\"")
        }
        if let wire0 = p.wireAPI?.trimmingCharacters(in: .whitespacesAndNewlines), !wire0.isEmpty {
            out.append("wire_api = \"\(wire0)\"")
        }
        if let qp = p.queryParamsRaw, !qp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append("query_params = \(qp)")
        }
        if let hh = p.httpHeadersRaw, !hh.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append("http_headers = \(hh)")
        }
        if let ehh = p.envHttpHeadersRaw, !ehh.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append("env_http_headers = \(ehh)")
        }
        if let r = p.requestMaxRetries { out.append("request_max_retries = \(r)") }
        if let r = p.streamMaxRetries { out.append("stream_max_retries = \(r)") }
        if let r = p.streamIdleTimeoutMs { out.append("stream_idle_timeout_ms = \(r)") }
        return out.joined(separator: "\n") + "\n"
    }

    // MARK: - Projects (config-backed)

    func listProjects() -> [Project] {
        let text = (try? String(contentsOf: paths.configURL, encoding: .utf8)) ?? ""
        return parseProjects(from: text)
    }

    // Deprecated: CodMate no longer writes projects to config.toml.
    // Kept for API compatibility; acts as a no-op.
    func upsertProject(_ project: Project) throws {
        _ = project
        return
    }

    // Deprecated: CodMate no longer writes projects to config.toml.
    // Kept for API compatibility; acts as a no-op.
    func deleteProject(id: String) throws { _ = id }

    // MARK: - Canonical providers region rewriter
    private func rewriteProvidersRegion(in text: String, with providers: [CodexProvider]) -> String {
        // 1) Remove all provider blocks (and any stray managed provider bodies without header)
        let stripped = stripProviderLikeBlocks(from: text)
        // 2) Append canonical providers region at the end (if any)
        guard !providers.isEmpty else { return stripped }
        var out = stripped
        // Ensure there is an empty line separator before providers region
        if !out.hasSuffix("\n") { out += "\n" }
        if !out.hasSuffix("\n\n") { out += "\n" }
        for p in providers {
            out += "[model_providers.\(p.id)]\n"
            out += renderProviderBody(p)
            out += "\n"
        }
        return out
    }

    private func rewriteFeaturesBlock(in text: String, overrides: [String: Bool]) -> String {
        var stripped = replaceTableBlock(header: "[features]", body: nil, in: text)
        let entries = overrides.sorted(by: { $0.key < $1.key }).map { key, value in
            "\(key) = \(value ? "true" : "false")"
        }
        guard !entries.isEmpty else { return stripped }
        if !stripped.hasSuffix("\n") { stripped += "\n" }
        if !stripped.hasSuffix("\n\n") { stripped += "\n" }
        stripped += "[features]\n"
        stripped += "# managed-by=codmate\n"
        stripped += entries.joined(separator: "\n") + "\n\n"
        return stripped
    }

    private func parseFeatureOverrides(from text: String) -> [String: Bool] {
        let body = parseTableBody(table: "[features]", from: text)
        var overrides: [String: Bool] = [:]
        for raw in body {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces).lowercased()
            if value == "true" {
                overrides[key] = true
            } else if value == "false" {
                overrides[key] = false
            }
        }
        return overrides
    }

    private func stripProviderLikeBlocks(from text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var keep: [String] = []
        var i = 0
        func isHeader(_ t: String) -> Bool { t.trimmingCharacters(in: .whitespaces).hasPrefix("[") }
        let providerKeys: Set<String> = [
            "name", "base_url", "env_key", "wire_api", "query_params", "http_headers",
            "env_http_headers", "request_max_retries", "stream_max_retries",
            "stream_idle_timeout_ms",
        ]
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            // Remove normal provider blocks
            if t.hasPrefix("[model_providers.") && t.hasSuffix("]") {
                // skip until next header or EOF
                i += 1
                while i < lines.count {
                    let t2 = lines[i].trimmingCharacters(in: .whitespaces)
                    if isHeader(t2) { break }
                    i += 1
                }
                continue
            }
            // Remove stray managed provider bodies without header (best-effort):
            // A sequence starting with '# managed-by=codmate' followed by lines whose keys
            // are all within providerKeys constitutes such a body.
            if t.contains("managed-by=codmate") {
                _ = i
                var j = i + 1
                var looksLikeProvider = false
                while j < lines.count {
                    let raw = lines[j]
                    let tr = raw.trimmingCharacters(in: .whitespaces)
                    if tr.isEmpty { j += 1; continue }
                    if isHeader(tr) { break }
                    // key check
                    if let eq = tr.firstIndex(of: "=") {
                        let key = tr[..<eq].trimmingCharacters(in: .whitespaces)
                        if providerKeys.contains(key) { looksLikeProvider = true; j += 1; continue }
                    }
                    // encountered a non-provider-looking line — stop
                    break
                }
                if looksLikeProvider {
                    // drop [start, j)
                    i = j
                    continue
                }
            }
            // Keep line
            keep.append(lines[i])
            i += 1
        }
        return keep.joined(separator: "\n")
    }

    // MARK: - Projects region rewriter and parser

    private func parseProjects(from text: String) -> [Project] {
        var map: [String: Project] = [:]
        var order: [String] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if let id = matchProjectHeader(line) {
                var j = i + 1
                var body: [String] = []
                while j < lines.count {
                    let l = lines[j]
                    if l.trimmingCharacters(in: .whitespaces).hasPrefix("[") { break }
                    body.append(l)
                    j += 1
                }
                let p = parseProjectBody(id: id, body: body)
                map[id] = p
                if !order.contains(id) { order.append(id) }
                i = j
                continue
            }
            i += 1
        }
        return order.compactMap { map[$0] }
    }

    private func matchProjectHeader(_ line: String) -> String? {
        // [projects.<id>]
        guard line.hasPrefix("[projects.") && line.hasSuffix("]") else { return nil }
        let start = "[projects.".count
        let endIndex = line.index(before: line.endIndex)
        let id = String(line[line.index(line.startIndex, offsetBy: start)..<endIndex])
        return id.trimmingCharacters(in: .whitespaces)
    }

    private func parseProjectBody(id: String, body: [String]) -> Project {
        var name: String = id
        var directory: String? = nil
        var trust: String? = nil
        var overview: String? = nil
        var instructions: String? = nil
        var profile: String? = nil
        for raw in body {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "name": name = unquote(value)
            case "directory": directory = unquote(value)
            case "path": if directory == nil || directory == "" { directory = unquote(value) }
            case "trust_level": trust = unquote(value)
            case "overview": overview = unquote(value)
            case "instructions": instructions = unquote(value)
            case "profile": profile = unquote(value)
            default: break
            }
        }
        // Normalize directory: treat empty string as nil
        let dirNorm: String? = {
            guard let d = directory?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
            return d.isEmpty ? nil : d
        }()
        return Project(id: id, name: name, directory: dirNorm, trustLevel: trust, overview: overview, instructions: instructions, profileId: profile)
    }

    private func renderProjectBody(_ p: Project) -> String {
        var out: [String] = []
        out.append("# managed-by=codmate")
        if !p.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append("name = \"\(p.name)\"") }
        if let dir = p.directory, !dir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append("directory = \"\(dir)\"")
        }
        if let v = p.trustLevel, !v.isEmpty { out.append("trust_level = \"\(v)\"") }
        if let v = p.overview, !v.isEmpty { out.append("overview = \"\(v)\"") }
        if let v = p.instructions, !v.isEmpty { out.append("instructions = \"\(v)\"") }
        if let v = p.profileId, !v.isEmpty { out.append("profile = \"\(v)\"") }
        return out.joined(separator: "\n") + "\n"
    }

    private func rewriteProjectsRegion(in text: String, with projects: [Project]) -> String {
        // Remove all project blocks
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Pass 1: strip all [projects.*] blocks
        do {
            var i = 0
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("[projects.") && t.hasSuffix("]") {
                    var j = i + 1
                    while j < lines.count {
                        let tt = lines[j].trimmingCharacters(in: .whitespaces)
                        if tt.hasPrefix("[") { break }
                        j += 1
                    }
                    lines.removeSubrange(i..<j)
                    continue
                }
                i += 1
            }
        }
        var out = lines.joined(separator: "\n")
        guard !projects.isEmpty else { return out }
        if !out.hasSuffix("\n") { out += "\n" }
        if !out.hasSuffix("\n\n") { out += "\n" }
        for p in projects {
            out += "[projects.\(p.id)]\n"
            out += renderProjectBody(p)
            out += "\n"
        }
        return out
    }

    private func countStrayProviderBodies(in text: String) -> Int {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        var count = 0
        func isHeader(_ t: String) -> Bool { t.trimmingCharacters(in: .whitespaces).hasPrefix("[") }
        let providerKeys: Set<String> = [
            "name", "base_url", "env_key", "wire_api", "query_params", "http_headers",
            "env_http_headers", "request_max_retries", "stream_max_retries",
            "stream_idle_timeout_ms",
        ]
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.contains("managed-by=codmate") {
                var j = i + 1
                var looksLikeProvider = false
                while j < lines.count {
                    let tr = lines[j].trimmingCharacters(in: .whitespaces)
                    if tr.isEmpty { j += 1; continue }
                    if isHeader(tr) { break }
                    if let eq = tr.firstIndex(of: "=") {
                        let key = tr[..<eq].trimmingCharacters(in: .whitespaces)
                        if providerKeys.contains(key) { looksLikeProvider = true; j += 1; continue }
                    }
                    break
                }
                if looksLikeProvider { count += 1; i = j; continue }
            }
            i += 1
        }
        return count
    }

    // MARK: - Migration helpers
    // Ensure boolean keys are written as bare booleans (true/false), not quoted strings.
    func sanitizeQuotedBooleans() -> Bool {
        var text = (try? String(contentsOf: paths.configURL, encoding: .utf8)) ?? ""
        let keys = ["show_raw_agent_reasoning", "hide_agent_reasoning"]
        var changed = false
        for key in keys {
            let (newText, didChange) = ensureTopLevelBoolLiteral(key: key, in: text)
            if didChange { text = newText; changed = true }
        }
        if changed {
            do { try writeConfig(text) } catch { /* ignore */ }
        }
        return changed
    }

    private func ensureTopLevelBoolLiteral(key: String, in text: String) -> (String, Bool) {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var changed = false
        for i in lines.indices {
            let raw = lines[i]
            let t = raw.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix(key + " ") || t.hasPrefix(key + "=") else { continue }
            guard let eq = raw.firstIndex(of: "=") else { continue }
            let prefix = String(raw[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(raw[raw.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            // If value starts with a quote, rewrite as bare boolean when it matches true/false
            if value.hasPrefix("\"") && value.hasSuffix("\"") {
                let unq = unquote(value).lowercased()
                if unq == "true" || unq == "false" {
                    lines[i] = "\(prefix) = \(unq)"
                    changed = true
                }
            }
            break
        }
        return (lines.joined(separator: "\n"), changed)
    }

    private func parseTableBody(table: String, from text: String) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var start: Int?; var end: Int?
        for (idx, raw) in lines.enumerated() {
            if raw.trimmingCharacters(in: .whitespaces) == table { start = idx + 1; continue }
            if let _ = start, raw.trimmingCharacters(in: .whitespaces).hasPrefix("[") { end = idx; break }
        }
        guard let s = start else { return [] }
        let e = end ?? lines.count
        return Array(lines[s..<e])
    }

    private func parseTableKeyValue(table: String, key: String, from text: String) -> String? {
        let body = parseTableBody(table: table, from: text)
        for raw in body {
            let t = raw.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { continue }
            let k = t[..<eq].trimmingCharacters(in: .whitespaces)
            if k == key { return String(t[t.index(after: eq)...]).trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    private func upsertTableKeyValue(table: String, key: String, valueText: String, in text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var start: Int?; var end: Int?
        for (idx, raw) in lines.enumerated() {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t == table { start = idx; continue }
            if let _ = start, t.hasPrefix("[") { end = idx; break }
        }
        if let s = start {
            let e = end ?? lines.count
            var replaced = false
            if e > s {
                for i in (s+1)..<e {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { continue }
                    let k = t[..<eq].trimmingCharacters(in: .whitespaces)
                    if k == key {
                        lines[i] = "\(key) = \(valueText)"
                        replaced = true
                        break
                    }
                }
            }
            if !replaced { lines.insert("\(key) = \(valueText)", at: e) }
            return lines.joined(separator: "\n")
        } else {
            let block = [table, "# managed-by=codmate", "\(key) = \(valueText)", ""]
            if let idx = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }) {
                lines.insert(contentsOf: block, at: idx + 1)
            } else {
                if !lines.isEmpty { lines.append("") }
                lines.append(contentsOf: block)
            }
            return lines.joined(separator: "\n")
        }
    }

    private func parseArrayLiteral(_ value: String) -> [String]? {
        var s = value.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("[") && s.hasSuffix("]") else { return nil }
        s.removeFirst(); s.removeLast()
        if s.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
        let parts = s.split(separator: ",").map { unquote(String($0)).trimmingCharacters(in: .whitespaces) }
        return parts
    }

    private func renderArrayLiteral(_ arr: [String]) -> String {
        let quoted = arr.map { "\"\($0)\"" }.joined(separator: ", ")
        return "[\(quoted)]"
    }

    private func parseInlineTable(_ value: String) -> [String:String]? {
        var s = value.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("{") && s.hasSuffix("}") else { return nil }
        s.removeFirst(); s.removeLast()
        if s.trimmingCharacters(in: .whitespaces).isEmpty { return [:] }
        var dict: [String:String] = [:]
        for part in s.split(separator: ",") {
            let seg = String(part)
            guard let eq = seg.firstIndex(of: "=") else { continue }
            let k = seg[..<eq].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "")
            let v = seg[seg.index(after: eq)...].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "")
            dict[k] = v
        }
        return dict
    }

    private func renderInlineTable(_ dict: [String:String]) -> String {
        let parts = dict.map { key, val in "\"\(key)\" = \"\(val)\"" }.sorted().joined(separator: ", ")
        return "{ \(parts) }"
    }

    private func extractInlineEndpoint(from exporterLine: String) -> String? {
        guard let r = exporterLine.range(of: "endpoint") else { return nil }
        let sub = exporterLine[r.lowerBound...]
        if let eq = sub.firstIndex(of: "=") {
            let after = sub[sub.index(after: eq)...]
            let trimmed = String(after).trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\"") {
                let s = trimmed
                if let q2 = s.dropFirst().firstIndex(of: "\"") {
                    let val = s[s.index(after: s.startIndex)..<q2]
                    return String(val)
                }
            }
        }
        return nil
    }
}

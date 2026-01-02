import Foundation
import AppKit
import SwiftUI

/// Manages the CLIProxyAPI binary process and configuration.
/// Integrates the CLI Proxy capability into CodMate.
@MainActor
final class CLIProxyService: ObservableObject {
    static let shared = CLIProxyService()

    // MARK: - Properties
    
    @Published var isRunning = false
    @Published var isInstalling = false
    @Published var installProgress: Double = 0
    @Published var lastError: String?
    @Published var loginPrompt: LoginPrompt?

    struct LoginPrompt: Identifiable, Equatable {
        let id = UUID()
        let provider: LocalAuthProvider
        let message: String
    }

    struct LocalModelList: Decodable {
        let data: [LocalModel]
    }

    struct LocalModel: Decodable, Hashable {
        let id: String
        let owned_by: String?
        let provider: String?
        let source: String?
    }
    
    // Log streaming
    @Published var logs: String = ""
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    
    var port: UInt16 {
        let p = UserDefaults.standard.integer(forKey: "codmate.localserver.port")
        return p > 0 ? UInt16(p) : 8080
    }
    
    private var process: Process?
    private var loginProcess: Process?
    private var loginInputPipe: Pipe?
    private var loginProvider: LocalAuthProvider?
    private var loginCancellationRequested = false
    private var openedLoginURL: URL?
    private let proxyBridge = CLIProxyBridge()
    
    // Paths
    private let binaryPath: String
    private let configPath: String
    private let authDir: String
    private let managementKey: String
    
    // Constants
    private static let githubRepo = "router-for-me/CLIProxyAPIPlus"
    private static let binaryName = "CLIProxyAPI"
    
    private var internalPort: UInt16 {
        CLIProxyBridge.internalPort(from: port)
    }
    
    init() {
        // Setup paths in Application Support
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let codMateDir = appSupport.appendingPathComponent("CodMate")
        let binDir = codMateDir.appendingPathComponent("bin", isDirectory: true)
        try? FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        
        self.binaryPath = binDir.appendingPathComponent(Self.binaryName).path
        self.configPath = codMateDir.appendingPathComponent("config.yaml").path
        self.authDir = homeDir.appendingPathComponent(".codmate/auth").path
        
        // Persistent Management Key
        if let savedKey = UserDefaults.standard.string(forKey: "CLIProxyManagementKey") {
            self.managementKey = savedKey
        } else {
            self.managementKey = UUID().uuidString
            UserDefaults.standard.set(self.managementKey, forKey: "CLIProxyManagementKey")
        }
        
        try? FileManager.default.createDirectory(atPath: authDir, withIntermediateDirectories: true)
        ensureConfigExists()
    }
    
    // MARK: - Process Management
    
    func start() async throws {
        guard isBinaryInstalled else {
            appendLog("Binary not found. Please install it first.\n", isError: true)
            throw ServiceError.binaryNotFound
        }
        
        guard !isRunning else {
            appendLog("Service is already running.\n")
            return
        }
        
        lastError = nil
        
        // Cleanup old processes
        cleanupOrphanProcesses()
        
        // Update config with correct internal port (since we use bridge mode)
        updateConfigPort(internalPort)
        
        // --- Diagnostic Section ---
        appendLog("Inspecting binary at \(binaryPath)...\n")
        let fileOutput = runShell(command: "/usr/bin/file", args: [binaryPath])
        appendLog("-> File type: \(fileOutput.trimmingCharacters(in: .whitespacesAndNewlines))\n")
        
        let lsOutput = runShell(command: "/bin/ls", args: ["-l", binaryPath])
        appendLog("-> Permissions: \(lsOutput.trimmingCharacters(in: .whitespacesAndNewlines))\n")
        // --- End Diagnostic Section ---

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["-config", configPath]
        process.currentDirectoryURL = URL(fileURLWithPath: binaryPath).deletingLastPathComponent()
        
        // Environment
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        process.environment = env
        
        // Log Capture
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        self.outputPipe = out
        self.errorPipe = err
        
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                Task { @MainActor [weak self] in self?.appendLog(str) }
            }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                Task { @MainActor [weak self] in self?.appendLog(str, isError: true) }
            }
        }
        
        process.terminationHandler = { [weak self] terminatedProcess in
            Task { @MainActor in
                self?.isRunning = false
                self?.process = nil
                self?.proxyBridge.stop()
                self?.outputPipe?.fileHandleForReading.readabilityHandler = nil
                self?.errorPipe?.fileHandleForReading.readabilityHandler = nil
                
                let reason: String
                switch terminatedProcess.terminationReason {
                case .exit:
                    reason = "Exited with code \(terminatedProcess.terminationStatus)"
                case .uncaughtSignal:
                    reason = "Terminated by signal \(terminatedProcess.terminationStatus)"
                @unknown default:
                    reason = "Unknown reason"
                }
                self?.appendLog("Service stopped. \(reason)\n", isError: terminatedProcess.terminationStatus != 0)
            }
        }
        
        do {
            appendLog("Starting Local AI Server on port \(internalPort)...\n")
            try process.run()
            self.process = process
            
            // Wait for startup
            try await Task.sleep(nanoseconds: 1_500_000_000)
            
            guard process.isRunning else {
                let reason: String
                switch process.terminationReason {
                case .exit:
                    reason = "Exited with code \(process.terminationStatus)"
                case .uncaughtSignal:
                    reason = "Terminated by signal \(process.terminationStatus)"
                @unknown default:
                    reason = "Unknown reason"
                }
                let errText = "Process failed to stay running. \(reason)."
                appendLog(errText + "\n", isError: true)
                throw ServiceError.startupFailed
            }
            
            // Start Proxy Bridge
            proxyBridge.configure(listenPort: port, targetPort: internalPort)
            proxyBridge.start()
            
            // Wait for bridge
            try await Task.sleep(nanoseconds: 500_000_000)
            
            if !proxyBridge.isRunning {
                process.terminate()
                appendLog("Proxy bridge failed to start.\n", isError: true)
                throw ServiceError.startupFailed
            }
            
            isRunning = true
            appendLog("Service started successfully.\n")
            
        } catch {
            lastError = error.localizedDescription
            appendLog("Error starting service: \(error.localizedDescription)\n", isError: true)
            throw error
        }
    }
    
    func stop() {
        proxyBridge.stop()
        
        if let p = process, p.isRunning {
            p.terminate()
        }
        process = nil
        
        cleanupOrphanProcesses()
        isRunning = false
    }
    
    func clearLogs() {
        logs = ""
    }
    
    private func appendLog(_ text: String, isError: Bool = false) {
        // Keep last 50k characters to avoid memory issues
        if logs.count > 50000 {
            logs = String(logs.suffix(40000))
        }
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logs.append("[\(timestamp)] \(text)")
    }
    
    // MARK: - Installation
    
    var isBinaryInstalled: Bool {
        FileManager.default.fileExists(atPath: binaryPath)
    }
    
    var binaryFilePath: String {
        binaryPath
    }
    
    func install() async throws {
        isInstalling = true
        installProgress = 0
        defer { isInstalling = false }
        
        do {
            let release = try await fetchLatestRelease()
            guard let asset = findCompatibleAsset(in: release) else {
                throw ServiceError.noCompatibleBinary
            }
            
            installProgress = 0.2
            let data = try await downloadAsset(url: asset.downloadURL)
            installProgress = 0.7
            
            try await extractAndInstall(data: data, assetName: asset.name)
            installProgress = 1.0
            
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    func login(provider: LocalAuthProvider) async throws {
        guard isBinaryInstalled else {
            appendLog("Binary not found. Please install it first.\n", isError: true)
            throw ServiceError.binaryNotFound
        }

        openedLoginURL = nil

        // Qwen: Skip CLI --no-browser mode, use management OAuth directly
        // The CLI device code flow has reliability issues with browser callback detection
        if provider == .qwen {
            appendLog("Starting \(provider.displayName) login via management API...\n")
            try await loginViaManagement(provider: provider)
            return
        }

        let flag = provider.loginFlag

        appendLog("Starting \(provider.displayName) login...\n")
        do {
            try await withTaskCancellationHandler {
                try await runCLI(arguments: ["-config", configPath, flag], loginProvider: provider)
            } onCancel: {
                Task { @MainActor in
                    self.cancelLogin()
                }
            }
            appendLog("\(provider.displayName) login finished.\n")
        } catch is CancellationError {
            appendLog("\(provider.displayName) login cancelled.\n")
            throw CancellationError()
        }
    }

    func cancelLogin() {
        loginCancellationRequested = true
        if let process = loginProcess, process.isRunning {
            process.terminate()
        }
        loginPrompt = nil
        openedLoginURL = nil
    }

    func logout(provider: LocalAuthProvider) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: authDir) else { return }
        let aliases = provider.authAliases.map { $0.lowercased() }
        var removed = 0
        for name in items {
            let lower = name.lowercased()
            guard lower.hasSuffix(".json") else { continue }
            let path = (authDir as NSString).appendingPathComponent(name)
            if aliases.contains(where: { lower.contains($0) }) {
                try? fm.removeItem(atPath: path)
                removed += 1
                continue
            }
            if fileContainsProviderType(path: path, providers: aliases) {
                try? fm.removeItem(atPath: path)
                removed += 1
            }
        }
        if removed > 0 {
            appendLog("Removed \(removed) \(provider.displayName) credential file(s).\n")
        }
    }

    func hasAuthToken(for provider: LocalAuthProvider) -> Bool {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: authDir) else { return false }
        let normalized = items.map { $0.lowercased() }
        let aliases = provider.authAliases.map { $0.lowercased() }
        for (idx, name) in normalized.enumerated() {
            guard name.hasSuffix(".json") else { continue }
            if aliases.contains(where: { name.contains($0) }) { return true }
            let original = items[idx]
            let path = (authDir as NSString).appendingPathComponent(original)
            if fileContainsProviderType(path: path, providers: aliases) {
                return true
            }
        }
        return false
    }

    private func fileContainsProviderType(path: String, providers: [String]) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return false }
        guard let text = String(data: data, encoding: .utf8) else { return false }
        let lower = text.lowercased()
        for provider in providers {
            let patterns = [
                "\"type\":\"\(provider)\"",
                "\"type\": \"\(provider)\"",
                "\"provider\":\"\(provider)\"",
                "\"provider\": \"\(provider)\""
            ]
            if patterns.contains(where: { lower.contains($0) }) {
                return true
            }
        }
        return false
    }

    func submitLoginInput(_ input: String) {
        guard let pipe = loginInputPipe else { return }
        let payload = input.hasSuffix("\n") ? input : (input + "\n")
        if let data = payload.data(using: .utf8) {
            pipe.fileHandleForWriting.write(data)
        }
    }

    func loadPublicAPIKey() -> String? {
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else { return nil }
        var inKeys = false
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("api-keys:") {
                inKeys = true
                continue
            }
            if inKeys {
                if trimmed.hasPrefix("-") {
                    var value = trimmed
                    if let range = value.range(of: "-") {
                        value = String(value[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    }
                    if value.hasPrefix("\"") && value.hasSuffix("\"") {
                        value.removeFirst()
                        value.removeLast()
                    }
                    return value.trimmingCharacters(in: .whitespaces)
                }
                if !trimmed.isEmpty {
                    inKeys = false
                }
            }
        }
        return nil
    }

    func fetchLocalModels() async -> [LocalModel] {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/models") else { return [] }
        var request = URLRequest(url: url)
        if let key = loadPublicAPIKey(), !key.isEmpty {
            let bearer = key.hasPrefix("Bearer ") ? key : "Bearer \(key)"
            request.setValue(bearer, forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
            return (try? JSONDecoder().decode(LocalModelList.self, from: data))?.data ?? []
        } catch {
            return []
        }
    }

    func updatePublicAPIKey(_ key: String) {
        guard FileManager.default.fileExists(atPath: configPath),
              var content = try? String(contentsOfFile: configPath, encoding: .utf8) else { return }

        let lines = content.components(separatedBy: .newlines)
        var out: [String] = []
        var inKeys = false
        var replaced = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("api-keys:") {
                inKeys = true
                out.append(line)
                continue
            }
            if inKeys {
                if trimmed.hasPrefix("-") {
                    if !replaced {
                        let indent = line.prefix { $0 == " " || $0 == "\t" }
                        out.append("\(indent)- \"\(key)\"")
                        replaced = true
                    } else {
                        out.append(line)
                    }
                    continue
                }
                if !trimmed.isEmpty {
                    if !replaced {
                        out.append("  - \"\(key)\"")
                        replaced = true
                    }
                    inKeys = false
                }
            }
            out.append(line)
        }

        if inKeys && !replaced {
            out.append("  - \"\(key)\"")
        }

        content = out.joined(separator: "\n")
        try? content.write(toFile: configPath, atomically: true, encoding: .utf8)
    }

    func generatePublicAPIKey(minLength: Int = 20) -> String {
        let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        if raw.count >= minLength {
            return "codmate-\(raw.prefix(minLength))"
        }
        let padding = String(repeating: "x", count: max(0, minLength - raw.count))
        return "codmate-\(raw)\(padding)"
    }
    
    // MARK: - Helpers
    
    private func cleanupOrphanProcesses() {
        killProcessOnPort(port)
        killProcessOnPort(internalPort)
    }
    
    private func killProcessOnPort(_ port: UInt16) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-ti", "tcp:\(port)"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        
        try? task.run()
        task.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8) {
            for line in output.components(separatedBy: .newlines) {
                if let pid = Int32(line.trimmingCharacters(in: .whitespaces)) {
                    kill(pid, SIGKILL)
                }
            }
        }
    }
    
    private func ensureConfigExists() {
        guard !FileManager.default.fileExists(atPath: configPath) else { return }

        let config = """
host: \"127.0.0.1\"
port: \(internalPort)
auth-dir: \"\(authDir)\"

api-keys:
  - \"codmate-local-\(UUID().uuidString.prefix(8))\"

remote-management:
  allow-remote: false
  secret-key: \"\(managementKey)\"

debug: false
logging-to-file: false
usage-statistics-enabled: true

routing:
  strategy: \"round-robin\"
"""

        try? config.write(toFile: configPath, atomically: true, encoding: .utf8)
    }

    func syncThirdPartyProviders() async {
        let registry = ProvidersRegistryService()
        let providers = await registry.listProviders()

        var config = """
host: \"127.0.0.1\"
port: \(internalPort)
auth-dir: \"\(authDir)\"

api-keys:
  - \"codmate-local-\(UUID().uuidString.prefix(8))\"

remote-management:
  allow-remote: false
  secret-key: \"\(managementKey)\"

debug: false
logging-to-file: false
usage-statistics-enabled: true

routing:
  strategy: \"round-robin\"

"""

        // Append third-party providers configuration
        var sections: [String] = []

        for provider in providers {
            // Check for OpenAI-compatible providers (Codex connector)
            if let codexConnector = provider.connectors[ProvidersRegistryService.Consumer.codex.rawValue],
               let baseURL = codexConnector.baseURL,
               !baseURL.isEmpty {

                let envKey = provider.envKey ?? codexConnector.envKey ?? "OPENAI_API_KEY"
                if let apiKey = ProcessInfo.processInfo.environment[envKey], !apiKey.isEmpty {
                    let providerName = provider.name ?? provider.id
                    let section = """
# Third-party provider: \(providerName)
openai:
  - name: "\(providerName)"
    base-url: "\(baseURL)"
    api-key: "\(apiKey)"
"""
                    sections.append(section)
                }
            }

            // Check for Claude-compatible providers
            if let claudeConnector = provider.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue],
               let baseURL = claudeConnector.baseURL,
               !baseURL.isEmpty {

                let envKey = provider.envKey ?? claudeConnector.envKey ?? "ANTHROPIC_API_KEY"
                if let apiKey = ProcessInfo.processInfo.environment[envKey], !apiKey.isEmpty {
                    let providerName = provider.name ?? provider.id
                    let section = """
# Third-party provider: \(providerName)
claude:
  - name: "\(providerName)"
    base-url: "\(baseURL)"
    api-key: "\(apiKey)"
"""
                    sections.append(section)
                }
            }
        }

        if !sections.isEmpty {
            config += sections.joined(separator: "\n\n")
        }

        try? config.write(toFile: configPath, atomically: true, encoding: .utf8)
        appendLog("Synced \(sections.count) third-party provider(s) to config.\n")

        // Restart service if running to apply new config
        if isRunning {
            appendLog("Restarting service to apply configuration changes...\n")
            stop()
            try? await Task.sleep(nanoseconds: 500_000_000)
            try? await start()
        }
    }
    
    private func updateConfigPort(_ newPort: UInt16) {
        guard FileManager.default.fileExists(atPath: configPath),
              var content = try? String(contentsOfFile: configPath, encoding: .utf8) else { return }
        
        if let range = content.range(of: #"port:\s*\d+"#, options: .regularExpression) {
            content.replaceSubrange(range, with: "port: \(newPort)")
            try? content.write(toFile: configPath, atomically: true, encoding: .utf8)
        }
    }
    
    // MARK: - GitHub API
    
    private struct ReleaseInfo: Decodable {
        let assets: [AssetInfo]
    }
    
    private struct AssetInfo: Decodable {
        let name: String
        let browser_download_url: String
        var downloadURL: String { browser_download_url }
    }
    
    private struct CompatibleAsset {
        let name: String
        let downloadURL: String
    }
    
    private func fetchLatestRelease() async throws -> ReleaseInfo {
        let url = URL(string: "https://api.github.com/repos/\(Self.githubRepo)/releases/latest")!
        var req = URLRequest(url: url)
        req.addValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw ServiceError.networkError
        }
        return try JSONDecoder().decode(ReleaseInfo.self, from: data)
    }
    
    private func findCompatibleAsset(in release: ReleaseInfo) -> CompatibleAsset? {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "amd64"
        #endif
        let target = "darwin_\(arch)"
        
        for asset in release.assets {
            let name = asset.name.lowercased()
            if name.contains(target) && !name.contains("checksum") {
                return CompatibleAsset(name: asset.name, downloadURL: asset.downloadURL)
            }
        }
        return nil
    }
    
    private func downloadAsset(url: String) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(from: URL(string: url)!)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw ServiceError.networkError
        }
        return data
    }
    
    private func extractAndInstall(data: Data, assetName: String) async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let archivePath = tempDir.appendingPathComponent(assetName)
        try data.write(to: archivePath)
        
        // Extract
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", archivePath.path, "-C", tempDir.path]
        try tar.run()
        tar.waitUntilExit()
        
        // Find binary
        let binary = search(tempDir)
        
        guard let validBinary = binary else {
            throw ServiceError.extractionFailed
        }
        
        if FileManager.default.fileExists(atPath: binaryPath) {
            try FileManager.default.removeItem(atPath: binaryPath)
        }
        try FileManager.default.copyItem(at: validBinary, to: URL(fileURLWithPath: binaryPath))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryPath)
    }
    
    private func runShell(command: String, args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = args
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? "Failed to read output"
        } catch {
            return "Failed to run command: \(error.localizedDescription)"
        }
    }

    private func runCLI(arguments: [String], loginProvider: LocalAuthProvider? = nil) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: binaryPath).deletingLastPathComponent()

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        process.environment = env

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        if loginProvider != nil {
            let input = Pipe()
            process.standardInput = input
            self.loginInputPipe = input
        }

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                Task { @MainActor [weak self] in
                    self?.appendLog(str)
                    if let provider = self?.loginProvider {
                        self?.detectLoginURL(in: str, provider: provider)
                        self?.detectLoginPrompt(in: str)
                    }
                }
            }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                Task { @MainActor [weak self] in
                    self?.appendLog(str, isError: true)
                    if let provider = self?.loginProvider {
                        self?.detectLoginURL(in: str, provider: provider)
                        self?.detectLoginPrompt(in: str)
                    }
                }
            }
        }

        if let provider = loginProvider {
            self.loginProvider = provider
            self.loginProcess = process
            self.loginCancellationRequested = false
        }

        defer {
            if loginProvider != nil {
                self.loginProvider = nil
                self.loginProcess = nil
                self.loginInputPipe = nil
                self.loginPrompt = nil
                self.openedLoginURL = nil
            }
        }

        do {
            try process.run()
        } catch {
            appendLog("Failed to start CLIProxyAPI: \(error.localizedDescription)\n", isError: true)
            throw ServiceError.loginFailed
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                continuation.resume(returning: ())
            }
        }

        if loginProvider != nil, loginCancellationRequested {
            loginCancellationRequested = false
            throw CancellationError()
        }

        if process.terminationStatus != 0 {
            appendLog("CLIProxyAPI exited with code \(process.terminationStatus).\n", isError: true)
            throw ServiceError.loginFailed
        }
    }

    private func detectLoginPrompt(in text: String) {
        guard let provider = loginProvider else { return }
        let lower = text.lowercased()
        let prompt: String?
        if lower.contains("paste the codex callback url") || lower.contains("paste the callback url") {
            if provider == .codex {
                submitLoginInput("")
                appendLog("Codex callback prompt detected; continuing to wait.\n")
                return
            }
            if provider == .gemini {
                submitLoginInput("")
                appendLog("Gemini callback prompt detected; continuing to wait.\n")
                return
            }
            prompt = "Paste the callback URL"
        } else if lower.contains("enter project id") {
            if provider == .gemini {
                submitLoginInput("")
                appendLog("Gemini project prompt detected; using default project.\n")
                return
            }
            prompt = "Enter project ID or ALL"
        } else if lower.contains("device code")
                    || lower.contains("verification code")
                    || lower.contains("enter code")
                    || lower.contains("input code")
                    || lower.contains("paste code")
                    || lower.contains("设备码")
                    || lower.contains("验证码")
                    || lower.contains("输入验证码")
                    || lower.contains("输入代码")
                    || lower.contains("输入设备码") {
            prompt = "Enter device or verification code"
        } else if lower.contains("enter email")
                    || lower.contains("enter your email")
                    || lower.contains("enter nickname")
                    || lower.contains("enter a nickname")
                    || lower.contains("enter name")
                    || lower.contains("enter username")
                    || lower.contains("enter alias")
                    || lower.contains("enter account")
                    || lower.contains("enter label")
                    || lower.contains("enter display name")
                    || lower.contains("输入邮箱")
                    || lower.contains("输入昵称")
                    || lower.contains("输入名字")
                    || lower.contains("输入名称")
                    || lower.contains("输入用户名")
                    || lower.contains("输入别名")
                    || lower.contains("输入账号")
                    || lower.contains("输入账户")
                    || lower.contains("输入账号名称")
                    || lower.contains("输入账户名称")
                    || lower.contains("输入账号别名")
                    || lower.contains("输入账户别名") {
            prompt = "Enter email or nickname"
        } else {
            prompt = nil
        }

        guard let message = prompt else { return }
        if loginPrompt?.message == message && loginPrompt?.provider == provider {
            return
        }
        loginPrompt = LoginPrompt(provider: provider, message: message)
    }

    private func detectLoginURL(in text: String, provider: LocalAuthProvider) {
        guard provider == .qwen else { return }
        guard openedLoginURL == nil else { return }
        guard text.contains("http") else { return }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in detector.matches(in: text, options: [], range: range) {
            guard let url = match.url else { continue }
            openedLoginURL = url
            appendLog("Opening \(provider.displayName) login URL...\n")
            NSWorkspace.shared.open(url)
            break
        }
    }

    private struct ManagementAuthURLResponse: Decodable {
        let status: String?
        let url: String?
        let state: String?
        let error: String?
    }

    private struct ManagementAuthStatusResponse: Decodable {
        let status: String?
        let error: String?
    }

    private func loginViaManagement(provider: LocalAuthProvider) async throws {
        let shouldStopAfter = !isRunning
        if shouldStopAfter {
            appendLog("Starting local server for \(provider.displayName) login...\n")
            try await start()
        }
        defer {
            if shouldStopAfter {
                stop()
            }
        }

        let (authURL, state) = try await fetchManagementAuthURL(for: provider)
        appendLog("Opening browser for \(provider.displayName) login...\n")
        NSWorkspace.shared.open(authURL)

        guard let state, !state.isEmpty else {
            appendLog("Missing auth state for \(provider.displayName) login.\n", isError: true)
            throw ServiceError.loginFailed
        }

        try await waitForAuthCompletion(state: state, provider: provider)
        appendLog("\(provider.displayName) login finished.\n")
    }

    private func fetchManagementAuthURL(for provider: LocalAuthProvider) async throws -> (URL, String?) {
        guard let endpoint = managementAuthEndpoint(for: provider),
              let request = managementRequest(path: endpoint) else {
            throw ServiceError.networkError
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ServiceError.networkError
        }
        let payload = try JSONDecoder().decode(ManagementAuthURLResponse.self, from: data)
        guard payload.status?.lowercased() == "ok",
              let urlText = payload.url,
              let url = URL(string: urlText) else {
            throw ServiceError.loginFailed
        }
        return (url, payload.state)
    }

    private func waitForAuthCompletion(state: String, provider: LocalAuthProvider) async throws {
        let timeoutSeconds: TimeInterval = 180
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            try Task.checkCancellation()
            let status = try await fetchAuthStatus(state: state)
            switch status {
            case "ok":
                return
            case "error":
                appendLog("\(provider.displayName) login failed.\n", isError: true)
                throw ServiceError.loginFailed
            default:
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        appendLog("\(provider.displayName) login timed out.\n", isError: true)
        throw ServiceError.loginFailed
    }

    private func fetchAuthStatus(state: String) async throws -> String {
        let query = [URLQueryItem(name: "state", value: state)]
        guard let request = managementRequest(path: "get-auth-status", queryItems: query) else {
            throw ServiceError.networkError
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ServiceError.networkError
        }
        let payload = try JSONDecoder().decode(ManagementAuthStatusResponse.self, from: data)
        return payload.status?.lowercased() ?? "error"
    }

    private func managementAuthEndpoint(for provider: LocalAuthProvider) -> String? {
        switch provider {
        case .codex: return "codex-auth-url"
        case .claude: return "anthropic-auth-url"
        case .gemini: return "gemini-cli-auth-url"
        case .antigravity: return "antigravity-auth-url"
        case .qwen: return "qwen-auth-url"
        }
    }

    private func managementRequest(path: String, queryItems: [URLQueryItem]? = nil) -> URLRequest? {
        guard var components = URLComponents(string: "http://127.0.0.1:\(internalPort)/v0/management/\(path)") else {
            return nil
        }
        if let queryItems, !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        return request
    }
    
    private func search(_ dir: URL) -> URL? {
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isExecutableKey, .isDirectoryKey]) else { return nil }
        
        let candidates = ["cliproxyapiplus", "cliproxyapi", "cli-proxy-api", "cli-proxy-api-plus"]
        
        for item in items {
            if let vals = try? item.resourceValues(forKeys: [.isDirectoryKey]), vals.isDirectory == true {
                 if let found = search(item) { return found }
                 continue
            }
            
            let name = item.lastPathComponent.lowercased()
            if candidates.contains(name) { return item }
            if name.contains("cliproxy") && !name.contains(".txt") && !name.contains(".md") && !name.contains(".gz") {
                return item
            }
        }
        return nil
    }
}

enum ServiceError: LocalizedError {
    case binaryNotFound
    case startupFailed
    case networkError
    case noCompatibleBinary
    case extractionFailed
    case loginFailed
    
    var errorDescription: String? {
        switch self {
        case .binaryNotFound: return "CLIProxyAPI binary not found. Please install it first."
        case .startupFailed: return "Failed to start CLIProxyAPI"
        case .networkError: return "Network error"
        case .noCompatibleBinary: return "No compatible binary found"
        case .extractionFailed: return "Extraction failed"
        case .loginFailed: return "Login failed"
        }
    }
}

import CoreGraphics
import Foundation

#if canImport(Darwin)
  import Darwin
#endif

@MainActor
final class SessionPreferencesStore: ObservableObject {
  @Published var sessionsRoot: URL {
    didSet { persist() }
  }

  @Published var notesRoot: URL {
    didSet { persist() }
  }

  // New: Projects data directory (metadata + memberships)
  @Published var projectsRoot: URL {
    didSet { persist() }
  }

  @Published var codexCommandPath: String {
    didSet { persistCLIPaths() }
  }

  @Published var claudeCommandPath: String {
    didSet { persistCLIPaths() }
  }

  @Published var geminiCommandPath: String {
    didSet { persistCLIPaths() }
  }

  @Published var sessionPathConfigs: [SessionPathConfig] {
    didSet { persistSessionPaths() }
  }

  private let defaults: UserDefaults
  private let fileManager: FileManager
  private struct Keys {
    static let sessionsRootPath = "codex.sessions.rootPath"
    static let notesRootPath = "codex.notes.rootPath"
    static let projectsRootPath = "codmate.projects.rootPath"
    static let codexCommandPath = "codmate.command.codex"
    static let claudeCommandPath = "codmate.command.claude"
    static let geminiCommandPath = "codmate.command.gemini"
    static let resumeUseEmbedded = "codex.resume.useEmbedded"
    static let resumeCopyClipboard = "codex.resume.copyClipboard"
    static let resumeExternalApp = "codex.resume.externalApp"
    static let resumeSandboxMode = "codex.resume.sandboxMode"
    static let resumeApprovalPolicy = "codex.resume.approvalPolicy"
    static let resumeFullAuto = "codex.resume.fullAuto"
    static let resumeDangerBypass = "codex.resume.dangerBypass"
    static let autoAssignNewToSameProject = "codex.projects.autoAssignNewToSame"
    static let timelineVisibleKinds = "codex.timeline.visibleKinds"
    static let markdownVisibleKinds = "codex.markdown.visibleKinds"
    static let enabledRemoteHosts = "codex.remote.enabledHosts"
    static let searchPanelStyle = "codmate.search.panelStyle"
    static let systemMenuVisibility = "codmate.systemMenu.visibility"
    static let statusBarVisibility = "codmate.statusbar.visibility"
    static let confirmBeforeQuit = "codmate.app.confirmBeforeQuit"
    static let launchAtLogin = "codmate.app.launchAtLogin"
    static let notifyCommitMessage = "codmate.notifications.commitMessage"
    static let notifyTitleComment = "codmate.notifications.titleComment"
    static let notifyCommandCopy = "codmate.notifications.commandCopy"
    // Claude advanced
    static let claudeDebug = "claude.debug"
    static let claudeDebugFilter = "claude.debug.filter"
    static let claudeVerbose = "claude.verbose"
    static let claudePermissionMode = "claude.permission.mode"
    static let claudeAllowedTools = "claude.allowedTools"
    static let claudeDisallowedTools = "claude.disallowedTools"
    static let claudeAddDirs = "claude.addDirs"
    static let claudeIDE = "claude.ide"
    static let claudeStrictMCP = "claude.strictMCP"
    static let claudeFallbackModel = "claude.fallbackModel"
    static let claudeSkipPermissions = "claude.skipPermissions"
    static let claudeAllowSkipPermissions = "claude.allowSkipPermissions"
    static let claudeAllowUnsandboxedCommands = "claude.allowUnsandboxedCommands"
    // Default editor for quick file opens
    static let defaultFileEditor = "codmate.editor.default"
    // Git Review
    static let gitShowLineNumbers = "git.review.showLineNumbers"
    static let gitWrapText = "git.review.wrapText"
    static let commitPromptTemplate = "git.review.commitPromptTemplate"
    static let commitProviderId = "git.review.commitProviderId"  // provider id or nil for auto
    static let commitModelId = "git.review.commitModelId"  // optional model id tied to provider
    // Unified provider selections (CLIProxy-backed pickers)
    static let codexProxyProviderId = "codmate.codex.proxyProviderId"
    static let codexProxyModelId = "codmate.codex.proxyModelId"
    static let claudeProxyProviderId = "codmate.claude.proxyProviderId"
    static let claudeProxyModelId = "codmate.claude.proxyModelId"
    static let geminiProxyProviderId = "codmate.gemini.proxyProviderId"
    static let geminiProxyModelId = "codmate.gemini.proxyModelId"
    static let claudeProxyModelAliases = "codmate.claude.proxyModelAliases"
    // Terminal mode (DEV): use CLI console instead of shell
    static let terminalUseCLIConsole = "terminal.useCliConsole"
    static let terminalFontName = "terminal.fontName"
    static let terminalFontSize = "terminal.fontSize"
    static let terminalCursorStyle = "terminal.cursorStyle"
    static let terminalThemeName = "terminalThemeName"
    static let terminalThemeNameLight = "terminalThemeNameLight"
    static let terminalUsePerAppearanceTheme = "terminalUsePerAppearanceTheme"
    static let warpPromptEnabled = "codmate.warp.promptTitle"
    // Local AI Server (formerly CLI Proxy)
    static let localServerEnabled = "codmate.localserver.enabled"         // Public server switch
    static let localServerReroute = "codmate.localserver.reroute"         // ReRoute built-ins
    static let localServerReroute3P = "codmate.localserver.reroute3p"     // ReRoute 3P providers
    static let localServerAutoStart = "codmate.localserver.autostart"     // On-demand/Auto logic
    static let localServerPort = "codmate.localserver.port"
    static let oauthProvidersEnabled = "codmate.providers.oauth.enabled"
    static let oauthAccountsEnabled = "codmate.providers.oauth.accounts.enabled"
    static let apiKeyProvidersEnabled = "codmate.providers.apikey.enabled"
    // Legacy keys for migration
    static let legacyUseCLIProxy = "codmate.cliproxy.useForInternal"
    static let legacyCLIProxyPort = "codmate.cliproxy.port"
    // Session path configurations
    static let sessionPathConfigs = "codmate.sessions.pathConfigs"
  }

  init(
    defaults: UserDefaults = .standard,
    fileManager: FileManager = .default
  ) {
    self.defaults = defaults
    self.fileManager = fileManager
    // Get the real user home directory (not sandbox container)
    let homeURL = SessionPreferencesStore.getRealUserHomeURL()

    // Resolve sessions root without touching self (still used internally; no longer user-configurable)
    let resolvedSessionsRoot: URL = {
      if let storedRoot = defaults.string(forKey: Keys.sessionsRootPath) {
        let url = URL(fileURLWithPath: storedRoot, isDirectory: true)
        if fileManager.fileExists(atPath: url.path) {
          return url
        } else {
          defaults.removeObject(forKey: Keys.sessionsRootPath)
        }
      }
      return SessionPreferencesStore.defaultSessionsRoot(for: homeURL)
    }()

    // Resolve notes root (prefer stored path; else centralized ~/.codmate/notes)
    let resolvedNotesRoot: URL = {
      if let storedNotes = defaults.string(forKey: Keys.notesRootPath) {
        let url = URL(fileURLWithPath: storedNotes, isDirectory: true)
        if fileManager.fileExists(atPath: url.path) {
          return url
        } else {
          defaults.removeObject(forKey: Keys.notesRootPath)
        }
      }
      return SessionPreferencesStore.defaultNotesRoot(for: resolvedSessionsRoot)
    }()

    // Resolve projects root (prefer stored path; else ~/.codmate/projects)
    let resolvedProjectsRoot: URL = {
      if let stored = defaults.string(forKey: Keys.projectsRootPath) {
        let url = URL(fileURLWithPath: stored, isDirectory: true)
        if fileManager.fileExists(atPath: url.path) { return url }
        defaults.removeObject(forKey: Keys.projectsRootPath)
      }
      return SessionPreferencesStore.defaultProjectsRoot(for: homeURL)
    }()

    let storedCodexCommandPath = defaults.string(forKey: Keys.codexCommandPath) ?? ""
    let storedClaudeCommandPath = defaults.string(forKey: Keys.claudeCommandPath) ?? ""
    let storedGeminiCommandPath = defaults.string(forKey: Keys.geminiCommandPath) ?? ""

    // Assign after all are computed to avoid using self before init completes
    self.sessionsRoot = resolvedSessionsRoot
    self.notesRoot = resolvedNotesRoot
    self.projectsRoot = resolvedProjectsRoot
    self.codexCommandPath = storedCodexCommandPath
    self.claudeCommandPath = storedClaudeCommandPath
    self.geminiCommandPath = storedGeminiCommandPath
    
    // Load session path configs (with migration)
    let loadedConfigs = Self.loadSessionPathConfigs(
      defaults: defaults,
      fileManager: fileManager,
      homeURL: homeURL,
      currentSessionsRoot: resolvedSessionsRoot
    )
    self.sessionPathConfigs = loadedConfigs
    
    // Resume defaults (defer assigning to self until value is finalized)
    let resumeEmbedded: Bool
    #if APPSTORE
      if defaults.object(forKey: Keys.resumeUseEmbedded) as? Bool != false {
        defaults.set(false, forKey: Keys.resumeUseEmbedded)
      }
      resumeEmbedded = false
    #else
      var embedded = defaults.object(forKey: Keys.resumeUseEmbedded) as? Bool ?? true
      if AppSandbox.isEnabled && embedded {
        embedded = false
        defaults.set(false, forKey: Keys.resumeUseEmbedded)
      }
      resumeEmbedded = embedded
    #endif
    self.defaultResumeUseEmbeddedTerminal = resumeEmbedded
    self.defaultResumeCopyToClipboard =
      defaults.object(forKey: Keys.resumeCopyClipboard) as? Bool ?? true
    ExternalTerminalProfileStore.shared.seedUserFileIfNeeded()
    let appRaw = defaults.string(forKey: Keys.resumeExternalApp) ?? "terminal"
    let resolvedExternalId = ExternalTerminalProfileStore.shared.resolvePreferredId(id: appRaw)
    self.defaultResumeExternalAppId = resolvedExternalId

    let statusBarRaw = defaults.string(forKey: Keys.statusBarVisibility) ?? StatusBarVisibility.hidden.rawValue
    self.statusBarVisibility = StatusBarVisibility(rawValue: statusBarRaw) ?? .hidden

    // Default editor for quick open (files)
    let editorRaw = defaults.string(forKey: Keys.defaultFileEditor) ?? EditorApp.vscode.rawValue
    var editor = EditorApp(rawValue: editorRaw) ?? .vscode
    // If the stored editor is no longer installed, fall back to the first installed option when available.
    let installedEditors = EditorApp.installedEditors
    if !installedEditors.isEmpty, !installedEditors.contains(editor) {
      editor = installedEditors[0]
    }
    self.defaultFileEditor = editor

    // Git Review defaults
    self.gitShowLineNumbers = defaults.object(forKey: Keys.gitShowLineNumbers) as? Bool ?? true
    self.gitWrapText = defaults.object(forKey: Keys.gitWrapText) as? Bool ?? false
    self.commitPromptTemplate = defaults.string(forKey: Keys.commitPromptTemplate) ?? ""
    self.commitProviderId = defaults.string(forKey: Keys.commitProviderId)
    self.commitModelId = defaults.string(forKey: Keys.commitModelId)
    self.codexProxyProviderId = defaults.string(forKey: Keys.codexProxyProviderId)
    self.codexProxyModelId = defaults.string(forKey: Keys.codexProxyModelId)
    self.claudeProxyProviderId = defaults.string(forKey: Keys.claudeProxyProviderId)
    self.claudeProxyModelId = defaults.string(forKey: Keys.claudeProxyModelId)
    self.geminiProxyProviderId = defaults.string(forKey: Keys.geminiProxyProviderId)
    self.geminiProxyModelId = defaults.string(forKey: Keys.geminiProxyModelId)
    self.claudeProxyModelAliases =
      SessionPreferencesStore.decodeJSON([String: [String: String]].self, defaults: defaults, key: Keys.claudeProxyModelAliases) ?? [:]

    // Terminal mode (DEV) – compute locally first
    let cliConsole: Bool
    #if APPSTORE
      if defaults.object(forKey: Keys.terminalUseCLIConsole) as? Bool != false {
        defaults.set(false, forKey: Keys.terminalUseCLIConsole)
      }
      cliConsole = false
    #else
      var console = defaults.object(forKey: Keys.terminalUseCLIConsole) as? Bool ?? false
      if !AppSandbox.isEnabled && console {
        console = false
        defaults.set(false, forKey: Keys.terminalUseCLIConsole)
      }
      if AppSandbox.isEnabled && console {
        console = false
        defaults.set(false, forKey: Keys.terminalUseCLIConsole)
      }
      cliConsole = console
    #endif
    self.useEmbeddedCLIConsole = cliConsole
    self.terminalFontName = defaults.string(forKey: Keys.terminalFontName) ?? ""
    let storedFontSize = defaults.object(forKey: Keys.terminalFontSize) as? Double ?? 12.0
    self.terminalFontSize = SessionPreferencesStore.clampFontSize(storedFontSize)
    let storedCursor =
      defaults.string(forKey: Keys.terminalCursorStyle)
      ?? TerminalCursorStyleOption.blinkBlock.rawValue
    self.terminalCursorStyleRaw = storedCursor
    self.terminalThemeName = defaults.string(forKey: Keys.terminalThemeName) ?? "Xcode Dark"
    self.terminalThemeNameLight = defaults.string(forKey: Keys.terminalThemeNameLight) ?? "Xcode Light"
    self.terminalUsePerAppearanceTheme = defaults.object(forKey: Keys.terminalUsePerAppearanceTheme) as? Bool ?? true

    // CLI policy defaults (with legacy value coercion)
    let resolvedSandbox: SandboxMode = {
      if let s = defaults.string(forKey: Keys.resumeSandboxMode),
        let val = SessionPreferencesStore.coerceSandboxMode(s)
      {
        if val.rawValue != s { defaults.set(val.rawValue, forKey: Keys.resumeSandboxMode) }
        return val
      }
      return .workspaceWrite
    }()
    let resolvedApproval: ApprovalPolicy = {
      if let a = defaults.string(forKey: Keys.resumeApprovalPolicy),
        let val = SessionPreferencesStore.coerceApprovalPolicy(a)
      {
        if val.rawValue != a { defaults.set(val.rawValue, forKey: Keys.resumeApprovalPolicy) }
        return val
      }
      return .onRequest
    }()

    // Prefer Codex config.toml defaults when present (keeps CodMate in sync with Codex settings)
    let codexSandbox = SessionPreferencesStore.readCodexTopLevelConfigString("sandbox_mode")
      .flatMap { SandboxMode(rawValue: $0) }
    let codexApproval = SessionPreferencesStore.readCodexTopLevelConfigString("approval_policy")
      .flatMap { ApprovalPolicy(rawValue: $0) }

    let finalSandbox = codexSandbox ?? resolvedSandbox
    let finalApproval = codexApproval ?? resolvedApproval

    self.defaultResumeSandboxMode = finalSandbox
    self.defaultResumeApprovalPolicy = finalApproval
    defaults.set(finalSandbox.rawValue, forKey: Keys.resumeSandboxMode)
    defaults.set(finalApproval.rawValue, forKey: Keys.resumeApprovalPolicy)
    self.defaultResumeFullAuto = defaults.object(forKey: Keys.resumeFullAuto) as? Bool ?? false
    self.defaultResumeDangerBypass =
      defaults.object(forKey: Keys.resumeDangerBypass) as? Bool ?? false
    // Projects behaviors
    self.autoAssignNewToSameProject =
      defaults.object(forKey: Keys.autoAssignNewToSameProject) as? Bool ?? true

    // Message visibility defaults
    var resolvedTimelineKinds: Set<MessageVisibilityKind>
    if let storedTimeline = defaults.array(forKey: Keys.timelineVisibleKinds) as? [String] {
      resolvedTimelineKinds = Set(
        storedTimeline.compactMap { MessageVisibilityKind.coerced(from: $0) })
    } else {
      resolvedTimelineKinds = MessageVisibilityKind.timelineDefault
    }
    resolvedTimelineKinds.remove(.turnContext)
    resolvedTimelineKinds.remove(.environmentContext)
    if resolvedTimelineKinds.contains(.tool) {
      resolvedTimelineKinds.insert(.codeEdit)
    }

    var resolvedMarkdownKinds: Set<MessageVisibilityKind>
    if let storedMarkdown = defaults.array(forKey: Keys.markdownVisibleKinds) as? [String] {
      resolvedMarkdownKinds = Set(
        storedMarkdown.compactMap { MessageVisibilityKind.coerced(from: $0) })
    } else {
      resolvedMarkdownKinds = MessageVisibilityKind.markdownDefault
    }
    resolvedMarkdownKinds.remove(.turnContext)
    resolvedMarkdownKinds.remove(.environmentContext)
    if resolvedMarkdownKinds.contains(.tool) {
      resolvedMarkdownKinds.insert(.codeEdit)
    }

    self.timelineVisibleKinds = resolvedTimelineKinds
    self.markdownVisibleKinds = resolvedMarkdownKinds
    // Global search panel style: load stored preference when available, default to floating.
    if let rawStyle = defaults.string(forKey: Keys.searchPanelStyle),
       let style = GlobalSearchPanelStyle(rawValue: rawStyle) {
      self.searchPanelStyle = style
    } else {
      self.searchPanelStyle = .floating
    }
    if let rawMenu = defaults.string(forKey: Keys.systemMenuVisibility),
       let visibility = SystemMenuVisibility(rawValue: rawMenu) {
      self.systemMenuVisibility = visibility
    } else {
      self.systemMenuVisibility = .visible
    }
    // App behavior defaults
    self.confirmBeforeQuit = defaults.object(forKey: Keys.confirmBeforeQuit) as? Bool ?? true
    self.launchAtLogin = defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false
    // Notifications defaults
    self.commitMessageNotificationsEnabled =
      defaults.object(forKey: Keys.notifyCommitMessage) as? Bool ?? true
    self.titleCommentNotificationsEnabled =
      defaults.object(forKey: Keys.notifyTitleComment) as? Bool ?? true
    self.commandCopyNotificationsEnabled =
      defaults.object(forKey: Keys.notifyCommandCopy) as? Bool ?? true
    // Claude advanced defaults
    self.claudeDebug = defaults.object(forKey: Keys.claudeDebug) as? Bool ?? false
    self.claudeDebugFilter = defaults.string(forKey: Keys.claudeDebugFilter) ?? ""
    self.claudeVerbose = defaults.object(forKey: Keys.claudeVerbose) as? Bool ?? false
    if let pm = defaults.string(forKey: Keys.claudePermissionMode) {
      self.claudePermissionMode = ClaudePermissionMode(rawValue: pm) ?? .default
    } else {
      self.claudePermissionMode = .default
    }
    self.claudeAllowedTools = defaults.string(forKey: Keys.claudeAllowedTools) ?? ""
    self.claudeDisallowedTools = defaults.string(forKey: Keys.claudeDisallowedTools) ?? ""
    self.claudeAddDirs = defaults.string(forKey: Keys.claudeAddDirs) ?? ""
    self.claudeIDE = defaults.object(forKey: Keys.claudeIDE) as? Bool ?? false
    self.claudeStrictMCP = defaults.object(forKey: Keys.claudeStrictMCP) as? Bool ?? false
    self.claudeFallbackModel = defaults.string(forKey: Keys.claudeFallbackModel) ?? ""
    self.claudeSkipPermissions = defaults.object(forKey: Keys.claudeSkipPermissions) as? Bool ?? false
    self.claudeAllowSkipPermissions = defaults.object(forKey: Keys.claudeAllowSkipPermissions) as? Bool ?? false
    self.claudeAllowUnsandboxedCommands = defaults.object(forKey: Keys.claudeAllowUnsandboxedCommands) as? Bool ?? false

    // Remote hosts
    let storedHosts = defaults.array(forKey: Keys.enabledRemoteHosts) as? [String] ?? []
    self.enabledRemoteHosts = Set(storedHosts)

    self.promptForWarpTitle = defaults.object(forKey: Keys.warpPromptEnabled) as? Bool ?? false

    // Local Server Defaults & Migration
    let legacyPort = defaults.object(forKey: Keys.legacyCLIProxyPort) as? Int
    let legacyUse = defaults.object(forKey: Keys.legacyUseCLIProxy) as? Bool ?? false

    self.localServerPort = defaults.object(forKey: Keys.localServerPort) as? Int ?? legacyPort ?? Int(CLIProxyService.defaultPort)
    self.localServerEnabled = defaults.object(forKey: Keys.localServerEnabled) as? Bool ?? false
    self.localServerReroute = defaults.object(forKey: Keys.localServerReroute) as? Bool ?? legacyUse
    // Temporarily disable rerouting API key providers until finalized.
    self.localServerReroute3P = false
    defaults.set(false, forKey: Keys.localServerReroute3P)
    // Default auto-start to true if public server is enabled, or if reroute is on (on-demand implied)
    self.localServerAutoStart = defaults.object(forKey: Keys.localServerAutoStart) as? Bool ?? true

    let oauthEnabled = defaults.array(forKey: Keys.oauthProvidersEnabled) as? [String] ?? []
    self.oauthProvidersEnabled = Set(oauthEnabled)
    let oauthAccountsEnabled = defaults.array(forKey: Keys.oauthAccountsEnabled) as? [String] ?? []
    self.oauthAccountsEnabled = Set(oauthAccountsEnabled)
    let apiKeyEnabled = defaults.array(forKey: Keys.apiKeyProvidersEnabled) as? [String] ?? []
    self.apiKeyProvidersEnabled = Set(apiKeyEnabled)

    Task { @MainActor [weak self] in
      await self?.normalizeProviderSelectionsIfNeeded()
    }

    // Now that all properties are initialized, ensure directories exist
    ensureDirectoryExists(sessionsRoot)
    ensureDirectoryExists(notesRoot)
    }

  private func normalizeProviderSelectionsIfNeeded() async {
    let registry = ProvidersRegistryService()
    let providers = await registry.listProviders()
    let normalize: (String?) -> String? = { UnifiedProviderID.normalize($0, registryProviders: providers) }

    let nextCommit = normalize(commitProviderId)
    if nextCommit != commitProviderId { commitProviderId = nextCommit }

    let nextCodex = normalize(codexProxyProviderId)
    if nextCodex != codexProxyProviderId { codexProxyProviderId = nextCodex }

    let nextClaude = normalize(claudeProxyProviderId)
    if nextClaude != claudeProxyProviderId { claudeProxyProviderId = nextClaude }

    let nextGemini = normalize(geminiProxyProviderId)
    if nextGemini != geminiProxyProviderId { geminiProxyProviderId = nextGemini }
  }

  private func persist() {
    defaults.set(sessionsRoot.path, forKey: Keys.sessionsRootPath)
    defaults.set(notesRoot.path, forKey: Keys.notesRootPath)
    defaults.set(projectsRoot.path, forKey: Keys.projectsRootPath)
  }
  
  private func persistSessionPaths() {
    persistJSON(sessionPathConfigs, key: Keys.sessionPathConfigs)
  }

  private static func decodeJSON<T: Decodable>(_ type: T.Type, defaults: UserDefaults, key: String) -> T? {
    guard let data = defaults.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
  }

  private func persistJSON<T: Encodable>(_ value: T, key: String) {
    guard let data = try? JSONEncoder().encode(value) else { return }
    defaults.set(data, forKey: key)
  }

  private func persistCLIPaths() {
    setOptionalPath(codexCommandPath, key: Keys.codexCommandPath)
    setOptionalPath(claudeCommandPath, key: Keys.claudeCommandPath)
    setOptionalPath(geminiCommandPath, key: Keys.geminiCommandPath)
  }

  private func setOptionalPath(_ value: String, key: String) {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      defaults.removeObject(forKey: key)
    } else {
      defaults.set(trimmed, forKey: key)
    }
  }

    private func ensureDirectoryExists(_ url: URL) {
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDir) {
            if isDir.boolValue { return }
            // Remove non-directory item occupying the expected path
            try? fileManager.removeItem(at: url)
        }
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
  }

  convenience init(defaults: UserDefaults = .standard) {
    self.init(defaults: defaults, fileManager: .default)
  }

  private static func clampFontSize(_ value: Double) -> Double {
    return min(max(value, 8.0), 32.0)
  }

  static func defaultSessionsRoot(for homeDirectory: URL) -> URL {
    homeDirectory
      .appendingPathComponent(".codex", isDirectory: true)
      .appendingPathComponent("sessions", isDirectory: true)
  }

  static func defaultNotesRoot(for sessionsRoot: URL) -> URL {
    // Use real home directory, not sandbox container
    let home = getRealUserHomeURL()
    return home.appendingPathComponent(".codmate", isDirectory: true)
      .appendingPathComponent("notes", isDirectory: true)
  }

  static func defaultProjectsRoot(for homeDirectory: URL) -> URL {
    homeDirectory
      .appendingPathComponent(".codmate", isDirectory: true)
      .appendingPathComponent("projects", isDirectory: true)
  }

  static func isCommitMessageNotificationEnabled(defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: Keys.notifyCommitMessage) as? Bool ?? true
  }

  static func isTitleCommentNotificationEnabled(defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: Keys.notifyTitleComment) as? Bool ?? true
  }

  static func isCommandCopyNotificationEnabled(defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: Keys.notifyCommandCopy) as? Bool ?? true
  }

  func resolvedCommandOverrideURL(for kind: SessionSource.Kind) -> URL? {
    let raw: String
    switch kind {
    case .codex: raw = codexCommandPath
    case .claude: raw = claudeCommandPath
    case .gemini: raw = geminiCommandPath
    }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let expanded = expandHomePath(trimmed)
    guard expanded.contains("/") else { return nil }
    let url = URL(fileURLWithPath: expanded)
    return fileManager.isExecutableFile(atPath: url.path) ? url : nil
  }

  func preferredExecutablePath(for kind: SessionSource.Kind) -> String {
    if let override = resolvedCommandOverrideURL(for: kind) {
      return override.path
    }
    return kind.cliExecutableName
  }

  /// Get the real user home directory (not sandbox container)
  nonisolated static func getRealUserHomeURL() -> URL {
    #if canImport(Darwin)
      if let homeDir = getpwuid(getuid())?.pointee.pw_dir {
        let path = String(cString: homeDir)
        return URL(fileURLWithPath: path, isDirectory: true)
      }
    #endif
    if let home = ProcessInfo.processInfo.environment["HOME"] {
      return URL(fileURLWithPath: home, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
  }

  private func expandHomePath(_ path: String) -> String {
    if path.hasPrefix("~") {
      return (path as NSString).expandingTildeInPath
    }
    if path.contains("$HOME") {
      return path.replacingOccurrences(of: "$HOME", with: NSHomeDirectory())
    }
    return path
  }

  // Removed: default executable URLs – resolution uses PATH

  // MARK: - Legacy coercion helpers
  private static func coerceSandboxMode(_ raw: String) -> SandboxMode? {
    let v = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if let exact = SandboxMode(rawValue: v) { return exact }
    switch v {
    case "full": return SandboxMode.dangerFullAccess
    case "rw", "write": return SandboxMode.workspaceWrite
    case "ro", "read": return SandboxMode.readOnly
    default: return nil
    }
  }

  private static func coerceApprovalPolicy(_ raw: String) -> ApprovalPolicy? {
    let v = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if let exact = ApprovalPolicy(rawValue: v) { return exact }
    switch v {
    case "auto": return ApprovalPolicy.onRequest
    case "fail", "onfail": return ApprovalPolicy.onFailure
    default: return nil
    }
  }

  private static func readCodexTopLevelConfigString(_ key: String) -> String? {
    let url = getRealUserHomeURL()
      .appendingPathComponent(".codex", isDirectory: true)
      .appendingPathComponent("config.toml", isDirectory: false)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
      let trimmed = raw.trimmingCharacters(in: CharacterSet.whitespaces)
      guard trimmed.hasPrefix(key + " ") || trimmed.hasPrefix(key + "=") else { continue }
      guard let eq = trimmed.firstIndex(of: "=") else { continue }
      var value = String(trimmed[trimmed.index(after: eq)...])
        .trimmingCharacters(in: CharacterSet.whitespaces)
      if value.hasPrefix("\"") && value.hasSuffix("\"") {
        value.removeFirst()
        value.removeLast()
      }
      let finalValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
      if !finalValue.isEmpty { return finalValue }
    }
    return nil
  }

  // MARK: - Resume Preferences
  @Published var defaultResumeUseEmbeddedTerminal: Bool {
    didSet {
      #if APPSTORE
        if defaultResumeUseEmbeddedTerminal {
          defaultResumeUseEmbeddedTerminal = false
          defaults.set(false, forKey: Keys.resumeUseEmbedded)
          return
        }
      #endif
      if AppSandbox.isEnabled, defaultResumeUseEmbeddedTerminal {
        defaultResumeUseEmbeddedTerminal = false
        defaults.set(false, forKey: Keys.resumeUseEmbedded)
        return
      }
      defaults.set(defaultResumeUseEmbeddedTerminal, forKey: Keys.resumeUseEmbedded)
    }
  }
  @Published var defaultResumeCopyToClipboard: Bool {
    didSet { defaults.set(defaultResumeCopyToClipboard, forKey: Keys.resumeCopyClipboard) }
  }
  @Published var defaultResumeExternalAppId: String {
    didSet { defaults.set(defaultResumeExternalAppId, forKey: Keys.resumeExternalApp) }
  }
  @Published var promptForWarpTitle: Bool {
    didSet { defaults.set(promptForWarpTitle, forKey: Keys.warpPromptEnabled) }
  }

  // MARK: - Local AI Server
  @Published var localServerEnabled: Bool {
    didSet { defaults.set(localServerEnabled, forKey: Keys.localServerEnabled) }
  }
  @Published var localServerReroute: Bool {
    didSet { defaults.set(localServerReroute, forKey: Keys.localServerReroute) }
  }
  @Published var localServerReroute3P: Bool {
    didSet { defaults.set(localServerReroute3P, forKey: Keys.localServerReroute3P) }
  }
  @Published var localServerAutoStart: Bool {
    didSet { defaults.set(localServerAutoStart, forKey: Keys.localServerAutoStart) }
  }
  @Published var localServerPort: Int {
    didSet { defaults.set(localServerPort, forKey: Keys.localServerPort) }
  }
  @Published var oauthProvidersEnabled: Set<String> {
    didSet { defaults.set(Array(oauthProvidersEnabled), forKey: Keys.oauthProvidersEnabled) }
  }
  @Published var oauthAccountsEnabled: Set<String> {
    didSet { defaults.set(Array(oauthAccountsEnabled), forKey: Keys.oauthAccountsEnabled) }
  }
  @Published var apiKeyProvidersEnabled: Set<String> {
    didSet { defaults.set(Array(apiKeyProvidersEnabled), forKey: Keys.apiKeyProvidersEnabled) }
  }

  @Published var defaultResumeSandboxMode: SandboxMode {
    didSet { defaults.set(defaultResumeSandboxMode.rawValue, forKey: Keys.resumeSandboxMode) }
  }
  @Published var defaultResumeApprovalPolicy: ApprovalPolicy {
    didSet { defaults.set(defaultResumeApprovalPolicy.rawValue, forKey: Keys.resumeApprovalPolicy) }
  }
  @Published var defaultResumeFullAuto: Bool {
    didSet { defaults.set(defaultResumeFullAuto, forKey: Keys.resumeFullAuto) }
  }
  @Published var defaultResumeDangerBypass: Bool {
    didSet { defaults.set(defaultResumeDangerBypass, forKey: Keys.resumeDangerBypass) }
  }

  // Projects: auto-assign new sessions from detail to same project (default ON)
  @Published var autoAssignNewToSameProject: Bool {
    didSet { defaults.set(autoAssignNewToSameProject, forKey: Keys.autoAssignNewToSameProject) }
  }

  // Visibility for timeline and export markdown
  @Published var timelineVisibleKinds: Set<MessageVisibilityKind> = MessageVisibilityKind
    .timelineDefault
  {
    didSet {
      defaults.set(
        Array(timelineVisibleKinds.map { $0.rawValue }), forKey: Keys.timelineVisibleKinds)
    }
  }
  @Published var markdownVisibleKinds: Set<MessageVisibilityKind> = MessageVisibilityKind
    .markdownDefault
  {
    didSet {
      defaults.set(
        Array(markdownVisibleKinds.map { $0.rawValue }), forKey: Keys.markdownVisibleKinds)
    }
  }

  @Published var searchPanelStyle: GlobalSearchPanelStyle {
    didSet { defaults.set(searchPanelStyle.rawValue, forKey: Keys.searchPanelStyle) }
  }

  @Published var statusBarVisibility: StatusBarVisibility {
    didSet { defaults.set(statusBarVisibility.rawValue, forKey: Keys.statusBarVisibility) }
  }

  @Published var systemMenuVisibility: SystemMenuVisibility {
    didSet { defaults.set(systemMenuVisibility.rawValue, forKey: Keys.systemMenuVisibility) }
  }

  @Published var confirmBeforeQuit: Bool {
    didSet { defaults.set(confirmBeforeQuit, forKey: Keys.confirmBeforeQuit) }
  }

  @Published var launchAtLogin: Bool {
    didSet {
      defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
      LaunchAtLoginService.shared.setLaunchAtLogin(enabled: launchAtLogin)
    }
  }

  // MARK: - Notifications (App)
  @Published var commitMessageNotificationsEnabled: Bool {
    didSet { defaults.set(commitMessageNotificationsEnabled, forKey: Keys.notifyCommitMessage) }
  }
  @Published var titleCommentNotificationsEnabled: Bool {
    didSet { defaults.set(titleCommentNotificationsEnabled, forKey: Keys.notifyTitleComment) }
  }
  @Published var commandCopyNotificationsEnabled: Bool {
    didSet { defaults.set(commandCopyNotificationsEnabled, forKey: Keys.notifyCommandCopy) }
  }

  @Published var enabledRemoteHosts: Set<String> = [] {
    didSet { defaults.set(Array(enabledRemoteHosts), forKey: Keys.enabledRemoteHosts) }
  }

  var isEmbeddedTerminalEnabled: Bool {
    !AppSandbox.isEnabled && defaultResumeUseEmbeddedTerminal
  }

  var resumeOptions: ResumeOptions {
    var opt = ResumeOptions(
      sandbox: defaultResumeSandboxMode,
      approval: defaultResumeApprovalPolicy,
      fullAuto: defaultResumeFullAuto,
      dangerouslyBypass: defaultResumeDangerBypass
    )
    // Carry Claude advanced flags for launch
    opt.claudeDebug = claudeDebug
    opt.claudeDebugFilter = claudeDebugFilter.isEmpty ? nil : claudeDebugFilter
    opt.claudeVerbose = claudeVerbose
    opt.claudePermissionMode = claudePermissionMode
    opt.claudeAllowedTools = claudeAllowedTools.isEmpty ? nil : claudeAllowedTools
    opt.claudeDisallowedTools = claudeDisallowedTools.isEmpty ? nil : claudeDisallowedTools
    opt.claudeAddDirs = claudeAddDirs.isEmpty ? nil : claudeAddDirs
    opt.claudeIDE = claudeIDE
    opt.claudeStrictMCP = claudeStrictMCP
    opt.claudeFallbackModel = claudeFallbackModel.isEmpty ? nil : claudeFallbackModel
    opt.claudeSkipPermissions = claudeSkipPermissions
    opt.claudeAllowSkipPermissions = claudeAllowSkipPermissions
    opt.claudeAllowUnsandboxedCommands = claudeAllowUnsandboxedCommands
    return opt
  }

  // MARK: - Claude Advanced (Published)
  @Published var claudeDebug: Bool {
    didSet { defaults.set(claudeDebug, forKey: Keys.claudeDebug) }
  }
  @Published var claudeDebugFilter: String {
    didSet { defaults.set(claudeDebugFilter, forKey: Keys.claudeDebugFilter) }
  }
  @Published var claudeVerbose: Bool {
    didSet { defaults.set(claudeVerbose, forKey: Keys.claudeVerbose) }
  }
  @Published var claudePermissionMode: ClaudePermissionMode {
    didSet { defaults.set(claudePermissionMode.rawValue, forKey: Keys.claudePermissionMode) }
  }
  @Published var claudeAllowedTools: String {
    didSet { defaults.set(claudeAllowedTools, forKey: Keys.claudeAllowedTools) }
  }
  @Published var claudeDisallowedTools: String {
    didSet { defaults.set(claudeDisallowedTools, forKey: Keys.claudeDisallowedTools) }
  }
  @Published var claudeAddDirs: String {
    didSet { defaults.set(claudeAddDirs, forKey: Keys.claudeAddDirs) }
  }
  @Published var claudeIDE: Bool { didSet { defaults.set(claudeIDE, forKey: Keys.claudeIDE) } }
  @Published var claudeStrictMCP: Bool {
    didSet { defaults.set(claudeStrictMCP, forKey: Keys.claudeStrictMCP) }
  }
  @Published var claudeFallbackModel: String {
    didSet { defaults.set(claudeFallbackModel, forKey: Keys.claudeFallbackModel) }
  }
  @Published var claudeSkipPermissions: Bool {
    didSet { defaults.set(claudeSkipPermissions, forKey: Keys.claudeSkipPermissions) }
  }
  @Published var claudeAllowSkipPermissions: Bool {
    didSet { defaults.set(claudeAllowSkipPermissions, forKey: Keys.claudeAllowSkipPermissions) }
  }
  @Published var claudeAllowUnsandboxedCommands: Bool {
    didSet {
      defaults.set(claudeAllowUnsandboxedCommands, forKey: Keys.claudeAllowUnsandboxedCommands)
    }
  }

  // MARK: - Editor Preferences
  @Published var defaultFileEditor: EditorApp {
    didSet { defaults.set(defaultFileEditor.rawValue, forKey: Keys.defaultFileEditor) }
  }

  // MARK: - Git Review
  @Published var gitShowLineNumbers: Bool {
    didSet { defaults.set(gitShowLineNumbers, forKey: Keys.gitShowLineNumbers) }
  }
  @Published var gitWrapText: Bool {
    didSet { defaults.set(gitWrapText, forKey: Keys.gitWrapText) }
  }
  @Published var commitPromptTemplate: String {
    didSet { defaults.set(commitPromptTemplate, forKey: Keys.commitPromptTemplate) }
  }
  @Published var commitProviderId: String? {
    didSet { defaults.set(commitProviderId, forKey: Keys.commitProviderId) }
  }
  @Published var commitModelId: String? {
    didSet { defaults.set(commitModelId, forKey: Keys.commitModelId) }
  }
  @Published var codexProxyProviderId: String? {
    didSet { defaults.set(codexProxyProviderId, forKey: Keys.codexProxyProviderId) }
  }
  @Published var codexProxyModelId: String? {
    didSet { defaults.set(codexProxyModelId, forKey: Keys.codexProxyModelId) }
  }
  @Published var claudeProxyProviderId: String? {
    didSet { defaults.set(claudeProxyProviderId, forKey: Keys.claudeProxyProviderId) }
  }
  @Published var claudeProxyModelId: String? {
    didSet { defaults.set(claudeProxyModelId, forKey: Keys.claudeProxyModelId) }
  }
  @Published var geminiProxyProviderId: String? {
    didSet { defaults.set(geminiProxyProviderId, forKey: Keys.geminiProxyProviderId) }
  }
  @Published var geminiProxyModelId: String? {
    didSet { defaults.set(geminiProxyModelId, forKey: Keys.geminiProxyModelId) }
  }
  @Published var claudeProxyModelAliases: [String: [String: String]] {
    didSet { persistJSON(claudeProxyModelAliases, key: Keys.claudeProxyModelAliases) }
  }

  // MARK: - Terminal (DEV)
  @Published var useEmbeddedCLIConsole: Bool {
    didSet {
      #if APPSTORE
        if useEmbeddedCLIConsole {
          useEmbeddedCLIConsole = false
          defaults.set(false, forKey: Keys.terminalUseCLIConsole)
          return
        }
      #endif
      if !AppSandbox.isEnabled, useEmbeddedCLIConsole {
        useEmbeddedCLIConsole = false
        defaults.set(false, forKey: Keys.terminalUseCLIConsole)
        return
      }
      if AppSandbox.isEnabled, useEmbeddedCLIConsole {
        useEmbeddedCLIConsole = false
        defaults.set(false, forKey: Keys.terminalUseCLIConsole)
        return
      }
      defaults.set(useEmbeddedCLIConsole, forKey: Keys.terminalUseCLIConsole)
    }
  }

  @Published var terminalFontName: String {
    didSet {
      defaults.set(terminalFontName, forKey: Keys.terminalFontName)
    }
  }

  @Published var terminalFontSize: Double {
    didSet {
      let clamped = SessionPreferencesStore.clampFontSize(terminalFontSize)
      if clamped != terminalFontSize {
        terminalFontSize = clamped
        return
      }
      defaults.set(terminalFontSize, forKey: Keys.terminalFontSize)
    }
  }

  @Published var terminalCursorStyleRaw: String {
    didSet {
      defaults.set(terminalCursorStyleRaw, forKey: Keys.terminalCursorStyle)
    }
  }

  @Published var terminalThemeName: String {
    didSet {
      defaults.set(terminalThemeName, forKey: Keys.terminalThemeName)
    }
  }

  @Published var terminalThemeNameLight: String {
    didSet {
      defaults.set(terminalThemeNameLight, forKey: Keys.terminalThemeNameLight)
    }
  }

  @Published var terminalUsePerAppearanceTheme: Bool {
    didSet {
      defaults.set(terminalUsePerAppearanceTheme, forKey: Keys.terminalUsePerAppearanceTheme)
    }
  }

  var terminalCursorStyleOption: TerminalCursorStyleOption {
    get { TerminalCursorStyleOption(rawValue: terminalCursorStyleRaw) ?? .blinkBlock }
    set { terminalCursorStyleRaw = newValue.rawValue }
  }

  var clampedTerminalFontSize: CGFloat {
    CGFloat(SessionPreferencesStore.clampFontSize(terminalFontSize))
  }
  
  // MARK: - Session Path Configs
  
  /// Load session path configs with migration from legacy settings
  private static func loadSessionPathConfigs(
    defaults: UserDefaults,
    fileManager: FileManager,
    homeURL: URL,
    currentSessionsRoot: URL
  ) -> [SessionPathConfig] {
    // Try to load existing configs
    if let data = defaults.data(forKey: Keys.sessionPathConfigs),
       let configs = try? JSONDecoder().decode([SessionPathConfig].self, from: data),
       !configs.isEmpty {
      return configs
    }
    
    // Migration: generate default configs
    let codexPath = currentSessionsRoot.path
    let claudePath = homeURL
      .appendingPathComponent(".claude", isDirectory: true)
      .appendingPathComponent("projects", isDirectory: true)
      .path
    let geminiPath = homeURL
      .appendingPathComponent(".gemini", isDirectory: true)
      .appendingPathComponent("tmp", isDirectory: true)
      .path
    
    return [
      SessionPathConfig(
        kind: .codex,
        path: codexPath,
        enabled: true,
        displayName: "Codex"
      ),
      SessionPathConfig(
        kind: .claude,
        path: claudePath,
        enabled: true,
        displayName: "Claude"
      ),
      SessionPathConfig(
        kind: .gemini,
        path: geminiPath,
        enabled: true,
        displayName: "Gemini"
      )
    ]
  }
  
  /// Get enabled session paths for a specific kind
  func enabledSessionPaths(for kind: SessionSource.Kind) -> [URL] {
    sessionPathConfigs
      .filter { $0.kind == kind && $0.enabled }
      .compactMap { URL(fileURLWithPath: $0.path) }
  }
  
  /// Get the primary enabled path for a kind (first enabled, or default if none)
  func primarySessionPath(for kind: SessionSource.Kind) -> URL? {
    if let enabled = enabledSessionPaths(for: kind).first {
      return enabled
    }
    // Fallback to default path
    let home = Self.getRealUserHomeURL()
    switch kind {
    case .codex:
      return sessionsRoot
    case .claude:
      return home
        .appendingPathComponent(".claude", isDirectory: true)
        .appendingPathComponent("projects", isDirectory: true)
    case .gemini:
      return home
        .appendingPathComponent(".gemini", isDirectory: true)
        .appendingPathComponent("tmp", isDirectory: true)
    }
  }
  
  /// Get the config for a specific kind (default or custom)
  func config(for kind: SessionSource.Kind) -> SessionPathConfig? {
    sessionPathConfigs.first { $0.kind == kind && $0.isDefault }
  }
  
  /// Check if a path should be ignored based on config
  func shouldIgnorePath(_ absolutePath: String, under config: SessionPathConfig) -> Bool {
    guard config.enabled else { return true }
    let lowercasedPath = absolutePath.lowercased()
    for ignored in config.ignoredSubpaths {
      let needle = ignored.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !needle.isEmpty else { continue }
      if lowercasedPath.contains(needle.lowercased()) {
        return true
      }
    }
    return false
  }
}

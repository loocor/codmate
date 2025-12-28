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
    // Terminal mode (DEV): use CLI console instead of shell
    static let terminalUseCLIConsole = "terminal.useCliConsole"
    static let terminalFontName = "terminal.fontName"
    static let terminalFontSize = "terminal.fontSize"
    static let terminalCursorStyle = "terminal.cursorStyle"
    static let warpPromptEnabled = "codmate.warp.promptTitle"
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
    
    // Now that all properties are initialized, ensure directories exist
    ensureDirectoryExists(sessionsRoot)
    ensureDirectoryExists(notesRoot)
    }
  private func persist() {
    defaults.set(sessionsRoot.path, forKey: Keys.sessionsRootPath)
    defaults.set(notesRoot.path, forKey: Keys.notesRootPath)
    defaults.set(projectsRoot.path, forKey: Keys.projectsRootPath)
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

  @Published var systemMenuVisibility: SystemMenuVisibility {
    didSet { defaults.set(systemMenuVisibility.rawValue, forKey: Keys.systemMenuVisibility) }
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

  var terminalCursorStyleOption: TerminalCursorStyleOption {
    get { TerminalCursorStyleOption(rawValue: terminalCursorStyleRaw) ?? .blinkBlock }
    set { terminalCursorStyleRaw = newValue.rawValue }
  }

  var clampedTerminalFontSize: CGFloat {
    CGFloat(SessionPreferencesStore.clampFontSize(terminalFontSize))
  }
}

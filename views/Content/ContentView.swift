import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
  @ObservedObject var viewModel: SessionListViewModel
  @ObservedObject var preferences: SessionPreferencesStore
  @StateObject var permissionsManager = SandboxPermissionsManager.shared
  @Environment(\.colorScheme) var colorScheme
  @Environment(\.openWindow) var openWindow
  // Stable shared cache for project Review VMs to avoid ephemeral lifetimes
  // that can lead to ObservedObject referencing deallocated instances during
  // split-view construction. Using a static store prevents state mutations
  // during body evaluation and keeps a single VM per project across columns.
  private static var sharedProjectReviewVMs: [String: GitChangesViewModel] = [:]

  @State var columnVisibility: NavigationSplitViewVisibility = .all
  @State var selection = Set<SessionSummary.ID>()
  @State var selectionPrimaryId: SessionSummary.ID? = nil
  @State var lastSelectionSnapshot = Set<SessionSummary.ID>()
  @State var isPerformingAction = false
  @State var deleteConfirmationPresented = false
  @State var alertState: AlertState?
  @State var selectingSessionsRoot = false
  // Track which sessions are running in embedded terminal
  @State var runningSessionIDs = Set<SessionSummary.ID>()
  @State var selectedTerminalKey: SessionSummary.ID? = nil
  @State var isDetailMaximized = false
  @State var isListHidden = false
  @SceneStorage("cm.sidebarHidden") var storeSidebarHidden: Bool = false
  @SceneStorage("cm.listHidden") var storeListHidden: Bool = false
  // Persist content column (sessions list / review left pane) preferred width
  @State var contentColumnIdealWidth: CGFloat = 420
  @State var showSidebarNewProjectSheet = false
  @State var showProjectEditorSheet = false
  @State var projectEditorTarget: Project? = nil
  // When starting embedded sessions, record the initial command lines per-session
  @State var embeddedInitialCommands: [SessionSummary.ID: String] = [:]
  // Soft-return flag: when true, stopping embedded terminal should not change
  // sidebar/list expand/collapse; keep overall layout stable.
  @State var softReturnPending: Bool = false
  // Confirm stopping a running embedded terminal
  struct ConfirmStopState: Identifiable {
    let id = UUID()
    let sessionId: String
  }
  @State var confirmStopState: ConfirmStopState? = nil
  struct PendingTerminalLaunch: Identifiable {
    let id = UUID()
    let session: SessionSummary
  }
  @State var pendingTerminalLaunch: PendingTerminalLaunch? = nil
  // Prompt picker state for embedded terminal quick-insert
  @State var showPromptPicker = false
  @State var promptQuery = ""
  // Debounced query to keep filtering cheap on main thread
  @State var throttledPromptQuery = ""
  @State var promptDebounceTask: Task<Void, Never>? = nil
  @StateObject var globalSearchViewModel: GlobalSearchViewModel
  @State var selectedUsageProvider: UsageProviderKind = .codex
  @State var pendingSelectionID: String? = nil
  @State var pendingConversationFilter: (id: String, term: String)? = nil
  @State var isSearchPopoverPresented = false
  @State var searchPopoverSize: CGSize = ContentView.defaultSearchPopoverSize
  @State var shouldBlockAutoSelection = false
  @State var popoverDismissDisabled = false
  @State var lastWorkspaceMode: ProjectWorkspaceMode? = nil
  @StateObject var overviewViewModel: AllOverviewViewModel
  static let defaultSearchPopoverSize = CGSize(width: 440, height: 320)
  static let searchPopoverMinSize = CGSize(width: 380, height: 220)
  static let searchPopoverMaxSize = CGSize(width: 640, height: 520)
  // Deprecated: keep for future removal; no longer used for retention.
  // @State private var projectReviewVMs: [String: GitChangesViewModel] = [:]
  struct SourcedPrompt: Identifiable, Hashable {
    let id = UUID()
    enum Source: Hashable { case project, user, builtin }
    var prompt: PresetPromptsStore.Prompt
    var source: Source
    var label: String { prompt.label }
    var command: String { prompt.command }

    // Custom Hashable implementation to hash based on content, not UUID
    func hash(into hasher: inout Hasher) {
      hasher.combine(prompt)
      hasher.combine(source)
    }

    static func == (lhs: SourcedPrompt, rhs: SourcedPrompt) -> Bool {
      lhs.prompt == rhs.prompt && lhs.source == rhs.source
    }
  }
  @State var loadedPrompts: [SourcedPrompt] = []
  @State var hoveredPromptKey: String? = nil
  func promptKey(_ p: SourcedPrompt) -> String { p.command }
  func canDelete(_ p: SourcedPrompt) -> Bool { true }
  @State var pendingDelete: SourcedPrompt? = nil
  // Build highlighted text where matches of `query` are tinted; non-matches use the provided base color
  func highlightedText(_ text: String, query: String, base: Color = .primary) -> Text {
    guard !query.isEmpty else {
      let baseText = Text(text).foregroundStyle(base)
      return baseText
    }

    var result = Text("")
    var searchStart = text.startIndex
    let end = text.endIndex

    while searchStart < end,
      let r = text.range(
        of: query, options: [.caseInsensitive, .diacriticInsensitive], range: searchStart..<end)
    {
      if r.lowerBound > searchStart {
        let prefix = String(text[searchStart..<r.lowerBound])
        let prefixText = Text(prefix).foregroundStyle(base)
        result = result + prefixText
      }

      let match = String(text[r])
      let matchText = Text(match).foregroundStyle(.tint)
      result = result + matchText

      searchStart = r.upperBound
    }

    if searchStart < end {
      let tail = String(text[searchStart..<end])
      let tailText = Text(tail).foregroundStyle(base)
      result = result + tailText
    }

    return result
  }
  func builtinPrompts() -> [PresetPromptsStore.Prompt] {
    []
  }
  func makeSidebarActions() -> SidebarActions {
    SidebarActions(
      selectAllProjects: { viewModel.setSelectedProject(nil) },
      requestNewProject: { showSidebarNewProjectSheet = true },
      setDateDimension: { viewModel.dateDimension = $0 },
      setMonthStart: { viewModel.setSidebarMonthStart($0) },
      setSelectedDay: { viewModel.setSelectedDay($0) },
      toggleSelectedDay: { viewModel.toggleSelectedDay($0) }
    )
  }
  enum DetailTab: Hashable { case timeline, review, terminal }
  // Per-session detail tab state: tracks which tab (timeline/review/terminal) each session is viewing
  @State var sessionDetailTabs: [SessionSummary.ID: DetailTab] = [:]
  // Current displayed tab (synced with focused session's state)
  @State var selectedDetailTab: DetailTab = .timeline
  // Track pending rekey for embedded New so we can move the PTY to the real new session id
  struct PendingEmbeddedRekey {
    let anchorId: String
    let expectedCwd: String
    let t0: Date
    let selectOnSuccess: Bool
    let projectId: String?
  }
  @State private var pendingEmbeddedRekeys: [PendingEmbeddedRekey] = []
  func makeTerminalFont() -> NSFont {
    TerminalFontResolver.resolvedFont(
      name: viewModel.preferences.terminalFontName,
      size: viewModel.preferences.clampedTerminalFontSize
    )
  }

  init(viewModel: SessionListViewModel) {
    self.viewModel = viewModel
    _preferences = ObservedObject(wrappedValue: viewModel.preferences)
    _globalSearchViewModel = StateObject(
      wrappedValue: GlobalSearchViewModel(
        preferences: viewModel.preferences,
        sessionListViewModel: viewModel
      )
    )
    _overviewViewModel = StateObject(
      wrappedValue: AllOverviewViewModel(sessionListViewModel: viewModel)
    )
  }

  var body: some View {
    GeometryReader { geometry in
      navigationSplitView(geometry: geometry)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showProjectEditorSheet, onDismiss: { projectEditorTarget = nil }) {
          if let target = projectEditorTarget {
            ProjectEditorSheet(isPresented: $showProjectEditorSheet, mode: .edit(existing: target))
              .environmentObject(viewModel)
          } else {
            EmptyView()
          }
        }
    }
  }

  // navigationSplitView moved to Content/ContentView+Modifiers.swift

  // applyTaskAndChangeModifiers moved to Content/ContentView+Modifiers.swift

  // applyNotificationModifiers moved to Content/ContentView+Modifiers.swift

  // applyDialogsAndAlerts moved to Content/ContentView+Modifiers.swift

  // sidebarContent moved to Content/ContentView+Sidebar.swift

  // listContent moved to Content/ContentView+Sidebar.swift

  // refreshToolbarContent moved to Content/ContentView+Sidebar.swift

  // detailColumn moved to Content/ContentView+Detail.swift

  // mainDetailContent moved to ContentView+MainDetail.swift

  // detailActionBar moved to ContentView+DetailActionBar.swift

  // focusedSummary and summaryLookup moved to ContentView+Helpers.swift

  func normalizeSelection() {
    let orderedIDs = viewModel.sections.flatMap { $0.sessions.map(\.id) }
    let validIDs = Set(orderedIDs)
    let original = selection
    selection.formIntersection(validIDs)

    // Don't auto-select first item when blocked (e.g., when search popover is about to open)
    if selection.isEmpty, let first = orderedIDs.first, !shouldBlockAutoSelection {
      selection.insert(first)
    }
    // Avoid unnecessary churn if nothing changed
    if selection == original { return }
  }

  // Provide a stable GitChangesViewModel per selected project for Review layout
  func projectReviewVM(for projectId: String) -> GitChangesViewModel {
    if let existing = ContentView.sharedProjectReviewVMs[projectId] { return existing }
    let vm = GitChangesViewModel()
    ContentView.sharedProjectReviewVMs[projectId] = vm
    return vm
  }

  func resumeFromList(_ session: SessionSummary) {
    selection = [session.id]
    selectionPrimaryId = session.id
    if viewModel.preferences.defaultResumeUseEmbeddedTerminal {
      startEmbedded(for: session)
    } else {
      openPreferredExternal(for: session)
    }
  }

  func handleDeleteRequest(_ session: SessionSummary) {
    if !selection.contains(session.id) {
      selection = [session.id]
    }
    presentDeleteConfirmation()
  }

  // exportMarkdownForSession moved to ContentView+Helpers.swift

  func presentDeleteConfirmation() {
    guard !selection.isEmpty else { return }
    deleteConfirmationPresented = true
  }

  func deleteSelections(ids: [SessionSummary.ID]) {
    let summaries = ids.compactMap { summaryLookup[$0] }
    guard !summaries.isEmpty else { return }

    deleteConfirmationPresented = false
    isPerformingAction = true

    Task {
      await viewModel.delete(summaries: summaries)
      await MainActor.run {
        // Best-effort: stop any embedded terminals for deleted sessions
        #if canImport(SwiftTerm) && !APPSTORE
          for s in summaries { TerminalSessionManager.shared.stop(key: s.id) }
        #endif
        // Clean up per-session state for deleted sessions
        for id in ids {
          sessionDetailTabs.removeValue(forKey: id)
          embeddedInitialCommands.removeValue(forKey: id)
          runningSessionIDs.remove(id)
        }
        isPerformingAction = false
        selection.subtract(ids)
        normalizeSelection()
      }
    }
  }

  func startEmbedded(for session: SessionSummary, using source: SessionSource? = nil) {
    let target = source.map { session.overridingSource($0) } ?? session
    #if APPSTORE
      openPreferredExternal(for: target)
      return
    #else
      // Ensure cwd authorization under App Sandbox (both shell and CLI modes)
      let cwd = workingDirectory(for: target)
      let dirURL = URL(fileURLWithPath: cwd, isDirectory: true)
      if !AuthorizationHub.shared.canAccessNow(directory: dirURL) {
        let toolLabel = target.source.baseKind.cliExecutableName
        let granted = AuthorizationHub.shared.ensureDirectoryAccessOrPromptSync(
          directory: dirURL,
          purpose: .cliConsoleCwd,
          message: "Authorize this folder for CLI console to run \(toolLabel)"
        )
        guard granted || AuthorizationHub.shared.canAccessNow(directory: dirURL) else {
          // Do not start embedded; remain in timeline
          return
        }
      }
      // Build the default resume commands for this session so TerminalHostView can inject them
      embeddedInitialCommands[target.id] = viewModel.buildResumeCommands(session: target)
      runningSessionIDs.insert(target.id)
      selectedTerminalKey = target.id
      // Switch detail surface to Terminal when embedded starts
      selectedDetailTab = .terminal
      sessionDetailTabs[target.id] = .terminal
      // User has taken over: clear awaiting follow-up highlight
      viewModel.clearAwaitingFollowup(target.id)
      // Nudge Codex to redraw cleanly once it starts, by sending "/" then backspace
      #if canImport(SwiftTerm) && !APPSTORE
        TerminalSessionManager.shared.scheduleSlashNudge(forKey: target.id, delay: 1.0)
      #endif
    #endif
  }

  func stopEmbedded(forID id: SessionSummary.ID) {
    // Tear down the embedded terminal view and terminate its child process
    #if canImport(SwiftTerm) && !APPSTORE
      TerminalSessionManager.shared.stop(key: id)
    #endif
    runningSessionIDs.remove(id)
    embeddedInitialCommands.removeValue(forKey: id)
    if selectedTerminalKey == id {
      selectedTerminalKey = runningSessionIDs.first
    }
    // Exit embedded terminal: clear awaiting follow-up highlight
    viewModel.clearAwaitingFollowup(id)
    if selectedDetailTab == .terminal {
      selectedDetailTab = .timeline
    }
    // If this stop is triggered by Return to History, do not alter sidebar/list
    // visibility to keep the view stable.
    if softReturnPending {
      softReturnPending = false
      return
    }
    // Default behavior: if no embedded terminals left, restore default columns
    if runningSessionIDs.isEmpty {
      isDetailMaximized = false
      columnVisibility = .all
    }
  }

  private func isTerminalLikelyRunning(forID id: SessionSummary.ID) -> Bool {
    // Multi-layer detection for more accurate running state:
    // 1. Check if terminal manager reports a running process
    #if canImport(SwiftTerm) && !APPSTORE
      if TerminalSessionManager.shared.hasRunningProcess(key: id) {
        return true
      }
    #endif

    // 2. Check if this is a pending new session (anchor awaiting rekey)
    if pendingEmbeddedRekeys.contains(where: { $0.anchorId == id }) {
      return true
    }

    // 3. Check recent file activity heartbeat (session actively writing)
    if viewModel.isActivelyUpdating(id) {
      return true
    }

    return false
  }

  func requestStopEmbedded(forID id: SessionSummary.ID) {
    // Always check current running state before showing confirmation
    let isRunning = isTerminalLikelyRunning(forID: id)

    if isRunning {
      // Show confirmation dialog for running sessions
      confirmStopState = ConfirmStopState(sessionId: id)
    } else {
      // Directly stop if not running
      stopEmbedded(forID: id)
    }
  }

  private func shellEscapeForCD(_ path: String) -> String {
    // Minimal POSIX shell escaping suitable for `cd` arguments
    return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  /// Launches a new session using the given anchor and shared task context.
  /// This regenerates ~/.codmate/tasks/context-<taskId>.md before launching.
  func newSessionWithTaskContext(task: CodMateTask, anchor: SessionSummary) {
    // Only support local sessions as anchors for now; remote sessions
    // cannot reliably access the local ~/.codmate/tasks directory.
    guard !anchor.isRemote else { return }

    Task {
      guard let workspaceVM = viewModel.workspaceVM else { return }
      _ = await workspaceVM.syncTaskContext(taskId: task.id)

      let taskIdString = task.id.uuidString
      let pathHint = "~/.codmate/tasks/context-\(taskIdString).md"
      let promptLines: [String] = [
        "当前 Task 的共享上下文已整理并保存到本地文件：",
        pathHint,
        "",
        "在回答本次问题前，如有需要，请先阅读该文件以了解任务历史记录和相关约束。",
      ]
      let prompt = promptLines.joined(separator: "\n")

      #if APPSTORE
        // App Store 版本不支持嵌入式终端，直接使用外部终端流程。
        let dir: String = {
          if FileManager.default.fileExists(atPath: anchor.cwd) {
            return anchor.cwd
          } else {
            return anchor.fileURL.deletingLastPathComponent().path
          }
        }()

        // External terminals rely on the existing auto-assign intent mechanism.
        viewModel.recordIntentForDetailNew(anchor: anchor)

        // Hint + targeted refresh so new session appears quickly in lists
        applyIncrementalHint(for: anchor.source, directory: dir)
        scheduleIncrementalRefresh(for: anchor.source, directory: dir)

        let app = viewModel.preferences.defaultResumeExternalApp
        switch app {
        case .iterm2:
          let cmd = viewModel.buildNewSessionCLIInvocationRespectingProject(
            session: anchor,
            initialPrompt: prompt
          )
          let pb = NSPasteboard.general
          pb.clearContents()
          pb.setString(cmd + "\n", forType: .string)
          viewModel.openPreferredTerminalViaScheme(app: .iterm2, directory: dir, command: cmd)
        case .warp:
          guard viewModel.copyNewSessionCommandsRespectingProject(
            session: anchor,
            destinationApp: .warp,
            initialPrompt: prompt
          ) else { return }
          viewModel.openPreferredTerminalViaScheme(app: .warp, directory: dir)
        case .terminal:
          viewModel.openNewSessionRespectingProject(session: anchor, initialPrompt: prompt)
          let cmd = viewModel.buildNewSessionCLIInvocationRespectingProject(
            session: anchor,
            initialPrompt: prompt
          )
          let pb = NSPasteboard.general
          pb.clearContents()
          pb.setString(cmd + "\n", forType: .string)
        case .none:
          _ = viewModel.openAppleTerminal(at: dir)
          let cmd = viewModel.buildNewSessionCLIInvocationRespectingProject(
            session: anchor,
            initialPrompt: prompt
          )
          let pb = NSPasteboard.general
          pb.clearContents()
          pb.setString(cmd + "\n", forType: .string)
        }
      #else
        if viewModel.preferences.defaultResumeUseEmbeddedTerminal {
          // 在内置终端中运行新的会话，并把 Task 上下文作为初始提示注入。
          selectedDetailTab = .terminal
          sessionDetailTabs[anchor.id] = .terminal
          let source = anchor.source
          let target = source == anchor.source ? anchor : anchor.overridingSource(source)
          let cwd =
            FileManager.default.fileExists(atPath: target.cwd)
            ? target.cwd : target.fileURL.deletingLastPathComponent().path
          // 构造带 Task 上下文的 CLI 调用
          let invocation = viewModel.buildNewSessionCLIInvocationRespectingProject(
            session: target,
            initialPrompt: prompt
          )
          let cd = "cd " + shellEscapeForCD(cwd)
          let preclear = "printf '\\033[?1049h\\033[H\\033[2J'"

          // 使用虚拟 anchor id 以便后续 rekey 到真实新会话。
          let anchorId = "new-anchor:task:\(task.id.uuidString):\(Int(Date().timeIntervalSince1970)))"
          embeddedInitialCommands[anchorId] =
            preclear + "\n" + cd + "\n" + invocation + "\n"
          runningSessionIDs.insert(anchorId)
          selectedTerminalKey = anchorId
          sessionDetailTabs[anchorId] = .terminal
          pendingEmbeddedRekeys.append(
            PendingEmbeddedRekey(
              anchorId: anchorId,
              expectedCwd: canonicalizePath(cwd),
              t0: Date(),
              selectOnSuccess: true,
              projectId: task.projectId
            )
          )
          // Event-driven incremental refresh for quick visibility in Tasks/Sessions lists
          applyIncrementalHint(for: target.source, directory: cwd)
          scheduleIncrementalRefresh(for: target.source, directory: cwd)
          selection.removeAll()
          isDetailMaximized = true
          columnVisibility = .detailOnly
        } else {
          // 回退到现有的外部终端逻辑
          let dir: String = {
            if FileManager.default.fileExists(atPath: anchor.cwd) {
              return anchor.cwd
            } else {
              return anchor.fileURL.deletingLastPathComponent().path
            }
          }()

          // External terminals rely on the auto-assign intent mechanism (project only).
          viewModel.recordIntentForDetailNew(anchor: anchor)

          // Hint + targeted refresh so new session appears quickly in lists
          applyIncrementalHint(for: anchor.source, directory: dir)
          scheduleIncrementalRefresh(for: anchor.source, directory: dir)

          let app = viewModel.preferences.defaultResumeExternalApp
          switch app {
          case .iterm2:
            let cmd = viewModel.buildNewSessionCLIInvocationRespectingProject(
              session: anchor,
              initialPrompt: prompt
            )
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(cmd + "\n", forType: .string)
            viewModel.openPreferredTerminalViaScheme(
              app: .iterm2, directory: dir, command: cmd)
          case .warp:
            guard viewModel.copyNewSessionCommandsRespectingProject(
              session: anchor,
              destinationApp: .warp,
              initialPrompt: prompt
            ) else { return }
            viewModel.openPreferredTerminalViaScheme(app: .warp, directory: dir)
          case .terminal:
            viewModel.openNewSessionRespectingProject(session: anchor, initialPrompt: prompt)
            let cmd = viewModel.buildNewSessionCLIInvocationRespectingProject(
              session: anchor,
              initialPrompt: prompt
            )
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(cmd + "\n", forType: .string)
          case .none:
            _ = viewModel.openAppleTerminal(at: dir)
            let cmd = viewModel.buildNewSessionCLIInvocationRespectingProject(
              session: anchor,
              initialPrompt: prompt
            )
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(cmd + "\n", forType: .string)
          }
        }
      #endif

      await SystemNotifier.shared.notify(
        title: "CodMate",
        body: "Command copied. Session starts with shared Task context."
      )
    }
  }

  func workingDirectory(for session: SessionSummary) -> String {
    if FileManager.default.fileExists(atPath: session.cwd) {
      return session.cwd
    }
    return session.fileURL.deletingLastPathComponent().path
  }

  func projectDirectory(for session: SessionSummary) -> String? {
    guard
      let pid = viewModel.projectIdForSession(session.id),
      let project = viewModel.projects.first(where: { $0.id == pid }),
      let directory = project.directory,
      !directory.isEmpty
    else { return nil }
    if FileManager.default.fileExists(atPath: directory) {
      return directory
    }
    return directory
  }

  func ensureRepoAccessForReview() {
    guard let focused = focusedSummary else { return }
    // Non-sandboxed builds don't require bookmark authorization or forced refresh
    if SecurityScopedBookmarks.shared.isSandboxed == false {
      return
    }
    let dir = workingDirectory(for: focused)
    let startURL = URL(fileURLWithPath: dir, isDirectory: true)

    // Resolve repository root by walking up to the nearest folder that contains .git
    func findRepoRootByFS(from start: URL) -> URL? {
      let fm = FileManager.default
      var cur = start.standardizedFileURL
      var guardCounter = 0
      while guardCounter < 200 {  // safety guard
        let gitDir = cur.appendingPathComponent(".git", isDirectory: true)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: gitDir.path, isDirectory: &isDir) {
          return cur
        }
        let parent = cur.deletingLastPathComponent()
        if parent.path == cur.path { break }
        cur = parent
        guardCounter += 1
      }
      return nil
    }

    let repoRoot = findRepoRootByFS(from: startURL) ?? startURL

    // If already authorized for this repo root, just ensure access is active and return silently
    if SecurityScopedBookmarks.shared.hasDynamicBookmark(for: repoRoot) {
      _ = SecurityScopedBookmarks.shared.startAccessDynamic(for: repoRoot)
      return
    }

    // Use synchronous authorization to ensure we get the result before proceeding
    let success = AuthorizationHub.shared.ensureDirectoryAccessOrPromptSync(
      directory: repoRoot,
      purpose: .gitReviewRepo,
      message: "Authorize the repository folder (the one containing .git) for Git Review"
    )

    if success {
      print("[ContentView] Git review authorization successful for: \(repoRoot.path)")
      // Force a view refresh by toggling away and back to Review
      Task { @MainActor in
        let was = selectedDetailTab
        selectedDetailTab = .timeline
        try? await Task.sleep(nanoseconds: 100_000_000)  // 0.1s
        selectedDetailTab = was
      }
    } else {
      print("[ContentView] Git review authorization failed or cancelled")
    }
  }

  func ensureRepoAccessForProjectReview(directory: String) {
    // Non-sandboxed builds don't require bookmark authorization
    if SecurityScopedBookmarks.shared.isSandboxed == false { return }
    let startURL = URL(fileURLWithPath: directory, isDirectory: true)

    func findRepoRootByFS(from start: URL) -> URL? {
      let fm = FileManager.default
      var cur = start.standardizedFileURL
      var guardCounter = 0
      while guardCounter < 200 {
        let gitDir = cur.appendingPathComponent(".git", isDirectory: true)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: gitDir.path, isDirectory: &isDir) {
          return cur
        }
        let parent = cur.deletingLastPathComponent()
        if parent.path == cur.path { break }
        cur = parent
        guardCounter += 1
      }
      return nil
    }

    let repoRoot = findRepoRootByFS(from: startURL) ?? startURL

    if SecurityScopedBookmarks.shared.hasDynamicBookmark(for: repoRoot) {
      _ = SecurityScopedBookmarks.shared.startAccessDynamic(for: repoRoot)
      return
    }

    let success = AuthorizationHub.shared.ensureDirectoryAccessOrPromptSync(
      directory: repoRoot,
      purpose: .gitReviewRepo,
      message: "Authorize the repository folder (the one containing .git) for Git Review"
    )

    if success {
      print("[ContentView] Project Git review authorization successful for: \(repoRoot.path)")
    } else {
      print("[ContentView] Project Git review authorization failed or cancelled")
    }
  }

  // MARK: - Embedded CLI console specs (DEV)
  private func consoleEnv(for source: SessionSource) -> [String: String] {
    var env: [String: String] = [:]
    env["LANG"] = "zh_CN.UTF-8"
    env["LC_ALL"] = "zh_CN.UTF-8"
    env["LC_CTYPE"] = "zh_CN.UTF-8"
    env["TERM"] = "xterm-256color"
    if source.baseKind == .codex { env["CODEX_DISABLE_COLOR_QUERY"] = "1" }
    return env
  }

  func consoleSpecForResume(_ session: SessionSummary) -> TerminalHostView.ConsoleSpec? {
    if SecurityScopedBookmarks.shared.isSandboxed {
      return nil
    }
    let exe = session.source.baseKind.cliExecutableName
    #if canImport(SwiftTerm)
      guard TerminalSessionManager.executableExists(exe) else {
        NSLog("⚠️ [ContentView] CLI executable %@ not found on PATH; falling back to shell", exe)
        return nil
      }
    #endif
    let args = viewModel.buildResumeCLIArgs(session: session)
    let cwd = workingDirectory(for: session)
    AuthorizationHub.shared.ensureDirectoryAccessOrPrompt(
      directory: URL(fileURLWithPath: cwd, isDirectory: true),
      purpose: .cliConsoleCwd,
      message: "Authorize this folder for CLI console to run \(exe)"
    )
    var env = consoleEnv(for: session.source)
    if session.source.baseKind == .gemini {
      let overrides = viewModel.actions.geminiEnvironmentOverrides(
        options: viewModel.preferences.resumeOptions)
      for (key, value) in overrides { env[key] = value }
    }
    return TerminalHostView.ConsoleSpec(
      executable: exe, args: args, cwd: cwd, env: env)
  }

  func consoleSpecForAnchor(_ anchorId: String) -> TerminalHostView.ConsoleSpec? {
    if SecurityScopedBookmarks.shared.isSandboxed { return nil }
    // For the project-level New anchor, we do not know the final session. We start a plain codex with defaults.
    // Minimal viable: start a login-less shell is not desired; instead start a no-op codex to present UI quickly.
    // As a preview, run `codex` without args in the project directory if we can infer it.
    if let pending = pendingEmbeddedRekeys.first(where: { $0.anchorId == anchorId }) {
      let exe = "codex"
      #if canImport(SwiftTerm)
        guard TerminalSessionManager.executableExists(exe) else {
          NSLog(
            "⚠️ [ContentView] CLI executable %@ not found on PATH for anchor %@; falling back to shell",
            exe, anchorId)
          return nil
        }
      #endif
      let args: [String] = []
      AuthorizationHub.shared.ensureDirectoryAccessOrPrompt(
        directory: URL(fileURLWithPath: pending.expectedCwd, isDirectory: true),
        purpose: .cliConsoleCwd,
        message: "Authorize this folder for CLI console to run \(exe)"
      )
      return TerminalHostView.ConsoleSpec(
        executable: exe, args: args, cwd: pending.expectedCwd, env: consoleEnv(for: .codexLocal))
    }
    return nil
  }

  /// Schedule a short-lived incremental refresh loop to surface newly created
  /// sessions for auto-assign (project / task) matching. Uses a 2s interval
  /// for up to ~2 minutes, aligned with the PendingAssignIntent lifetime.
  func startEmbeddedNew(for session: SessionSummary, using source: SessionSource? = nil) {
    let target = source.map { session.overridingSource($0) } ?? session
    #if APPSTORE
      openPreferredExternalForNew(session: target)
      return
    #else
      // Switch detail surface to Terminal tab when launching embedded new
      selectedDetailTab = .terminal
      sessionDetailTabs[session.id] = .terminal
      // Build the 'new session' commands (respecting project profile when present)
      let cwd =
        FileManager.default.fileExists(atPath: target.cwd)
        ? target.cwd : target.fileURL.deletingLastPathComponent().path
      if viewModel.preferences.useEmbeddedCLIConsole {
        let dirURL = URL(fileURLWithPath: cwd, isDirectory: true)
        if !AuthorizationHub.shared.canAccessNow(directory: dirURL) {
          let granted = AuthorizationHub.shared.ensureDirectoryAccessOrPromptSync(
            directory: dirURL,
            purpose: .cliConsoleCwd,
            message: "Authorize this folder for CLI console to run codex"
          )
          guard granted || AuthorizationHub.shared.canAccessNow(directory: dirURL) else {
            return
          }
        }
      }
      let cd = "cd " + shellEscapeForCD(cwd)
      let invocation = viewModel.buildNewSessionCLIInvocationRespectingProject(session: target)
      // Enter alternate screen and clear for a truly clean view (cursor home);
      // avoids reflow artifacts and isolates scrollback while the new session runs.
      let preclear = "printf '\\033[?1049h\\033[H\\033[2J'"

      // Use virtual anchor id to avoid hijacking an existing session's running state
      let anchorId = "new-anchor:detail:\(target.id):\(Int(Date().timeIntervalSince1970)))"
      embeddedInitialCommands[anchorId] =
        preclear + "\n" + cd + "\n" + invocation + "\n"
      runningSessionIDs.insert(anchorId)
      selectedTerminalKey = anchorId
      sessionDetailTabs[anchorId] = .terminal
      // Record pending rekey so that when the new session appears, we can move this PTY to the real id
      pendingEmbeddedRekeys.append(
        PendingEmbeddedRekey(
          anchorId: anchorId,
          expectedCwd: canonicalizePath(cwd),
          t0: Date(),
          selectOnSuccess: true,
          projectId: viewModel.projectIdForSession(target.id)
        )
      )
      // Event-driven incremental refresh: set a hint so directory monitor triggers a targeted refresh
      applyIncrementalHint(for: target.source, directory: cwd)
      // Proactively trigger a targeted incremental refresh for immediate visibility
      scheduleIncrementalRefresh(for: target.source, directory: cwd)
      // Clear selection so fallbackRunningAnchorId() can display the virtual anchor terminal
      selection.removeAll()
      // Ensure terminal is visible
      isDetailMaximized = true
      columnVisibility = .detailOnly
    #endif
  }

  func startEmbeddedNewForProject(_ project: Project) {
    #if APPSTORE
      NSLog("📌 [ContentView] startEmbeddedNewForProject (APPSTORE fallback) id=%@", project.id)
      viewModel.newSession(project: project)
      return
    #else
      // Build 'new project' invocation and inject into embedded terminal
      let dir: String = {
        let d = (project.directory ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return d.isEmpty ? NSHomeDirectory() : d
      }()
      NSLog(
        "📌 [ContentView] startEmbeddedNewForProject id=%@ dir=%@ useEmbeddedCLIConsole=%@",
        project.id, dir, viewModel.preferences.useEmbeddedCLIConsole ? "YES" : "NO"
      )
      // Ensure Terminal tab is active so the embedded session is visible
      selectedDetailTab = .terminal
      if viewModel.preferences.useEmbeddedCLIConsole {
        let dirURL = URL(fileURLWithPath: dir, isDirectory: true)
        if !AuthorizationHub.shared.canAccessNow(directory: dirURL) {
          let granted = AuthorizationHub.shared.ensureDirectoryAccessOrPromptSync(
            directory: dirURL,
            purpose: .cliConsoleCwd,
            message: "Authorize this folder for CLI console to run codex"
          )
          guard granted || AuthorizationHub.shared.canAccessNow(directory: dirURL) else {
            NSLog("⚠️ [ContentView] Authorization denied for embedded New dir=%@", dir)
            return
          }
        }
      }
      let cd = "cd " + shellEscapeForCD(dir)
      let invocation = viewModel.buildNewProjectCLIInvocation(project: project)
      let command = invocation
      let preclear = "printf '\\033[?1049h\\033[H\\033[2J'"

      // Always use a virtual anchor for project-level New
      let anchorId = "new-anchor:project:\(project.id):\(Int(Date().timeIntervalSince1970)))"
      NSLog("📌 [ContentView] Embedded New anchor=%@ command=%@", anchorId, command)
      embeddedInitialCommands[anchorId] =
        preclear + "\n" + cd + "\n" + invocation + "\n"
      runningSessionIDs.insert(anchorId)
      selectedTerminalKey = anchorId
      sessionDetailTabs[anchorId] = .terminal
      // Pending rekey: when the new session lands under this cwd, move PTY to the real id
      pendingEmbeddedRekeys.append(
        PendingEmbeddedRekey(
          anchorId: anchorId,
          expectedCwd: canonicalizePath(dir),
          t0: Date(),
          selectOnSuccess: true,
          projectId: project.id
        )
      )
      // Event-driven incremental refresh: scoped to today's Codex folder
      viewModel.setIncrementalHintForCodexToday()
      // Proactively refresh today's subset so the new item appears quickly
      Task {
        await viewModel.refreshIncrementalForNewCodexToday()
        // Follow-up probes to catch late file creation
        try? await Task.sleep(nanoseconds: 600_000_000)
        await viewModel.refreshIncrementalForNewCodexToday()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await viewModel.refreshIncrementalForNewCodexToday()
      }
      // Clear selection so fallbackRunningAnchorId() can display the virtual anchor terminal
      selection.removeAll()
      // Maximize detail to show embedded terminal
      isDetailMaximized = true
      columnVisibility = .detailOnly
    #endif
  }

  func openPreferredExternal(for session: SessionSummary, using source: SessionSource? = nil) {
    let target = source.map { session.overridingSource($0) } ?? session
    let app = viewModel.preferences.defaultResumeExternalApp
    viewModel.copyResumeCommandsRespectingProject(session: target, destinationApp: app)
    let dir = workingDirectory(for: target)
    switch app {
    case .iterm2:
      let cmd = viewModel.buildResumeCLIInvocationRespectingProject(session: target)
      viewModel.openPreferredTerminalViaScheme(app: .iterm2, directory: dir, command: cmd)
    case .warp:
      viewModel.openPreferredTerminalViaScheme(app: .warp, directory: dir)
    case .terminal:
      if !viewModel.openInTerminal(session: target) {
        viewModel.copyResumeCommandsRespectingProject(session: target, destinationApp: app)
        _ = viewModel.openAppleTerminal(at: dir)
        Task { await SystemNotifier.shared.notify(title: "CodMate", body: "Command copied. Paste it in the opened terminal.") }
      }
    case .none:
      break
    }
    Task {
      await SystemNotifier.shared.notify(
        title: "CodMate", body: "Command copied. Paste it in the opened terminal.")
    }
  }

  func openPreferredExternalForNew(session: SessionSummary) {
    // Record pending intent for auto-assign before launching
    viewModel.recordIntentForDetailNew(anchor: session)
    let app = viewModel.preferences.defaultResumeExternalApp
    let dir = workingDirectory(for: session)
    // Event hint for targeted incremental refresh on FS change
    applyIncrementalHint(for: session.source, directory: dir)
    // Also proactively refresh the targeted subset for faster UI update
    scheduleIncrementalRefresh(for: session.source, directory: dir)
    switch app {
    case .iterm2:
      let cmd = viewModel.buildNewSessionCLIInvocationRespectingProject(session: session)
      viewModel.openPreferredTerminalViaScheme(app: .iterm2, directory: dir, command: cmd)
    case .warp:
      // Warp scheme cannot run a command; open path only and rely on clipboard
      viewModel.openPreferredTerminalViaScheme(app: .warp, directory: dir)
    case .terminal:
      #if APPSTORE
        viewModel.copyNewSessionCommandsRespectingProject(session: session, destinationApp: .terminal)
        _ = viewModel.openAppleTerminal(at: dir)
      #else
        viewModel.openNewSessionRespectingProject(session: session)
      #endif
    case .none:
      break
    }
    Task {
      await SystemNotifier.shared.notify(
        title: "CodMate", body: "Command copied. Paste it in the opened terminal.")
    }
  }

  func startNewSession(for session: SessionSummary, using source: SessionSource? = nil) {
    let target = source.map { session.overridingSource($0) } ?? session
    let app = viewModel.preferences.defaultResumeExternalApp
    viewModel.copyNewSessionCommandsRespectingProject(session: target, destinationApp: app)
    openPreferredExternalForNew(session: target)
  }

  enum NewLaunchStyle {
    case preferred
    case terminal
    case iterm
    case warp
    case embedded
  }

  func launchNewSession(
    for session: SessionSummary, using source: SessionSource, style: NewLaunchStyle
  ) {
    let target = source == session.source ? session : session.overridingSource(source)
    switch style {
    case .preferred:
      if viewModel.preferences.defaultResumeUseEmbeddedTerminal {
        viewModel.recordIntentForDetailNew(anchor: target)
        startEmbeddedNew(for: target)
      } else {
        startNewSession(for: target)
      }
    case .terminal:
      viewModel.recordIntentForDetailNew(anchor: target)
      #if APPSTORE
        if !viewModel.openNewSession(session: target) {
        viewModel.copyNewSessionCommandsRespectingProject(session: target, destinationApp: .terminal)
        _ = viewModel.openAppleTerminal(at: workingDirectory(for: target))
        Task {
          await SystemNotifier.shared.notify(
            title: "CodMate",
            body: "Command copied. Paste it in the opened terminal.")
          }
        }
      #else
        if !viewModel.openNewSession(session: target) {
        viewModel.copyNewSessionCommandsRespectingProject(session: target, destinationApp: .terminal)
        _ = viewModel.openAppleTerminal(at: workingDirectory(for: target))
        Task {
          await SystemNotifier.shared.notify(
            title: "CodMate",
            body: "Command copied. Paste it in the opened terminal.")
          }
        }
      #endif
    case .iterm:
      viewModel.recordIntentForDetailNew(anchor: target)
      let cmd = viewModel.buildNewSessionCLIInvocationRespectingProject(session: target)
      viewModel.openPreferredTerminalViaScheme(
        app: .iterm2, directory: workingDirectory(for: target), command: cmd)
    case .warp:
      viewModel.recordIntentForDetailNew(anchor: target)
      guard viewModel.copyNewSessionCommandsRespectingProject(session: target, destinationApp: .warp)
      else { return }
      viewModel.openPreferredTerminalViaScheme(
        app: .warp, directory: workingDirectory(for: target))
      Task {
        await SystemNotifier.shared.notify(
          title: "CodMate",
          body: "Command copied. Paste it in the opened terminal.")
      }
    case .embedded:
      viewModel.recordIntentForDetailNew(anchor: target)
      startEmbeddedNew(for: target)
    }
  }

  enum ResumeLaunchStyle {
    case terminal
    case iterm
    case warp
    case embedded
  }

  func launchResume(
    for session: SessionSummary,
    using source: SessionSource,
    style: ResumeLaunchStyle
  ) {
    let target = source == session.source ? session : session.overridingSource(source)
    switch style {
    case .terminal:
      if !viewModel.openInTerminal(session: target) {
        viewModel.copyResumeCommandsRespectingProject(session: target, destinationApp: .terminal)
        _ = viewModel.openAppleTerminal(at: workingDirectory(for: target))
        Task {
          await SystemNotifier.shared.notify(
            title: "CodMate",
            body: "Command copied. Paste it in the opened terminal.")
        }
      }
    case .iterm:
      let cmd = viewModel.buildResumeCLIInvocationRespectingProject(session: target)
      viewModel.openPreferredTerminalViaScheme(
        app: .iterm2, directory: workingDirectory(for: target), command: cmd)
    case .warp:
      viewModel.copyResumeCommandsRespectingProject(session: target, destinationApp: .warp)
      viewModel.openPreferredTerminalViaScheme(
        app: .warp, directory: workingDirectory(for: target))
      Task {
        await SystemNotifier.shared.notify(
          title: "CodMate",
          body: "Command copied. Paste it in the opened terminal.")
      }
    case .embedded:
      startEmbedded(for: target)
    }
  }

  // moved to ContentView+Helpers.swift

  private func toggleDetailMaximized() {
    withAnimation(.easeInOut(duration: 0.18)) {
      let shouldHide = columnVisibility != .detailOnly
      columnVisibility = shouldHide ? .detailOnly : .all
      isDetailMaximized = shouldHide
    }
  }

  func toggleSidebarVisibility() {
    // Toggle sidebar between shown (.all) and hidden (.doubleColumn). If maximized, restore.
    withAnimation(.easeInOut(duration: 0.15)) {
      switch columnVisibility {
      case .detailOnly:
        columnVisibility = .all; storeSidebarHidden = false
      case .all:
        columnVisibility = .doubleColumn; storeSidebarHidden = true
      case .doubleColumn:
        columnVisibility = .all; storeSidebarHidden = false
      default:
        columnVisibility = storeSidebarHidden ? .all : .doubleColumn
        storeSidebarHidden.toggle()
      }
    }
  }

  func toggleListVisibility() {
    // Revert to non-animated toggle to keep detail anchored and stable
    isListHidden.toggle()
    storeListHidden = isListHidden
  }

  func applyVisibilityFromStorage(animated: Bool) {
    let action = {
      // Apply list visibility
      isListHidden = storeListHidden
      // Apply sidebar visibility when not maximized
      if columnVisibility != .detailOnly {
        columnVisibility = storeSidebarHidden ? .doubleColumn : .all
      }
    }
    if animated { withAnimation(.easeInOut(duration: 0.12)) { action() } } else { action() }
  }

  @ViewBuilder
  func maximizeToggleButton() -> some View {
    let isBothHidden = storeSidebarHidden && isListHidden
    Button {
      withAnimation(.easeInOut(duration: 0.15)) {
        toggleSidebarVisibility()
        toggleListVisibility()
      }
    } label: {
      Image(
        systemName: isBothHidden
          ? "arrow.up.right.and.arrow.down.left"
          : "arrow.down.left.and.arrow.up.right"
      )
      .imageScale(.medium)
    }
    .buttonStyle(.bordered)
    .controlSize(.regular)
    .frame(height: 28)
    .accessibilityLabel(isBothHidden ? "Restore lists" : "Maximize detail")
  }

  func handleFolderSelection(
    result: Result<[URL], Error>,
    update: @escaping (URL) async -> Void
  ) {
    switch result {
    case .success(let urls):
      selectingSessionsRoot = false
      guard let url = urls.first else { return }
      Task { await update(url) }
    case .failure(let error):
      selectingSessionsRoot = false
      alertState = AlertState(
        title: "Failed to choose directory", message: error.localizedDescription)
    }
  }

  // Removed: executable chooser handler

  var placeholder: some View {
    ContentUnavailableView(
      "Select a session", systemImage: "rectangle.and.text.magnifyingglass",
      description: Text("Pick a session from the middle list to view details.")
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

// MARK: - Embedded PTY rekey helpers
extension ContentView {
  // canonicalizePath moved to ContentView+Helpers.swift

  func reconcilePendingEmbeddedRekeys() {
    guard !pendingEmbeddedRekeys.isEmpty else { return }
    let all = viewModel.sections.flatMap(\.sessions)
    let now = Date()
    var remaining: [PendingEmbeddedRekey] = []
    for pending in pendingEmbeddedRekeys {
      // Window to match nearby creations
      let windowStart = pending.t0.addingTimeInterval(-2)
      let windowEnd = pending.t0.addingTimeInterval(120)
      let candidates = all.filter { s in
        guard s.id != pending.anchorId else { return false }
        let canon = canonicalizePath(s.cwd)
        guard canon == pending.expectedCwd else { return false }
        return s.startedAt >= windowStart && s.startedAt <= windowEnd
      }
      if let winner = candidates.min(by: {
        abs($0.startedAt.timeIntervalSince(pending.t0))
          < abs($1.startedAt.timeIntervalSince(pending.t0))
      }) {
        #if canImport(SwiftTerm) && !APPSTORE
          TerminalSessionManager.shared.rekey(from: pending.anchorId, to: winner.id)
        #endif
        if runningSessionIDs.contains(pending.anchorId) {
          runningSessionIDs.remove(pending.anchorId)
          runningSessionIDs.insert(winner.id)
        }
        if selectedTerminalKey == pending.anchorId {
          selectedTerminalKey = winner.id
        }
        if let savedTab = sessionDetailTabs.removeValue(forKey: pending.anchorId) {
          sessionDetailTabs[winner.id] = savedTab
        } else if selectedDetailTab == .terminal
          && (pending.selectOnSuccess || selection.contains(pending.anchorId))
        {
          sessionDetailTabs[winner.id] = .terminal
        }
        if pending.selectOnSuccess || selection.contains(pending.anchorId) {
          selection = [winner.id]
        }
        if let pid = pending.projectId {
          Task {
            await viewModel.assignSessions(to: pid, ids: [winner.id])
          }
        }
      } else {
        if now.timeIntervalSince(pending.t0) < 180 {
          remaining.append(pending)
        } else {
          // Timeout: stop the anchor terminal to avoid lingering shells
          #if canImport(SwiftTerm) && !APPSTORE
            TerminalSessionManager.shared.stop(key: pending.anchorId)
          #endif
          runningSessionIDs.remove(pending.anchorId)
          embeddedInitialCommands.removeValue(forKey: pending.anchorId)
          sessionDetailTabs.removeValue(forKey: pending.anchorId)
          if selectedTerminalKey == pending.anchorId {
            selectedTerminalKey = runningSessionIDs.first
          }
        }
      }
    }
    pendingEmbeddedRekeys = remaining
  }
}

struct AlertState: Identifiable {
  let id = UUID()
  let title: String
  let message: String
}

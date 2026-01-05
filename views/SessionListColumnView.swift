import AppKit
import SwiftUI

struct SessionListColumnView: View {
  let sections: [SessionDaySection]
  @Binding var selection: Set<SessionSummary.ID>
  @Binding var sortOrder: SessionSortOrder
  let isLoading: Bool
  let isEnriching: Bool
  let enrichmentProgress: Int
  let enrichmentTotal: Int
  let onResume: (SessionSummary) -> Void
  let onReveal: (SessionSummary) -> Void
  let onDeleteRequest: (SessionSummary) -> Void
  let onExportMarkdown: (SessionSummary) -> Void
  // running state probe
  var isRunning: ((SessionSummary) -> Bool)? = nil
  // live updating probe (file activity)
  var isUpdating: ((SessionSummary) -> Bool)? = nil
  // awaiting follow-up probe
  var isAwaitingFollowup: ((SessionSummary) -> Bool)? = nil
  // notify which item is the user's primary (last clicked) for detail focus
  var onPrimarySelect: ((SessionSummary) -> Void)? = nil
  // callback for launching new session with task context
  var onNewSessionWithTaskContext: ((CodMateTask, SessionSummary?, SessionSource, ExternalTerminalProfile) -> Void)? = nil
  @EnvironmentObject private var viewModel: SessionListViewModel
  @Environment(\.colorScheme) private var colorScheme
  @State private var showNewProjectSheet = false
  @State private var draftTaskFromSession: CodMateTask? = nil
  @State private var taskEditingMode: EditTaskSheet.Mode = .edit
  @State private var newProjectPrefill: ProjectEditorSheet.Prefill? = nil
  @State private var newProjectAssignIDs: [String] = []
  @State private var lastClickedID: String? = nil
  @State private var containerWidth: CGFloat = 0
  @FocusState private var quickSearchFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      header
        .padding(.horizontal, 8)
        .padding(.top, 0)
        .padding(.bottom, 8)

      contentView
    }
    .padding(.vertical, 16)
    .padding(.horizontal, 6)
    .sheet(isPresented: $showNewProjectSheet) {
      ProjectEditorSheet(
        isPresented: $showNewProjectSheet,
        mode: .new,
        prefill: newProjectPrefill,
        autoAssignSessionIDs: newProjectAssignIDs
      )
      .environmentObject(viewModel)
    }
    .sheet(item: $draftTaskFromSession) { task in
      if let workspaceVM = viewModel.workspaceVM {
        EditTaskSheet(
          task: task,
          mode: taskEditingMode,
          workspaceVM: workspaceVM,
          onSave: { updatedTask in
            Task {
              await workspaceVM.updateTask(updatedTask)
              draftTaskFromSession = nil
            }
          },
          onCancel: {
            draftTaskFromSession = nil
          }
        )
      }
    }
    .background(
      GeometryReader { geo in
        Color.clear
          .preference(key: ListColumnWidthKey.self, value: geo.size.width)
      }
    )
    .onPreferenceChange(ListColumnWidthKey.self) { w in
      containerWidth = w
    }
  }

  @ViewBuilder
  private var contentView: some View {
    // In Tasks mode, show TaskListView instead of regular sessions list
    if viewModel.projectWorkspaceMode == .tasks, let workspaceVM = viewModel.workspaceVM {
      TaskListView(
        workspaceVM: workspaceVM,
        selection: $selection,
        onResume: onResume,
        onReveal: onReveal,
        onDeleteRequest: onDeleteRequest,
        onExportMarkdown: onExportMarkdown,
        isRunning: isRunning,
        isUpdating: isUpdating,
        isAwaitingFollowup: isAwaitingFollowup,
        onPrimarySelect: onPrimarySelect,
        onNewSessionWithTaskContext: onNewSessionWithTaskContext
      )
    } else {
      // Regular sessions list for other modes
      if sections.isEmpty {
        if isLoading {
          VStack {
            Spacer()
            ProgressView("Scanning…")
            Spacer()
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .padding(.horizontal, -2)
        } else {
          emptyStateView
            .padding(.horizontal, -2)
        }
      } else {
        sessionsListView
      }
    }
  }

  private var emptyStateView: some View {
    let selected = selectedProject()
    let isOtherProject = selected?.id == SessionListViewModel.otherProjectId

    return VStack(spacing: 12) {
      Spacer(minLength: 12)

      // Different message for Other project bucket
      if isOtherProject {
        Group {
          if #available(macOS 14.0, *) {
            unavailableView(
              title: "No Unassigned Sessions",
              systemImage: "tray",
              description:
                "Sessions can only be created within a project. Select a project from the sidebar to start a new session."
            )
          } else {
            fallbackUnavailableView(
              title: "No Unassigned Sessions",
              systemImage: "tray",
              description:
                "Sessions can only be created within a project. Select a project from the sidebar to start a new session."
            )
          }
        }
        .frame(maxWidth: .infinity)
      } else {
        Group {
          if #available(macOS 14.0, *) {
            unavailableView(
              title: "No Sessions",
              systemImage: "tray",
              description: "Adjust directories or launch Codex CLI to generate new session logs."
            )
          } else {
            fallbackUnavailableView(
              title: "No Sessions",
              systemImage: "tray",
              description: "Adjust directories or launch Codex CLI to generate new session logs."
            )
          }
        }
        .frame(maxWidth: .infinity)
      }

      // Primary action: New (hidden for Other project, shown for regular projects)
      if let project = selected, !isOtherProject {
        let embeddedPreferredNew =
          viewModel.preferences.defaultResumeUseEmbeddedTerminal && !AppSandbox.isEnabled
        let anchor = projectAnchor(for: project)
        SplitPrimaryMenuButton(
          title: "New",
          systemImage: "plus",
          primary: {
            if embeddedPreferredNew {
              // Defer to shared embedded flow (exactly as detail bar does)
              viewModel.newSession(project: project)
            } else {
              startExternalNewForProject(project)
            }
          },
          items: anchor.map { buildNewMenuItems(anchor: $0) } ?? []
        )
        .help("Start a new session in \(projectDisplayName(project))")
      } else if !isOtherProject {
        SplitPrimaryMenuButton(
          title: "New",
          systemImage: "plus",
          primary: {},
          items: []
        )
        .opacity(0.6)
        .help("Select a project in the sidebar to start a new session")
      }

      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @available(macOS 14.0, *)
  private func unavailableView(title: String, systemImage: String, description: String) -> some View {
    ContentUnavailableView(title, systemImage: systemImage, description: Text(description))
  }

  private func fallbackUnavailableView(title: String, systemImage: String, description: String)
    -> some View
  {
    UnavailableStateView(
      title,
      systemImage: systemImage,
      description: description,
      titleColor: .primary
    )
  }

  @ViewBuilder
  private var sessionsListView: some View {
    List(selection: $selection) {
      ForEach(sections) { section in
        Section {
          ForEach(section.sessions, id: \.id) { session in
            sessionRow(for: session)
          }
        } header: {
          HStack {
            Text(section.title)
            Spacer()
            Label(section.totalDuration.readableFormattedDuration, systemImage: "clock")
            Label("\(section.totalEvents)", systemImage: "chart.bar")
          }
          .font(.subheadline)
          .foregroundStyle(.secondary)
        }
      }
    }
    .padding(.horizontal, -2)
    .listStyle(.inset)
    .contextMenu { backgroundContextMenu() }
  }

  @ViewBuilder
  private func sessionRow(for session: SessionSummary) -> some View {
    EquatableSessionListRow(
      summary: session,
      isRunning: isRunning?(session) ?? false,
      isSelected: selectionContains(session.id),
      isUpdating: isUpdating?(session) ?? false,
      awaitingFollowup: isAwaitingFollowup?(session) ?? false,
      inProject: viewModel.projectIdForSession(session.id) != nil,
      projectTip: projectTip(for: session),
      inTaskContainer: false
    )
    .tag(session.id)
    .contentShape(Rectangle())
    .onTapGesture(count: 2) {
      selection = [session.id]
      onPrimarySelect?(session)
      Task { await viewModel.beginEditing(session: session) }
    }
    .onTapGesture { handleClick(on: session) }
    .onDrag {
      let ids: [String]
      if selectionContains(session.id) && selection.count > 1 {
        ids = Array(selection)
      } else {
        ids = [session.id]
      }
      let payloads: [String] = ids.compactMap { id in
        if let summary = viewModel.sessionSummary(for: id) {
          return viewModel.sessionDragIdentifier(for: summary)
        }
        return id
      }
      return NSItemProvider(object: payloads.joined(separator: "\n") as NSString)
    }
    .listRowInsets(EdgeInsets())
    .contextMenu {
      sessionContextMenu(for: session)
    }
  }

  @ViewBuilder
  private func sessionContextMenu(for session: SessionSummary) -> some View {
    let project = projectForSession(session)

    if session.source == .codexLocal || session.source == .geminiLocal {
      let resumeItems = buildResumeMenuItems(for: session)
      if !resumeItems.isEmpty {
        Menu { SplitMenuItemsView(items: resumeItems) } label: {
          let icon = assetIconForSessionSource(session.source)
          Label {
            Text("Resume")
          } icon: {
            if let menuIcon = menuAssetNSImage(
              named: icon,
              invertForDarkMode: icon == "ChatGPTIcon" && colorScheme == .dark
            ) {
              Image(nsImage: menuIcon)
                .frame(width: 14, height: 14)
            } else {
              Image(icon)
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 14)
                .clipped()
                .modifier(DarkModeInvertModifier(active: icon == "ChatGPTIcon" && colorScheme == .dark))
            }
          }
        }
      }
    }
    Divider()
    Button {
      Task { await viewModel.beginEditing(session: session) }
    } label: {
      Label("Edit Title & Comment", systemImage: "pencil")
    }
    Button {
      Task { @MainActor in
        await viewModel.generateTitleAndComment(for: session, force: false)
      }
    } label: {
      Label("Generate Title & Comment", systemImage: "sparkles")
    }

    if let project, project.id != SessionListViewModel.otherProjectId {
      let newItems = buildNewMenuItems(anchor: session)
      if newItems.isEmpty {
        Button {
          viewModel.newSession(project: project)
        } label: {
          Label("New Session", systemImage: "plus")
        }
      } else {
        Menu {
          SplitMenuItemsView(items: newItems)
        } label: {
          Label("New Session…", systemImage: "plus")
        }
      }
      Button {
        draftTaskFromSession = CodMateTask(
          title: "",
          description: nil,
          projectId: project.id,
          sessionIds: [session.id]
        )
      } label: {
        Label("New Task…", systemImage: "checklist")
      }
    }

    if !viewModel.projects.isEmpty {
      Menu {
        Button {
          newProjectPrefill = prefillForProject(from: session)
          newProjectAssignIDs = [session.id]
          showNewProjectSheet = true
        } label: {
          Label("New Project…", systemImage: "square.grid.2x2")
        }
        Divider()
        ForEach(viewModel.projects) { p in
          Button(p.name.isEmpty ? p.id : p.name) {
            Task { await viewModel.assignSessions(to: p.id, ids: [session.id]) }
          }
        }
      } label: {
        Label("Assign to Project…", systemImage: "rectangle.stack.badge.plus")
      }
    }
    Button {
      onExportMarkdown(session)
    } label: {
      Label("Export Markdown", systemImage: "square.and.arrow.up")
    }
    Divider()
    Button {
      copyAbsolutePath(session)
    } label: {
      Label("Copy Absolute Path", systemImage: "doc.on.doc")
    }
    Button {
      onReveal(session)
    } label: {
      Label("Reveal in Finder", systemImage: "finder")
    }
    Button(role: .destructive) {
      if !selectionContains(session.id) {
        selection = [session.id]
      }
      onDeleteRequest(session)
    } label: {
      let isBatchDelete = selectionContains(session.id) && selection.count > 1
      Label(
        isBatchDelete ? "Move Sessions to Trash" : "Move Session to Trash",
        systemImage: "trash")
    }

    if shouldShowTaskCollapseControls {
      Divider()
      Button {
        postTaskCollapseNotification(.codMateCollapseAllTasks)
      } label: {
        Label("Collapse all Tasks", systemImage: "arrow.down.right.and.arrow.up.left")
      }
      Button {
        postTaskCollapseNotification(.codMateExpandAllTasks)
      } label: {
        Label("Expand all Tasks", systemImage: "arrow.up.left.and.arrow.down.right")
      }
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Quick search with optional Task collapse controls in Tasks mode
      HStack(spacing: 8) {
        HStack(spacing: 6) {
          Image(systemName: "magnifyingglass")
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
          TextField("Search title or comment", text: $viewModel.quickSearchText)
            .textFieldStyle(.plain)
            .focused($quickSearchFocused)
            .onSubmit {
              viewModel.immediateApplyQuickSearch(viewModel.quickSearchText)
            }
          if !viewModel.quickSearchText.isEmpty {
            Button {
              viewModel.quickSearchText = ""
            } label: {
              Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(nsColor: .textBackgroundColor))
            .overlay(
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            )
        )
        .frame(maxWidth: .infinity)
        // 当全局搜索触发时，确保本地搜索框让出焦点，避免与 Cmd+F 竞争
        .onReceive(NotificationCenter.default.publisher(for: .codMateFocusGlobalSearch)) { _ in
          quickSearchFocused = false
        }

        if shouldShowTaskCollapseControls {
          CollapseExpandButtonGroup(
            collapseHelp: "Collapse all Tasks",
            expandHelp: "Expand all Tasks",
            onCollapse: { postTaskCollapseNotification(.codMateCollapseAllTasks) },
            onExpand: { postTaskCollapseNotification(.codMateExpandAllTasks) }
          )
        }
      }

      HStack(spacing: 8) {
        EqualWidthSegmentedControl(
          items: Array(SessionSortOrder.allCases),
          selection: $sortOrder,
          title: { $0.title }
        )
        .frame(maxWidth: .infinity)
      }
      .transition(.opacity.combined(with: .move(edge: .leading)))
    }
    .frame(maxWidth: .infinity)
  }
}

extension SessionListColumnView {
  fileprivate var shouldShowTaskCollapseControls: Bool {
    viewModel.projectWorkspaceMode == .tasks && viewModel.workspaceVM != nil
  }

  fileprivate func postTaskCollapseNotification(_ name: Notification.Name) {
    var info: [AnyHashable: Any]? = nil
    if let projectId = viewModel.selectedProjectIDs.first { info = ["projectId": projectId] }
    NotificationCenter.default.post(name: name, object: nil, userInfo: info)
  }
}

private struct ListColumnWidthKey: PreferenceKey {
  static var defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = nextValue()
  }
}

extension SessionListColumnView {
  private func selectedProject() -> Project? {
    guard viewModel.selectedProjectIDs.count == 1,
      let pid = viewModel.selectedProjectIDs.first
    else { return nil }

    // Check if it's the synthetic Other project
    if pid == SessionListViewModel.otherProjectId {
      return Project(
        id: SessionListViewModel.otherProjectId,
        name: "Other",
        directory: nil,
        trustLevel: nil,
        overview: nil,
        instructions: nil,
        profileId: nil,
        profile: nil,
        parentId: nil,
        sources: ProjectSessionSource.allSet
      )
    }

    return viewModel.projects.first(where: { $0.id == pid })
  }

  private func projectDisplayName(_ p: Project) -> String {
    let trimmed = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { return trimmed }
    if let dir = p.directory, !dir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let base = URL(fileURLWithPath: dir, isDirectory: true).lastPathComponent
      return base.isEmpty ? p.id : base
    }
    return p.id
  }

  private func projectForSession(_ session: SessionSummary) -> Project? {
    guard let pid = viewModel.projectIdForSession(session.id) else { return nil }
    if pid == SessionListViewModel.otherProjectId { return nil }
    return viewModel.projects.first(where: { $0.id == pid })
  }

  func selectionContains(_ id: SessionSummary.ID) -> Bool {
    selection.contains(id)
  }

  private func backgroundContextMenu() -> some View {
    let project = selectedProject()
    let anchor = project.flatMap { projectAnchor(for: $0) }
    return Group {
      if let project {
        newSessionMenu(for: project, anchor: anchor)
        if viewModel.workspaceVM != nil {
          Button {
            taskEditingMode = .new
            draftTaskFromSession = CodMateTask(title: "", description: nil, projectId: selectedProject()?.id ?? "")
          } label: {
            Label("New Task…", systemImage: "checklist")
          }
        }
      }
      if shouldShowTaskCollapseControls {
        Divider()
        Button {
          postTaskCollapseNotification(.codMateCollapseAllTasks)
        } label: {
          Label("Collapse all Tasks", systemImage: "arrow.down.right.and.arrow.up.left")
        }
        Button {
          postTaskCollapseNotification(.codMateExpandAllTasks)
        } label: {
          Label("Expand all Tasks", systemImage: "arrow.up.left.and.arrow.down.right")
        }
      }
    }
  }

  private func projectAnchor(for project: Project) -> SessionSummary? {
    // Prefer currently visible sessions for this project; fall back to any cached session.
    if let visible = sections.flatMap({ $0.sessions }).first(
      where: { viewModel.projectIdForSession($0.id) == project.id })
    {
      return visible
    }
    return viewModel.allSessions.first { viewModel.projectIdForSession($0.id) == project.id }
  }

  // Build external Terminal flow exactly like newSession(project:) external branch,
  // but force external when App Sandbox blocks embedded terminals.
  private func startExternalNewForProject(_ project: Project) {
    guard
      let profile = ExternalTerminalProfileStore.shared.resolvePreferredProfile(
        id: viewModel.preferences.defaultResumeExternalAppId
      )
    else { return }
    let dir: String = {
      let d = (project.directory ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      return d.isEmpty ? NSHomeDirectory() : d
    }()
    let command = buildProjectCommand(project: project, directory: dir)
    if profile.usesWarpCommands {
      guard viewModel.copyNewProjectCommandsIfEnabled(project: project, destinationApp: profile)
      else { return }
      viewModel.openPreferredTerminalViaScheme(profile: profile, directory: dir)
    } else {
      if profile.isNone {
        _ = viewModel.copyNewProjectCommandsIfEnabled(project: project, destinationApp: profile)
        if viewModel.shouldCopyCommandsToClipboard
          && viewModel.preferences.commandCopyNotificationsEnabled
        {
          Task {
            await SystemNotifier.shared.notify(
              title: "CodMate", body: "Command copied. Paste it in the opened terminal.")
          }
        }
        return
      }
      if !profile.supportsCommandResolved, viewModel.shouldCopyCommandsToClipboard {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(command + "\n", forType: .string)
      }
      if profile.isTerminal {
        _ = viewModel.openAppleTerminal(at: dir)
      } else {
        let cmd = profile.supportsCommandResolved ? command : nil
        viewModel.openPreferredTerminalViaScheme(profile: profile, directory: dir, command: cmd)
      }
    }
    if viewModel.shouldCopyCommandsToClipboard && viewModel.preferences.commandCopyNotificationsEnabled {
      Task {
        await SystemNotifier.shared.notify(
          title: "CodMate", body: "Command copied. Paste it in the opened terminal.")
      }
    }
    // Hint + targeted refresh aligns with viewModel.newSession external path
    viewModel.setIncrementalHintForCodexToday()
    Task { await viewModel.refreshIncrementalForNewCodexToday() }
  }

  private func buildProjectCommand(project: Project, directory: String) -> String {
    let cd = "cd " + directory.replacingOccurrences(of: " ", with: "\\ ")
    let cmd = viewModel.buildNewProjectCLIInvocation(project: project)
    return cd + "\n" + cmd
  }

  private func projectTip(for session: SessionSummary) -> String? {
    guard let pid = viewModel.projectIdForSession(session.id),
      let p = viewModel.projects.first(where: { $0.id == pid })
    else { return nil }
    let name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let display = name.isEmpty ? p.id : name
    let raw = (p.overview ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return display }
    let snippet = raw.count > 20 ? String(raw.prefix(20)) + "…" : raw
    return display + "\n" + snippet
  }

  private func prefillForProject(from session: SessionSummary) -> ProjectEditorSheet.Prefill {
    let dir =
      FileManager.default.fileExists(atPath: session.cwd)
      ? session.cwd
      : session.fileURL.deletingLastPathComponent().path
    var name = session.userTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if name.isEmpty { name = URL(fileURLWithPath: dir, isDirectory: true).lastPathComponent }
    // overview: prefer userComment; fallback instruction snippet
    let overview =
      (session.userComment?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
        $0.isEmpty ? nil : $0
      }
      ?? (session.instructions?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
        s in
        if s.isEmpty { return nil }
        // limit to ~220 chars to keep it short
        return s.count <= 220 ? s : String(s.prefix(220)) + "…"
      }
    return ProjectEditorSheet.Prefill(
      name: name,
      directory: dir,
      trustLevel: nil,
      overview: overview,
      profileId: nil
    )
  }

  private func handleClick(on session: SessionSummary) {
    // Determine current modifiers (command/control/shift)
    let mods = NSApp.currentEvent?.modifierFlags ?? []
    let isToggle = mods.contains(.command) || mods.contains(.control)
    let isRange = mods.contains(.shift)
    let id = session.id
    if isRange, let anchor = lastClickedID {
      let flat = sections.flatMap { $0.sessions.map(\.id) }
      if let a = flat.firstIndex(of: anchor), let b = flat.firstIndex(of: id) {
        let lo = min(a, b)
        let hi = max(a, b)
        let rangeIDs = Set(flat[lo...hi])
        selection = rangeIDs
      } else {
        selection = [id]
      }
      onPrimarySelect?(session)
    } else if isToggle {
      if selection.contains(id) {
        selection.remove(id)
      } else {
        selection.insert(id)
      }
      lastClickedID = id
      onPrimarySelect?(session)
    } else {
      selection = [id]
      lastClickedID = id
      onPrimarySelect?(session)
    }
  }

  private func workingDirectory(for session: SessionSummary) -> String {
    viewModel.resolvedWorkingDirectory(for: session)
  }

  private func assetIconForSessionSource(_ source: SessionSource) -> String {
    switch source.baseKind {
    case .codex: return "ChatGPTIcon"
    case .claude: return "ClaudeIcon"
    case .gemini: return "GeminiIcon"
    }
  }

  private func buildResumeMenuItems(for session: SessionSummary) -> [SplitMenuItem] {
    var items: [SplitMenuItem] = []

    if viewModel.preferences.isEmbeddedTerminalEnabled {
      items.append(
        SplitMenuItem(
          id: "resume-embedded-\(session.id)",
          kind: .action(
            title: "CodMate",
            systemImage: "macwindow",
            run: {
              NotificationCenter.default.post(
                name: .codMateResumeSession,
                object: nil,
                userInfo: ["sessionId": session.id, "forceEmbedded": true]
              )
            }
          )
        )
      )
    }

    for profile in externalTerminalOrderedProfiles(includeNone: false) {
      items.append(
        SplitMenuItem(
          id: "resume-\(profile.id)-\(session.id)",
          kind: .action(
            title: profile.displayTitle,
            systemImage: "terminal",
            run: {
              NotificationCenter.default.post(
                name: .codMateResumeSession,
                object: nil,
                userInfo: ["sessionId": session.id, "profileId": profile.id]
              )
            }
          )
        )
      )
    }

    return items
  }

  private func launchNewSession(
    for session: SessionSummary,
    using source: SessionSource,
    profile: ExternalTerminalProfile
  ) {
    let target = source == session.source ? session : session.overridingSource(source)
    viewModel.recordIntentForDetailNew(anchor: target)
    let dir = workingDirectory(for: target)

    if profile.id == "codmate.embedded" {
      EmbeddedSessionNotification.postEmbeddedNewSession(sessionId: target.id, source: source)
      return
    }

    guard viewModel.copyNewSessionCommandsIfEnabled(session: target, destinationApp: profile)
    else { return }
    if profile.usesWarpCommands {
      viewModel.openPreferredTerminalViaScheme(profile: profile, directory: dir)
      if viewModel.shouldCopyCommandsToClipboard
        && viewModel.preferences.commandCopyNotificationsEnabled
      {
        Task {
          await SystemNotifier.shared.notify(
            title: "CodMate", body: "Command copied. Paste it in the opened terminal.")
        }
      }
      return
    }
    if profile.isTerminal {
      if !viewModel.openNewSession(session: target) {
        _ = viewModel.openAppleTerminal(at: dir)
        if viewModel.shouldCopyCommandsToClipboard
          && viewModel.preferences.commandCopyNotificationsEnabled
        {
          Task {
            await SystemNotifier.shared.notify(
              title: "CodMate", body: "Command copied. Paste it in the opened terminal.")
          }
        }
      }
      return
    }
    if profile.isNone {
      if viewModel.shouldCopyCommandsToClipboard
        && viewModel.preferences.commandCopyNotificationsEnabled
      {
        Task {
          await SystemNotifier.shared.notify(
            title: "CodMate", body: "Command copied. Paste it in the opened terminal.")
        }
      }
      return
    }

    let cmd =
      profile.supportsCommandResolved
      ? viewModel.buildNewSessionCLIInvocationRespectingProject(session: target)
      : nil
    if !profile.supportsCommandResolved {
      // Clipboard already populated when copy preference is enabled.
    }
    viewModel.openPreferredTerminalViaScheme(
      profile: profile,
      directory: dir,
      command: cmd
    )
    if !profile.supportsCommandResolved, viewModel.shouldCopyCommandsToClipboard,
      viewModel.preferences.commandCopyNotificationsEnabled
    {
      Task {
        await SystemNotifier.shared.notify(
          title: "CodMate", body: "Command copied. Paste it in the opened terminal.")
      }
    }
  }

  private func copyAbsolutePath(_ session: SessionSummary) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(session.fileURL.path, forType: .string)
  }

  // Build menu items matching Timeline “New” split control for a given session anchor.
  private func buildNewMenuItems(anchor: SessionSummary) -> [SplitMenuItem] {
    let allowed = Set(viewModel.allowedSources(for: anchor))
    let requestedOrder: [ProjectSessionSource] = [.claude, .codex, .gemini]
    let enabledRemoteHosts = viewModel.preferences.enabledRemoteHosts.sorted()

    func sourceKey(_ source: SessionSource) -> String {
      switch source {
      case .codexLocal: return "codex-local"
      case .codexRemote(let host): return "codex-\(host)"
      case .claudeLocal: return "claude-local"
      case .claudeRemote(let host): return "claude-\(host)"
      case .geminiLocal: return "gemini-local"
      case .geminiRemote(let host): return "gemini-\(host)"
      }
    }

    func launchItems(for source: SessionSource) -> [SplitMenuItem] {
      let key = sourceKey(source)
      var items = externalTerminalMenuItems(idPrefix: key) { profile in
        launchNewSession(for: anchor, using: source, profile: profile)
      }
      if viewModel.preferences.isEmbeddedTerminalEnabled {
        let embedded = embeddedTerminalProfile()
        items.insert(
          SplitMenuItem(
            id: "\(key)-\(embedded.id)",
            kind: .action(
              title: embedded.displayTitle,
              systemImage: "macwindow",
              run: {
                launchNewSession(for: anchor, using: source, profile: embedded)
              })
          ), at: 0)
      }
      return items
    }

    func remoteSource(for base: ProjectSessionSource, host: String) -> SessionSource {
      switch base {
      case .codex: return .codexRemote(host: host)
      case .claude: return .claudeRemote(host: host)
      case .gemini: return .geminiRemote(host: host)
      }
    }

    func providerAssetIcon(_ source: ProjectSessionSource) -> String {
      switch source {
      case .codex: return "ChatGPTIcon"
      case .claude: return "ClaudeIcon"
      case .gemini: return "GeminiIcon"
      }
    }

    var menuItems: [SplitMenuItem] = []
    for base in requestedOrder where allowed.contains(base) {
      var providerItems = launchItems(for: base.sessionSource)
      if !enabledRemoteHosts.isEmpty {
        providerItems.append(.init(kind: .separator))
        for host in enabledRemoteHosts {
          let remote = remoteSource(for: base, host: host)
          providerItems.append(
            .init(
              id: "remote-\(base.rawValue)-\(host)",
              kind: .submenu(title: host, systemImage: "network", items: launchItems(for: remote))
            ))
        }
      }
      menuItems.append(
        .init(
          id: "provider-\(base.rawValue)",
          kind: .submenu(title: base.displayName, assetImage: providerAssetIcon(base), items: providerItems)
        ))
    }

    if menuItems.isEmpty {
      let fallbackSource = anchor.source
      menuItems.append(
        .init(
          id: "fallback-\(sourceKey(fallbackSource))",
          kind: .submenu(
            title: fallbackSource.branding.displayName,
            systemImage: "terminal",
            items: launchItems(for: fallbackSource)
          )))
    }
    return menuItems
  }

  private func newSessionMenu(for project: Project, anchor: SessionSummary?) -> some View {
    Menu {
      if let anchor {
        SplitMenuItemsView(items: buildNewMenuItems(anchor: anchor))
      } else {
        Button("No recent session to anchor", action: {})
          .disabled(true)
      }
    } label: {
      Label("New Session…", systemImage: "plus")
    }
  }
}

// SplitPrimaryMenuButton and helpers are shared in SplitControls.swift

// Native NSSearchField wrapper to get unified macOS search field chrome
private struct SearchField: NSViewRepresentable {
  let placeholder: String
  @Binding var text: String
  var onSubmit: ((String) -> Void)? = nil

  init(_ placeholder: String, text: Binding<String>, onSubmit: ((String) -> Void)? = nil) {
    self.placeholder = placeholder
    self._text = text
    self.onSubmit = onSubmit
  }

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSSearchField {
    let field = NSSearchField(frame: .zero)
    field.placeholderString = placeholder
    field.delegate = context.coordinator
    field.focusRingType = .none
    // Avoid premature submit during IME composition; we handle Return/Escape in delegate instead
    field.sendsSearchStringImmediately = false
    field.sendsWholeSearchString = true
    // Do not steal initial focus; if the system puts focus here, drop it back to window
    DispatchQueue.main.async {
      if let win = field.window,
        win.firstResponder === field || win.firstResponder === field.currentEditor()
      {
        win.makeFirstResponder(nil)
      }
    }
    context.coordinator.configure(field: field)
    return field
  }

  func updateNSView(_ nsView: NSSearchField, context: Context) {
    // Avoid programmatic writes while user is editing (prevents breaking IME composition)
    if let editor = nsView.currentEditor(), nsView.window?.firstResponder === editor { return }
    if nsView.stringValue != text { nsView.stringValue = text }
    if nsView.placeholderString != placeholder { nsView.placeholderString = placeholder }
  }

  class Coordinator: NSObject, NSSearchFieldDelegate {
    var parent: SearchField
    weak var field: NSSearchField?
    private var observers: [NSObjectProtocol] = []
    private var isFocusBlocked = false
    init(_ parent: SearchField) { self.parent = parent }

    deinit {
      for observer in observers {
        NotificationCenter.default.removeObserver(observer)
      }
    }

    func configure(field: NSSearchField) {
      self.field = field
      field.refusesFirstResponder = isFocusBlocked
      if observers.isEmpty {
        let center = NotificationCenter.default
        let resign = center.addObserver(
          forName: .codMateResignQuickSearch,
          object: nil,
          queue: .main
        ) { [weak self] _ in self?.resignIfNeeded() }
        let block = center.addObserver(
          forName: .codMateQuickSearchFocusBlocked,
          object: nil,
          queue: .main
        ) { [weak self] note in
          Task { @MainActor in self?.handleFocusBlocked(note: note) }
        }
        observers.append(contentsOf: [resign, block])
      }
    }

    private func resignIfNeeded() {
      guard let field, let window = field.window else { return }
      if window.firstResponder === field || window.firstResponder === field.currentEditor() {
        window.makeFirstResponder(nil)
      }
    }

    @MainActor
    private func handleFocusBlocked(note: Notification) {
      let active = (note.userInfo?["active"] as? Bool) ?? false
      isFocusBlocked = active
      field?.refusesFirstResponder = active
      if active { resignIfNeeded() }
    }

    @MainActor
    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSSearchField else { return }
      // Skip updates while IME is composing (marked text present)
      if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
      parent.text = field.stringValue
    }

    @MainActor
    func searchFieldDidEndSearching(_ sender: NSSearchField) {
      let value = sender.stringValue
      parent.text = value
      parent.onSubmit?(value)
    }

    // Intercept Return/Escape; respect IME composition
    @MainActor
    func control(
      _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
      // If composing with IME, let the editor handle the key (do not submit)
      if textView.hasMarkedText() { return false }
      if commandSelector == #selector(NSResponder.insertNewline(_:)) {
        let value = textView.string
        parent.text = value
        parent.onSubmit?(value)
        return true
      }
      if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
        parent.text = ""
        parent.onSubmit?("")
        return true
      }
      return false
    }
  }
}

// MARK: - Equal-width segmented control backed by NSSegmentedControl
private struct EqualWidthSegmentedControl<Item: Identifiable & Hashable>: NSViewRepresentable {
  let items: [Item]
  @Binding var selection: Item
  var title: (Item) -> String

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSView {
    let container = NSView()
    container.translatesAutoresizingMaskIntoConstraints = false
    let control = NSSegmentedControl()
    control.translatesAutoresizingMaskIntoConstraints = false
    control.segmentStyle = .rounded
    control.trackingMode = .selectOne
    control.target = context.coordinator
    control.action = #selector(Coordinator.changed(_:))
    rebuildSegments(control)
    if #available(macOS 13.0, *) { control.segmentDistribution = .fillEqually }

    control.setContentHuggingPriority(.defaultLow, for: .horizontal)
    control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    container.addSubview(control)
    NSLayoutConstraint.activate([
      control.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      control.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      control.topAnchor.constraint(equalTo: container.topAnchor),
      control.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    context.coordinator.control = control
    return container
  }

  func updateNSView(_ container: NSView, context: Context) {
    guard let control = context.coordinator.control else { return }
    if control.segmentCount != items.count { rebuildSegments(control) }
    // Update labels if needed
    for (i, it) in items.enumerated() { control.setLabel(title(it), forSegment: i) }
    // Selection
    if let idx = items.firstIndex(of: selection) {
      control.selectedSegment = idx
    } else {
      control.selectedSegment = -1
    }

    // Ensure segments expand after the middle column resizes from 0 → normal.
    let containerWidth = container.bounds.width
    if context.coordinator.lastContainerWidth != containerWidth {
      context.coordinator.lastContainerWidth = containerWidth
      if #available(macOS 13.0, *) {
        control.segmentDistribution = .fillEqually
      }
      // Force a fresh layout pass now and in next runloop to avoid "scrunched" state.
      control.invalidateIntrinsicContentSize()
      control.needsLayout = true
      control.layoutSubtreeIfNeeded()
      DispatchQueue.main.async {
        control.invalidateIntrinsicContentSize()
        control.needsLayout = true
        control.layoutSubtreeIfNeeded()
      }
    }

    if #available(macOS 13.0, *) {
      // Nothing else; fillEqually handles widths.
    } else {
      // Fallback: try to equalize manually each update
      let superWidth = control.superview?.bounds.width ?? containerWidth
      if superWidth > 0 {
        let width = max(60.0, superWidth / CGFloat(max(1, items.count)))
        for i in 0..<control.segmentCount { control.setWidth(width, forSegment: i) }
      }
    }
  }

  private func rebuildSegments(_ control: NSSegmentedControl) {
    control.segmentCount = items.count
    for (i, it) in items.enumerated() {
      control.setLabel(title(it), forSegment: i)
    }
  }

  final class Coordinator: NSObject {
    weak var control: NSSegmentedControl?
    var parent: EqualWidthSegmentedControl
    var lastContainerWidth: CGFloat = -1
    init(_ parent: EqualWidthSegmentedControl) { self.parent = parent }
    @objc func changed(_ sender: NSSegmentedControl) {
      let idx = sender.selectedSegment
      guard idx >= 0 && idx < parent.items.count else { return }
      parent.selection = parent.items[idx]
    }
  }
}

extension TimeInterval {
  fileprivate var readableFormattedDuration: String {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = durationUnits
    formatter.unitsStyle = .abbreviated
    return formatter.string(from: self) ?? "—"
  }

  private var durationUnits: NSCalendar.Unit {
    if self >= 3600 {
      return [.hour, .minute]
    } else if self >= 60 {
      return [.minute, .second]
    }
    return [.second]
  }
}

#Preview {
  // Mock SessionDaySection data
  let mockSections = [
    SessionDaySection(
      id: Date().addingTimeInterval(-86400),  // Yesterday
      title: "Yesterday",
      totalDuration: 7200,  // 2 hours
      totalEvents: 15,
      sessions: [
        SessionSummary(
          id: "session-1",
          fileURL: URL(
            fileURLWithPath: "/Users/developer/.codex/sessions/session-1.json"),
          fileSizeBytes: 12340,
          startedAt: Date().addingTimeInterval(-7200),
          endedAt: Date().addingTimeInterval(-3600),
          activeDuration: nil,
          cliVersion: "1.2.3",
          cwd: "/Users/developer/projects/codmate",
          originator: "developer",
          instructions: "Optimize SwiftUI list performance",
          model: "gpt-4o-mini",
          approvalPolicy: "auto",
          userMessageCount: 3,
          assistantMessageCount: 2,
          toolInvocationCount: 1,
          responseCounts: [:],
          turnContextCount: 5,
          totalTokens: 740,
          eventCount: 6,
          lineCount: 89,
          lastUpdatedAt: Date().addingTimeInterval(-3600),
          source: .codexLocal,
          remotePath: nil
        ),
        SessionSummary(
          id: "session-2",
          fileURL: URL(
            fileURLWithPath: "/Users/developer/.codex/sessions/session-2.json"),
          fileSizeBytes: 8900,
          startedAt: Date().addingTimeInterval(-10800),
          endedAt: Date().addingTimeInterval(-9000),
          activeDuration: nil,
          cliVersion: "1.2.3",
          cwd: "/Users/developer/projects/test",
          originator: "developer",
          instructions: "Create a to-do app",
          model: "gpt-4o",
          approvalPolicy: "manual",
          userMessageCount: 4,
          assistantMessageCount: 3,
          toolInvocationCount: 2,
          responseCounts: ["reasoning": 1],
          turnContextCount: 7,
          totalTokens: 1120,
          eventCount: 9,
          lineCount: 120,
          lastUpdatedAt: Date().addingTimeInterval(-9000),
          source: .codexLocal,
          remotePath: nil
        ),
      ]
    ),
    SessionDaySection(
      id: Date().addingTimeInterval(-172800),  // Day before yesterday
      title: "Dec 15, 2024",
      totalDuration: 5400,  // 1.5 hours
      totalEvents: 12,
      sessions: [
        SessionSummary(
          id: "session-3",
          fileURL: URL(
            fileURLWithPath: "/Users/developer/.codex/sessions/session-3.json"),
          fileSizeBytes: 15600,
          startedAt: Date().addingTimeInterval(-172800),
          endedAt: Date().addingTimeInterval(-158400),
          activeDuration: nil,
          cliVersion: "1.2.2",
          cwd: "/Users/developer/documents",
          originator: "developer",
          instructions: "Write technical documentation",
          model: "gpt-4o-mini",
          approvalPolicy: "auto",
          userMessageCount: 6,
          assistantMessageCount: 5,
          toolInvocationCount: 3,
          responseCounts: ["reasoning": 2],
          turnContextCount: 11,
          totalTokens: 2100,
          eventCount: 14,
          lineCount: 200,
          lastUpdatedAt: Date().addingTimeInterval(-158400),
          source: .codexLocal,
          remotePath: nil
        )
      ]
    ),
  ]

  SessionListColumnView(
    sections: mockSections,
    selection: .constant(Set<String>()),
    sortOrder: .constant(.mostRecent),
    isLoading: false,
    isEnriching: false,
    enrichmentProgress: 0,
    enrichmentTotal: 0,
    onResume: { session in print("Resume: \(session.displayName)") },
    onReveal: { session in print("Reveal: \(session.displayName)") },
    onDeleteRequest: { session in print("Delete: \(session.displayName)") },
    onExportMarkdown: { session in print("Export: \(session.displayName)") }
  )
  .frame(width: 500, height: 600)
}

#Preview("Loading State") {
  SessionListColumnView(
    sections: [],
    selection: .constant(Set<String>()),
    sortOrder: .constant(.mostRecent),
    isLoading: true,
    isEnriching: false,
    enrichmentProgress: 0,
    enrichmentTotal: 0,
    onResume: { _ in },
    onReveal: { _ in },
    onDeleteRequest: { _ in },
    onExportMarkdown: { _ in }
  )
  .frame(width: 500, height: 600)
}

#Preview("Empty State") {
  SessionListColumnView(
    sections: [],
    selection: .constant(Set<String>()),
    sortOrder: .constant(.mostRecent),
    isLoading: false,
    isEnriching: false,
    enrichmentProgress: 0,
    enrichmentTotal: 0,
    onResume: { _ in },
    onReveal: { _ in },
    onDeleteRequest: { _ in },
    onExportMarkdown: { _ in }
  )
  .frame(width: 500, height: 600)
}

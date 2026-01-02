import SwiftUI

#if os(macOS)
  import AppKit
#endif

/// TaskListView: Displays tasks and sessions in Tasks mode, maintaining the original session list appearance
struct TaskListView: View {
  @EnvironmentObject private var viewModel: SessionListViewModel
  @ObservedObject var workspaceVM: ProjectWorkspaceViewModel
  @Binding var selection: Set<SessionSummary.ID>

  let onResume: (SessionSummary) -> Void
  let onReveal: (SessionSummary) -> Void
  let onDeleteRequest: (SessionSummary) -> Void
  let onExportMarkdown: (SessionSummary) -> Void
  var isRunning: ((SessionSummary) -> Bool)? = nil
  var isUpdating: ((SessionSummary) -> Bool)? = nil
  var isAwaitingFollowup: ((SessionSummary) -> Bool)? = nil
  var onPrimarySelect: ((SessionSummary) -> Void)? = nil
  var onNewSessionWithTaskContext: ((CodMateTask, SessionSummary?, SessionSource, ExternalTerminalProfile) -> Void)? = nil
  @State private var editingTask: CodMateTask? = nil
  @Environment(\.colorScheme) private var colorScheme
  @State private var draggedSession: SessionSummary? = nil
  @State private var taskToDelete: CodMateTask? = nil
  @State private var showDeleteConfirmation = false
  @State private var lastClickedID: SessionSummary.ID? = nil
  @State private var pendingMove: PendingSessionMove? = nil
  @State private var editingMode: EditTaskSheet.Mode = .edit
  @State private var collapsedTaskIDs: Set<UUID> = []
  @State private var sessionAssigningTask: SessionSummary? = nil

  private var currentProjectId: String? {
    viewModel.selectedProjectIDs.first
  }

  private struct PendingSessionMove: Identifiable {
    let id = UUID()
    let session: SessionSummary
    let fromTask: CodMateTask
    let toTask: CodMateTask
  }

  var body: some View {
    VStack(spacing: 0) {
      let enrichedTasks = workspaceVM.enrichTasksWithSessions()
      let assignedSessionIds = Set(enrichedTasks.flatMap { $0.task.sessionIds })

      // Use the same sections from viewModel, but render tasks inline
      List(selection: $selection) {
        ForEach(viewModel.sections) { section in
          Section {
            ForEach(
              enrichedSessionsForSection(
                section,
                enrichedTasks: enrichedTasks,
                assignedSessionIds: assignedSessionIds),
              id: \.id
            ) { item in
              switch item {
              case .taskHeader(let taskWithSessions):
                taskRow(taskWithSessions)
              case .taskSession(let taskWithSessions, let session):
                sessionRow(session, parentTask: taskWithSessions.task)
              case .session(let session):
                sessionRow(session)
              }
            }
          } header: {
            sectionHeader(for: section)
          }
        }
      }
      .padding(.horizontal, -2)
      .listStyle(.inset)
      .contextMenu { taskListBackgroundContextMenu() }
    }
    .sheet(item: $editingTask) { task in
      EditTaskSheet(
        task: task,
        mode: editingMode,
        workspaceVM: workspaceVM,
        onSave: { updatedTask in
          Task {
            await workspaceVM.updateTask(updatedTask)
            editingTask = nil
          }
        },
        onCancel: {
          editingTask = nil
        }
      )
    }
    .sheet(item: $sessionAssigningTask) { session in
      if let projectId = currentProjectId {
        TaskSelectionSheet(
          tasks: workspaceVM.tasks.filter { $0.projectId == projectId },
          onSelect: { task in
            Task {
              var updatedTask = task
              if !updatedTask.sessionIds.contains(session.id) {
                updatedTask.sessionIds.append(session.id)
                await workspaceVM.updateTask(updatedTask)
              }
              sessionAssigningTask = nil
            }
          },
          onCreate: { title in
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            Task {
              await workspaceVM.createTask(
                title: trimmed,
                description: nil,
                projectId: projectId
              )
              if let newTask = workspaceVM.tasks.first(
                where: {
                  $0.projectId == projectId
                    && $0.effectiveTitle.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
                }
              ) {
                var updatedTask = newTask
                if !updatedTask.sessionIds.contains(session.id) {
                  updatedTask.sessionIds.append(session.id)
                  await workspaceVM.updateTask(updatedTask)
                }
              }
              sessionAssigningTask = nil
            }
          },
          onCancel: {
            sessionAssigningTask = nil
          }
        )
      }
    }
    .task(id: currentProjectId) {
      if let projectId = currentProjectId {
        await workspaceVM.loadTasks(for: projectId)
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .codMateCollapseAllTasks)) { note in
      guard shouldHandleTaskNotification(note) else { return }
      collapsedTaskIDs = taskIDsForCurrentProject()
    }
    .onReceive(NotificationCenter.default.publisher(for: .codMateExpandAllTasks)) { note in
      guard shouldHandleTaskNotification(note) else { return }
      collapsedTaskIDs.removeAll()
    }
    .confirmationDialog(
      "Delete Task",
      isPresented: $showDeleteConfirmation,
      presenting: taskToDelete
    ) { task in
      Button("Delete", role: .destructive) {
        Task {
          if let projectId = currentProjectId {
            await workspaceVM.deleteTask(task.id, projectId: projectId)
          }
          taskToDelete = nil
        }
      }
      Button("Cancel", role: .cancel) {
        taskToDelete = nil
      }
    } message: { task in
      Text(
        "Delete \"\(task.effectiveTitle)\"? This will not delete the associated sessions, only remove the task container."
      )
    }
    .confirmationDialog(
      "Move Session to Another Task?",
      isPresented: Binding(
        get: { pendingMove != nil },
        set: { if !$0 { pendingMove = nil } }
      ),
      presenting: pendingMove
    ) { move in
      Button("Move") {
        guard let projectId = currentProjectId else {
          pendingMove = nil
          return
        }
        Task {
          // Move session by updating target task; ProjectWorkspaceViewModel
          // will enforce 0/1 membership across tasks.
          var updatedTarget = move.toTask
          if !updatedTarget.sessionIds.contains(move.session.id) {
            updatedTarget.sessionIds.append(move.session.id)
            await workspaceVM.updateTask(updatedTarget)
          }
          pendingMove = nil
          // Reload tasks for current project to reflect latest state
          await workspaceVM.loadTasks(for: projectId)
        }
      }
      Button("Cancel", role: .cancel) {
        pendingMove = nil
      }
    } message: { move in
      Text(
        "Move \"\(move.session.effectiveTitle)\" from \"\(move.fromTask.effectiveTitle)\" to \"\(move.toTask.effectiveTitle)\"?"
      )
    }
  }

  // MARK: - Data Enrichment

  enum SessionOrTask: Identifiable {
    case taskHeader(TaskWithSessions)
    case taskSession(TaskWithSessions, SessionSummary)
    case session(SessionSummary)

    var id: String {
      switch self {
      case .taskHeader(let t): return "task-header-\(t.id.uuidString)"
      case .taskSession(let t, let s): return "task-session-\(t.id.uuidString)-\(s.id)"
      case .session(let s): return "session-\(s.id)"
      }
    }
  }

  private func enrichedSessionsForSection(
    _ section: SessionDaySection,
    enrichedTasks: [TaskWithSessions],
    assignedSessionIds: Set<String>
  ) -> [SessionOrTask] {
    guard !enrichedTasks.isEmpty else {
      return section.sessions.map { .session($0) }
    }

    let sectionSessionIDs = Set(section.sessions.map(\.id))
    let calendar = Calendar.current

    // Build per-task sessions limited to this section, and also include
    // tasks that currently have no sessions but were updated on this day.
    var taskSectionSessions: [UUID: [SessionSummary]] = [:]
    var tasksInSection: [TaskWithSessions] = []
    for task in enrichedTasks {
      let inSection = task.sessions.filter { sectionSessionIDs.contains($0.id) }
      if !inSection.isEmpty {
        tasksInSection.append(task)
        taskSectionSessions[task.task.id] = inSection
      } else if task.sessions.isEmpty,
        calendar.isDate(task.task.updatedAt, inSameDayAs: section.id)
      {
        // New or empty tasks should still appear in the Tasks view
        // on the day they were last updated, even before any sessions
        // are assigned to them.
        tasksInSection.append(task)
        taskSectionSessions[task.task.id] = []
      }
    }
    guard !tasksInSection.isEmpty else {
      // No tasks relevant for this section; fall back to standalone sessions only.
      return section.sessions.map { .session($0) }
    }

    // Sort tasks according to current sort order, using aggregated metrics
    let sortedTasks: [TaskWithSessions] = {
      switch viewModel.sortOrder {
      case .mostRecent:
        // Use the latest timestamp among this section's sessions, respecting date dimension
        let dim = viewModel.dateDimension
        return tasksInSection.sorted { lhs, rhs in
          let ls = taskSectionSessions[lhs.task.id] ?? []
          let rs = taskSectionSessions[rhs.task.id] ?? []
          func key(_ s: SessionSummary) -> Date {
            switch dim {
            case .created: return s.startedAt
            case .updated: return s.lastUpdatedAt ?? s.startedAt
            }
          }
          let lDate = ls.map(key).max() ?? .distantPast
          let rDate = rs.map(key).max() ?? .distantPast
          return lDate > rDate
        }

      case .longestDuration:
        // Aggregate total duration for this section's sessions
        return tasksInSection.sorted { lhs, rhs in
          let lDur = (taskSectionSessions[lhs.task.id] ?? []).reduce(0) { $0 + $1.duration }
          let rDur = (taskSectionSessions[rhs.task.id] ?? []).reduce(0) { $0 + $1.duration }
          if lDur != rDur { return lDur > rDur }
          // Tie-breaker: most recent activity
          let lDate =
            (taskSectionSessions[lhs.task.id] ?? []).map { $0.lastUpdatedAt ?? $0.startedAt }.max()
            ?? .distantPast
          let rDate =
            (taskSectionSessions[rhs.task.id] ?? []).map { $0.lastUpdatedAt ?? $0.startedAt }.max()
            ?? .distantPast
          return lDate > rDate
        }

      case .mostActivity:
        // Aggregate total event count
        return tasksInSection.sorted { lhs, rhs in
          let lEvents = (taskSectionSessions[lhs.task.id] ?? []).reduce(0) { $0 + $1.eventCount }
          let rEvents = (taskSectionSessions[rhs.task.id] ?? []).reduce(0) { $0 + $1.eventCount }
          if lEvents != rEvents { return lEvents > rEvents }
          let lDate =
            (taskSectionSessions[lhs.task.id] ?? []).map { $0.lastUpdatedAt ?? $0.startedAt }.max()
            ?? .distantPast
          let rDate =
            (taskSectionSessions[rhs.task.id] ?? []).map { $0.lastUpdatedAt ?? $0.startedAt }.max()
            ?? .distantPast
          if lDate != rDate { return lDate > rDate }
          return lhs.task.effectiveTitle.localizedCaseInsensitiveCompare(rhs.task.effectiveTitle)
            == .orderedAscending
        }

      case .alphabetical:
        return tasksInSection.sorted { lhs, rhs in
          let cmp = lhs.task.effectiveTitle.localizedStandardCompare(rhs.task.effectiveTitle)
          if cmp == .orderedSame {
            let lDate =
              (taskSectionSessions[lhs.task.id] ?? []).map { $0.lastUpdatedAt ?? $0.startedAt }
              .max() ?? .distantPast
            let rDate =
              (taskSectionSessions[rhs.task.id] ?? []).map { $0.lastUpdatedAt ?? $0.startedAt }
              .max() ?? .distantPast
            if lDate != rDate { return lDate > rDate }
            return lhs.task.id.uuidString < rhs.task.id.uuidString
          }
          return cmp == .orderedAscending
        }

      case .largestSize:
        // Approximate size by total file size across this section's sessions
        return tasksInSection.sorted { lhs, rhs in
          func totalSize(for task: TaskWithSessions) -> UInt64 {
            (taskSectionSessions[task.task.id] ?? []).reduce(0) { acc, s in
              acc + (s.fileSizeBytes ?? 0)
            }
          }
          let lSize = totalSize(for: lhs)
          let rSize = totalSize(for: rhs)
          if lSize != rSize { return lSize > rSize }
          let lDate =
            (taskSectionSessions[lhs.task.id] ?? []).map { $0.lastUpdatedAt ?? $0.startedAt }.max()
            ?? .distantPast
          let rDate =
            (taskSectionSessions[rhs.task.id] ?? []).map { $0.lastUpdatedAt ?? $0.startedAt }.max()
            ?? .distantPast
          return lDate > rDate
        }
      }
    }()

    var result: [SessionOrTask] = []

    // For each task (in sorted order), add a header row and then its sessions that belong to this section
    for task in sortedTasks {
      result.append(.taskHeader(task))
      if !collapsedTaskIDs.contains(task.task.id),
        let sectionSessions = taskSectionSessions[task.task.id]
      {
        for session in sectionSessions {
          result.append(.taskSession(task, session))
        }
      }
    }

    // Add standalone sessions (not assigned to any task), preserving existing section order
    for session in section.sessions where !assignedSessionIds.contains(session.id) {
      result.append(.session(session))
    }

    return result
  }

  // MARK: - Section Header

  @ViewBuilder
  private func sectionHeader(for section: SessionDaySection) -> some View {
    HStack {
      Text(section.title)
      Spacer()
      Label(readableFormattedDuration(section.totalDuration), systemImage: "clock")
      Label("\(section.totalEvents)", systemImage: "chart.bar")
    }
    .font(.subheadline)
    .foregroundStyle(.secondary)
  }

  // MARK: - Task Row

  @ViewBuilder
  private func taskRow(_ taskWithSessions: TaskWithSessions) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      // Task header - using same visual style as SessionListRowView
      HStack(alignment: .top, spacing: 12) {
        // Left icon — purely visual
        let container = RoundedRectangle(cornerRadius: 9, style: .continuous)
        ZStack {
          container
            .fill(Color.white)
            .shadow(color: Color.black.opacity(0.08), radius: 1.5, x: 0, y: 1)
          container
            .stroke(Color.black.opacity(0.06), lineWidth: 1)

          Image(systemName: "checklist")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.accentColor)
        }
        .frame(width: 32, height: 32)
        .help("Task")

        // Content area
        VStack(alignment: .leading, spacing: 4) {
          // Title only - status and collapse indicator removed
          Text(taskWithSessions.task.effectiveTitle)
            .font(.headline)
            .lineLimit(1)
            .truncationMode(.tail)

          // Metadata row
          HStack(spacing: 8) {
            Text(taskWithSessions.task.updatedAt.formatted(date: .numeric, time: .shortened))
              .layoutPriority(1)
            Text(formatDuration(taskWithSessions.totalDuration))
              .layoutPriority(1)
          }
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)

          // Description if available
          if let description = taskWithSessions.task.effectiveDescription {
            Text(description)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }

          // Metrics
          HStack(spacing: 8) {
            metric(icon: "doc.text", value: taskWithSessions.sessions.count)
            metric(icon: "clock", value: Int(taskWithSessions.totalDuration / 60))
            if taskWithSessions.totalTokens > 0 {
              metric(icon: "circle.grid.cross", value: taskWithSessions.totalTokens)
            }
          }
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 32)

        Spacer(minLength: 0)
      }
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      .padding(.vertical, 8)
      .overlay(alignment: .topTrailing) {
        // Top-right collapse/expand button
        Button {
          if collapsedTaskIDs.contains(taskWithSessions.task.id) {
            collapsedTaskIDs.remove(taskWithSessions.task.id)
          } else {
            collapsedTaskIDs.insert(taskWithSessions.task.id)
          }
        } label: {
          Image(systemName: collapsedTaskIDs.contains(taskWithSessions.task.id) ? "chevron.down" : "chevron.up")
            .foregroundStyle(Color.secondary)
            .font(.system(size: 14, weight: .semibold))
        }
        .buttonStyle(.borderless)
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.top, 8)
      }
      .onDrop(
        of: [.text],
        delegate: TaskDropDelegate(
          task: taskWithSessions.task,
          draggedSession: $draggedSession,
          workspaceVM: workspaceVM,
          onRequestMove: handleMoveRequest
        )
      )
      .contentShape(Rectangle())
      .onTapGesture(count: 2) {
        editingMode = .edit
        editingTask = taskWithSessions.task
      }
      .contextMenu {
        if let project = projectForTask(taskWithSessions.task) {
          let anchor = latestLocalSession(for: taskWithSessions)
          let items = buildNewMenuItems(anchor: anchor, project: project) { anchor, source, profile in
            if let handler = onNewSessionWithTaskContext {
              handler(taskWithSessions.task, anchor, source, profile)
            }
          }
          if items.isEmpty {
            Button {
              if let handler = onNewSessionWithTaskContext, let anchor {
                // Fallback to default behavior if menu generation failed but anchor exists
                // We'll use the anchor's source and default profile
                let defaultProfile = ExternalTerminalProfileStore.shared.resolvePreferredProfile(
                  id: viewModel.preferences.defaultResumeExternalAppId
                ) ?? ExternalTerminalProfileStore.shared.availableProfiles().first!
                handler(taskWithSessions.task, anchor, anchor.source, defaultProfile)
              } else {
                viewModel.newSession(project: project)
              }
            } label: {
              Label("Collaborate with", systemImage: "person.2")
            }
          } else {
            Menu { SplitMenuItemsView(items: items) } label: { Label("Collaborate with…", systemImage: "person.2") }
          }
          Button {
            let draft = CodMateTask(
              title: "",
              description: nil,
              projectId: project.id
            )
            editingMode = .new
            editingTask = draft
          } label: {
            Label("New Task…", systemImage: "checklist")
          }
        }
        Button {
          editingMode = .edit
          editingTask = taskWithSessions.task
        } label: {
          Label("Edit Task", systemImage: "pencil")
        }
        Button(role: .destructive) {
          taskToDelete = taskWithSessions.task
          showDeleteConfirmation = true
        } label: {
          Label("Delete Task", systemImage: "trash")
        }
        taskCollapseContextMenuItems()
      }

    }
  }

  // MARK: - Session Row

  @ViewBuilder
  private func sessionRow(_ session: SessionSummary, parentTask: CodMateTask? = nil) -> some View {
    EquatableSessionListRow(
      summary: session,
      isRunning: isRunning?(session) ?? false,
      isSelected: selection.contains(session.id),
      isUpdating: isUpdating?(session) ?? false,
      awaitingFollowup: isAwaitingFollowup?(session) ?? false,
      inProject: viewModel.projectIdForSession(session.id) != nil,
      projectTip: projectTip(for: session),
      inTaskContainer: parentTask != nil
    )
    .tag(session.id)
    .contentShape(Rectangle())
    .padding(.leading, parentTask != nil ? 44 : 0)
    .onTapGesture(count: 2) {
      selection = [session.id]
      onPrimarySelect?(session)
      Task {
        await viewModel.beginEditing(session: session)
      }
    }
    .onTapGesture {
      handleClick(on: session)
    }
    .contextMenu {
      let resumeItems = buildResumeMenuItems(for: session)
      if !resumeItems.isEmpty {
        Menu { SplitMenuItemsView(items: resumeItems) } label: {
          let icon = assetIconForSessionSource(session.source)
          Label {
            Text("Resume session")
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
      if let project = projectForSession(session, parentTask: parentTask) {
        let items = buildNewMenuItems(anchor: session)
        if items.isEmpty {
          Button { viewModel.newSession(project: project) } label: { Label("New Session", systemImage: "plus") }
        } else {
          Menu { SplitMenuItemsView(items: items) } label: { Label("New Session…", systemImage: "plus") }
        }
        Divider()
        Button {
          let draft = CodMateTask(
            title: "",
            description: nil,
            projectId: project.id
          )
          editingMode = .new
          editingTask = draft
        } label: {
          Label("New Task…", systemImage: "checklist")
        }
        if parentTask == nil {
          Button { sessionAssigningTask = session } label: { Label("Add to Task…", systemImage: "plus.circle") }
        }
      }
      if parentTask != nil {
        Button {
          Task {
            guard let task = parentTask else { return }
            var updatedTask = task
            updatedTask.sessionIds.removeAll { $0 == session.id }
            await viewModel.workspaceVM?.updateTask(updatedTask)
          }
        } label: {
          Label("Remove from Task", systemImage: "minus.circle")
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
      Divider()
      Button { copyAbsolutePath(session) } label: { Label("Copy Absolute Path", systemImage: "doc.on.doc") }
      Button { onExportMarkdown(session) } label: { Label("Export as Markdown", systemImage: "square.and.arrow.up") }
      Divider()
      Button { onReveal(session) } label: { Label("Reveal in Finder", systemImage: "finder") }
      Button(role: .destructive) { onDeleteRequest(session) } label: { Label("Move to Trash", systemImage: "trash") }
      taskCollapseContextMenuItems()
    }
    .onDrag {
      self.draggedSession = session
      return NSItemProvider(object: session.id as NSString)
    }
    .onDrop(
      of: [.text],
      delegate: SessionDropDelegate(
        session: session,
        draggedSession: $draggedSession,
        workspaceVM: workspaceVM,
        currentProjectId: currentProjectId
      )
    )
    .listRowInsets(EdgeInsets())
  }

  // MARK: - Helpers

  @ViewBuilder
  private func metric(icon: String, value: Int) -> some View {
    HStack(spacing: 2) {
      Image(systemName: icon)
      Text("\(value)")
    }
  }

  private func statusColor(_ status: TaskStatus) -> Color {
    switch status {
    case .pending: return .gray
    case .inProgress: return .blue
    case .completed: return .green
    case .archived: return .orange
    }
  }

  private func formatDuration(_ duration: TimeInterval) -> String {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = [.hour, .minute]
    formatter.unitsStyle = .abbreviated
    return formatter.string(from: duration) ?? "—"
  }

  private func readableFormattedDuration(_ interval: TimeInterval) -> String {
    let formatter = DateComponentsFormatter()
    formatter.unitsStyle = .abbreviated
    if interval >= 3600 {
      formatter.allowedUnits = [.hour, .minute]
    } else if interval >= 60 {
      formatter.allowedUnits = [.minute, .second]
    } else {
      formatter.allowedUnits = [.second]
    }
    return formatter.string(from: interval) ?? "—"
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

  private func handleClick(on session: SessionSummary) {
    #if os(macOS)
      let mods = NSApp.currentEvent?.modifierFlags ?? []
      let isToggle = mods.contains(.command) || mods.contains(.control)
      let isRange = mods.contains(.shift)
    #else
      let isToggle = false
      let isRange = false
    #endif
    let id = session.id
    if isRange, let anchor = lastClickedID {
      let flat = viewModel.sections.flatMap { $0.sessions.map(\.id) }
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

  private func handleMoveRequest(
    session: SessionSummary, fromTask: CodMateTask, toTask: CodMateTask
  ) {
    pendingMove = PendingSessionMove(session: session, fromTask: fromTask, toTask: toTask)
  }

  private func projectForSession(_ session: SessionSummary, parentTask: CodMateTask?) -> Project? {
    if let parentTask {
      return projectForTask(parentTask)
    }
    guard let pid = viewModel.projectIdForSession(session.id) else { return nil }
    if pid == SessionListViewModel.otherProjectId { return nil }
    return viewModel.projects.first(where: { $0.id == pid })
  }

  private func projectForTask(_ task: CodMateTask) -> Project? {
    let pid = task.projectId
    if pid == SessionListViewModel.otherProjectId { return nil }
    return viewModel.projects.first(where: { $0.id == pid })
  }

  // MARK: - Task Context Helpers

  /// Returns the most recent local (non-remote) session for a given task, if any.
  private func latestLocalSession(for taskWithSessions: TaskWithSessions) -> SessionSummary? {
    let candidates = taskWithSessions.sessions.filter { !$0.isRemote }
    return candidates.max(by: { (lhs, rhs) in
      let lDate = lhs.lastUpdatedAt ?? lhs.startedAt
      let rDate = rhs.lastUpdatedAt ?? rhs.startedAt
      return lDate < rDate
    })
  }

  @ViewBuilder
  private func projectContextMenu(for project: Project) -> some View {
    let items = buildNewMenuItems(anchor: latestAnchor(for: project))
    Menu("New Session…") {
      if items.isEmpty {
        Button("No recent session to anchor", action: {}).disabled(true)
      } else {
        SplitMenuItemsView(items: items)
      }
    }
  }

  @ViewBuilder
  private func taskListBackgroundContextMenu() -> some View {
    if let projectId = currentProjectId,
      let project = viewModel.projects.first(where: { $0.id == projectId })
    {
      let items = buildNewMenuItems(anchor: latestAnchor(for: project))
      Menu {
        if items.isEmpty {
          Button("No recent session to anchor", action: {}).disabled(true)
        } else {
          SplitMenuItemsView(items: items)
        }
      } label: {
        Label("New Session…", systemImage: "plus")
      }
      Button {
        editingMode = .new
        editingTask = CodMateTask(title: "", description: nil, projectId: currentProjectId ?? "")
      } label: {
        Label("New Task…", systemImage: "checklist")
      }
    }
    Divider()
    Button {
      NotificationCenter.default.post(
        name: .codMateCollapseAllTasks, object: nil,
        userInfo: ["projectId": currentProjectId as Any])
    } label: {
      Label("Collapse all Tasks", systemImage: "arrow.down.right.and.arrow.up.left")
    }
    Button {
      NotificationCenter.default.post(
        name: .codMateExpandAllTasks, object: nil,
        userInfo: ["projectId": currentProjectId as Any])
    } label: {
      Label("Expand all Tasks", systemImage: "arrow.up.left.and.arrow.down.right")
    }
  }

  private func copyAbsolutePath(_ session: SessionSummary) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(session.fileURL.path, forType: .string)
  }

  @ViewBuilder
  private func taskCollapseContextMenuItems() -> some View {
    Divider()
    Button {
      NotificationCenter.default.post(
        name: .codMateCollapseAllTasks, object: nil,
        userInfo: ["projectId": currentProjectId as Any])
    } label: {
      Label("Collapse all Tasks", systemImage: "arrow.down.right.and.arrow.up.left")
    }
    Button {
      NotificationCenter.default.post(
        name: .codMateExpandAllTasks, object: nil,
        userInfo: ["projectId": currentProjectId as Any])
    } label: {
      Label("Expand all Tasks", systemImage: "arrow.up.left.and.arrow.down.right")
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

  private func assetIconForSessionSource(_ source: SessionSource) -> String {
    switch source.baseKind {
    case .codex: return "ChatGPTIcon"
    case .claude: return "ClaudeIcon"
    case .gemini: return "GeminiIcon"
    }
  }

  private func buildNewMenuItems(
    anchor: SessionSummary?,
    project: Project? = nil,
    customAction: ((SessionSummary?, SessionSource, ExternalTerminalProfile) -> Void)? = nil
  ) -> [SplitMenuItem] {
    guard anchor != nil || project != nil else { return [] }
    let allowed: Set<ProjectSessionSource>
    if let anchor {
      allowed = Set(viewModel.allowedSources(for: anchor))
    } else if let project {
      allowed = project.sources.isEmpty ? ProjectSessionSource.allSet : project.sources
    } else {
      allowed = ProjectSessionSource.allSet
    }
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
        if let customAction {
          customAction(anchor, source, profile)
        } else if let anchor {
          onNewSession(with: anchor, using: source, profile: profile)
        }
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
                if let customAction {
                  customAction(anchor, source, embedded)
                } else if let anchor {
                  onNewSession(with: anchor, using: source, profile: embedded)
                }
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

    if menuItems.isEmpty, let anchor {
      let fallback = anchor.source
      menuItems.append(
        .init(
          id: "fallback-\(sourceKey(fallback))",
          kind: .submenu(title: fallback.branding.displayName, systemImage: "terminal", items: launchItems(for: fallback))
        ))
    }
    return menuItems
  }

  private func onNewSession(
    with anchor: SessionSummary,
    using source: SessionSource,
    profile: ExternalTerminalProfile
  ) {
    let target = anchor.overridingSource(source)
    viewModel.recordIntentForDetailNew(anchor: target)
    let dir = target.cwd

    if profile.id == "codmate.embedded" {
      EmbeddedSessionNotification.postEmbeddedNewSession(sessionId: target.id, source: source)
      return
    }

    guard viewModel.copyNewSessionCommandsIfEnabled(session: target, destinationApp: profile)
    else { return }
    if profile.usesWarpCommands {
      viewModel.openPreferredTerminalViaScheme(profile: profile, directory: dir)
      if viewModel.shouldCopyCommandsToClipboard {
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
        if viewModel.shouldCopyCommandsToClipboard {
          Task {
            await SystemNotifier.shared.notify(
              title: "CodMate", body: "Command copied. Paste it in the opened terminal.")
          }
        }
      }
      return
    }
    if profile.isNone {
      if viewModel.shouldCopyCommandsToClipboard {
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
    viewModel.openPreferredTerminalViaScheme(profile: profile, directory: dir, command: cmd)
    if !profile.supportsCommandResolved, viewModel.shouldCopyCommandsToClipboard {
      Task {
        await SystemNotifier.shared.notify(
          title: "CodMate", body: "Command copied. Paste it in the opened terminal.")
      }
    }
  }

  private func latestAnchor(for project: Project) -> SessionSummary? {
    if let visible = viewModel.sections.flatMap({ $0.sessions }).first(
      where: { viewModel.projectIdForSession($0.id) == project.id })
    {
      return visible
    }
    return viewModel.allSessions.first { viewModel.projectIdForSession($0.id) == project.id }
  }
}

extension TaskListView {
  fileprivate func shouldHandleTaskNotification(_ note: Notification) -> Bool {
    guard let target = note.userInfo?["projectId"] as? String else { return true }
    return target == currentProjectId
  }

  fileprivate func taskIDsForCurrentProject() -> Set<UUID> {
    guard let projectId = currentProjectId else { return [] }
    let ids = workspaceVM.tasks.filter { $0.projectId == projectId }.map { $0.id }
    return Set(ids)
  }
}

// MARK: - New Task Sheet (Removed - now using EditTaskSheet with mode: .new)

// MARK: - Edit Task Sheet
struct EditTaskSheet: View {
  enum Mode {
    case new
    case edit
  }

  let task: CodMateTask
  let mode: Mode
  @State private var title: String
  @State private var description: String
  @State private var status: TaskStatus
  let onSave: (CodMateTask) -> Void
  let onCancel: () -> Void
  @FocusState private var focusedField: Field?
  @ObservedObject var workspaceVM: ProjectWorkspaceViewModel

  enum Field {
    case title
    case description
  }

  init(
    task: CodMateTask,
    mode: Mode = .edit,
    workspaceVM: ProjectWorkspaceViewModel,
    onSave: @escaping (CodMateTask) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.task = task
    self.mode = mode
    self.workspaceVM = workspaceVM
    self._title = State(initialValue: task.title)
    self._description = State(initialValue: task.description ?? "")
    self._status = State(initialValue: task.status)
    self.onSave = onSave
    self.onCancel = onCancel
  }

  var body: some View {
    let hasAnyContent = !workspaceVM.getSessionsForTask(task.id).isEmpty
      || !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text(mode == .new ? "New Task" : "Edit Task")
          .font(.title3).bold()
        Spacer()

        // Generate button (icon only, transparent background)
        // Show if there are sessions OR any content (title/description)
        if hasAnyContent {
          Button(action: {
            Task { @MainActor in
              await workspaceVM.generateTitleAndDescription(for: task, currentTitle: title, currentDescription: description, force: false)
              // After generation, update local state
              if let generatedTitle = workspaceVM.generatedTaskTitle {
                title = generatedTitle
              }
              if let generatedDescription = workspaceVM.generatedTaskDescription {
                description = generatedDescription
              }
              // Clear generated content
              workspaceVM.generatedTaskTitle = nil
              workspaceVM.generatedTaskDescription = nil
            }
          }) {
            if workspaceVM.isGeneratingTitleDescription && workspaceVM.generatingTaskId == task.id {
              ProgressView()
                .controlSize(.small)
                .frame(width: 16, height: 16)
            } else {
              Image(systemName: "sparkles")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
            }
          }
          .buttonStyle(.plain)
          .help("Generate title and description using AI")
          .disabled(workspaceVM.isGeneratingTitleDescription && workspaceVM.generatingTaskId == task.id)
        }
      }

      TextField("Task Title", text: $title)
        .textFieldStyle(.roundedBorder)
        .focused($focusedField, equals: .title)

      VStack(alignment: .leading, spacing: 8) {
        Text("Description (optional)").font(.subheadline)
        TextEditor(text: $description)
          .font(.body)
          .codmatePlainTextEditorStyleIfAvailable()
          .scrollContentBackground(.hidden)
          .frame(minHeight: 120)
          .padding(8)
          .background(
            RoundedRectangle(cornerRadius: 6)
              .stroke(Color.gray.opacity(0.2), lineWidth: 1)
          )
          .focused($focusedField, equals: .description)
      }

      Picker("Status", selection: $status) {
        ForEach(TaskStatus.allCases) { s in
          Text(s.displayName).tag(s)
        }
      }

      HStack {
        Button("Cancel", action: onCancel)
          .keyboardShortcut(.cancelAction)

        Spacer()

        Button("Save") {
          var updated = task
          updated.title = title
          updated.description = description.isEmpty ? nil : description
          updated.status = status
          onSave(updated)
        }
        .keyboardShortcut(.defaultAction)
        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(20)
    .frame(minWidth: 520)
    .onAppear {
      // Set focus to title field when view appears
      focusedField = .title
    }
  }
}

// MARK: - Drop Delegates

/// Drop delegate for dropping a session onto another session (creates a new task)
struct SessionDropDelegate: DropDelegate {
  let session: SessionSummary
  @Binding var draggedSession: SessionSummary?
  let workspaceVM: ProjectWorkspaceViewModel
  let currentProjectId: String?

  func performDrop(info: DropInfo) -> Bool {
    guard let draggedSession = draggedSession,
      draggedSession.id != session.id,
      let projectId = currentProjectId
    else {
      return false
    }

    // Only allow creating a new task when both sessions are currently unassigned
    let draggedTaskId = workspaceVM.tasks.first(where: { $0.sessionIds.contains(draggedSession.id) }
    )?.id
    let targetTaskId = workspaceVM.tasks.first(where: { $0.sessionIds.contains(session.id) })?.id
    guard draggedTaskId == nil, targetTaskId == nil else {
      self.draggedSession = nil
      return false
    }

    // Create a new task with both unassigned sessions
    Task {
      let taskTitle = "Task: \(draggedSession.displayName) + \(session.displayName)"
      await workspaceVM.createTask(
        title: taskTitle,
        description: nil,
        projectId: projectId
      )

      // Find the newly created task (it will be the first one)
      if let newTask = workspaceVM.tasks.first {
        // Add both sessions to the task
        var updatedTask = newTask
        updatedTask.sessionIds = [draggedSession.id, session.id]
        await workspaceVM.updateTask(updatedTask)
      }
    }

    self.draggedSession = nil
    return true
  }

  func validateDrop(info: DropInfo) -> Bool {
    guard let dragged = draggedSession,
      dragged.id != session.id
    else { return false }

    let draggedTaskId = workspaceVM.tasks.first(where: { $0.sessionIds.contains(dragged.id) })?.id
    let targetTaskId = workspaceVM.tasks.first(where: { $0.sessionIds.contains(session.id) })?.id

    // Only allow drop when both sessions are not yet assigned to any task
    return draggedTaskId == nil && targetTaskId == nil
  }
}

/// Drop delegate for dropping a session onto a task (adds session to task)
struct TaskDropDelegate: DropDelegate {
  let task: CodMateTask
  @Binding var draggedSession: SessionSummary?
  let workspaceVM: ProjectWorkspaceViewModel
  let onRequestMove: (SessionSummary, CodMateTask, CodMateTask) -> Void

  func performDrop(info: DropInfo) -> Bool {
    guard let draggedSession = draggedSession else {
      return false
    }

    let draggedTask = workspaceVM.tasks.first(where: { $0.sessionIds.contains(draggedSession.id) })

    if let fromTask = draggedTask {
      // If already in this task, do nothing
      guard fromTask.id != task.id else {
        self.draggedSession = nil
        return false
      }
      // Request a confirmed move from fromTask → task
      DispatchQueue.main.async {
        onRequestMove(draggedSession, fromTask, task)
      }
      self.draggedSession = nil
      return true
    } else {
      // Add unassigned session to this task
      Task {
        var updatedTask = task
        if !updatedTask.sessionIds.contains(draggedSession.id) {
          updatedTask.sessionIds.append(draggedSession.id)
          await workspaceVM.updateTask(updatedTask)
        }
      }

      self.draggedSession = nil
      return true
    }
  }

  func validateDrop(info: DropInfo) -> Bool {
    guard let draggedSession = draggedSession else { return false }
    let draggedTask = workspaceVM.tasks.first(where: { $0.sessionIds.contains(draggedSession.id) })
    // Allow drop if session is unassigned or belongs to a different task
    return draggedTask == nil || draggedTask?.id != task.id
  }
}

// MARK: - Task Selection Sheet
struct TaskSelectionSheet: View {
  let tasks: [CodMateTask]
  let onSelect: (CodMateTask) -> Void
  let onCreate: (String) -> Void
  let onCancel: () -> Void
  @State private var searchText = ""

  var filteredTasks: [CodMateTask] {
    if searchText.isEmpty {
      return tasks
    }
    return tasks.filter { $0.effectiveTitle.localizedCaseInsensitiveContains(searchText) }
  }

  private var trimmedSearch: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var canCreateNewTask: Bool {
    guard !trimmedSearch.isEmpty else { return false }
    return !tasks.contains {
      $0.effectiveTitle.localizedCaseInsensitiveCompare(trimmedSearch) == .orderedSame
    }
  }

  var body: some View {
    VStack(spacing: 16) {
      Text("Add to Task")
        .font(.title2)
        .fontWeight(.bold)

      TextField("Search tasks", text: $searchText)
        .textFieldStyle(.roundedBorder)
        .onSubmit {
          if canCreateNewTask {
            onCreate(trimmedSearch)
          }
        }
        .overlay(alignment: .trailing) {
          if canCreateNewTask {
            Button {
              onCreate(trimmedSearch)
            } label: {
              Image(systemName: "plus.circle.fill")
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)
          }
        }

      if filteredTasks.isEmpty {
        Text("No tasks found.")
          .foregroundColor(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(filteredTasks) { task in
          HStack {
            Image(systemName: task.status.icon)
              .foregroundColor(statusColor(task.status))
            Text(task.effectiveTitle)
              .lineLimit(1)
            Spacer()
          }
          .padding(.vertical, 4)
          .contentShape(Rectangle())
          .onTapGesture {
            onSelect(task)
          }
        }
        .listStyle(.plain)
        .overlay(
          RoundedRectangle(cornerRadius: 6)
            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
      }

      HStack {
        Spacer()
        Button("Cancel", action: onCancel)
          .keyboardShortcut(.cancelAction)
      }
    }
    .padding()
    .frame(width: 400, height: 400)
  }

  private func statusColor(_ status: TaskStatus) -> Color {
    switch status {
    case .pending: return .gray
    case .inProgress: return .blue
    case .completed: return .green
    case .archived: return .orange
    }
  }
}

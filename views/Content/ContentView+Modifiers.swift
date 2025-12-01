import SwiftUI
import UniformTypeIdentifiers

extension ContentView {
  fileprivate func canProjectWorkspaceReview() -> Bool {
    guard viewModel.selectedProjectIDs.count == 1,
          let pid = viewModel.selectedProjectIDs.first,
          let p = viewModel.projects.first(where: { $0.id == pid }),
          let dir = p.directory?.trimmingCharacters(in: .whitespacesAndNewlines), !dir.isEmpty
    else { return false }
    return true
  }

  fileprivate func syncListHiddenForWorkspaceMode() {
    // Do not auto-hide the session list based on workspace mode.
    // Respect the user's manual toggle (storeListHidden) and leave isListHidden unchanged.
  }
  fileprivate func navigationTitleForSelection() -> String {
    if isAllSelection() {
      return "Overview"
    } else if isOtherSelection() {
      return "Sessions"
    } else {
      return ""
    }
  }

  fileprivate func isAllSelection() -> Bool {
    return viewModel.selectedProjectIDs.isEmpty
  }

  fileprivate func isOtherSelection() -> Bool {
    if viewModel.selectedProjectIDs.count == 1,
       let pid = viewModel.selectedProjectIDs.first,
       pid == SessionListViewModel.otherProjectId {
      return true
    }
    return false
  }

  fileprivate func enforceWorkspaceModeForSelection() {
    // "All" is forced to Overview
    if isAllSelection() {
      if viewModel.projectWorkspaceMode != .overview {
        viewModel.projectWorkspaceMode = .overview
      }
      return
    }
    // "Other" is forced to Sessions mode (for managing unassigned sessions)
    if isOtherSelection() {
      if viewModel.projectWorkspaceMode != .sessions {
        viewModel.projectWorkspaceMode = .sessions
      }
      return
    }
    // Single real project: restore its last workspace mode, default to Tasks; sanitize hidden modes
    if viewModel.selectedProjectIDs.count == 1,
       let pid = viewModel.selectedProjectIDs.first,
       let project = viewModel.projects.first(where: { $0.id == pid }),
       let dir = project.directory, !dir.isEmpty {
      var restored = viewModel.windowStateStore.restoreWorkspaceMode(for: pid) ?? .tasks
      // Hide Overview/Memory for real projects: coerce to Tasks if persisted as hidden
      if restored == .overview || restored == .memory { restored = .tasks }
      if viewModel.projectWorkspaceMode != restored { viewModel.projectWorkspaceMode = restored }
    }
  }
  func navigationSplitView(geometry: GeometryProxy) -> some View {
    let sidebarMaxWidth = geometry.size.width * 0.25
    _ = storeSidebarHidden
    _ = storeListHidden

    let isSingleContentMode: Bool = {
      switch viewModel.projectWorkspaceMode {
      case .overview, .agents, .memory, .settings:
        return true
      default:
        return false
      }
    }()

    let splitView: AnyView = {
      if isSingleContentMode {
        let v = NavigationSplitView(columnVisibility: $columnVisibility) {
          sidebarContent(sidebarMaxWidth: sidebarMaxWidth)
        } detail: {
          detailColumn
        }
        .navigationSplitViewStyle(.prominentDetail)
        return AnyView(v)
      } else {
        let v = NavigationSplitView(columnVisibility: $columnVisibility) {
          sidebarContent(sidebarMaxWidth: sidebarMaxWidth)
        } content: {
          contentColumn
        } detail: {
          detailColumn
        }
        .navigationSplitViewStyle(.prominentDetail)
        return AnyView(v)
      }
    }()

    let baseView = splitView
      .navigationTitle(navigationTitleForSelection())
      .onAppear {
        applyVisibilityFromStorage(animated: false)
        permissionsManager.restoreAccess()
        SecurityScopedBookmarks.shared.restoreAllDynamicBookmarks()
        Task { await permissionsManager.ensureCriticalDirectoriesAccess() }
        // Restore preferred content column width (sessions list / review tree)
        if let w = viewModel.windowStateStore.restoreContentColumnWidth() {
          let clamped = max(360, min(480, w))
          if contentColumnIdealWidth != clamped { contentColumnIdealWidth = clamped }
        }

        // Restore session selection from previous launch
        let restored = viewModel.windowStateStore.restoreSessionSelection()
        if !restored.selectedIDs.isEmpty {
          selection = restored.selectedIDs
          selectionPrimaryId = restored.primaryId
        }

        // On initial launch, ensure workspace mode matches the current selection.
        // We dispatch to next runloop to avoid racing with view initialization.
        DispatchQueue.main.async {
          enforceWorkspaceModeForSelection()
          syncListHiddenForWorkspaceMode()
        }
      }
      .onChange(of: selection) { _, newSelection in
        // Save session selection whenever it changes
        viewModel.windowStateStore.saveSessionSelection(selectedIDs: newSelection, primaryId: selectionPrimaryId)
      }
      .onChange(of: selectionPrimaryId) { _, newPrimaryId in
        // Save primary ID whenever it changes
        viewModel.windowStateStore.saveSessionSelection(selectedIDs: selection, primaryId: newPrimaryId)
      }
    let viewWithTasks = applyTaskAndChangeModifiers(to: baseView)
    let viewWithNotifications = applyNotificationModifiers(to: viewWithTasks)
    let viewWithDialogs = applyDialogsAndAlerts(to: viewWithNotifications)
    return applyGlobalSearchOverlay(to: viewWithDialogs, geometry: geometry)
      .background(
        GlobalFindKeyInterceptor {
          NotificationCenter.default.post(name: .codMateFocusGlobalSearch, object: nil)
        }
      )
      .onChange(of: preferences.searchPanelStyle) { _, newStyle in
        handleSearchPanelStyleChange(newStyle)
      }
      .onChange(of: viewModel.projectWorkspaceMode) { _, _ in
        syncListHiddenForWorkspaceMode()
      }
      .onChange(of: viewModel.selectedProjectIDs) { _, _ in
        // Enforce Overview only when the selection truly is All/Other.
        // Dispatching to the next run loop avoids racing with List(selection:)
        // rebinds that momentarily emit an empty selection while re-rendering.
        DispatchQueue.main.async {
          enforceWorkspaceModeForSelection()
          syncListHiddenForWorkspaceMode()
        }
      }
  }

  func applyTaskAndChangeModifiers<V: View>(to view: V) -> some View {
    let v1 = view.task { await viewModel.refreshSessions(force: true) }
    let v2 = v1.onChange(of: viewModel.sections) { _, _ in
      // Avoid mutating selection while search popover is opening/active to prevent focus loss/auto-dismiss
      if !shouldBlockAutoSelection {
        applyPendingSelectionIfNeeded()
        normalizeSelection()
      }
      reconcilePendingEmbeddedRekeys()
    }
    let v3 = v2.onChange(of: selection) { _, newSel in
      // 当搜索弹出开启时，立即释放并回拉焦点；否则不要在选择变化时强制归一化，
      // 以免点击空白导致又被选中首项。
      if shouldBlockAutoSelection && preferences.searchPanelStyle == .popover {
        releasePrimaryFirstResponder()
        DispatchQueue.main.async { [weak globalSearchViewModel] in
          if isSearchPopoverPresented { globalSearchViewModel?.setFocus(true) }
        }
      }
      let added = newSel.subtracting(lastSelectionSnapshot)
      if let justAdded = added.first { selectionPrimaryId = justAdded }
      if let primary = selectionPrimaryId, !newSel.contains(primary) {
        selectionPrimaryId = newSel.first
      }
      lastSelectionSnapshot = newSel
    }
    let v4 = v3.onChange(of: viewModel.errorMessage) { _, message in
      guard let message else { return }
      alertState = AlertState(title: "Operation Failed", message: message)
      viewModel.errorMessage = nil
    }
    let v5 = v4.onChange(of: viewModel.pendingEmbeddedProjectNew) { _, project in
      guard let project else { return }
      startEmbeddedNewForProject(project)
      viewModel.pendingEmbeddedProjectNew = nil
    }
    let v6 = v5.toolbar {
      // Project workspace mode segmented (toolbar leading) — AppKit-backed for icon+text in one segment
      ToolbarItem(placement: .navigation) {
        // Only show segmented control for specific projects (not All/Other)
        if viewModel.selectedProjectIDs.count == 1 && !isAllSelection() && !isOtherSelection() {
          let items: [SegmentedIconPicker<ProjectWorkspaceMode>.Item] = [
            .init(title: "Tasks", systemImage: "checklist", tag: .tasks),
            .init(title: "Review", systemImage: "doc.text.magnifyingglass", tag: .review),
            .init(title: "Agents", systemImage: "book.pages", tag: .agents),
            .init(title: "Overview", systemImage: "chart.bar", tag: .settings)
          ]
          SegmentedIconPicker(items: items, selection: $viewModel.projectWorkspaceMode)
            .help("Project workspace mode")
        } else {
          EmptyView()
        }
      }

      ToolbarItem(placement: .primaryAction) {
        refreshToolbarContent
      }
    }
    return AnyView(v6)
  }

  func applyNotificationModifiers<V: View>(to view: V) -> some View {
    view
      .onReceive(NotificationCenter.default.publisher(for: .codMateStartEmbeddedNewProject)) {
        note in
        NSLog("📌 [ContentView] Received codMateStartEmbeddedNewProject: %@", note.userInfo ?? [:])
        if let pid = note.userInfo?["projectId"] as? String,
          let project = viewModel.projects.first(where: { $0.id == pid })
        {
          NSLog("📌 [ContentView] Starting embedded New for project id=%@", pid)
          startEmbeddedNewForProject(project)
        } else {
          NSLog("⚠️ [ContentView] Project for embedded New not found; id=%@",
                note.userInfo?["projectId"] as? String ?? "<nil>")
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .codMateToggleSidebar)) { _ in
        toggleSidebarVisibility()
      }
      .onReceive(NotificationCenter.default.publisher(for: .codMateToggleList)) { _ in
        toggleListVisibility()
      }
      .onReceive(NotificationCenter.default.publisher(for: .codMateFocusGlobalSearch)) { _ in
        focusGlobalSearchPanel()
      }
      .onReceive(NotificationCenter.default.publisher(for: .codMateGlobalRefresh)) { _ in
        // Always refresh sessions to keep global stats in sync
        Task { await viewModel.refreshSessions(force: true) }
        // If in Review mode with a concrete project selected, refresh git status as well
        if viewModel.projectWorkspaceMode == .review,
           let project = currentSelectedProject(),
           let dir = project.directory, !dir.isEmpty {
          let vm = projectReviewVM(for: project.id)
          Task { await vm.refreshStatus() }
        }
      }
  }

  func applyDialogsAndAlerts<V: View>(to view: V) -> some View {
    view
      .confirmationDialog(
        "Stop running session?",
        isPresented: Binding<Bool>(
          get: { confirmStopState != nil }, set: { if !$0 { confirmStopState = nil } }),
        titleVisibility: .visible
      ) {
        Button("Stop", role: .destructive) {
          if let st = confirmStopState {
            stopEmbedded(forID: st.sessionId)
            confirmStopState = nil
          }
        }
        Button("Cancel", role: .cancel) { confirmStopState = nil }
      } message: {
        Text(
          "The embedded terminal appears to be running. Stopping now will terminate the current Codex/Claude task."
        )
      }
      .confirmationDialog(
        "Resume in embedded terminal?",
        isPresented: Binding<Bool>(
          get: { pendingTerminalLaunch != nil }, set: { if !$0 { pendingTerminalLaunch = nil } }),
        presenting: pendingTerminalLaunch?.session
      ) { session in
        Button("Resume", role: .none) {
          startEmbedded(for: session)
          pendingTerminalLaunch = nil
        }
        Button("Cancel", role: .cancel) {
          pendingTerminalLaunch = nil
        }
      } message: { session in
        Text(
          "CodMate will launch \(session.source.branding.displayName) inside the built-in terminal to resume “\(session.displayName)”."
        )
      }
      .alert(item: $alertState) { state in
        Alert(
          title: Text(state.title), message: Text(state.message),
          dismissButton: .default(Text("OK")))
      }
      .alert(
        "Delete selected sessions?", isPresented: $deleteConfirmationPresented,
        presenting: Array(selection)
      ) { ids in
        Button("Cancel", role: .cancel) {}
        Button("Move to Trash", role: .destructive) { deleteSelections(ids: ids) }
      } message: { _ in
        Text("Session files will be moved to Trash and can be restored in Finder.")
      }
      .fileImporter(
        isPresented: $selectingSessionsRoot, allowedContentTypes: [.folder],
        allowsMultipleSelection: false
      ) { result in
        handleFolderSelection(result: result, update: viewModel.updateSessionsRoot)
      }
  }

  private func handleSearchPanelStyleChange(_ newStyle: GlobalSearchPanelStyle) {
    switch newStyle {
    case .popover:
      clampSearchPopoverSizeIfNeeded()
      if globalSearchViewModel.shouldShowPanel {
        isSearchPopoverPresented = true
      }
    case .floating:
      if isSearchPopoverPresented {
        isSearchPopoverPresented = false
      }
    }
  }
}

#if os(macOS)
import AppKit

// Intercepts Command+F at the window level and routes it to global search,
// swallowing the event so focused text fields don't consume it first.
private struct GlobalFindKeyInterceptor: NSViewRepresentable {
  var onFind: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator(onFind: onFind) }

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    context.coordinator.installMonitor()
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {}

  final class Coordinator {
    let onFind: () -> Void
    var monitor: Any?

    init(onFind: @escaping () -> Void) { self.onFind = onFind }

    func installMonitor() {
      if monitor != nil { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
        guard let self, event.modifierFlags.contains(.command) else { return event }
        if let chars = event.charactersIgnoringModifiers?.lowercased(), chars == "f" {
          self.onFind()
          return nil // swallow so first responder doesn't handle it
        }
        return event
      }
    }

    deinit {
      if let monitor { NSEvent.removeMonitor(monitor) }
    }
  }
}
#endif

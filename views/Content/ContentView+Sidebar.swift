import SwiftUI

extension ContentView {
  // Clamp and persist content column width (sessions list / review tree)
  fileprivate func captureContentColumnWidth(_ width: CGFloat) {
    guard width.isFinite, width > 0 else { return }
    // Ignore when hidden (width may report 0 or tiny values)
    if isListHidden { return }
    let clamped = max(360, min(480, width))
    if abs(Double(clamped - contentColumnIdealWidth)) > 0.5 {
      contentColumnIdealWidth = clamped
      viewModel.windowStateStore.saveContentColumnWidth(clamped)
    }
  }
  func sidebarContent(sidebarMaxWidth: CGFloat) -> some View {
    let state = viewModel.sidebarStateSnapshot
    let digest = makeSidebarDigest(for: state)
    let isAllSelected = viewModel.selectedProjectIDs.isEmpty
    let isOtherSelected = viewModel.selectedProjectIDs.count == 1
      && viewModel.selectedProjectIDs.first == SessionListViewModel.otherProjectId
    return EquatableSidebarContainer(key: digest) {
      SessionNavigationView(
        state: state,
        actions: makeSidebarActions(),
        projectWorkspaceMode: viewModel.projectWorkspaceMode,
        isAllOrOtherSelected: isAllSelected || isOtherSelected
      ) {
        ProjectsListView(onEditProject: { project in
          presentProjectEditor(for: project)
        })
          .environmentObject(viewModel)
      }
      .navigationSplitViewColumnWidth(min: 260, ideal: 260, max: 260)
    }
    .sheet(isPresented: $showSidebarNewProjectSheet) {
      ProjectEditorSheet(isPresented: $showSidebarNewProjectSheet, mode: .new)
        .environmentObject(viewModel)
    }
  }

  // Preference key to read current content column width
  private struct ContentColumnWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
  }

  var listContent: some View {
    SessionListColumnView(
      sections: viewModel.sections,
      selection: guardedListSelectionBinding,
      sortOrder: $viewModel.sortOrder,
      isLoading: viewModel.isLoading,
      isEnriching: viewModel.isEnriching,
      enrichmentProgress: viewModel.enrichmentProgress,
      enrichmentTotal: viewModel.enrichmentTotal,
      onResume: resumeFromList,
      onReveal: { viewModel.reveal(session: $0) },
      onDeleteRequest: handleDeleteRequest,
      onExportMarkdown: exportMarkdownForSession,
      isRunning: { runningSessionIDs.contains($0.id) },
      isUpdating: { viewModel.isActivelyUpdating($0.id) },
      isAwaitingFollowup: { viewModel.isAwaitingFollowup($0.id) },
      onPrimarySelect: { s in selectionPrimaryId = s.id },
      onNewSessionWithTaskContext: newSessionWithTaskContext
    )
    .id(isListHidden ? "list-hidden" : "list-shown")
    .environmentObject(viewModel)
    .navigationSplitViewColumnWidth(
      min: isListHidden ? 0 : 360,
      ideal: isListHidden ? 0 : contentColumnIdealWidth,
      max: isListHidden ? 0 : 480
    )
    .background(
      GeometryReader { gr in
        Color.clear.preference(key: ContentColumnWidthPreferenceKey.self, value: gr.size.width)
      }
    )
    .onPreferenceChange(ContentColumnWidthPreferenceKey.self) { w in
      captureContentColumnWidth(w)
    }
    .allowsHitTesting(listAllowsHitTesting)
    .refuseFirstResponder(when: isSearchPopoverPresented || shouldBlockAutoSelection || selection.isEmpty)
    .environment(\.controlActiveState,
                ((preferences.searchPanelStyle == .popover && (isSearchPopoverPresented || shouldBlockAutoSelection)) || selection.isEmpty) ? .inactive : .active)
    .sheet(item: $viewModel.editingSession, onDismiss: { viewModel.cancelEdits() }) { _ in
      EditSessionMetaView(viewModel: viewModel)
    }
  }

  // Content column that switches between the session list and a simple placeholder
  // depending on the current project workspace mode. Use AnyView to unify types.
  var contentColumn: some View {
    switch viewModel.projectWorkspaceMode {
    case .tasks, .sessions:
      AnyView(listContent)
    case .review:
      AnyView(reviewLeftColumn)
    case .overview, .agents, .memory, .settings:
      AnyView(listPlaceholderContent)
    }
  }

  // Neutral placeholder for non-session modes to replace the list column.
  private var listPlaceholderContent: some View {
    let (title, icon) = placeholderTitleAndIcon(for: viewModel.projectWorkspaceMode)
    return placeholderSurface(title: title, systemImage: icon)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .navigationSplitViewColumnWidth(
        min: isListHidden ? 0 : 360,
        ideal: isListHidden ? 0 : contentColumnIdealWidth,
        max: isListHidden ? 0 : 480
      )
      .background(
        GeometryReader { gr in
          Color.clear.preference(key: ContentColumnWidthPreferenceKey.self, value: gr.size.width)
        }
      )
      .onPreferenceChange(ContentColumnWidthPreferenceKey.self) { w in
        captureContentColumnWidth(w)
      }
      .allowsHitTesting(false)
      .id(isListHidden ? "list-placeholder-hidden" : "list-placeholder-shown")
  }

  // Left column for Project Review: Git changes tree/search/commit
  private var reviewLeftColumn: some View {
    Group {
      if let project = currentSelectedProject(), let dir = project.directory, !dir.isEmpty {
        let ws = dir
        let stateBinding = Binding<ReviewPanelState>(
          get: { viewModel.projectReviewPanelStates[project.id] ?? ReviewPanelState() },
          set: { viewModel.projectReviewPanelStates[project.id] = $0 }
        )
        let vm = projectReviewVM(for: project.id)
        EquatableGitChangesContainer(
          key: .init(
            workingDirectoryPath: ws,
            projectDirectoryPath: ws,
            state: stateBinding.wrappedValue
          ),
          workingDirectory: URL(fileURLWithPath: ws, isDirectory: true),
          projectDirectory: URL(fileURLWithPath: ws, isDirectory: true),
          presentation: .full,
          regionLayout: .leftOnly,
          preferences: viewModel.preferences,
          onRequestAuthorization: { ensureRepoAccessForProjectReview(directory: ws) },
          externalVM: vm,
          savedState: stateBinding
        )
      } else {
        placeholderSurface(title: "Review", systemImage: "doc.text.magnifyingglass")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .navigationSplitViewColumnWidth(
      min: isListHidden ? 0 : 360,
      ideal: isListHidden ? 0 : contentColumnIdealWidth,
      max: isListHidden ? 0 : 480
    )
    .background(
      GeometryReader { gr in
        Color.clear.preference(key: ContentColumnWidthPreferenceKey.self, value: gr.size.width)
      }
    )
    .onPreferenceChange(ContentColumnWidthPreferenceKey.self) { w in
      captureContentColumnWidth(w)
    }
  }

  private func placeholderTitleAndIcon(for mode: ProjectWorkspaceMode) -> (String, String) {
    switch mode {
    case .overview: return ("Overview", "square.grid.2x2")
    case .agents: return ("Agents", "book.pages")
    case .memory: return ("Memory", "bookmark")
    case .settings: return ("Project Settings", "gearshape")
    case .tasks: return ("", "") // never used
    case .sessions: return ("", "") // never used
    case .review: return ("", "") // never used
    }
  }

  private var guardedListSelectionBinding: Binding<Set<SessionSummary.ID>> {
    Binding(
      get: { selection },
      set: { newSel in
        // Swallow selection sets while search popover is opening/active
        if preferences.searchPanelStyle == .popover && (isSearchPopoverPresented || shouldBlockAutoSelection) {
          return
        }
        selection = newSel
      }
    )
  }

  private func makeSidebarDigest(for state: SidebarState) -> SidebarDigest {
    func hashInt<S: Sequence>(_ seq: S) -> Int where S.Element == String {
      var h = Hasher()
      for s in seq { h.combine(s) }
      return h.finalize()
    }
    func hashIntDates<S: Sequence>(_ seq: S) -> Int where S.Element == Date {
      var h = Hasher()
      for d in seq { h.combine(d.timeIntervalSinceReferenceDate.bitPattern) }
      return h.finalize()
    }
    let projectsIdsHash = hashInt(viewModel.projects.map { $0.id + ("|" + ($0.parentId ?? "")) })
    func hashCounts(_ counts: [Int: Int]) -> Int {
      var h = Hasher()
      for key in counts.keys.sorted() {
        h.combine(key)
        h.combine(counts[key] ?? 0)
      }
      return h.finalize()
    }
    func hashEnabled(_ set: Set<Int>?) -> Int {
      guard let set else { return -1 }
      var h = Hasher()
      for value in set.sorted() { h.combine(value) }
      return h.finalize()
    }
    let selectedProjectsHash = hashInt(state.selectedProjectIDs.sorted())
    let selectedDaysHash = hashIntDates(state.selectedDays.sorted())
    return SidebarDigest(
      projectsCount: viewModel.projects.count,
      projectsIdsHash: projectsIdsHash,
      totalSessionCount: state.totalSessionCount,
      selectedProjectsHash: selectedProjectsHash,
      selectedDaysHash: selectedDaysHash,
      dateDimensionRaw: state.dateDimension == .created ? 1 : 2,
      monthStartInterval: state.monthStart.timeIntervalSinceReferenceDate,
      calendarCountsHash: hashCounts(state.calendarCounts),
      enabledDaysHash: hashEnabled(state.enabledProjectDays),
      visibleAllCount: state.visibleAllCount,
      projectWorkspaceMode: viewModel.projectWorkspaceMode
    )
  }

  var refreshToolbarContent: some View {
    HStack(spacing: 12) {
      if permissionsManager.needsAuthorization {
        Button {
          openWindow(id: "settings")
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").font(
              .system(size: 14, weight: .medium)
            ).foregroundStyle(.orange)
            Text("Grant Access").font(.system(size: 12, weight: .medium))
          }
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
        .controlSize(.small)
        .help("Some directories need authorization to access sessions data")
      }

      EquatableUsageContainer(
        snapshots: viewModel.usageSnapshots,
        selectedProvider: $selectedUsageProvider,
        onRequestRefresh: { viewModel.requestUsageStatusRefreshThrottled(for: $0) }
      )

      searchToolbarButton

      ToolbarCircleButton(
        systemImage: "arrow.clockwise",
        isActive: viewModel.isEnriching,
        showProgress: viewModel.isEnriching || viewModel.isLoading,
        help: "Refresh"
      ) {
        NotificationCenter.default.post(name: .codMateGlobalRefresh, object: nil)
      }
      .disabled(viewModel.isEnriching || viewModel.isLoading)
    }
    .padding(.horizontal, 3)
    .padding(.vertical, 2)
  }

  @ViewBuilder
  private var searchToolbarButton: some View {
    let button = ToolbarCircleButton(
      systemImage: "magnifyingglass",
      isActive: searchPanelIsActive,
      activeColor: Color.primary.opacity(0.8),
      help: "Open global search (⌘F)"
    ) {
      // In popover mode, route through dedicated open/close to ensure focus guards
      if preferences.searchPanelStyle == .popover {
        if isSearchPopoverPresented {
          dismissGlobalSearchPanel()
        } else {
          focusGlobalSearchPanel()
        }
      } else {
        focusGlobalSearchPanel()
      }
    }

    if preferences.searchPanelStyle == .popover {
      button.popover(isPresented: searchPopoverBinding, arrowEdge: .top) {
        GlobalSearchPopoverPanel(
          viewModel: globalSearchViewModel,
          size: $searchPopoverSize,
          minSize: ContentView.searchPopoverMinSize,
          maxSize: ContentView.searchPopoverMaxSize,
          onSelect: { handleGlobalSearchSelection($0) },
          onClose: { dismissGlobalSearchPanel() }
        )
        .interactiveDismissDisabled(popoverDismissDisabled)
      }
    } else {
      button
    }
  }

  private var searchPopoverBinding: Binding<Bool> {
    Binding(
      get: { isSearchPopoverPresented },
      set: { isPresented in
        isSearchPopoverPresented = isPresented

        if isPresented {
          // Opening: clamp size (focus is handled in focusGlobalSearchPanel)
          clampSearchPopoverSizeIfNeeded()
        } else {
          // Closing popover: clean up and re-enable auto-selection
          shouldBlockAutoSelection = false
          popoverDismissDisabled = false
          globalSearchViewModel.dismissPanel()
        }
      }
    )
  }

  private var searchPanelIsActive: Bool {
    if preferences.searchPanelStyle == .popover {
      return isSearchPopoverPresented
    }
    return globalSearchViewModel.shouldShowPanel
  }

  private var listAllowsHitTesting: Bool {
    guard !isListHidden else { return false }
    // Block hit testing when popover is presented OR about to be presented
    if preferences.searchPanelStyle == .popover && (isSearchPopoverPresented || shouldBlockAutoSelection) {
      return false
    }
    return true
  }
}

private struct ToolbarCircleButton: View {
  let systemImage: String
  var isActive: Bool = false
  var activeColor: Color? = nil
  var showProgress: Bool = false
  var help: String?
  var action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      ZStack {
        if showProgress {
          ProgressView()
            .progressViewStyle(.circular)
            .controlSize(.small)
        } else {
          Image(systemName: systemImage)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(iconColor)
        }
      }
      .frame(width: 14, height: 14)
      .padding(8)
      .background(
        Circle()
          .fill(backgroundColor)
      )
      .overlay(
        Circle()
          .stroke(borderColor, lineWidth: 1)
      )
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .help(help ?? "")
    .onHover { hover in
      withAnimation(.easeInOut(duration: 0.15)) {
        hovering = hover
      }
    }
  }

  private var iconColor: Color {
    if isActive, let activeColor {
      return activeColor
    }
    return hovering ? Color.primary : Color.primary.opacity(0.55)
  }

  private var backgroundColor: Color {
    if isActive || showProgress {
      return Color.primary.opacity(0.08)
    }
    return (hovering ? Color.primary.opacity(0.12) : Color(nsColor: .separatorColor).opacity(0.18))
  }

  private var borderColor: Color {
    return Color(nsColor: .separatorColor).opacity(hovering ? 0.65 : 0.45)
  }
}

#if os(macOS)
import AppKit

// Custom ViewModifier to prevent a view hierarchy from accepting first responder
private struct RefuseFirstResponderModifier: ViewModifier {
  let shouldRefuse: Bool

  func body(content: Content) -> some View {
    content.background(
      RefuseFirstResponderHelper(shouldRefuse: shouldRefuse)
    )
  }
}

private struct RefuseFirstResponderHelper: NSViewRepresentable {
  let shouldRefuse: Bool

  func makeNSView(context: Context) -> RefuseFirstResponderView {
    let view = RefuseFirstResponderView()
    view.shouldRefuse = shouldRefuse
    return view
  }

  func updateNSView(_ nsView: RefuseFirstResponderView, context: Context) {
    nsView.shouldRefuse = shouldRefuse
  }
}

private class RefuseFirstResponderView: NSView {
  var shouldRefuse: Bool = false {
    didSet {
      if shouldRefuse != oldValue {
        // Traverse the view hierarchy and apply refusal to all subviews
        applyRefusalToHierarchy(shouldRefuse)
      }
    }
  }

  override var acceptsFirstResponder: Bool {
    if shouldRefuse {
      return false
    }
    return super.acceptsFirstResponder
  }

  private func applyRefusalToHierarchy(_ refuse: Bool) {
    // Walk up to find the root of the list content
    var current: NSView? = self.superview
    while let view = current {
      if let outlineView = view as? NSOutlineView {
        outlineView.refusesFirstResponder = refuse
        if refuse, let window = outlineView.window, window.firstResponder === outlineView {
          window.makeFirstResponder(nil)
        }
        return
      }
      // Also check for NSTableView (in case List uses it)
      if let tableView = view as? NSTableView {
        tableView.refusesFirstResponder = refuse
        if refuse, let window = tableView.window, window.firstResponder === tableView {
          window.makeFirstResponder(nil)
        }
        return
      }
      current = view.superview
    }
  }
}

extension View {
  func refuseFirstResponder(when condition: Bool) -> some View {
    self.modifier(RefuseFirstResponderModifier(shouldRefuse: condition))
  }
}
#endif

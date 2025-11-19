import SwiftUI

#if canImport(AppKit)
  import AppKit
#endif

struct GitChangesPanel: View {
  enum Presentation { case embedded, full }
  enum RegionLayout { case combined, leftOnly, rightOnly }
  let workingDirectory: URL
  let projectDirectory: URL?
  var presentation: Presentation = .embedded
  var regionLayout: RegionLayout = .combined
  let preferences: SessionPreferencesStore
  var onRequestAuthorization: (() -> Void)? = nil
  @Binding var savedState: ReviewPanelState
  @ObservedObject var vm: GitChangesViewModel
  // Layout state
  @State var leftColumnWidth: CGFloat = 0  // 0 = init to 1/4 of container
  @State var commitEditorHeight: CGFloat = 28
  // Tree state (keep staged/unstaged expansions independent)
  @State var expandedDirsStaged: Set<String> = []
  @State var expandedDirsUnstaged: Set<String> = []
  @State var treeQuery: String = ""
  // Cached trees for performance
  @State var cachedNodesStaged: [FileNode] = []
  @State var cachedNodesUnstaged: [FileNode] = []
  @State var displayedStaged: [FileNode] = []
  @State var displayedUnstaged: [FileNode] = []
  @State var stagedCollapsed: Bool = false
  @State var unstagedCollapsed: Bool = false
  @State var commitInlineHeight: CGFloat = 20
  @State var mode: ReviewPanelState.Mode = .diff
  @State var expandedDirsBrowser: Set<String> = []
  @State var browserNodes: [FileNode] = []
  @State var displayedBrowserRows: [BrowserRow] = []
  @State var isLoadingBrowserTree: Bool = false
  @State var browserTreeError: String? = nil
  @State var browserTreeTruncated: Bool = false
  @State var browserTotalEntries: Int = 0
  @State var browserTreeTask: Task<Void, Never>? = nil
  // Hover state for quick actions
  @State var hoverFilePath: String? = nil
  @State var hoverDirKey: String? = nil
  @State var hoverEditPath: String? = nil
  @State var hoverRevertPath: String? = nil
  @State var hoverStagePath: String? = nil
  @State var hoverDirButtonPath: String? = nil
  @State var hoverBrowserFilePath: String? = nil
  @State var hoverBrowserRevealPath: String? = nil
  @State var hoverBrowserEditPath: String? = nil
  @State var hoverBrowserStagePath: String? = nil
  @State var hoverBrowserDirKey: String? = nil
  @State var hoverStagedHeader: Bool = false
  @State var hoverUnstagedHeader: Bool = false
  @State var pendingDiscardPaths: [String] = []
  @State var pendingDiscardIncludesStaged: Bool = false
  @State var showDiscardAlert: Bool = false
  @State var showCommitConfirm: Bool = false
  // Graph view toggle + model
  @State var showGraph: Bool = false
  @StateObject var graphVM = GitGraphViewModel()
  @State var historyDetailCommit: GitService.GraphCommit? = nil
  // Use an optional Int for segmented momentary actions: 0=collapse, 1=expand
  // @State private var treeToggleIndex: Int? = nil
  // Layout constraints
  let leftMin: CGFloat = 280
  let leftMax: CGFloat = 520
  let commitMinHeight: CGFloat = 140
  // Indent guide metrics (horizontal):
  // - indentStep: per-depth indent distance (matches VS Code's 16px)
  // - chevronWidth: width reserved for disclosure chevron
  let indentStep: CGFloat = 16
  let chevronWidth: CGFloat = 16
  let quickActionWidth: CGFloat = 18
  let quickActionHeight: CGFloat = 16
  let trailingPad: CGFloat = 8
  let hoverButtonSpacing: CGFloat = 8
  let statusBadgeWidth: CGFloat = 18
  let browserEntryLimit: Int = 6000
  let repoContentMatchLimit: Int = 4000
  // Viewer options (from Settings › Git Review). Defaults: line numbers ON, wrap OFF
  var wrapText: Bool { preferences.gitWrapText }
  var showLineNumbers: Bool { preferences.gitShowLineNumbers }
  // Wand button metrics
  let wandButtonSize: CGFloat = 24
  var wandReservedTrailing: CGFloat { wandButtonSize }  // equal-width indent to avoid overlap
  @State var hoverWand: Bool = false
  @State private var diffModePreviewPreference: Bool = false
  @State private var forcedBrowserDueToMissingRepo = false
  @State var contentSearchMatches: Set<String> = []
  @State private var contentSearchTask: Task<Void, Never>? = nil
  @State private var contentSearchQueryVersion: UInt64 = 0
  // Unified header search
  @State var headerSearchQuery: String = ""
  #if canImport(AppKit)
    @State var previewImage: NSImage? = nil
    @State var previewImageTask: Task<Void, Never>? = nil
  #endif
  private let repoSearchService = RepoContentSearchService()

  var body: some View {
    Group {
      if vm.repoRoot == nil && vm.isResolvingRepo {
        VStack(spacing: 16) {
          ProgressView()
          Text("Resolving repository access…")
            .font(.headline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if !explorerRootExists && vm.repoRoot == nil {
        VStack(spacing: 12) {
          Image(systemName: "lock.rectangle.on.rectangle")
            .font(.system(size: 42))
            .foregroundStyle(.secondary)
          Text("Git Review Unavailable")
            .font(.headline)
          Text(
            "This folder is either not a Git repository or requires permission. Authorize the repository root (the folder containing .git)."
          )
          .font(.subheadline)
          .multilineTextAlignment(.center)
          .foregroundStyle(.secondary)
          .frame(maxWidth: 520)
          Button("Authorize Repository Folder…") {
            onRequestAuthorization?()
          }
          .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        contentWithPresentation
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .codMateRepoAuthorizationChanged)) { _ in
      // Only the left/combined pane should trigger repo re-attachment
      if regionLayout == .combined || regionLayout == .leftOnly {
        vm.attach(to: workingDirectory)
      }
    }
    .alert("Discard changes?", isPresented: $showDiscardAlert) {
      Button("Discard", role: .destructive) {
        let paths = pendingDiscardPaths
        let includeStaged = pendingDiscardIncludesStaged
        pendingDiscardPaths = []
        pendingDiscardIncludesStaged = true
        Task { await vm.discard(paths: paths, includeStaged: includeStaged) }
      }
      Button("Cancel", role: .cancel) {
        pendingDiscardPaths = []
        pendingDiscardIncludesStaged = true
      }
    } message: {
      let count = pendingDiscardPaths.count
      if pendingDiscardIncludesStaged {
        Text(
          "This will permanently discard staged and unstaged changes for \(count) file\(count == 1 ? "" : "s")."
        )
      } else {
        Text(
          "This will permanently discard unstaged changes for \(count) file\(count == 1 ? "" : "s"). Staged changes (if any) will be preserved."
        )
      }
    }
    .confirmationDialog(
      "Commit changes?",
      isPresented: $showCommitConfirm,
      titleVisibility: .visible
    ) {
      Button("Commit", role: .destructive) { Task { await vm.commit() } }
      Button("Cancel", role: .cancel) {}
    } message: {
      let msg = vm.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
      if msg.isEmpty {
        Text("This will create a commit for staged changes.")
      } else {
        Text("Commit message:\n\n\(msg)")
      }
    }
    .task(id: workingDirectory) {
      // Avoid double attach from both halves; left/combined is the source of truth
      if regionLayout == .combined || regionLayout == .leftOnly {
        vm.attach(to: workingDirectory, fallbackProjectDirectory: projectDirectory)
      }
    }
    .task(id: vm.repoRoot?.path) {
      browserNodes = []
      displayedBrowserRows = []
      browserTreeError = nil
      if (regionLayout == .combined || regionLayout == .leftOnly) && mode == .browser {
        reloadBrowserTreeIfNeeded(force: true)
      }
      let trimmed = treeQuery.trimmingCharacters(in: .whitespacesAndNewlines)
      if (regionLayout == .combined || regionLayout == .leftOnly) && !trimmed.isEmpty {
        await MainActor.run {
          handleTreeQueryChange(treeQuery)
        }
      }
    }
    .onChange(of: mode) { oldMode, newMode in
      if newMode == .browser {
        if regionLayout == .combined || regionLayout == .leftOnly {
          reloadBrowserTreeIfNeeded()
          if let selectedPath = vm.selectedPath { ensureBrowserPathExpanded(selectedPath) }
        }
      }
    }
    .modifier(
      LifecycleModifier(
        expandedDirsStaged: $expandedDirsStaged,
        expandedDirsUnstaged: $expandedDirsUnstaged,
        expandedDirsBrowser: $expandedDirsBrowser,
        savedState: $savedState,
        mode: $mode,
        vm: vm,
        treeQuery: treeQuery,
        onSearchQueryChanged: { handleTreeQueryChange($0) },
        onRebuildNodes: rebuildNodes,
        onRebuildDisplayed: rebuildDisplayed,
        onEnsureExpandAll: ensureExpandAllIfNeeded,
        onRebuildBrowserDisplayed: rebuildBrowserDisplayed,
        onRefreshBrowserTree: { reloadBrowserTreeIfNeeded(force: false) }
      )
    )
    .onDisappear {
      contentSearchTask?.cancel()
      contentSearchTask = nil
    }
    .onAppear {
      diffModePreviewPreference = vm.showPreviewInsteadOfDiff
      // Restore mode on appear
      mode = savedState.mode
    }
    .onChange(of: savedState.mode) { _, newVal in
      if mode != newVal { mode = newVal }
    }
    .onChange(of: vm.showPreviewInsteadOfDiff) { _, newValue in
      if mode == .diff {
        diffModePreviewPreference = newValue
      }
    }
    .onChange(of: mode) { _, newMode in
      switch newMode {
      case .browser:
        // Explorer always shows preview on the right
        if !vm.showPreviewInsteadOfDiff { vm.showPreviewInsteadOfDiff = true }
      case .diff:
        // Diff mode must always render diff view
        if vm.showPreviewInsteadOfDiff { vm.showPreviewInsteadOfDiff = false }
      case .graph:
        // no-op; detail rendering managed by Graph container
        break
      }
      savedState.mode = newMode
    }
    .onChange(of: vm.repoRoot) { _, newRoot in
      if newRoot == nil {
        forcedBrowserDueToMissingRepo = true
        if mode != .browser {
          mode = .browser
        }
        if !vm.showPreviewInsteadOfDiff {
          vm.showPreviewInsteadOfDiff = true
        }
      } else if forcedBrowserDueToMissingRepo {
        forcedBrowserDueToMissingRepo = false
        let target = savedState.mode
        mode = target
        if target == .diff {
          vm.showPreviewInsteadOfDiff = diffModePreviewPreference
        } else if !vm.showPreviewInsteadOfDiff {
          vm.showPreviewInsteadOfDiff = true
        }
      }
    }
    .onChange(of: vm.selectedPath) { _, _ in }
    .onChange(of: leftColumnWidth) { _, newW in
      WindowStateStore().saveReviewLeftPaneWidth(newW)
    }
  }

  private var contentWithPresentation: some View {
    Group {
      switch presentation {
      case .embedded:
        baseContent
          .background(.thinMaterial)
          .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
          .padding(8)
      case .full:
        baseContent
      }
    }
  }

  // Extracted heavy content to reduce body type-checking complexity
  private var baseContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      switch regionLayout {
      case .combined:
        if mode == .graph, historyDetailCommit != nil {
          // History Details mode: hide left tree, use full width for History list + detail split
          historyDetailRoot
        } else {
          header
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
          Divider()
          VSplitView {
            GeometryReader { geo in
              splitContent(totalWidth: geo.size.width)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear {
                  if leftColumnWidth == 0 {
                    let store = WindowStateStore()
                    if let saved = store.restoreReviewLeftPaneWidth() {
                      leftColumnWidth = clampLeftWidth(saved, total: geo.size.width)
                    } else {
                      leftColumnWidth = clampLeftWidth(geo.size.width * 0.25, total: geo.size.width)
                    }
                  }
                }
            }
          }
        }
      case .leftOnly:
        // Left tree + commit inline; omit header/graph and any right detail
        leftPane
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .rightOnly:
        // Header + divider + detail (matching Tasks mode layout)
        VStack(spacing: 0) {
          header
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

          Divider()

          if mode == .graph, historyDetailCommit != nil {
            historyDetailBody
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else if mode == .graph {
            graphDetailView
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else {
            detailView
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        }
      }
    }
  }

  // MARK: - History detail layout (History mode, commit details)

  /// Combined layout root when left tree is hidden and full width is used for History list + detail.
  private var historyDetailRoot: some View {
    VStack(spacing: 0) {
      header
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
      Divider()
      historyDetailBody
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  /// Right-side body: horizontally split between compact History list and commit detail.
  private var historyDetailBody: some View {
    HSplitView {
      historyDetailListPane
      historyDetailPane
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// Left pane in History Details mode: compact History list (graph + description only).
  private var historyDetailListPane: some View {
    graphListView(compactColumns: true) { commit in
      historyDetailCommit = commit
    }
  }

  /// Right pane in History Details mode: commit meta + files tree + diff viewer.
  @ViewBuilder
  private var historyDetailPane: some View {
    if let commit = historyDetailCommit {
      HistoryCommitDetailView(
        commit: commit,
        viewModel: graphVM,
        onClose: {
          historyDetailCommit = nil
        },
        wrap: wrapText,
        showLineNumbers: showLineNumbers
      )
    } else {
      VStack {
        Text("No commit selected")
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func splitContent(totalWidth: CGFloat) -> some View {
    // Top split: left file tree and right diff/preview, with draggable divider
    let leftW = effectiveLeftWidth(total: totalWidth)
    let gutterW: CGFloat = 33  // divider 1pt + 8pt padding each side
    let rightW = max(totalWidth - gutterW - leftW, 240)
    return HStack(spacing: 0) {
      leftPane
        .frame(width: leftW)
        .frame(minWidth: leftMin, maxWidth: leftMax)
      // Visible divider with padding; whole gutter is draggable
      HStack(spacing: 0) {
        Color.clear.frame(width: 8)
        Divider().frame(width: 1)
        Color.clear.frame(width: 8)
      }
      .frame(width: gutterW)
      .frame(maxHeight: .infinity)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 1).onChanged { value in
          let newW = clampLeftWidth(leftColumnWidth + value.translation.width, total: totalWidth)
          leftColumnWidth = newW
        }
      )
      .onHover { inside in
        #if canImport(AppKit)
          if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
        #endif
      }
      Group {
        if mode == .graph {
          graphDetailView
        } else {
          detailView
        }
      }
      .padding(16)
      .frame(width: rightW)
      .frame(maxHeight: .infinity)
    }
  }

  @MainActor
  private func handleTreeQueryChange(_ query: String) {
    contentSearchTask?.cancel()
    contentSearchTask = nil
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      contentSearchMatches = []
      return
    }
    guard let root = vm.repoRoot else {
      contentSearchMatches = []
      return
    }
    contentSearchMatches = []
    contentSearchQueryVersion &+= 1
    let version = contentSearchQueryVersion
    let service = repoSearchService
    contentSearchTask = Task {
      try? await Task.sleep(nanoseconds: 200_000_000)
      if Task.isCancelled { return }
      do {
        let matches = try await service.searchFilesContaining(
          trimmed, in: root, limit: repoContentMatchLimit)
        if Task.isCancelled { return }
        await MainActor.run {
          if version == contentSearchQueryVersion {
            contentSearchMatches = matches
            rebuildDisplayed()
            rebuildBrowserDisplayed()
            contentSearchTask = nil
          }
        }
      } catch is CancellationError {
        // Ignore cancellation; another task will replace it
      } catch {
        await MainActor.run {
          if version == contentSearchQueryVersion {
            contentSearchMatches = []
            contentSearchTask = nil
          }
        }
      }
    }
  }

  private func ensureExpandAllIfNeeded() {
    if expandedDirsStaged.isEmpty {
      expandedDirsStaged = Set(allDirectoryKeys(nodes: cachedNodesStaged))
    }
    if expandedDirsUnstaged.isEmpty {
      expandedDirsUnstaged = Set(allDirectoryKeys(nodes: cachedNodesUnstaged))
    }
  }

  // MARK: - Layout helpers
  private func clampLeftWidth(_ proposed: CGFloat, total: CGFloat) -> CGFloat {
    let minW = leftMin
    let maxW = min(leftMax, total - 240)  // keep space for right pane + gutter
    return max(minW, min(maxW, proposed))
  }
  private func effectiveLeftWidth(total: CGFloat) -> CGFloat {
    let w = (leftColumnWidth == 0) ? total * 0.25 : leftColumnWidth
    return clampLeftWidth(w, total: total)
  }

  var explorerRootExists: Bool {
    FileManager.default.fileExists(atPath: explorerRoot.path)
  }

  var explorerRoot: URL {
    projectDirectory ?? workingDirectory
  }

  // Measure dynamic height for inline commit editor based on width
  func measureCommitHeight(_ text: String, width: CGFloat) -> CGFloat {
    #if canImport(AppKit)
      let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
      let s = text.isEmpty ? " " : text
      let rect = (s as NSString).boundingRect(
        with: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: [.font: font]
      )
      return max(20, ceil(rect.height))
    #else
      return 20
    #endif
  }

  // MARK: - File tree (grouped by directories)
  typealias FileNode = GitReviewNode

  // MARK: - TreeScope enum
  enum TreeScope { case unstaged, staged }

}

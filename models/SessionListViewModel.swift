import AppKit
import Combine
import CryptoKit
import Foundation
import OSLog

#if canImport(Darwin)
  import Darwin
#endif

@MainActor
final class SessionListViewModel: ObservableObject {
  @Published var sections: [SessionDaySection] = []
  @Published var searchText: String = "" {
    didSet { scheduleFulltextSearchIfNeeded() }
  }
  @Published var sortOrder: SessionSortOrder = .mostRecent {
    didSet { scheduleFiltersUpdate() }
  }
  @Published var isLoading = false
  @Published var isEnriching = false
  @Published var enrichmentProgress: Int = 0
  @Published var enrichmentTotal: Int = 0
  @Published var errorMessage: String?

  // Title/Comment quick search for the middle list only
  @Published var quickSearchText: String = "" {
    didSet { scheduleFiltersUpdate() }
  }

  // New filter state: supports combined filters
  @Published var selectedPath: String? = nil {
    didSet {
      guard !suppressFilterNotifications, oldValue != selectedPath else { return }
      // Path filtering works on already-loaded sessions (filters by cwd field),
      // so we don't need to refresh files from disk - just reapply filters
      scheduleFiltersUpdate()
    }
  }
  @Published var selectedDay: Date? = nil {
    didSet {
      guard !suppressFilterNotifications, oldValue != selectedDay else { return }
      invalidateVisibleCountCache()
      scheduleSelectionDrivenUpdate()
      windowStateStore.saveCalendarSelection(
        selectedDay: selectedDay, selectedDays: selectedDays, monthStart: sidebarMonthStart)
    }
  }
  @Published var dateDimension: DateDimension = .updated {
    didSet {
      guard !suppressFilterNotifications, oldValue != dateDimension else { return }
      invalidateVisibleCountCache()
      invalidateCalendarCaches()
      enrichmentSnapshots.removeAll()
      if dateDimension == .updated {
        for day in selectedDays {
          requestCoverageIfNeeded(for: day)
        }
        if let day = selectedDay {
          requestCoverageIfNeeded(for: day)
        }
      }
      scheduleFiltersUpdate()
      scheduleFilterRefresh(force: true)
    }
  }
  // Multiple day selection support (normalized to startOfDay)
  @Published var selectedDays: Set<Date> = [] {
    didSet {
      guard !suppressFilterNotifications else { return }
      invalidateVisibleCountCache()
      scheduleSelectionDrivenUpdate()
      windowStateStore.saveCalendarSelection(
        selectedDay: selectedDay, selectedDays: selectedDays, monthStart: sidebarMonthStart)
    }
  }
  @Published var sidebarMonthStart: Date = SessionListViewModel.normalizeMonthStart(Date()) {
    didSet {
      guard !suppressFilterNotifications, oldValue != sidebarMonthStart else { return }
      windowStateStore.saveCalendarSelection(
        selectedDay: selectedDay, selectedDays: selectedDays, monthStart: sidebarMonthStart)
    }
  }
  // Track current list selection for targeted refreshes
  @Published var selectedSessionIDs: Set<SessionSummary.ID> = []
  private var cacheUnavailableLastError: Date?
  private let cacheUnavailableCooldown: TimeInterval = 5.0

  private func markCacheUnavailableNow() {
    cacheUnavailableLastError = Date()
  }

  private func clearCacheUnavailable() {
    cacheUnavailableLastError = nil
  }

  private func shouldSkipForCacheUnavailable() -> Bool {
    guard let last = cacheUnavailableLastError else { return false }
    return Date().timeIntervalSince(last) < cacheUnavailableCooldown
  }

  let preferences: SessionPreferencesStore
  private var sessionsRoot: URL { preferences.sessionsRoot }

  internal let indexer: SessionIndexer
  let actions: SessionActions
  var allSessions: [SessionSummary] = [] {
    didSet {
      sessionsVersion &+= 1
      invalidateVisibleCountCache()
      invalidateCalendarCaches()
      pruneDayCache()
      pruneCoverageCache()
      for session in allSessions {
        _ = dayIndex(for: session)
      }
      // Incremental path tree update based on session cwd diffs
      let newCounts = cwdCounts(for: allSessions)
      let oldCounts = lastPathCounts
      lastPathCounts = newCounts
      pathTreeRefreshTask?.cancel()
      let delta = diffCounts(old: oldCounts, new: newCounts)
      if !delta.isEmpty {
        Task { [weak self] in
          guard let self else { return }
          if let updated = await self.pathTreeStore.applyDelta(delta) {
            await MainActor.run { self.pathTreeRootPublished = updated }
          } else {
            // Fallback to full snapshot rebuild when prefix changes or structure requires it
            let rebuilt = await self.pathTreeStore.applySnapshot(counts: newCounts)
            await MainActor.run { self.pathTreeRootPublished = rebuilt }
          }
        }
      }
      sessionLookup = Dictionary(uniqueKeysWithValues: allSessions.map { ($0.id, $0) })
    }
  }
  private var sessionLookup: [String: SessionSummary] = [:]
  private var sessionsVersion: UInt64 = 0
  private var fulltextMatches: Set<String> = []  // SessionSummary.id set
  private var fulltextTask: Task<Void, Never>?
  private var enrichmentTask: Task<Void, Never>?
  var notesStore: SessionNotesStore
  var notesSnapshot: [String: SessionNote] = [:]
  private var canonicalCwdCache: [String: String] = [:]
  private let ripgrepStore = SessionRipgrepStore()
  private var coverageLoadTasks: [String: Task<Void, Never>] = [:]
  private var pendingCoverageMonths: Set<String> = []
  private var coverageDebounceTasks: [String: Task<Void, Never>] = [:]  // Per-key debounce
  private var selectedSessionsRefreshTask: Task<Void, Never>?
  struct SessionDayIndex: Equatable {
    let created: Date
    let updated: Date
    let createdMonthKey: String
    let updatedMonthKey: String
    let createdDay: Int
    let updatedDay: Int
  }
  struct SessionMonthCoverageKey: Hashable, Sendable {
    let sessionID: String
    let monthKey: String
  }
  struct DaySelectionDescriptor: Hashable, Sendable {
    let date: Date
    let monthKey: String
    let day: Int
  }
  private var sessionDayCache: [String: SessionDayIndex] = [:]
  var updatedMonthCoverage: [SessionMonthCoverageKey: Set<Int>] = [:]
  private var directoryMonitor: DirectoryMonitor?
  private var claudeDirectoryMonitor: DirectoryMonitor?
  private var claudeProjectMonitor: DirectoryMonitor?
  private var geminiDirectoryMonitor: DirectoryMonitor?
  private var directoryRefreshTask: Task<Void, Never>?
  private var enrichmentSnapshots: [String: Set<String>] = [:]
  private var suppressFilterNotifications = false
  private var scheduledFilterRefresh: Task<Void, Never>?
  private var filterTask: Task<Void, Never>?
  private var filterDebounceTask: Task<Void, Never>?
  private var filterGeneration: UInt64 = 0
  private var pendingApplyFilters = false
  private var lastFilterSnapshotHash: Int?
  /// Debounce refresh triggers to avoid repeated full enumerations
  private var refreshDebounceTask: Task<Void, Never>?
  private var lastRefreshAt: Date?
  private var lastRefreshScope: SessionLoadScope?
  private let refreshCooldown: TimeInterval = 0.5
  private var pendingRefreshForce: Bool = false
  /// Scope-based refresh debouncing: track pending refresh by scope key to enable merging
  private var scopedRefreshTasks: [String: Task<Void, Never>] = [:]
  private var pendingScopeRefreshForce: [String: Bool] = [:]
  /// Track actively executing refreshes by scope to prevent concurrent duplicates
  private var activeScopeRefreshes: [String: UUID] = [:]
  /// File event aggregation: collect file change events within a time window
  private var pendingFileEvents: Set<String> = []  // file paths that changed
  private var fileEventAggregationTask: Task<Void, Never>?
  private var lastFileEventAt: Date = .distantPast
  struct VisibleCountKey: Equatable {
    var dimension: DateDimension
    var selectedDay: Date?
    var selectedDays: Set<Date>
    var sessionCount: Int
  }
  var cachedVisibleCount: (key: VisibleCountKey, value: Int)?
  struct ProjectVisibleKey: Equatable {
    var dimension: DateDimension
    var selectedDay: Date?
    var selectedDays: Set<Date>
    var sessionCount: Int
    var membershipVersion: UInt64
  }
  var cachedProjectVisibleCounts: (key: ProjectVisibleKey, value: [String: Int])?
  private var geminiProjectPathByHash: [String: String] = [:]
  private var codexUsageTask: Task<Void, Never>?
  private var claudeUsageTask: Task<Void, Never>?
  private var geminiUsageTask: Task<Void, Never>?
  private var pathTreeRefreshTask: Task<Void, Never>?
  private var calendarRefreshTasks: [String: Task<Void, Never>] = [:]
  private var cancellables = Set<AnyCancellable>()
  private let pathTreeStore = PathTreeStore()
  private var timelineCache: [String: TimelineCacheEntry] = [:]

  private struct TimelineCacheEntry {
    let signature: TimelineCacheSignature
    let turns: [ConversationTurn]
  }

  private struct TimelineCacheSignature: Equatable {
    let modifiedAt: Date?
    let fileSize: UInt64?
  }
  private var lastPathCounts: [String: Int] = [:]
  private let sidebarStatsDebounceNanoseconds: UInt64 = 150_000_000
  private let filterDebounceNanoseconds: UInt64 = 15_000_000
  private var cachedCalendar = Calendar.current
  private var pendingViewUpdate = false
  static let monthFormatter: DateFormatter = {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM"
    return df
  }()
  private var currentMonthKey: String?
  private var currentMonthDimension: DateDimension = .updated
  // Quick pulse (cheap file mtime scan) state
  private var quickPulseTask: Task<Void, Never>?
  private var lastQuickPulseAt: Date = .distantPast
  private var fileMTimeCache: [String: Date] = [:]  // session.id -> mtime
  private var lastDisplayedDigest: Int = 0
  @Published var editingSession: SessionSummary? = nil
  @Published var editTitle: String = ""
  @Published var editComment: String = ""
  @Published var globalSessionCount: Int = 0
  @Published private(set) var pathTreeRootPublished: PathTreeNode?
  private var monthCountsCache: [String: [Int: Int]] = [:]  // key: "dim|yyyy-MM" (not @Published to avoid updates during view reads)
  @Published private(set) var codexUsageStatus: CodexUsageStatus?
  @Published private(set) var usageSnapshots: [UsageProviderKind: UsageProviderSnapshot] = [:]
  private var claudeUsageAutoRefreshEnabled = false
  private var didAutoRefreshUsage = false
  // Live activity indicators
  @Published private(set) var activeUpdatingIDs: Set<String> = []
  @Published private(set) var awaitingFollowupIDs: Set<String> = []
  // Index meta for diagnostics/UI state (full cache completion marker)
  @Published private(set) var indexMeta: SessionIndexMeta?
  @Published private(set) var cacheCoverage: SessionIndexCoverage?
  private let diagLogger = Logger(subsystem: "io.umate.codmate", category: "SessionListVM")
  private func ts() -> Double { Date().timeIntervalSince1970 }

  // Persist Review (Git Changes) panel UI state per session so toggling
  // between Conversation, Terminal and Review preserves context.
  @Published var reviewPanelStates: [String: ReviewPanelState] = [:]
  // Project-level Git Review panel state per project id
  @Published var projectReviewPanelStates: [String: ReviewPanelState] = [:]

  // Project workspace mode (toolbar segmented)
  @Published var projectWorkspaceMode: ProjectWorkspaceMode = .overview

  let windowStateStore = WindowStateStore()

  // Project workspace view model for managing tasks
  private(set) var workspaceVM: ProjectWorkspaceViewModel?

  // Auto-assign: pending intents created when user clicks New
  struct PendingAssignIntent: Identifiable, Sendable, Hashable {
    let id = UUID()
    let projectId: String
    let expectedCwd: String  // canonical path
    let t0: Date
    struct Hints: Sendable, Hashable {
      var model: String?
      var sandbox: String?
      var approval: String?
    }
    let hints: Hints
  }
  var pendingAssignIntents: [PendingAssignIntent] = []
  var intentsCleanupTask: Task<Void, Never>?

  // Targeted incremental refresh hint, set when user triggers New
  struct PendingIncrementalRefreshHint {
    enum Kind {
      case codexDay(Date)
      case geminiDay(Date)
      case claudeProject(String)
    }
    let kind: Kind
    let expiresAt: Date
  }
  private var pendingIncrementalHint: PendingIncrementalRefreshHint? = nil

  // Projects
  let configService = CodexConfigService()
  var projectsStore: ProjectsStore
  let claudeProvider: ClaudeSessionProvider
  let geminiProvider: GeminiSessionProvider
  private let claudeUsageClient = ClaudeUsageAPIClient()
  private let geminiUsageClient = GeminiUsageAPIClient()
  private let codexAppServerProbe = CodexAppServerProbeService()
  private let providersRegistry = ProvidersRegistryService()
  let remoteProvider: RemoteSessionProvider
  let sqliteStore: SessionIndexSQLiteStore
  @Published var projects: [Project] = []
  var projectCounts: [String: Int] = [:]
  var projectMemberships: [String: String] = [:]
  var projectMembershipsVersion: UInt64 = 0
  var projectStructureVersion: UInt64 = 0  // Incremented when projects/parentIds change
  @Published var expandedProjectIDs: Set<String> = [] {
    didSet {
      if oldValue != expandedProjectIDs {
        windowStateStore.saveProjectExpansions(expandedProjectIDs)
      }
    }
  }

  struct ProjectAggregatedKey: Equatable {
    var visibleKey: ProjectVisibleKey
    var totalCountsHash: Int
    var structureVersion: UInt64
  }
  var cachedProjectAggregated:
    (key: ProjectAggregatedKey, value: [String: (visible: Int, total: Int)])?
  @Published var selectedProjectIDs: Set<String> = [] {
    didSet {
      guard !suppressFilterNotifications, oldValue != selectedProjectIDs else { return }
      if !selectedProjectIDs.isEmpty {
        // Defer selectedPath modification to avoid "Publishing changes from within view updates"
        Task { @MainActor [weak self] in
          self?.selectedPath = nil
        }
      }
      invalidateProjectVisibleCountsCache()
      scheduleSelectionDrivenUpdate()
      windowStateStore.saveProjectSelection(selectedProjectIDs)
    }
  }
  // Sidebar → Project-level New request when using embedded terminal
  @Published var pendingEmbeddedProjectNew: Project? = nil
  @Published var remoteSyncStates: [String: RemoteSyncState] = [:]

  private func pruneDayCache() {
    guard !sessionDayCache.isEmpty else { return }
    let ids = Set(allSessions.map(\.id))
    sessionDayCache = sessionDayCache.filter { ids.contains($0.key) }
  }

  private func pruneCoverageCache() {
    guard !updatedMonthCoverage.isEmpty else { return }
    let ids = Set(allSessions.map(\.id))
    updatedMonthCoverage = updatedMonthCoverage.filter { ids.contains($0.key.sessionID) }
  }

  private func invalidateVisibleCountCache() {
    cachedVisibleCount = nil
    invalidateProjectVisibleCountsCache()
  }

  func invalidateProjectVisibleCountsCache() {
    cachedProjectVisibleCounts = nil
    cachedProjectAggregated = nil
  }

  private func scheduleViewUpdate() {
    if pendingViewUpdate { return }
    pendingViewUpdate = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.objectWillChange.send()
      self.pendingViewUpdate = false
    }
  }

  func scheduleApplyFilters() {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      // Coalesce rapid triggers: if a filter task is in flight, mark pending and return.
      if self.filterTask != nil {
        self.pendingApplyFilters = true
        return
      }
      self.applyFilters()
    }
  }

  func setProjectMemberships(_ memberships: [String: String]) {
    var normalized: [String: String] = [:]
    for (key, value) in memberships {
      if key.contains("|") {
        normalized[key] = value
      } else {
        let legacyKey = membershipKey(for: key, source: .codex)
        normalized[legacyKey] = value
      }
    }
    projectMemberships = normalized
    projectMembershipsVersion &+= 1
    invalidateProjectVisibleCountsCache()
  }

  func monthKey(for date: Date) -> String {
    Self.monthFormatter.string(from: date)
  }

  private static func formattedMonthKey(year: Int, month: Int) -> String {
    return String(format: "%04d-%02d", year, month)
  }

  static func makeDayDescriptors(selectedDays: Set<Date>, singleDay: Date?)
    -> [DaySelectionDescriptor]
  {
    let calendar = Calendar.current
    let targets: [Date]
    if !selectedDays.isEmpty {
      targets = Array(selectedDays)
    } else if let single = singleDay {
      targets = [single]
    } else {
      targets = []
    }
    return targets.map { date in
      let comps = calendar.dateComponents([.year, .month, .day], from: date)
      let monthKey = formattedMonthKey(year: comps.year ?? 0, month: comps.month ?? 0)
      return DaySelectionDescriptor(date: date, monthKey: monthKey, day: comps.day ?? 0)
    }
  }

  func dayIndex(for session: SessionSummary) -> SessionDayIndex {
    let index = buildDayIndex(for: session)
    if let cached = sessionDayCache[session.id], cached == index {
      return cached
    }
    sessionDayCache[session.id] = index
    return index
  }

  private func buildDayIndex(for session: SessionSummary) -> SessionDayIndex {
    let created = cachedCalendar.startOfDay(for: session.startedAt)
    let updatedSource = session.lastUpdatedAt ?? session.startedAt
    let updated = cachedCalendar.startOfDay(for: updatedSource)
    let createdKey = monthKey(for: created)
    let updatedKey = monthKey(for: updated)
    let createdDay = cachedCalendar.component(.day, from: created)
    let updatedDay = cachedCalendar.component(.day, from: updated)
    return SessionDayIndex(
      created: created,
      updated: updated,
      createdMonthKey: createdKey,
      updatedMonthKey: updatedKey,
      createdDay: createdDay,
      updatedDay: updatedDay)
  }

  func dayStart(for session: SessionSummary, dimension: DateDimension) -> Date {
    let index = dayIndex(for: session)
    switch dimension {
    case .created: return index.created
    case .updated: return index.updated
    }
  }

  func matchesDayFilters(_ session: SessionSummary, descriptors: [DaySelectionDescriptor]) -> Bool {
    guard !descriptors.isEmpty else { return true }
    let bucket = dayIndex(for: session)
    return Self.matchesDayDescriptors(
      summary: session,
      bucket: bucket,
      descriptors: descriptors,
      dimension: dateDimension,
      coverage: updatedMonthCoverage,
      calendar: cachedCalendar
    )
  }

  static func normalizeMonthStart(_ date: Date) -> Date {
    let cal = Calendar.current
    let comps = cal.dateComponents([.year, .month], from: date)
    return cal.date(from: comps) ?? cal.startOfDay(for: date)
  }

  func setSidebarMonthStart(_ date: Date) {
    let normalized = Self.normalizeMonthStart(date)
    if normalized == sidebarMonthStart { return }
    sidebarMonthStart = normalized

    // Cancel unrelated coverage load tasks to reduce CPU usage when switching months
    let currentKey = cacheKey(normalized, dateDimension)
    for (key, task) in coverageLoadTasks where key != currentKey {
      task.cancel()
    }
    coverageLoadTasks.removeAll(keepingCapacity: true)

    _ = calendarCounts(for: normalized, dimension: dateDimension)

    // In Created mode, changing the viewed month requires reloading data
    // since we only load the current month's sessions for efficiency
    if dateDimension == .created {
      scheduleFilterRefresh(force: true)
    }
  }

  var sidebarStateSnapshot: SidebarState {
    SidebarState(
      totalSessionCount: totalSessionCount,
      isLoading: isLoading,
      visibleAllCount: visibleAllCountForDateScope(),
      selectedProjectIDs: selectedProjectIDs,
      selectedDay: selectedDay,
      selectedDays: selectedDays,
      dateDimension: dateDimension,
      monthStart: sidebarMonthStart,
      calendarCounts: calendarCounts(for: sidebarMonthStart, dimension: dateDimension),
      enabledProjectDays: calendarEnabledDaysForSelectedProject(
        monthStart: sidebarMonthStart,
        dimension: dateDimension
      )
    )
  }

  init(
    preferences: SessionPreferencesStore,
    sqliteStore: SessionIndexSQLiteStore = SessionIndexSQLiteStore(),
    indexer: SessionIndexer? = nil,
    actions: SessionActions = SessionActions()
  ) {
    self.preferences = preferences
    self.sqliteStore = sqliteStore
    self.indexer = indexer ?? SessionIndexer(sqliteStore: sqliteStore)
    self.actions = actions
    self.notesStore = SessionNotesStore(notesRoot: preferences.notesRoot)
    // Initialize ProjectsStore using configurable projectsRoot (defaults to ~/.codmate/projects)
    let pr = preferences.projectsRoot
    let p = ProjectsStore.Paths(
      root: pr,
      metadataDir: pr.appendingPathComponent("metadata", isDirectory: true),
      membershipsURL: pr.appendingPathComponent("memberships.json", isDirectory: false)
    )
    self.projectsStore = ProjectsStore(paths: p)
    self.claudeProvider = ClaudeSessionProvider(cacheStore: sqliteStore)
    self.geminiProvider = GeminiSessionProvider(
      projectsStore: self.projectsStore, cacheStore: sqliteStore)
    self.remoteProvider = RemoteSessionProvider(indexer: SessionIndexer(sqliteStore: sqliteStore))

    suppressFilterNotifications = true

    // Restore window state from previous session
    let calendar = windowStateStore.restoreCalendarSelection()
    if let restoredDay = calendar.selectedDay {
      // Use restored calendar state
      self.selectedDay = restoredDay
      self.selectedDays = calendar.selectedDays.isEmpty ? [restoredDay] : calendar.selectedDays
      // Restore monthStart if available, otherwise derive from selectedDay
      if let restoredMonthStart = calendar.monthStart {
        self.sidebarMonthStart = restoredMonthStart
      } else {
        self.sidebarMonthStart = Self.normalizeMonthStart(restoredDay)
      }
    } else if !calendar.selectedDays.isEmpty {
      // Restore selectedDays even if selectedDay is nil
      self.selectedDays = calendar.selectedDays
      self.selectedDay = calendar.selectedDays.count == 1 ? calendar.selectedDays.first : nil
      if let restoredMonthStart = calendar.monthStart {
        self.sidebarMonthStart = restoredMonthStart
      } else if let firstDay = calendar.selectedDays.first {
        self.sidebarMonthStart = Self.normalizeMonthStart(firstDay)
      } else {
        self.sidebarMonthStart = Self.normalizeMonthStart(Date())
      }
    } else if let restoredMonthStart = calendar.monthStart {
      // Only monthStart was saved, restore it but select today
      let today = Date()
      let cal = Calendar.current
      let start = cal.startOfDay(for: today)
      self.selectedDay = start
      self.selectedDays = [start]
      self.sidebarMonthStart = restoredMonthStart
    } else {
      // No saved state, default to today
      let today = Date()
      let cal = Calendar.current
      let start = cal.startOfDay(for: today)
      self.selectedDay = start
      self.selectedDays = [start]
      self.sidebarMonthStart = Self.normalizeMonthStart(today)
    }

    // Restore project selection
    self.selectedProjectIDs = windowStateStore.restoreProjectSelection()
    self.expandedProjectIDs = windowStateStore.restoreProjectExpansions()

    suppressFilterNotifications = false

    // Initialize workspace view model after self is fully initialized
    self.workspaceVM = ProjectWorkspaceViewModel(sessionListViewModel: self)

    // Prime cached index state early so sidebar counts/overview can render without a 0 flash.
    Task { @MainActor [weak self] in
      guard let self else { return }
      let meta = await self.indexer.currentMeta()
      let coverage = await self.indexer.currentCoverage()
      if let coverage {
        self.cacheCoverage = coverage
        self.globalSessionCount = coverage.sessionCount
        self.diagLogger.log(
          "prime index coverage count=\(coverage.sessionCount, privacy: .public) sources=\(coverage.sources, privacy: .public) ts=\(self.ts(), format: .fixed(precision: 3))"
        )
      } else if let meta {
        self.indexMeta = meta
        self.globalSessionCount = meta.sessionCount
        self.diagLogger.log(
          "prime index meta count=\(meta.sessionCount, privacy: .public) ts=\(self.ts(), format: .fixed(precision: 3))"
        )
      }
    }

    configureDirectoryMonitor()
    configureClaudeDirectoryMonitor()
    configureGeminiDirectoryMonitor()
    Task { await loadProjects() }
    Task { await self.performInitialRemoteSyncIfNeeded() }
    // Observe agent completion notifications to surface in list
    NotificationCenter.default.addObserver(
      forName: .codMateAgentCompleted,
      object: nil,
      queue: .main
    ) { [weak self] note in
      guard let id = note.userInfo?["sessionID"] as? String else { return }
      Task { @MainActor in
        self?.awaitingFollowupIDs.insert(id)
      }
    }
    // React to Active Provider changes to keep usage capsule in sync immediately
    NotificationCenter.default.addObserver(
      forName: .codMateActiveProviderChanged,
      object: nil,
      queue: .main
    ) { [weak self] note in
      guard let self else { return }
      let consumer = note.userInfo?["consumer"] as? String
      let providerId = note.userInfo?["providerId"] as? String
      Task { @MainActor in
        if consumer == ProvidersRegistryService.Consumer.codex.rawValue {
          if providerId == nil || providerId?.isEmpty == true {
            self.refreshCodexUsageStatus()
          } else {
            self.setUsageSnapshot(.codex, Self.thirdPartyUsageSnapshot(for: .codex))
          }
        } else if consumer == ProvidersRegistryService.Consumer.claudeCode.rawValue {
          if providerId == nil || providerId?.isEmpty == true {
            self.claudeUsageAutoRefreshEnabled = false
            self.setInitialClaudePlaceholder()
          } else {
            self.claudeUsageAutoRefreshEnabled = false
            self.setUsageSnapshot(.claude, Self.thirdPartyUsageSnapshot(for: .claude))
          }
        }
      }
    }
    startActivityPruneTicker()
    startIntentsCleanupTicker()
    // Observe remote host enablement changes to trigger sync

    preferences.$enabledRemoteHosts
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] _ in
        guard let self else { return }
        Task { await self.syncRemoteHosts(force: true, refreshAfter: true) }
      }
      .store(in: &cancellables)
    // Pre-seed usage snapshots based on current Active Provider selection to avoid initial flicker
    Task { [weak self] in
      guard let self else { return }
      let codexOrigin = await self.providerOrigin(for: .codex)
      let claudeOrigin = await self.providerOrigin(for: .claude)
      let geminiOrigin = await self.providerOrigin(for: .gemini)
      await MainActor.run {
        if codexOrigin == .thirdParty {
          self.setUsageSnapshot(.codex, Self.thirdPartyUsageSnapshot(for: .codex))
        }
        if claudeOrigin == .thirdParty {
          self.setUsageSnapshot(.claude, Self.thirdPartyUsageSnapshot(for: .claude))
        } else {
          self.claudeUsageAutoRefreshEnabled = false
          self.setInitialClaudePlaceholder()
        }
        if geminiOrigin == .thirdParty {
          self.setUsageSnapshot(.gemini, Self.thirdPartyUsageSnapshot(for: .gemini))
        } else {
          self.refreshGeminiUsageStatus()
        }
      }
      await MainActor.run {
        self.autoRefreshUsageIfNeeded(
          codexOrigin: codexOrigin,
          claudeOrigin: claudeOrigin,
          geminiOrigin: geminiOrigin
        )
      }
    }
  }

  // Immediate apply from UI (e.g., pressing Return in search field)
  func immediateApplyQuickSearch(_ text: String) { quickSearchText = text }

  private var activeRefreshToken = UUID()

  func refreshSessions(force: Bool = false) async {
    scheduledFilterRefresh?.cancel()
    scheduledFilterRefresh = nil
    let token = UUID()
    activeRefreshToken = token
    if shouldSkipForCacheUnavailable() {
      diagLogger.log(
        "refreshSessions skipped due to cache unavailable (cooldown) ts=\(self.ts(), format: .fixed(precision: 3))"
      )
      await MainActor.run { self.isLoading = false }
      return
    }
    let scope = currentScope()
    let scopeKeyValue = scopeKey(scope)

    if shouldSkipRefresh(scope: scope, force: force) {
      diagLogger.log(
        "refreshSessions skipped (executing or recent) scope=\(scopeKeyValue, privacy: .public) force=\(force, privacy: .public) ts=\(self.ts(), format: .fixed(precision: 3))"
      )
      await MainActor.run { self.isLoading = false }
      return
    }

    isLoading = true
    activeScopeRefreshes[scopeKeyValue] = token
    if force {
      invalidateEnrichmentCache(for: selectedDay)
    }
    let refreshBegan = Date()
    defer {
      if token == activeRefreshToken {
        isLoading = false
        let elapsed = Date().timeIntervalSince(refreshBegan)
        lastRefreshAt = Date()
        lastRefreshScope = currentScope()
        // Clean up active refresh tracker
        if activeScopeRefreshes[scopeKeyValue] == token {
          activeScopeRefreshes.removeValue(forKey: scopeKeyValue)
        }
        diagLogger.log(
          "refreshSessions done in \(elapsed, format: .fixed(precision: 3))s sessions=\(self.allSessions.count, privacy: .public) ts=\(self.ts(), format: .fixed(precision: 3))"
        )
      }
    }

    // Ensure we have access to the sessions directory in sandbox mode
    await ensureSessionsAccess()

    let enabledRemoteHosts = preferences.enabledRemoteHosts
    diagLogger.log(
      "refreshSessions start force=\(force, privacy: .public) scope=\(String(describing: scope), privacy: .public) ts=\(self.ts(), format: .fixed(precision: 3)) hosts=\(enabledRemoteHosts.count, privacy: .public)"
    )

    let providers = buildProviders(enabledRemoteHosts: Set(enabledRemoteHosts))
    let projectDirectories = singleSelectedProjectDirectory()
    let scopedProjectIds = dateDimension == .created ? singleSelectedProject() : nil
    let scopedProjectDirectories = dateDimension == .created ? projectDirectories : nil
    let scopedDateRange = dateDimension == .created ? currentDateRange() : nil
    let cacheContext = SessionProviderContext(
      scope: scope,
      sessionsRoot: preferences.sessionsRoot,
      enabledRemoteHosts: Set(enabledRemoteHosts),
      projectDirectories: scopedProjectDirectories,
      dateDimension: dateDimension,
      dateRange: scopedDateRange,
      projectIds: scopedProjectIds,
      forceFilesystemScan: false,
      cachePolicy: .cacheOnly
    )
    let refreshContext = SessionProviderContext(
      scope: scope,
      sessionsRoot: preferences.sessionsRoot,
      enabledRemoteHosts: Set(enabledRemoteHosts),
      projectDirectories: scopedProjectDirectories,
      dateDimension: dateDimension,
      dateRange: scopedDateRange,
      projectIds: scopedProjectIds,
      forceFilesystemScan: force,
      cachePolicy: .refresh
    )

    let cachedResults = await loadProviders(providers, context: cacheContext)
    let cachedSessions = dedupProviderSessions(cachedResults)
    let notes = await notesStore.all()
    notesSnapshot = notes

    if token == activeRefreshToken, !cachedSessions.isEmpty {
      var cachedForApply = cachedSessions
      apply(notes: notes, to: &cachedForApply)
      registerActivityHeartbeat(previous: allSessions, current: cachedForApply)
      smartMergeAllSessions(newSessions: cachedForApply)
      scheduleFiltersUpdate()
    }

    let refreshedResults = await loadProviders(providers, context: refreshContext)
    var sessions = dedupProviderSessions(cachedSessions + refreshedResults)

    guard token == activeRefreshToken else { return }
    let previousIDs = Set(allSessions.map { $0.id })
    // Refresh projects/memberships snapshot and import legacy mappings if needed
    Task { @MainActor in
      await self.loadProjects()
      await self.importMembershipsFromNotesIfNeeded(notes: notes)
    }
    apply(notes: notes, to: &sessions)
    // Auto-assign on newly appeared sessions matched with pending intents
    let newlyAppeared = sessions.filter { !previousIDs.contains($0.id) }
    if !newlyAppeared.isEmpty {
      for s in newlyAppeared { self.handleAutoAssignIfMatches(s) }
    }
    registerActivityHeartbeat(previous: allSessions, current: sessions)
    // Smart merge: only update if data actually changed to avoid unnecessary UI re-renders
    smartMergeAllSessions(newSessions: sessions)
    persistProjectAssignmentsToCache(sessions)
    recomputeProjectCounts()
    rebuildCanonicalCwdCache()
    await computeCalendarCaches()
    scheduleFiltersUpdate()
    // TEMPORARILY DISABLED FOR PERFORMANCE TESTING
    // Background enrichment causes continuous UI updates during scrolling
    // startBackgroundEnrichment()
    currentMonthDimension = dateDimension
    currentMonthKey = monthKey(for: selectedDay, dimension: dateDimension)
    Task { await self.refreshGlobalCount() }
    // Refresh path tree to ensure newly created files appear via refresh
    let enabledRemoteHostsForCounts = enabledRemoteHosts
    let sessionsRootForCounts = sessionsRoot
    Task {
      var counts = await indexer.collectCWDCounts(root: sessionsRootForCounts)
      let claudeCounts = await claudeProvider.collectCWDCounts()
      let geminiCounts = await geminiProvider.collectCWDCounts()
      for (key, value) in claudeCounts {
        counts[key, default: 0] += value
      }
      for (key, value) in geminiCounts {
        counts[key, default: 0] += value
      }
      if !enabledRemoteHostsForCounts.isEmpty {
        let remoteCodex = await remoteProvider.collectCWDAggregates(
          kind: .codex, enabledHosts: enabledRemoteHostsForCounts)
        for (key, value) in remoteCodex {
          counts[key, default: 0] += value
        }
        let remoteClaude = await remoteProvider.collectCWDAggregates(
          kind: .claude, enabledHosts: enabledRemoteHostsForCounts)
        for (key, value) in remoteClaude {
          counts[key, default: 0] += value
        }
      }
      let tree = counts.buildPathTreeFromCounts()
      await MainActor.run { self.pathTreeRootPublished = tree }
    }
    Task { [weak self] in
      guard let self else { return }
      self.indexMeta = await self.indexer.currentMeta()
      self.cacheCoverage = await self.indexer.currentCoverage()
      self.diagLogger.log(
        "refreshSessions meta/coverage updated metaCount=\(self.indexMeta?.sessionCount ?? -1, privacy: .public) coverageCount=\(self.cacheCoverage?.sessionCount ?? -1, privacy: .public) ts=\(self.ts(), format: .fixed(precision: 3))"
      )
    }
    refreshCodexUsageStatus()
    if claudeUsageAutoRefreshEnabled {
      refreshClaudeUsageStatus()
    }
    refreshGeminiUsageStatus()
    schedulePathTreeRefresh()

    // Ensure currently selected sessions are fully up-to-date with high-quality parsing.
    // This fixes the issue where global refresh (fast parse) keeps selected item in 'metadata' state
    // when user explicitly requests a refresh (Cmd+R).
    if !selectedSessionIDs.isEmpty {
      Task { await self.refreshSelectedSessions(sessionIds: self.selectedSessionIDs, force: force) }
    }
  }

  // MARK: - Selected Sessions Incremental Refresh

  /// Refresh only the selected sessions, avoiding full scope scan.
  /// Returns true if any sessions were refreshed.
  func refreshSelectedSessions(sessionIds: Set<String>, force: Bool = false) async -> Bool {
    guard !sessionIds.isEmpty else { return false }
    if shouldSkipForCacheUnavailable() {
      diagLogger.log(
        "refreshSelectedSessions skipped due to cache unavailable (cooldown) ts=\(self.ts(), format: .fixed(precision: 3))"
      )
      return false
    }

    diagLogger.log(
      "refreshSelectedSessions: start sessionIds=\(sessionIds.count, privacy: .public) force=\(force, privacy: .public) ts=\(self.ts(), format: .fixed(precision: 3))"
    )
    let refreshBegan = Date()

    // Pull cached file metadata (mtime/size) to avoid re-parsing unchanged files (Codex only)
    let cachedRecords = await indexer.fetchRecords(sessionIds: sessionIds)
    let cachedById = Dictionary(uniqueKeysWithValues: cachedRecords.map { ($0.summary.id, $0) })

    // 1. Find the selected sessions in current allSessions
    let selectedSessions = allSessions.filter { sessionIds.contains($0.id) }
    guard !selectedSessions.isEmpty else {
      diagLogger.log("refreshSelectedSessions: no sessions found in allSessions for given IDs")
      return false
    }

    // Split by source so we can use the correct parser
    let codexSessions = selectedSessions.filter { $0.source.baseKind == .codex }
    let claudeSessions = selectedSessions.filter { $0.source.baseKind == .claude }

    var refreshedSummaries: [SessionSummary] = []

    // 2. Codex: mtime/size check + reindex via SessionIndexer
    if !codexSessions.isEmpty {
      var needsRefresh: [(id: String, url: URL)] = []
      for session in codexSessions {
        let record = cachedById[session.id]
        let fileURL = record.flatMap { URL(fileURLWithPath: $0.filePath) } ?? session.fileURL
        guard
          let values = try? fileURL.resourceValues(
            forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
          values.isRegularFile == true
        else {
          // Missing file or unreadable: refresh to reconcile state
          needsRefresh.append((session.id, fileURL))
          continue
        }

        if force {
          needsRefresh.append((session.id, fileURL))
          continue
        }

        var hasComparableMetric = false
        var changed = false

        if let cachedMtime = record?.fileModificationTime,
          let mtime = values.contentModificationDate
        {
          hasComparableMetric = true
          if mtime > cachedMtime.addingTimeInterval(0.001) {
            changed = true
          }
        }

        if let cachedSize = record?.fileSize, let fsize = values.fileSize.map({ UInt64($0) }) {
          hasComparableMetric = true
          if cachedSize != fsize {
            changed = true
          }
        }

        // If we had no cached metrics, err on the side of refreshing
        if !hasComparableMetric || changed {
          needsRefresh.append((session.id, fileURL))
        }
      }

      if !needsRefresh.isEmpty {
        diagLogger.log(
          "refreshSelectedSessions (codex): refreshing \(needsRefresh.count, privacy: .public) files"
        )
        let urlsToRefresh = needsRefresh.map { $0.url }
        do {
          let codexSummaries = try await indexer.reindexFiles(urlsToRefresh)
          refreshedSummaries.append(contentsOf: codexSummaries)
        } catch {
          diagLogger.error(
            "refreshSelectedSessions: codex reindex failed: \(error.localizedDescription, privacy: .public)"
          )
        }
      }
    }

    // 3. Claude/Gemini: always parse with provider-specific parsers when forced or when selection includes them.
    if !claudeSessions.isEmpty {
      let claudeParser = ClaudeSessionParser()

      func parseSummary(for session: SessionSummary) -> SessionSummary? {
        let url = session.fileURL
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        let fileSize = values?.fileSize.flatMap { UInt64($0) }
        switch session.source.baseKind {
        case .claude:
          return claudeParser.parse(at: url, fileSize: fileSize)?.summary
        default:
          return nil
        }
      }

      for session in claudeSessions {
        if let summary = parseSummary(for: session) {
          var merged = summary
          // Preserve user metadata (title/comment/task)
          merged.userTitle = session.userTitle
          merged.userComment = session.userComment
          merged.taskId = session.taskId
          refreshedSummaries.append(merged)
        }
      }
    }

    guard !refreshedSummaries.isEmpty else {
      diagLogger.log("refreshSelectedSessions: no changes detected, skipping refresh")
      return false
    }

    // 4. Update allSessions with refreshed data
    var didChange = false
    await MainActor.run {
      var updatedSessions = allSessions
      for refreshed in refreshedSummaries {
        if let index = updatedSessions.firstIndex(where: { $0.id == refreshed.id }) {
          var merged = refreshed
          merged.userTitle = updatedSessions[index].userTitle
          merged.userComment = updatedSessions[index].userComment
          merged.taskId = updatedSessions[index].taskId
          if updatedSessions[index] != merged {
            updatedSessions[index] = merged
            didChange = true
          }
        }
      }
      if didChange {
        allSessions = updatedSessions
      }
    }

    // 5. Re-apply filters to update UI if anything changed
    if didChange {
      scheduleFiltersUpdate()
    }

    let elapsed = Date().timeIntervalSince(refreshBegan)
    diagLogger.log(
      "refreshSelectedSessions: completed in \(elapsed, format: .fixed(precision: 3))s, refreshed=\(refreshedSummaries.count, privacy: .public)"
    )

    return didChange
  }

  /// Schedule a debounced refresh for selected sessions.
  /// Call this method when selection changes to trigger incremental refresh.
  func scheduleSelectedSessionsRefresh(sessionIds: Set<String>) {
    guard !sessionIds.isEmpty else { return }

    // Cancel any pending refresh
    selectedSessionsRefreshTask?.cancel()

    // Schedule new refresh with 100ms debounce
    selectedSessionsRefreshTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
      guard let self, !Task.isCancelled else { return }
      _ = await self.refreshSelectedSessions(sessionIds: sessionIds, force: false)
    }
  }

  private func buildProviders(enabledRemoteHosts: Set<String>) -> [any SessionProvider] {
    var providers: [any SessionProvider] = [
      indexer,
      claudeProvider,
      geminiProvider,
    ]
    if !enabledRemoteHosts.isEmpty {
      providers.append(
        RemoteSessionProviderAdapter(
          kind: .codex,
          remoteKind: .codex,
          provider: remoteProvider,
          label: "CodexRemote"
        )
      )
      providers.append(
        RemoteSessionProviderAdapter(
          kind: .claude,
          remoteKind: .claude,
          provider: remoteProvider,
          label: "ClaudeRemote"
        )
      )
    }
    return providers
  }

  private func loadProviders(
    _ providers: [any SessionProvider],
    context: SessionProviderContext
  ) async -> [SessionSummary] {
    let logger = diagLogger
    let isCacheUnavailableError: (Error) -> Bool = { error in
      error is SessionIndexSQLiteStoreError
        || error is ClaudeSessionProvider.SessionProviderCacheError
        || error is GeminiSessionProvider.SessionProviderCacheError
    }
    return await withTaskGroup(
      of: ([SessionSummary], SessionIndexCoverage?, SessionSource.Kind).self
    ) { group in
      for provider in providers {
        group.addTask { [self] in
          do {
            let result = try await provider.load(context: context)
            let label = result.summaries.first?.source.baseKind.rawValue ?? provider.kind.rawValue
            logger.log(
              "provider load success kind=\(label, privacy: .public) count=\(result.summaries.count, privacy: .public) cacheHit=\(result.cacheHit, privacy: .public)"
            )
            if !result.summaries.isEmpty {
              await MainActor.run { self.clearCacheUnavailable() }
            }
            return (result.summaries, result.coverage, provider.kind)
          } catch {
            if isCacheUnavailableError(error) {
              await MainActor.run { self.markCacheUnavailableNow() }
            }
            logger.error(
              "provider load failed kind=\(provider.kind.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return ([], nil, provider.kind)
          }
        }
      }
      var all: [SessionSummary] = []
      var latestCoverage: SessionIndexCoverage?
      for await output in group {
        all.append(contentsOf: output.0)
        if output.2 == .codex, let cov = output.1 {
          latestCoverage = cov
        }
      }
      if let cov = latestCoverage {
        await MainActor.run { self.cacheCoverage = cov }
      }
      return all
    }
  }

  private func dedupProviderSessions(_ sessions: [SessionSummary]) -> [SessionSummary] {
    guard !sessions.isEmpty else { return [] }
    var best: [String: SessionSummary] = [:]
    for session in sessions {
      if let existing = best[session.id] {
        best[session.id] = preferSession(lhs: existing, rhs: session)
      } else {
        best[session.id] = session
      }
    }
    return Array(best.values)
  }

  private func preferSession(lhs: SessionSummary, rhs: SessionSummary) -> SessionSummary {
    // 1. Prefer higher parse level (Enriched > Full > Metadata)
    if let lLevel = lhs.parseLevel, let rLevel = rhs.parseLevel {
      if lLevel != rLevel {
        return lLevel > rLevel ? lhs : rhs
      }
    }
    // If one has explicit high quality level and other is unknown (nil), prefer explicit high quality
    if let lLevel = lhs.parseLevel, lLevel > .metadata, rhs.parseLevel == nil {
      return lhs
    }
    if let rLevel = rhs.parseLevel, rLevel > .metadata, lhs.parseLevel == nil {
      return rhs
    }

    // CRITICAL FIX: Prefer sessions with higher counts (from full parse) over lower counts (from fast parse)
    // When same file (matching size), always prefer the one with more complete data
    let lt = lhs.lastUpdatedAt ?? lhs.startedAt
    let rt = rhs.lastUpdatedAt ?? rhs.startedAt
    let ls = lhs.fileSizeBytes ?? 0
    let rs = rhs.fileSizeBytes ?? 0

    // If file sizes match (same file), prefer the one with more complete data regardless of timestamp
    // This handles the case where fast parse and full parse have slightly different timestamps
    if ls > 0 && ls == rs {
      let lhsTotal = lhs.userMessageCount + lhs.assistantMessageCount + lhs.toolInvocationCount
      let rhsTotal = rhs.userMessageCount + rhs.assistantMessageCount + rhs.toolInvocationCount
      if lhsTotal != rhsTotal {
        return lhsTotal > rhsTotal ? lhs : rhs  // Prefer richer data (full parse)
      }
      // If counts are equal, also check lineCount as another indicator of completeness
      if lhs.lineCount != rhs.lineCount {
        return lhs.lineCount > rhs.lineCount ? lhs : rhs
      }
    }

    // Original fallback logic
    if lt != rt { return lt > rt ? lhs : rhs }
    if ls != rs { return ls > rs ? lhs : rhs }
    return lhs.id < rhs.id ? lhs : rhs
  }

  /// Aggregated overview metrics from cached index (all sources).
  func fetchOverviewAggregate() async -> OverviewAggregate? {
    await indexer.fetchOverviewAggregate()
  }

  /// Aggregated overview metrics with scoped filters when supported by SQLite cache.
  func fetchOverviewAggregate(scope: OverviewAggregateScope?) async -> OverviewAggregate? {
    await indexer.fetchOverviewAggregate(scope: scope)
  }

  private func registerActivityHeartbeat(previous: [SessionSummary], current: [SessionSummary]) {
    // Map previous lastUpdated for quick lookup
    var prevMap: [String: Date] = [:]
    for s in previous { if let t = s.lastUpdatedAt { prevMap[s.id] = t } }
    let now = Date()
    for s in current {
      guard let newT = s.lastUpdatedAt else { continue }
      if let oldT = prevMap[s.id], newT > oldT {
        activityHeartbeat[s.id] = now
      }
    }
    recomputeActiveUpdatingIDs()
  }

  private var activityHeartbeat: [String: Date] = [:]
  private var activityPruneTask: Task<Void, Never>?
  private func startActivityPruneTicker() {
    activityPruneTask?.cancel()
    activityPruneTask = Task { [weak self] in
      while !(Task.isCancelled) {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        await MainActor.run { self?.recomputeActiveUpdatingIDs() }
      }
    }
  }

  private func startIntentsCleanupTicker() {
    intentsCleanupTask?.cancel()
    intentsCleanupTask = Task { [weak self] in
      while !(Task.isCancelled) {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        await MainActor.run { self?.pruneExpiredIntents() }
      }
    }
  }

  private func recomputeActiveUpdatingIDs() {
    let cutoff = Date().addingTimeInterval(-3.0)
    let newIDs = Set(activityHeartbeat.filter { $0.value > cutoff }.keys)
    guard newIDs != activeUpdatingIDs else { return }
    activeUpdatingIDs = newIDs
  }

  func isActivelyUpdating(_ id: String) -> Bool { activeUpdatingIDs.contains(id) }
  func isAwaitingFollowup(_ id: String) -> Bool { awaitingFollowupIDs.contains(id) }

  func clearAwaitingFollowup(_ id: String) {
    awaitingFollowupIDs.remove(id)
  }

  private func persistProjectAssignmentsToCache(_ sessions: [SessionSummary]) {
    guard !sessions.isEmpty else { return }
    let mapping = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, projectId(for: $0)) })
    let resolver: @Sendable (SessionSummary) -> String? = { session in
      mapping[session.id] ?? nil
    }
    Task { [weak self] in
      guard let self else { return }
      await self.indexer.updateProjects(for: sessions, resolver: resolver)
    }
  }

  // Cancel ongoing background tasks (fulltext, enrichment, scheduled refreshes, quick pulses).
  // Useful when a heavy modal/sheet is presented and the UI should stay responsive.
  func cancelHeavyWork() {
    fulltextTask?.cancel()
    fulltextTask = nil
    enrichmentTask?.cancel()
    enrichmentTask = nil
    filterDebounceTask?.cancel()
    filterDebounceTask = nil
    scheduledFilterRefresh?.cancel()
    scheduledFilterRefresh = nil
    // Cancel all scoped refresh tasks
    for (_, task) in scopedRefreshTasks {
      task.cancel()
    }
    scopedRefreshTasks.removeAll()
    pendingScopeRefreshForce.removeAll()
    directoryRefreshTask?.cancel()
    directoryRefreshTask = nil
    fileEventAggregationTask?.cancel()
    fileEventAggregationTask = nil
    pendingFileEvents.removeAll()
    quickPulseTask?.cancel()
    quickPulseTask = nil
    codexUsageTask?.cancel()
    codexUsageTask = nil
    geminiUsageTask?.cancel()
    geminiUsageTask = nil
    pathTreeRefreshTask?.cancel()
    pathTreeRefreshTask = nil
    for task in calendarRefreshTasks.values { task.cancel() }
    calendarRefreshTasks.removeAll()
    isEnriching = false
    isLoading = false
  }

  func reveal(session: SessionSummary) {
    actions.revealInFinder(session: session)
  }

  func delete(summaries: [SessionSummary]) async {
    do {
      try actions.delete(summaries: summaries)
      await indexer.deleteSessions(ids: summaries.map(\.id))
      await refreshSessions(force: true)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func updateSessionsRoot(to newURL: URL) async {
    guard newURL != preferences.sessionsRoot else { return }
    // Save security-scoped bookmark if sandboxed
    SecurityScopedBookmarks.shared.save(url: newURL, for: .sessionsRoot)
    preferences.sessionsRoot = newURL
    await notesStore.updateRoot(to: preferences.notesRoot)
    await indexer.invalidateAll()
    enrichmentSnapshots.removeAll()
    configureDirectoryMonitor()
    await refreshSessions(force: true)
  }

  func updateNotesRoot(to newURL: URL) async {
    guard newURL != preferences.notesRoot else { return }
    SecurityScopedBookmarks.shared.save(url: newURL, for: .notesRoot)
    preferences.notesRoot = newURL
    await notesStore.updateRoot(to: newURL)
    // Reload notes snapshot and re-apply to current sessions
    let notes = await notesStore.all()
    notesSnapshot = notes
    var sessions = allSessions
    apply(notes: notes, to: &sessions)
    allSessions = sessions
    // Avoid publishing during view updates
    scheduleApplyFilters()
  }

  func updateProjectsRoot(to newURL: URL) async {
    guard newURL != preferences.projectsRoot else { return }
    SecurityScopedBookmarks.shared.save(url: newURL, for: .projectsRoot)
    preferences.projectsRoot = newURL
    let p = ProjectsStore.Paths(
      root: newURL,
      metadataDir: newURL.appendingPathComponent("metadata", isDirectory: true),
      membershipsURL: newURL.appendingPathComponent("memberships.json", isDirectory: false)
    )
    self.projectsStore = ProjectsStore(paths: p)
    await geminiProvider.updateProjectsStore(self.projectsStore)
    await loadProjects()
    // Avoid publishing changes during view update; schedule on next runloop tick
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.recomputeProjectCounts()
      self.scheduleApplyFilters()
    }
  }

  // Removed: executable path updates – CLI resolution uses PATH

  var totalSessionCount: Int {
    globalSessionCount
  }

  // Expose data for navigation helpers
  func calendarCounts(for monthStart: Date, dimension: DateDimension) -> [Int: Int] {
    let key = cacheKey(monthStart, dimension)
    if let cached = monthCountsCache[key] { return cached }
    let monthKey = Self.monthFormatter.string(from: monthStart)
    let coverage = dimension == .updated ? monthCoverageMap(for: monthKey) : [:]
    let counts = Self.computeMonthCounts(
      sessions: allSessions,
      monthKey: monthKey,
      dimension: dimension,
      dayIndex: sessionDayCache,
      coverage: coverage)
    // Update cache synchronously to avoid race conditions
    monthCountsCache[key] = counts
    currentMonthKey = key
    currentMonthDimension = dimension
    if dimension == .updated {
      // Use current selected path for accurate cache key
      triggerCoverageLoad(for: monthStart, dimension: dimension, projectPath: selectedPath)
    }
    return counts
  }

  private func countsForLoadedMonth(dimension: DateDimension) -> [Int: Int] {
    guard let key = currentMonthKey else { return [:] }
    let components = key.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
    guard components.count == 2 else { return [:] }
    let monthKey = String(components[1])
    return Self.computeMonthCounts(
      sessions: allSessions,
      monthKey: monthKey,
      dimension: dimension,
      dayIndex: sessionDayCache)
  }

  func ensureCalendarCounts(for monthStart: Date, dimension: DateDimension) {
    let key = cacheKey(monthStart, dimension)
    if monthCountsCache[key] != nil { return }
    if currentMonthDimension == dimension,
      let currentKey = currentMonthKey,
      currentKey == key
    {
      let counts = countsForLoadedMonth(dimension: dimension)
      DispatchQueue.main.async { [weak self] in
        self?.monthCountsCache[key] = counts
      }
      return
    }
    let enabledHosts = preferences.enabledRemoteHosts
    let sessionsRoot = preferences.sessionsRoot
    Task { [weak self, monthStart, dimension, enabledHosts, sessionsRoot] in
      guard let self else { return }
      let started = Date()
      self.diagLogger.log(
        "calendarCounts start month=\(key, privacy: .public) ts=\(self.ts(), format: .fixed(precision: 3))"
      )
      var merged = await self.indexer.computeCalendarCounts(
        root: sessionsRoot, monthStart: monthStart, dimension: dimension)
      if !enabledHosts.isEmpty {
        let remoteCodex = await self.remoteProvider.codexSessions(
          scope: .month(monthStart), enabledHosts: enabledHosts)
        let remoteClaude = await self.remoteProvider.claudeSessions(
          scope: .month(monthStart), enabledHosts: enabledHosts)
        let remoteSessions = remoteCodex + remoteClaude
        if !remoteSessions.isEmpty {
          let calendar = Calendar.current
          for session in remoteSessions {
            let referenceDate: Date
            switch dimension {
            case .created:
              referenceDate = session.startedAt
            case .updated:
              referenceDate = session.lastUpdatedAt ?? session.startedAt
            }
            guard calendar.isDate(referenceDate, equalTo: monthStart, toGranularity: .month)
            else { continue }
            let day = calendar.component(.day, from: referenceDate)
            merged[day, default: 0] += 1
          }
        }
      }
      await MainActor.run {
        self.monthCountsCache[self.cacheKey(monthStart, dimension)] = merged
      }
      let elapsed = Date().timeIntervalSince(started)
      self.diagLogger.log(
        "calendarCounts done month=\(key, privacy: .public) days=\(merged.count, privacy: .public) in \(elapsed, format: .fixed(precision: 3))s ts=\(self.ts(), format: .fixed(precision: 3))"
      )
    }
  }

  func cacheKey(_ monthStart: Date, _ dimension: DateDimension) -> String {
    return dimension.rawValue + "|" + Self.monthFormatter.string(from: monthStart)
  }

  private func coverageCacheKey(
    _ monthStart: Date, _ dimension: DateDimension, projectPath: String? = nil
  ) -> String {
    var key = dimension.rawValue + "|" + Self.monthFormatter.string(from: monthStart)
    if let path = projectPath {
      key += "|" + path
    }
    return key
  }

  var pathTreeRoot: PathTreeNode? { pathTreeRootPublished }

  func ensurePathTree() {
    if pathTreeRootPublished != nil { return }
    schedulePathTreeRefresh()
  }

  private func schedulePathTreeRefresh() {
    pathTreeRefreshTask?.cancel()
    pathTreeRefreshTask = Task { [weak self] in
      guard let self else { return }
      let started = Date()
      diagLogger.log("pathTreeRefresh start ts=\(ts(), format: .fixed(precision: 3))")
      defer { self.pathTreeRefreshTask = nil }
      var counts = self.cwdCounts(for: self.allSessions)
      self.lastPathCounts = counts
      let enabledHosts = preferences.enabledRemoteHosts
      if !enabledHosts.isEmpty {
        let remoteCodex = await remoteProvider.collectCWDAggregates(
          kind: .codex, enabledHosts: enabledHosts)
        for (key, value) in remoteCodex {
          counts[key, default: 0] += value
        }
        let remoteClaude = await remoteProvider.collectCWDAggregates(
          kind: .claude, enabledHosts: enabledHosts)
        for (key, value) in remoteClaude {
          counts[key, default: 0] += value
        }
      }
      let tree = await self.pathTreeStore.applySnapshot(counts: counts)
      await MainActor.run { self.pathTreeRootPublished = tree }
      let elapsed = Date().timeIntervalSince(started)
      diagLogger.log(
        "pathTreeRefresh done in \(elapsed, format: .fixed(precision: 3))s counts=\(counts.count, privacy: .public) ts=\(ts(), format: .fixed(precision: 3))"
      )
    }
  }

  private func cwdCounts(for sessions: [SessionSummary]) -> [String: Int] {
    var counts: [String: Int] = [:]
    counts.reserveCapacity(sessions.count)
    for s in sessions { counts[s.cwd, default: 0] += 1 }
    return counts
  }

  private func diffCounts(old: [String: Int], new: [String: Int]) -> [String: Int] {
    var delta: [String: Int] = [:]
    let keys = Set(old.keys).union(new.keys)
    for k in keys {
      let d = (new[k] ?? 0) - (old[k] ?? 0)
      if d != 0 { delta[k] = d }
    }
    return delta
  }

  private func scheduleCalendarCountsRefresh(
    monthStart: Date,
    dimension: DateDimension,
    skipDebounce: Bool
  ) {
    // Legacy path removed; kept for compatibility if future disk scans are reintroduced.
    // For now, we compute counts synchronously from in-memory sessions.
    let key = cacheKey(monthStart, dimension)
    calendarRefreshTasks[key]?.cancel()
    if !skipDebounce {
      let delay = sidebarStatsDebounceNanoseconds
      calendarRefreshTasks[key] = Task { [weak self] in
        defer { self?.calendarRefreshTasks.removeValue(forKey: key) }
        try? await Task.sleep(nanoseconds: delay)
      }
    }
  }

  private func triggerCoverageLoad(
    for monthStart: Date,
    dimension: DateDimension,
    projectPath: String? = nil,
    forceRefresh: Bool = false
  ) {
    guard dimension == .updated else { return }
    let key = coverageCacheKey(monthStart, dimension, projectPath: projectPath)

    // Force refresh: invalidate cache for this scope
    if forceRefresh {
      let monthKey = Self.monthFormatter.string(from: monthStart)
      Task {
        await ripgrepStore.invalidateCoverage(monthKey: monthKey, projectPath: projectPath)
      }
      pendingCoverageMonths.remove(key)
    }

    // Cancel only this specific key's debounce task (not all of them!)
    coverageDebounceTasks[key]?.cancel()

    // Debounce: delay execution to avoid triggering too many scans during rapid month switching
    // Each key has its own debounce task, so switching between different months won't cancel each other
    coverageDebounceTasks[key] = Task { @MainActor in
      defer { coverageDebounceTasks.removeValue(forKey: key) }
      try? await Task.sleep(nanoseconds: 150_000_000)  // 150ms debounce
      guard !Task.isCancelled else { return }

      if coverageLoadTasks[key] != nil {
        pendingCoverageMonths.insert(key)
        return
      }
      // Precise query scope: filter by month AND project path
      let targets = sessionsIntersecting(monthStart: monthStart, projectPath: projectPath)
      guard !targets.isEmpty else { return }

      coverageLoadTasks[key] = Task.detached(priority: .background) { [weak self] in
        guard let self else { return }
        let data = await self.ripgrepStore.dayCoverage(for: monthStart, sessions: targets)
        guard !Task.isCancelled else { return }
        await MainActor.run {
          self.coverageLoadTasks[key]?.cancel()
          self.coverageLoadTasks.removeValue(forKey: key)
          if data.isEmpty {
            if !targets.isEmpty {
              self.pendingCoverageMonths.insert(key)
              self.rebuildMonthCounts(for: monthStart, dimension: dimension, skipUIUpdate: true)
            }
          } else {
            self.applyCoverage(monthStart: monthStart, coverage: data)
          }
          if self.pendingCoverageMonths.remove(key) != nil {
            self.triggerCoverageLoad(
              for: monthStart, dimension: dimension, projectPath: projectPath)
          }
        }
      }
    }
  }

  private func requestCoverageIfNeeded(for day: Date) {
    guard dateDimension == .updated else { return }
    let monthStart = Self.normalizeMonthStart(day)
    // Use current selected path for accurate cache key
    triggerCoverageLoad(for: monthStart, dimension: .updated, projectPath: selectedPath)
  }

  private func sessionsIntersecting(monthStart: Date, projectPath: String? = nil)
    -> [SessionSummary]
  {
    let calendar = Calendar.current
    guard let monthEnd = calendar.date(byAdding: DateComponents(month: 1), to: monthStart) else {
      return []
    }
    return allSessions.filter { summary in
      // Date range filter
      let start = summary.startedAt
      let end = summary.lastUpdatedAt ?? summary.startedAt
      guard end >= monthStart && start < monthEnd else { return false }

      // Project path filter (if specified)
      if let projectPath = projectPath {
        return summary.fileURL.path.hasPrefix(projectPath)
      }

      return true
    }
  }

  @MainActor
  private func applyCoverage(monthStart: Date, coverage: [String: Set<Int>]) {
    guard !coverage.isEmpty else {
      rebuildMonthCounts(for: monthStart, dimension: .updated, skipUIUpdate: true)
      return
    }
    let monthKey = monthKey(for: monthStart)
    var changed = false
    let validIDs = Set(allSessions.map(\.id))
    for (sessionID, days) in coverage {
      guard validIDs.contains(sessionID) else { continue }
      let key = SessionMonthCoverageKey(sessionID: sessionID, monthKey: monthKey)
      if updatedMonthCoverage[key] != days {
        updatedMonthCoverage[key] = days
        changed = true
      }
    }
    if changed {
      invalidateVisibleCountCache()
    }
    rebuildMonthCounts(for: monthStart, dimension: .updated, skipUIUpdate: !changed)
    if changed {
      scheduleApplyFilters()
    }
  }

  private func monthCoverageMap(for monthKey: String) -> [String: Set<Int>] {
    var map: [String: Set<Int>] = [:]
    for (key, days) in updatedMonthCoverage where key.monthKey == monthKey {
      map[key.sessionID] = days
    }
    return map
  }

  private func rebuildMonthCounts(
    for monthStart: Date, dimension: DateDimension, skipUIUpdate: Bool = false
  ) {
    let key = cacheKey(monthStart, dimension)
    let monthKey = monthKey(for: monthStart)
    let coverage = dimension == .updated ? monthCoverageMap(for: monthKey) : [:]
    let counts = Self.computeMonthCounts(
      sessions: allSessions,
      monthKey: monthKey,
      dimension: dimension,
      dayIndex: sessionDayCache,
      coverage: coverage)
    monthCountsCache[key] = counts
    currentMonthKey = key
    currentMonthDimension = dimension
    if !skipUIUpdate {
      scheduleViewUpdate()
    }
  }

  // MARK: - Filter state management

  func setSelectedPath(_ path: String?) {
    if selectedPath == path { return }
    selectedPath = path
  }

  func setSelectedDay(_ day: Date?) {
    let normalized = day.map { Calendar.current.startOfDay(for: $0) }
    if selectedDay == normalized { return }
    suppressFilterNotifications = true
    selectedDay = normalized
    if let d = normalized { selectedDays = [d] } else { selectedDays.removeAll() }

    // In Created mode, when selecting a day, ensure the calendar sidebar shows that month
    // so we only need to load one month's data
    if dateDimension == .created, let d = normalized {
      let newMonthStart = Self.normalizeMonthStart(d)
      if newMonthStart != sidebarMonthStart {
        sidebarMonthStart = newMonthStart
      }
    }

    if let d = normalized {
      requestCoverageIfNeeded(for: d)
    }

    suppressFilterNotifications = false
    // Manually save calendar state since didSet was suppressed
    windowStateStore.saveCalendarSelection(
      selectedDay: selectedDay, selectedDays: selectedDays, monthStart: sidebarMonthStart)
    // Update UI using next-runloop to avoid publishing during view updates
    scheduleApplyFilters()
    // After coordinated update of selectedDay/selectedDays, trigger a refresh only in Created mode.
    if dateDimension == .created {
      scheduleFilterRefresh(force: true)
    }
  }

  // Toggle selection for a specific day (Cmd-click behavior)
  func toggleSelectedDay(_ day: Date) {
    let d = Calendar.current.startOfDay(for: day)
    suppressFilterNotifications = true
    if selectedDays.contains(d) {
      selectedDays.remove(d)
    } else {
      selectedDays.insert(d)
    }
    requestCoverageIfNeeded(for: d)
    // Keep single-selection reflected in selectedDay; otherwise nil
    if selectedDays.count == 1, let only = selectedDays.first {
      selectedDay = only
    } else if selectedDays.isEmpty {
      selectedDay = nil
    } else {
      selectedDay = nil
    }
    suppressFilterNotifications = false
    // Manually save calendar state since didSet was suppressed
    windowStateStore.saveCalendarSelection(
      selectedDay: selectedDay, selectedDays: selectedDays, monthStart: sidebarMonthStart)
    // Update UI using next-runloop to avoid publishing during view updates
    scheduleApplyFilters()
    if dateDimension == .created {
      scheduleFilterRefresh(force: true)
    }
  }

  func clearAllFilters() {
    suppressFilterNotifications = true
    selectedPath = nil
    selectedDay = nil
    selectedDays.removeAll()
    selectedProjectIDs.removeAll()
    suppressFilterNotifications = false
    // Manually save calendar state since didSet was suppressed
    windowStateStore.saveCalendarSelection(
      selectedDay: selectedDay, selectedDays: selectedDays, monthStart: sidebarMonthStart)
    scheduleSelectionDrivenUpdate()
    // Keep searchText unchanged to allow consecutive searches
  }

  // Clear only scope filters (directory and project), keep the date filter intact
  func clearScopeFilters() {
    suppressFilterNotifications = true
    selectedPath = nil
    selectedProjectIDs.removeAll()
    suppressFilterNotifications = false
    scheduleSelectionDrivenUpdate()
  }

  private func scheduleFiltersUpdate() {
    filterDebounceTask?.cancel()
    filterDebounceTask = Task { [weak self] in
      guard let self else { return }
      if filterDebounceNanoseconds > 0 {
        try? await Task.sleep(nanoseconds: filterDebounceNanoseconds)
      }
      self.scheduleApplyFilters()
    }
  }

  private func scheduleSelectionDrivenUpdate() {
    let needRefresh = shouldRefreshForSelection()
    if needRefresh {
      scheduleFilterRefresh(force: true)
    } else {
      scheduleApplyFilters()
    }
  }

  private func shouldRefreshForSelection() -> Bool {
    guard dateDimension == .created else { return false }
    let projectIsSingle = selectedProjectIDs.count == 1
    let calendarIsSingle = (selectedDay != nil) || selectedDays.count == 1
    return projectIsSingle || calendarIsSingle
  }

  private func singleSelectedProject() -> Set<String>? {
    guard selectedProjectIDs.count == 1, let first = selectedProjectIDs.first else { return nil }
    return [first]
  }

  private func singleSelectedProjectDirectory() -> [String]? {
    guard let pid = selectedProjectIDs.first, selectedProjectIDs.count == 1 else { return nil }
    guard let project = projects.first(where: { $0.id == pid }), let dir = project.directory,
      !dir.isEmpty
    else {
      return nil
    }
    return [Self.canonicalPath(dir)]
  }

  private func currentDateRange() -> (Date, Date)? {
    let cal = Calendar.current
    var allDays: [Date] = []
    if let day = selectedDay {
      allDays.append(cal.startOfDay(for: day))
    }
    allDays.append(contentsOf: selectedDays.map { cal.startOfDay(for: $0) })
    guard let minDay = allDays.min(), let maxDay = allDays.max() else { return nil }
    let start = minDay
    guard let end = cal.date(byAdding: .day, value: 1, to: maxDay)?.addingTimeInterval(-1) else {
      return nil
    }
    return (start, end)
  }

  func applyFilters() {
    filterTask?.cancel()

    guard !allSessions.isEmpty else {
      filterTask = nil
      // Defer sections modification to avoid "Publishing changes from within view updates"
      Task { @MainActor [weak self] in
        self?.sections = []
      }
      return
    }

    filterGeneration &+= 1
    let generation = filterGeneration
    let snapshot = makeFilterSnapshot()
    let started = Date()
    logApplyFiltersStart(reason: snapshot.reasonDescription)

    filterTask = Task { [weak self] in
      guard let self else { return }
      let computeTask = Task.detached(priority: .userInitiated) {
        Self.computeFilteredSections(using: snapshot)
      }
      defer { computeTask.cancel() }
      let result = await computeTask.value
      guard !Task.isCancelled else { return }
      guard self.filterGeneration == generation else { return }

      // Snapshot hash to skip duplicate work within a short window.
      let snapshotHash = snapshot.digest
      if let lastHash = self.lastFilterSnapshotHash, lastHash == snapshotHash {
        self.logApplyFiltersEnd(
          reason: snapshot.reasonDescription + " (skipped same snapshot)",
          elapsed: 0,
          sections: self.sections.count,
          sessions: self.allSessions.count
        )
        self.pendingApplyFilters = false
        self.filterTask = nil
        return
      }
      self.lastFilterSnapshotHash = snapshotHash

      if !result.newCanonicalEntries.isEmpty {
        self.canonicalCwdCache.merge(result.newCanonicalEntries) { _, new in new }
      }
      // Use pre-computed sections from background task; avoid replacing when identical
      if self.sections != result.sections {
        self.sections = result.sections
      }
      let elapsed = Date().timeIntervalSince(started)
      self.logApplyFiltersEnd(
        reason: snapshot.reasonDescription,
        elapsed: elapsed,
        sections: result.sections.count,
        sessions: result.totalSessions
      )
      // If more filter requests were queued while this task ran, flush one more apply.
      if self.pendingApplyFilters {
        self.pendingApplyFilters = false
        // Schedule on next runloop to avoid deep recursion.
        DispatchQueue.main.async { [weak self] in
          self?.applyFilters()
        }
      } else {
        self.filterTask = nil
      }
    }
  }

  private func makeFilterSnapshot() -> FilterSnapshot {
    let pathFilter: FilterSnapshot.PathFilter? = {
      guard let path = selectedPath else { return nil }
      let canonical = Self.canonicalPath(path)
      let prefix = canonical == "/" ? "/" : canonical + "/"
      return .init(canonicalPath: canonical, prefix: prefix)
    }()

    let trimmedSearch = quickSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    let quickNeedle = trimmedSearch.isEmpty ? nil : trimmedSearch.lowercased()

    let projectFilter: FilterSnapshot.ProjectFilter? = {
      guard !selectedProjectIDs.isEmpty else { return nil }
      var allowedProjects = Set<String>()
      for pid in selectedProjectIDs {
        allowedProjects.insert(pid)
        allowedProjects.formUnion(collectDescendants(of: pid, in: projects))
      }
      let allowedSources = projects.reduce(into: [String: Set<ProjectSessionSource>]()) {
        $0[$1.id] = $1.sources
      }
      return .init(
        memberships: projectMemberships,
        allowedProjects: allowedProjects,
        allowedSourcesByProject: allowedSources,
        includeUnassigned: allowedProjects.contains(Self.otherProjectId)
      )
    }()

    var dayIndexMap: [String: SessionDayIndex] = [:]
    dayIndexMap.reserveCapacity(allSessions.count)
    for session in allSessions {
      dayIndexMap[session.id] = dayIndex(for: session)
    }
    let dayDescriptors = Self.makeDayDescriptors(
      selectedDays: selectedDays,
      singleDay: selectedDay
    )

    return FilterSnapshot(
      sessions: allSessions,
      sessionsVersion: sessionsVersion,
      pathFilter: pathFilter,
      projectFilter: projectFilter,
      selectedDays: selectedDays,
      singleDay: selectedDay,
      dateDimension: dateDimension,
      quickSearchNeedle: quickNeedle,
      sortOrder: sortOrder,
      canonicalCache: canonicalCwdCache,
      dayIndex: dayIndexMap,
      dayCoverage: updatedMonthCoverage,
      dayDescriptors: dayDescriptors,
      reasonDescription:
        "filters: projects=\(selectedProjectIDs.count) path=\(selectedPath ?? "nil") days=\(selectedDays.count) dim=\(dateDimension.rawValue) search=\(trimmedSearch.isEmpty ? "none" : "non-empty") isLoading=\(isLoading)"
    )
  }

  nonisolated private static func computeFilteredSections(using snapshot: FilterSnapshot)
    -> FilterComputationResult
  {
    var filtered = snapshot.sessions
    var canonicalCache = snapshot.canonicalCache
    var newCanonicalEntries: [String: String] = [:]

    if let pathFilter = snapshot.pathFilter {
      var matches: [SessionSummary] = []
      matches.reserveCapacity(filtered.count)
      for summary in filtered {
        let canonical: String
        if let cached = canonicalCache[summary.id] {
          canonical = cached
        } else {
          let value = Self.canonicalPath(summary.cwd)
          canonicalCache[summary.id] = value
          newCanonicalEntries[summary.id] = value
          canonical = value
        }
        if canonical == pathFilter.canonicalPath || canonical.hasPrefix(pathFilter.prefix) {
          matches.append(summary)
        }
      }
      filtered = matches
    }

    if let projectFilter = snapshot.projectFilter {
      let memberships = projectFilter.memberships
      let allowedProjects = projectFilter.allowedProjects
      let allowedSources = projectFilter.allowedSourcesByProject
      var matches: [SessionSummary] = []
      matches.reserveCapacity(filtered.count)
      for summary in filtered {
        let membershipKey = "\(summary.source.projectSource.rawValue)|\(summary.id)"
        if let assigned = memberships[membershipKey] {
          guard allowedProjects.contains(assigned) else { continue }
          let allowedSet = allowedSources[assigned] ?? ProjectSessionSource.allSet
          if allowedSet.contains(summary.source.projectSource) { matches.append(summary) }
        } else if projectFilter.includeUnassigned {
          matches.append(summary)
        }
      }
      filtered = matches
    }

    if !snapshot.dayDescriptors.isEmpty {
      let calendar = Calendar.current
      filtered = filtered.filter { summary in
        let bucket = snapshot.dayIndex[summary.id]
        return Self.matchesDayDescriptors(
          summary: summary,
          bucket: bucket,
          descriptors: snapshot.dayDescriptors,
          dimension: snapshot.dateDimension,
          coverage: snapshot.dayCoverage,
          calendar: calendar
        )
      }
    }

    if let needle = snapshot.quickSearchNeedle {
      filtered = filtered.filter { s in
        if s.effectiveTitle.lowercased().contains(needle) { return true }
        if let c = s.userComment?.lowercased(), c.contains(needle) { return true }
        return false
      }
    }

    filtered = snapshot.sortOrder.sort(filtered, dimension: snapshot.dateDimension)

    let sections = Self.groupSessions(filtered, dimension: snapshot.dateDimension)

    return FilterComputationResult(
      filteredSessions: filtered,
      sections: sections,
      newCanonicalEntries: newCanonicalEntries,
      totalSessions: filtered.count
    )
  }

  nonisolated private static func matchesDayDescriptors(
    summary: SessionSummary,
    bucket: SessionDayIndex?,
    descriptors: [DaySelectionDescriptor],
    dimension: DateDimension,
    coverage: [SessionMonthCoverageKey: Set<Int>],
    calendar: Calendar
  ) -> Bool {
    guard let bucket else { return false }
    for descriptor in descriptors {
      switch dimension {
      case .created:
        if calendar.isDate(bucket.created, inSameDayAs: descriptor.date) {
          return true
        }
      case .updated:
        let key = SessionMonthCoverageKey(sessionID: summary.id, monthKey: descriptor.monthKey)
        if let days = coverage[key], days.contains(descriptor.day) {
          return true
        }
        if calendar.isDate(bucket.updated, inSameDayAs: descriptor.date) {
          return true
        }
      }
    }
    return false
  }

  nonisolated private static func referenceDate(
    for session: SessionSummary, dimension: DateDimension
  )
    -> Date
  {
    switch dimension {
    case .created: return session.startedAt
    case .updated: return session.lastUpdatedAt ?? session.startedAt
    }
  }

  private struct FilterSnapshot: Sendable {
    struct PathFilter: Sendable {
      let canonicalPath: String
      let prefix: String
    }

    struct ProjectFilter: Sendable {
      let memberships: [String: String]
      let allowedProjects: Set<String>
      let allowedSourcesByProject: [String: Set<ProjectSessionSource>]
      let includeUnassigned: Bool
    }

    let sessions: [SessionSummary]
    let sessionsVersion: UInt64
    let pathFilter: PathFilter?
    let projectFilter: ProjectFilter?
    let selectedDays: Set<Date>
    let singleDay: Date?
    let dateDimension: DateDimension
    let quickSearchNeedle: String?
    let sortOrder: SessionSortOrder
    let canonicalCache: [String: String]
    let dayIndex: [String: SessionDayIndex]
    let dayCoverage: [SessionMonthCoverageKey: Set<Int>]
    let dayDescriptors: [DaySelectionDescriptor]
    let reasonDescription: String

    var digest: Int {
      var hasher = Hasher()
      hasher.combine(pathFilter?.canonicalPath ?? "")
      hasher.combine(pathFilter?.prefix ?? "")
      hasher.combine(projectFilter?.allowedProjects.count ?? 0)
      hasher.combine(selectedDays.count)
      hasher.combine(singleDay?.timeIntervalSince1970 ?? 0)
      hasher.combine(dateDimension.rawValue)
      hasher.combine(quickSearchNeedle ?? "")
      hasher.combine(sortOrder.rawValue)
      hasher.combine(sessionsVersion)
      return hasher.finalize()
    }
  }

  private struct FilterComputationResult: Sendable {
    let filteredSessions: [SessionSummary]
    let sections: [SessionDaySection]
    let newCanonicalEntries: [String: String]
    let totalSessions: Int
  }

  nonisolated private static func groupSessions(
    _ sessions: [SessionSummary], dimension: DateDimension
  )
    -> [SessionDaySection]
  {
    let calendar = Calendar.current
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateStyle = .medium
    formatter.timeStyle = .none

    var grouped: [Date: [SessionSummary]] = [:]
    for session in sessions {
      // Grouping honors the selected calendar dimension:
      // - Created: group by startedAt
      // - Last Updated: group by lastUpdatedAt (fallback to startedAt)
      let referenceDate: Date = {
        switch dimension {
        case .created: return session.startedAt
        case .updated: return session.lastUpdatedAt ?? session.startedAt
        }
      }()
      let day = calendar.startOfDay(for: referenceDate)
      grouped[day, default: []].append(session)
    }

    return
      grouped
      .sorted(by: { $0.key > $1.key })
      .map { day, sessions in
        let totalDuration = sessions.reduce(into: 0.0) { $0 += $1.duration }
        let totalEvents = sessions.reduce(0) { $0 + $1.eventCount }
        let title: String
        if calendar.isDateInToday(day) {
          title = "Today"
        } else if calendar.isDateInYesterday(day) {
          title = "Yesterday"
        } else {
          title = formatter.string(from: day)
        }
        return SessionDaySection(
          id: day,
          title: title,
          totalDuration: totalDuration,
          totalEvents: totalEvents,
          sessions: sessions
        )
      }
  }

  // MARK: - Fulltext search

  private func scheduleFulltextSearchIfNeeded() {
    scheduleFiltersUpdate()  // update metadata-only matches quickly
    fulltextTask?.cancel()
    let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !term.isEmpty else {
      fulltextMatches.removeAll()
      return
    }
    fulltextTask = Task { [allSessions] in
      // naive full-scan
      var matched = Set<String>()
      for s in allSessions {
        if Task.isCancelled { return }
        if await indexer.fileContains(url: s.fileURL, term: term) {
          matched.insert(s.id)
        }
      }
      await MainActor.run {
        self.fulltextMatches = matched
        self.scheduleApplyFilters()
      }
    }
  }

  // MARK: - Calendar caches (placeholder for future optimization)
  private func computeCalendarCaches() async {}

  // MARK: - Background enrichment
  private func startBackgroundEnrichment() {
    enrichmentTask?.cancel()
    guard let cacheKey = dayCacheKey(for: selectedDay) else {
      // Should not happen; we now return a synthetic key even when day is nil
      isEnriching = false
      enrichmentProgress = 0
      enrichmentTotal = 0
      return
    }

    // When a day is selected, enrich that day's sessions; otherwise enrich currently displayed ones
    let sessions: [SessionSummary]
    if selectedDay != nil {
      sessions = sessionsForCurrentDay()
    } else {
      sessions = sections.flatMap { $0.sessions }
    }
    let currentIDs = Set(sessions.map(\.id))
    if let cached = enrichmentSnapshots[cacheKey], cached == currentIDs {
      isEnriching = false
      enrichmentProgress = 0
      enrichmentTotal = 0
      return
    }
    if sessions.isEmpty {
      isEnriching = false
      enrichmentProgress = 0
      enrichmentTotal = 0
      enrichmentSnapshots[cacheKey] = currentIDs
      return
    }
    enrichmentTask = Task { [weak self] in
      guard let self else { return }

      await MainActor.run {
        self.isEnriching = true
        self.enrichmentProgress = 0
        self.enrichmentTotal = sessions.count
      }

      let concurrency = max(2, ProcessInfo.processInfo.processorCount / 2)
      try? await withThrowingTaskGroup(of: (String, SessionSummary)?.self) { group in
        var iterator = sessions.makeIterator()
        var processedCount = 0

        func addNext(_ n: Int) {
          for _ in 0..<n {
            guard let s = iterator.next() else { return }
            group.addTask { [weak self] in
              guard let self else { return nil }
              if s.source.baseKind == .claude {
                if let enriched = await self.claudeProvider.enrich(summary: s) {
                  return (s.id, enriched)
                }
                return (s.id, s)
              } else if s.source.baseKind == .gemini {
                if let enriched = await self.geminiProvider.enrich(summary: s) {
                  return (s.id, enriched)
                }
                return (s.id, s)
              } else if let enriched = try await self.indexer.enrich(url: s.fileURL) {
                return (s.id, enriched)
              }
              return (s.id, s)
            }
          }
        }
        addNext(concurrency)
        var updatesBuffer: [(String, SessionSummary)] = []
        var lastFlushTime = ContinuousClock.now
        func flush() async {
          guard !updatesBuffer.isEmpty else { return }
          await MainActor.run {
            var map = Dictionary(
              uniqueKeysWithValues: self.allSessions.map { ($0.id, $0) })
            for (id, item) in updatesBuffer {
              var enriched = item
              if let note = self.notesSnapshot[id] {
                enriched.userTitle = note.title
                enriched.userComment = note.comment
              }
              map[id] = enriched
            }
            self.allSessions = Array(map.values)
            self.rebuildCanonicalCwdCache()
            self.scheduleApplyFilters()
          }
          updatesBuffer.removeAll(keepingCapacity: true)
          lastFlushTime = ContinuousClock.now
        }
        while let result = try await group.next() {
          if let (id, enriched) = result {
            updatesBuffer.append((id, enriched))
            processedCount += 1

            await MainActor.run {
              self.enrichmentProgress = processedCount
            }

            let now = ContinuousClock.now
            let elapsed = lastFlushTime.duration(to: now)
            // Flush if buffer is large (50 items) OR enough time passed (1 second)
            if updatesBuffer.count >= 50 || elapsed.components.seconds >= 1 {
              await flush()
            }
          }
          addNext(1)
        }
        await flush()

        await MainActor.run {
          self.isEnriching = false
          self.enrichmentProgress = 0
          self.enrichmentTotal = 0
          self.enrichmentSnapshots[cacheKey] = currentIDs
        }
      }
    }
  }

  private func sessionsForCurrentDay() -> [SessionSummary] {
    guard let day = selectedDay else { return [] }
    let calendar = Calendar.current
    let pathFilter = selectedPath.map(Self.canonicalPath)
    return allSessions.filter { summary in
      let matchesDay: Bool = {
        switch dateDimension {
        case .created:
          return calendar.isDate(summary.startedAt, inSameDayAs: day)
        case .updated:
          if let end = summary.lastUpdatedAt {
            return calendar.isDate(end, inSameDayAs: day)
          }
          return calendar.isDate(summary.startedAt, inSameDayAs: day)
        }
      }()
      guard matchesDay else { return false }
      guard let path = pathFilter else { return true }
      let canonical = canonicalCwdCache[summary.id] ?? Self.canonicalPath(summary.cwd)
      return canonical == path || canonical.hasPrefix(path + "/")
    }
  }

  private func rebuildCanonicalCwdCache() {
    canonicalCwdCache = Dictionary(
      uniqueKeysWithValues: allSessions.map {
        ($0.id, Self.canonicalPath($0.cwd))
      })
  }

  func rebuildGeminiProjectHashLookup() {
    geminiProjectPathByHash = Self.computeGeminiProjectHashes(from: projects)
  }

  func updateSelection(_ ids: Set<SessionSummary.ID>) {
    selectedSessionIDs = ids
  }

  nonisolated static func canonicalPath(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    var standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
    if standardized.count > 1 && standardized.hasSuffix("/") {
      standardized.removeLast()
    }
    return standardized
  }

  private static func computeGeminiProjectHashes(from projects: [Project]) -> [String: String] {
    var map: [String: String] = [:]
    for project in projects {
      guard let dir = project.directory, !dir.isEmpty else { continue }
      guard let hash = geminiDirectoryHash(for: dir) else { continue }
      map[hash] = canonicalPath(dir)
    }
    return map
  }

  private static func geminiDirectoryHash(for directory: String) -> String? {
    let expanded = (directory as NSString).expandingTildeInPath
    guard let data = expanded.data(using: .utf8) else { return nil }
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  private static func geminiHashComponent(in path: String) -> String? {
    guard let range = path.range(of: "/.gemini/tmp/") else { return nil }
    let remainder = path[range.upperBound...]
    guard
      let candidate = remainder.split(
        separator: "/", maxSplits: 1, omittingEmptySubsequences: false
      )
      .first
    else { return nil }
    let hash = String(candidate)
    guard hash.count == 64,
      hash.range(of: "^[0-9a-f]+$", options: .regularExpression) != nil
    else { return nil }
    return hash
  }

  func displayWorkingDirectory(for summary: SessionSummary) -> String {
    guard summary.source.baseKind == .gemini else { return summary.cwd }
    if let hash = Self.geminiHashComponent(in: summary.cwd),
      let resolved = geminiProjectPathByHash[hash]
    {
      return resolved
    }
    if let hash = Self.geminiHashComponent(in: summary.fileURL.path),
      let resolved = geminiProjectPathByHash[hash]
    {
      return resolved
    }
    return summary.cwd
  }

  func resolvedWorkingDirectory(for summary: SessionSummary) -> String {
    let candidate: String
    if summary.source.baseKind == .gemini && !summary.isRemote {
      candidate = displayWorkingDirectory(for: summary)
    } else {
      candidate = summary.cwd
    }
    let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty, FileManager.default.fileExists(atPath: trimmed) {
      return trimmed
    }
    if FileManager.default.fileExists(atPath: summary.cwd) {
      return summary.cwd
    }
    let fallback = summary.fileURL.deletingLastPathComponent().path
    return fallback.isEmpty ? NSHomeDirectory() : fallback
  }

  private func currentScope() -> SessionLoadScope {
    switch dateDimension {
    case .created:
      // In Created mode, when a single day is selected, limit the scan
      // scope to that specific day for better performance and more
      // predictable behavior when users explicitly focus on "today".
      if let day = selectedDay {
        return .day(Calendar.current.startOfDay(for: day))
      }
      if selectedDays.count == 1, let only = selectedDays.first {
        return .day(Calendar.current.startOfDay(for: only))
      }
      // Fallback: load the month currently being viewed in the calendar
      // sidebar. Day filtering for the middle list still happens in
      // applyFilters().
      return .month(sidebarMonthStart)
    case .updated:
      // Updated dimension: load everything since updates can cross month
      // boundaries and files on disk are organized by creation date.
      return .all
    }
  }

  func overviewAggregateScope() -> OverviewAggregateScope? {
    if selectedPath != nil { return nil }
    if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
    if !quickSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
    let projects = selectedProjectIDs.isEmpty ? nil : selectedProjectIDs
    let cal = Calendar.current
    var allDays: [Date] = []
    if let day = selectedDay {
      allDays.append(cal.startOfDay(for: day))
    }
    allDays.append(contentsOf: selectedDays.map { cal.startOfDay(for: $0) })
    if allDays.isEmpty, let projects {
      return OverviewAggregateScope(
        dateDimension: dateDimension,
        start: Date(timeIntervalSince1970: 0),
        end: .distantFuture,
        projectIds: projects
      )
    }
    guard !allDays.isEmpty else { return nil }
    let start = allDays.min() ?? Date()
    let endBase = allDays.max() ?? start
    guard let end = cal.date(byAdding: .day, value: 1, to: endBase)?.addingTimeInterval(-1) else {
      return nil
    }
    return OverviewAggregateScope(
      dateDimension: dateDimension,
      start: start,
      end: end,
      projectIds: projects?.isEmpty == false ? projects : nil
    )
  }

  /// Whether the Overview can safely use global cached aggregates without clashing with filters.
  var canUseGlobalOverviewAggregate: Bool {
    if dateDimension != .updated { return false }
    if selectedDay != nil || !selectedDays.isEmpty { return false }
    if selectedPath != nil { return false }
    if !selectedProjectIDs.isEmpty { return false }
    if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
    if !quickSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
    return true
  }

  private func logApplyFiltersStart(reason: String) {
    diagLogger.log(
      "applyFilters start reason=\(reason, privacy: .public) ts=\(self.ts(), format: .fixed(precision: 3))"
    )
  }

  private func logApplyFiltersEnd(
    reason: String, elapsed: TimeInterval, sections: Int, sessions: Int
  ) {
    diagLogger.log(
      "applyFilters done reason=\(reason, privacy: .public) in \(elapsed, format: .fixed(precision: 3))s sections=\(sections, privacy: .public) sessions=\(sessions, privacy: .public) ts=\(self.ts(), format: .fixed(precision: 3))"
    )
  }

  private func configureDirectoryMonitor() {
    directoryMonitor?.cancel()
    directoryRefreshTask?.cancel()
    let root = preferences.sessionsRoot
    guard FileManager.default.fileExists(atPath: root.path) else {
      directoryMonitor = nil
      return
    }
    directoryMonitor = DirectoryMonitor(url: root) { [weak self] in
      Task { @MainActor in
        self?.quickPulse()
        self?.scheduleDirectoryRefresh()
      }
    }
  }

  private func configureClaudeDirectoryMonitor() {
    claudeDirectoryMonitor?.cancel()
    // Default Claude projects root: ~/.claude/projects
    let home = FileManager.default.homeDirectoryForCurrentUser
    let projects =
      home
      .appendingPathComponent(".claude", isDirectory: true)
      .appendingPathComponent("projects", isDirectory: true)
    guard FileManager.default.fileExists(atPath: projects.path) else {
      claudeDirectoryMonitor = nil
      return
    }
    claudeDirectoryMonitor = DirectoryMonitor(url: projects) { [weak self] in
      Task { @MainActor in
        // Only perform targeted incremental refresh when we have a matching hint
        if let hint = self?.pendingIncrementalHint, Date() < (hint.expiresAt) {
          await self?.refreshIncremental(using: hint)
        }
      }
    }
  }

  private func configureGeminiDirectoryMonitor() {
    geminiDirectoryMonitor?.cancel()
    // Default Gemini tmp root: ~/.gemini/tmp
    let home = SessionPreferencesStore.getRealUserHomeURL()
    let tmpRoot =
      home
      .appendingPathComponent(".gemini", isDirectory: true)
      .appendingPathComponent("tmp", isDirectory: true)
    guard FileManager.default.fileExists(atPath: tmpRoot.path) else {
      geminiDirectoryMonitor = nil
      return
    }
    geminiDirectoryMonitor = DirectoryMonitor(url: tmpRoot) { [weak self] in
      Task { @MainActor in
        // Trigger incremental refresh for Gemini sessions
        if let hint = self?.pendingIncrementalHint, Date() < (hint.expiresAt) {
          await self?.refreshIncremental(using: hint)
        } else {
          // Fallback to general refresh
          self?.quickPulse()
          self?.scheduleDirectoryRefresh()
        }
      }
    }
  }

  private func scheduleDirectoryRefresh() {
    // Use file event aggregation to collect changes within 500-1000ms window
    lastFileEventAt = Date()

    // Cancel existing aggregation task and start a new one
    fileEventAggregationTask?.cancel()
    fileEventAggregationTask = Task { @MainActor [weak self] in
      guard let self else { return }

      // Aggregate file events: wait 500ms for rapid changes, up to 1000ms total
      let rapidChangeWindow: UInt64 = 500_000_000  // 500ms
      let maxAggregationWindow: UInt64 = 1_000_000_000  // 1000ms
      let startTime = Date()

      // Wait for the rapid change window
      try? await Task.sleep(nanoseconds: rapidChangeWindow)
      guard !Task.isCancelled else { return }

      // Check if more events came in recently (within last 100ms)
      let timeSinceLastEvent = Date().timeIntervalSince(self.lastFileEventAt)
      if timeSinceLastEvent < 0.1 && Date().timeIntervalSince(startTime) < 1.0 {
        // More events are coming in, wait a bit more (up to max window)
        let remainingTime =
          maxAggregationWindow - UInt64(Date().timeIntervalSince(startTime) * 1_000_000_000)
        if remainingTime > 0 {
          try? await Task.sleep(nanoseconds: min(remainingTime, 200_000_000))
        }
      }

      guard !Task.isCancelled else { return }

      // Now trigger the refresh with aggregated events
      if let hint = self.pendingIncrementalHint, Date() < hint.expiresAt {
        await self.refreshIncremental(using: hint)
      } else {
        // First try a targeted refresh for the current selection; fall back to full refresh otherwise
        if !(await self.refreshSelectedSessions(sessionIds: self.selectedSessionIDs, force: true)) {
          self.enrichmentSnapshots.removeAll()
          // Use scope-based debouncing for the refresh
          self.scheduleFilterRefresh(force: true)
        }
      }

      self.fileEventAggregationTask = nil
    }
  }

  /// Smart merge: only update allSessions if data actually changed
  /// This prevents unnecessary UI re-renders when refreshing unchanged data
  private func smartMergeAllSessions(newSessions: [SessionSummary]) {
    // Quick check: if counts differ, definitely changed
    guard allSessions.count == newSessions.count else {
      allSessions = newSessions
      return
    }

    // Build map of old sessions
    let oldMap = Dictionary(uniqueKeysWithValues: allSessions.map { ($0.id, $0) })

    // Build merged array, preserving unchanged session object references
    var mergedSessions: [SessionSummary] = []
    mergedSessions.reserveCapacity(newSessions.count)
    var hasAnyChanges = false

    for newSession in newSessions {
      guard let oldSession = oldMap[newSession.id] else {
        // New session appeared
        mergedSessions.append(newSession)
        hasAnyChanges = true
        continue
      }

      // Parse Level Protection:
      // If old session has better parse level than new session (e.g. Enriched vs Metadata),
      // and file metadata (mtime/size) hasn't changed significantly, KEEP OLD SESSION.
      if let oldLevel = oldSession.parseLevel, let newLevel = newSession.parseLevel,
        oldLevel > newLevel
      {
        // Check if file is effectively unchanged to justify keeping old data
        let lastUpdatedMatches =
          abs(
            (newSession.lastUpdatedAt ?? Date.distantPast).timeIntervalSince(
              (oldSession.lastUpdatedAt ?? Date.distantPast))) < 0.1
        let fileSizeMatches = (newSession.fileSizeBytes ?? 0) == (oldSession.fileSizeBytes ?? 0)

        if lastUpdatedMatches && fileSizeMatches {
          // Keep high-quality old session
          mergedSessions.append(oldSession)
          continue
        }
      }

      // Check if this specific session actually changed by comparing key fields
      // Use file metadata + critical timestamps to avoid false positives from parsing variations
      let fileSizeMatches = oldSession.fileSizeBytes == newSession.fileSizeBytes
      let startedAtMatches = oldSession.startedAt == newSession.startedAt
      let lastUpdatedMatches = oldSession.lastUpdatedAt == newSession.lastUpdatedAt

      // CRITICAL FIX: Fast parsing (buildSummaryFast) only reads first ~64 lines, causing:
      // - Incomplete counts for tools, messages, etc.
      // - UI flicker when refresh switches between fast parse (low counts) and full parse (correct counts)
      // Solution: If file metadata unchanged but ANY count DECREASED, it's fast parse - keep old richer data
      let fileUnchanged = fileSizeMatches && lastUpdatedMatches
      let anyCountDecreased =
        (newSession.userMessageCount < oldSession.userMessageCount
          || newSession.assistantMessageCount < oldSession.assistantMessageCount
          || newSession.toolInvocationCount < oldSession.toolInvocationCount)

      if fileUnchanged && anyCountDecreased {
        // File hasn't changed but counts decreased - this is fast parse, keep old richer data
        mergedSessions.append(oldSession)
      } else if fileSizeMatches && startedAtMatches && lastUpdatedMatches
        && oldSession.userMessageCount == newSession.userMessageCount
        && oldSession.assistantMessageCount == newSession.assistantMessageCount
        && oldSession.toolInvocationCount == newSession.toolInvocationCount
      {
        // All counts match and file unchanged - truly no change
        mergedSessions.append(oldSession)
      } else {
        // Content actually changed - use new object
        mergedSessions.append(newSession)
        hasAnyChanges = true
      }
    }

    // Check if IDs changed (sessions added/removed)
    if Set(oldMap.keys) != Set(mergedSessions.map { $0.id }) {
      hasAnyChanges = true
    }

    // Only update if there are actual changes
    if hasAnyChanges {
      allSessions = mergedSessions
    }
    // If no changes at all, keep the existing allSessions array reference completely unchanged
  }

  private func invalidateEnrichmentCache(for day: Date?) {
    if let key = dayCacheKey(for: day) {
      enrichmentSnapshots.removeValue(forKey: key)
    }
  }

  private func dayCacheKey(for day: Date?) -> String? {
    let pathKey: String = selectedPath.map(Self.canonicalPath) ?? "*"
    if let day {
      let calendar = Calendar.current
      let comps = calendar.dateComponents([.year, .month, .day], from: day)
      guard let year = comps.year, let month = comps.month, let dayComponent = comps.day
      else {
        return nil
      }
      return "\(dateDimension.rawValue)|\(year)-\(month)-\(dayComponent)|\(pathKey)"
    }
    // No day selected (All): use synthetic cache key to avoid re-enriching repeatedly
    return "\(dateDimension.rawValue)|all|\(pathKey)"
  }

  private func scopeKey(_ scope: SessionLoadScope) -> String {
    switch scope {
    case .all: return "all"
    case .today: return "today"
    case .day(let date): return "day-\(Int(date.timeIntervalSince1970))"
    case .month(let date): return "month-\(Int(date.timeIntervalSince1970))"
    }
  }

  private func scheduleFilterRefresh(force: Bool) {
    let scope = currentScope()
    let key = scopeKey(scope)

    // Cancel existing task for this scope only (allows different scopes to coexist)
    scopedRefreshTasks[key]?.cancel()
    pendingScopeRefreshForce[key] = (pendingScopeRefreshForce[key] ?? false) || force

    if force {
      if allSessions.isEmpty {
        sections = []
      }
      isLoading = true
    }

    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      // Use longer debounce delay for non-force refreshes to reduce frequency
      // force=true: 10ms (user-initiated, responsive)
      // force=false: 300ms (auto-triggered, debounced)
      let runForce = self.pendingScopeRefreshForce[key] ?? false
      let debounceNanoseconds: UInt64 = runForce ? 10_000_000 : 300_000_000
      try? await Task.sleep(nanoseconds: debounceNanoseconds)
      guard !Task.isCancelled else {
        self.cleanupScopedTask(key: key)
        return
      }
      self.pendingScopeRefreshForce[key] = nil
      await self.refreshSessions(force: runForce)
      self.cleanupScopedTask(key: key)
    }

    scopedRefreshTasks[key] = task
    // Keep backward compatibility with existing code that cancels scheduledFilterRefresh
    scheduledFilterRefresh = task
  }

  private func cleanupScopedTask(key: String) {
    scopedRefreshTasks[key] = nil
    pendingScopeRefreshForce[key] = nil
  }

  /// Debounced wrapper around refreshSessions to reduce repeated full enumerations.
  private func scheduleRefreshDebounced(force: Bool) async {
    refreshDebounceTask?.cancel()
    pendingRefreshForce = pendingRefreshForce || force
    refreshDebounceTask = Task { [weak self] in
      guard let self else { return }
      // File-event aggregation: coalesce bursts into a single refresh
      let delay: UInt64 = self.pendingRefreshForce ? 50_000_000 : 500_000_000
      try? await Task.sleep(nanoseconds: delay)
      guard !Task.isCancelled else { return }
      let runForce = self.pendingRefreshForce
      self.pendingRefreshForce = false
      await self.refreshSessions(force: runForce)
    }
  }

  private func shouldSkipRefresh(scope: SessionLoadScope, force: Bool) -> Bool {
    let key = scopeKey(scope)

    // force=true (user-initiated): never skip
    if force {
      return false
    }

    // force=false (auto-triggered): check if already executing
    if activeScopeRefreshes[key] != nil {
      return true  // Skip if refresh for this scope is already in progress
    }

    // Skip if just completed (< 200ms) to filter rapid duplicates
    guard let lastScope = lastRefreshScope, let lastTs = lastRefreshAt else { return false }
    if lastScope == scope && Date().timeIntervalSince(lastTs) < 0.2 {
      return true
    }

    return false
  }

  private func shouldRefreshSessionsForDateChange(oldValue: Date?, newValue: Date?) -> Bool {
    // In Updated mode, all sessions are already loaded - no need to refresh
    guard dateDimension == .created else { return false }

    // In Created mode, only refresh if crossing month boundary
    guard let old = oldValue, let new = newValue else {
      return true  // Clearing or first selection
    }

    let oldMonth = Self.normalizeMonthStart(old)
    let newMonth = Self.normalizeMonthStart(new)
    return oldMonth != newMonth  // Only refresh when crossing months
  }

  private func shouldRefreshSessionsForDaysChange(oldValue: Set<Date>, newValue: Set<Date>) -> Bool
  {
    // In Updated mode, all sessions are already loaded - no need to refresh
    guard dateDimension == .created else { return false }

    // In Created mode, only refresh if any selected day crosses month boundary
    let oldMonths = Set(oldValue.map { Self.normalizeMonthStart($0) })
    let newMonths = Set(newValue.map { Self.normalizeMonthStart($0) })
    return oldMonths != newMonths  // Only refresh when month set changes
  }

  // MARK: - Quick pulse: cheap, low-latency activity tracking via file mtime
  private func quickPulse() {
    let now = Date()
    guard now.timeIntervalSince(lastQuickPulseAt) > 0.4 else { return }
    lastQuickPulseAt = now
    guard !sections.isEmpty else { return }
    #if canImport(AppKit)
      guard NSApp?.isActive != false else { return }
    #endif
    let displayedSessions = Array(self.sections.flatMap { $0.sessions }.prefix(200))
    guard !displayedSessions.isEmpty else { return }
    // Gate by visible rows digest to avoid scanning when the visible set didn't change
    var hasher = Hasher()
    for s in displayedSessions { hasher.combine(s.id) }
    let digest = hasher.finalize()
    if digest == lastDisplayedDigest { return }
    lastDisplayedDigest = digest
    quickPulseTask?.cancel()
    // Take a snapshot of currently displayed sessions (limit for safety)
    quickPulseTask = Task.detached { [weak self, displayedSessions] in
      guard let self else { return }
      let fm = FileManager.default
      var modified: [String: Date] = [:]
      for s in displayedSessions {
        let path = s.fileURL.path
        if let attrs = try? fm.attributesOfItem(atPath: path),
          let m = attrs[.modificationDate] as? Date
        {
          modified[s.id] = m
        }
      }
      let snapshot = modified
      await MainActor.run {
        let now = Date()
        for (id, m) in snapshot {
          let previous = self.fileMTimeCache[id]
          self.fileMTimeCache[id] = m
          if let previous, m > previous {
            self.activityHeartbeat[id] = now
          }
        }
        self.recomputeActiveUpdatingIDs()
      }
    }
  }

  private func monthKey(for day: Date?, dimension: DateDimension) -> String? {
    guard let day else { return nil }
    let calendar = Calendar.current
    let comps = calendar.dateComponents([.year, .month], from: day)
    guard let year = comps.year, let month = comps.month else { return nil }
    return "\(dimension.rawValue)|\(year)-\(month)"
  }

  // MARK: - Incremental refresh for New
  func setIncrementalHintForCodexToday(window seconds: TimeInterval = 10) {
    let day = Calendar.current.startOfDay(for: Date())
    pendingIncrementalHint = PendingIncrementalRefreshHint(
      kind: .codexDay(day), expiresAt: Date().addingTimeInterval(seconds))
  }

  func setIncrementalHintForGeminiToday(window seconds: TimeInterval = 10) {
    let day = Calendar.current.startOfDay(for: Date())
    pendingIncrementalHint = PendingIncrementalRefreshHint(
      kind: .geminiDay(day), expiresAt: Date().addingTimeInterval(seconds))
  }

  func setIncrementalHintForClaudeProject(directory: String, window seconds: TimeInterval = 120) {
    let canonical = Self.canonicalPath(directory)
    pendingIncrementalHint = PendingIncrementalRefreshHint(
      kind: .claudeProject(canonical),
      expiresAt: Date().addingTimeInterval(seconds))

    // Point a dedicated monitor at this project's folder to receive events for nested writes.
    // Claude writes session files inside ~/.claude/projects/<encoded-cwd>/, which are not visible
    // to a non-recursive top-level directory watcher.
    let home = FileManager.default.homeDirectoryForCurrentUser
    let projectsRoot =
      home
      .appendingPathComponent(".claude", isDirectory: true)
      .appendingPathComponent("projects", isDirectory: true)
    let encoded = Self.encodeClaudeProjectFolder(from: canonical)
    let projectURL = projectsRoot.appendingPathComponent(encoded, isDirectory: true)
    if FileManager.default.fileExists(atPath: projectURL.path) {
      if let monitor = claudeProjectMonitor {
        monitor.updateURL(projectURL)
      } else {
        claudeProjectMonitor = DirectoryMonitor(url: projectURL) { [weak self] in
          Task { await self?.refreshIncrementalForClaudeProject(directory: canonical) }
        }
      }
    }
  }

  // Claude project folder encoding mirrors ClaudeSessionProvider.encodeProjectFolder
  private static func encodeClaudeProjectFolder(from cwd: String) -> String {
    let expanded = (cwd as NSString).expandingTildeInPath
    var standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
    if standardized.hasSuffix("/") && standardized.count > 1 { standardized.removeLast() }
    var name = standardized.replacingOccurrences(of: ":", with: "-")
    name = name.replacingOccurrences(of: "/", with: "-")
    if !name.hasPrefix("-") { name = "-" + name }
    return name
  }

  private func mergeAndApply(_ subset: [SessionSummary]) {
    guard !subset.isEmpty else { return }
    var updatedSessions = allSessions
    var indexById = Dictionary(uniqueKeysWithValues: allSessions.enumerated().map { ($1.id, $0) })
    var changed = false
    var newSessions: [SessionSummary] = []

    for var session in subset {
      if let note = notesSnapshot[session.id] {
        session.userTitle = note.title
        session.userComment = note.comment
      }
      if let idx = indexById[session.id] {
        if updatedSessions[idx] != session {
          updatedSessions[idx] = session
          changed = true
        }
      } else {
        indexById[session.id] = updatedSessions.count
        updatedSessions.append(session)
        newSessions.append(session)
        changed = true
        handleAutoAssignIfMatches(session)
      }
    }

    guard changed else { return }
    allSessions = updatedSessions
    rebuildCanonicalCwdCache()

    var viewNeedsUpdate = false
    if !newSessions.isEmpty {
      persistProjectAssignmentsToCache(newSessions)
      _ = incrementProjectCounts(for: newSessions)
      viewNeedsUpdate = true
    }
    if viewNeedsUpdate {
      scheduleViewUpdate()
    }
    scheduleApplyFilters()
    // Keep global total based on full scan (Codex + Claude [+ Remote]),
    // not on currently loaded subset. Recompute asynchronously.
    Task { await self.refreshGlobalCount() }
  }

  private func incrementProjectCounts(for newSessions: [SessionSummary]) -> Bool {
    guard !newSessions.isEmpty else { return false }
    var updated = projectCounts
    var changed = false
    let allowedSourcesByProject = projects.reduce(into: [String: Set<ProjectSessionSource>]()) {
      $0[$1.id] = $1.sources
    }

    for session in newSessions {
      if let projectId = projectId(for: session) {
        let allowedSources = allowedSourcesByProject[projectId] ?? ProjectSessionSource.allSet
        guard allowedSources.contains(session.source.projectSource) else { continue }
        updated[projectId, default: 0] += 1
        changed = true
      } else {
        updated[SessionListViewModel.otherProjectId, default: 0] += 1
        changed = true
      }
    }

    if changed {
      projectCounts = updated
    }
    return changed
  }

  private func dayOfToday() -> Date { Calendar.current.startOfDay(for: Date()) }

  func refreshIncrementalForNewCodexToday() async {
    do {
      let subset = try await indexer.refreshSessions(
        root: preferences.sessionsRoot,
        scope: .day(dayOfToday()),
        dateRange: currentDateRange(),
        projectIds: singleSelectedProject(),
        dateDimension: dateDimension)
      await MainActor.run { self.mergeAndApply(subset) }
    } catch {
      // Swallow errors for incremental path; full refresh will recover if needed.
    }
  }

  func refreshIncrementalForGeminiToday() async {
    do {
      let subset = try await geminiProvider.sessions(scope: .day(dayOfToday()))
      await MainActor.run { self.mergeAndApply(subset) }
    } catch {
      diagLogger.error(
        "refreshIncrementalForGeminiToday failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  func refreshIncrementalForClaudeToday() async {
    do {
      let subset = try await claudeProvider.sessions(scope: .day(dayOfToday()))
      await MainActor.run { self.mergeAndApply(subset) }
    } catch {
      diagLogger.error(
        "refreshIncrementalForClaudeToday failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  func refreshIncrementalForClaudeProject(directory: String) async {
    do {
      let subset = try await claudeProvider.sessions(inProjectDirectory: directory)
      await MainActor.run { self.mergeAndApply(subset) }
    } catch {
      diagLogger.error(
        "refreshIncrementalForClaudeProject failed: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  private func refreshIncremental(using hint: PendingIncrementalRefreshHint) async {
    switch hint.kind {
    case .codexDay:
      await refreshIncrementalForNewCodexToday()
    case .geminiDay:
      await refreshIncrementalForGeminiToday()
    case .claudeProject(let dir):
      await refreshIncrementalForClaudeProject(directory: dir)
    }
  }

  nonisolated private static func computeMonthCounts(
    sessions: [SessionSummary],
    monthKey: String,
    dimension: DateDimension,
    dayIndex: [String: SessionDayIndex],
    coverage: [String: Set<Int>] = [:]
  ) -> [Int: Int] {
    var counts: [Int: Int] = [:]
    for session in sessions {
      guard let bucket = dayIndex[session.id] else { continue }
      switch dimension {
      case .created:
        guard bucket.createdMonthKey == monthKey else { continue }
        counts[bucket.createdDay, default: 0] += 1
      case .updated:
        guard bucket.updatedMonthKey == monthKey else { continue }
        if let days = coverage[session.id], !days.isEmpty {
          for day in days { counts[day, default: 0] += 1 }
        } else {
          counts[bucket.updatedDay, default: 0] += 1
        }
      }
    }
    return counts
  }
}

extension SessionListViewModel {
  private func apply(
    notes: [String: SessionNote], to sessions: inout [SessionSummary]
  ) {
    for index in sessions.indices {
      if let note = notes[sessions[index].id] {
        sessions[index].userTitle = note.title
        sessions[index].userComment = note.comment
      }
    }
  }

  func refreshGlobalCount() async {
    // Fast path: use cached coverage/meta to avoid re-parsing sessions on cold start.
    if let coverage = await indexer.currentCoverage() {
      await MainActor.run { self.globalSessionCount = coverage.sessionCount }
      diagLogger.log(
        "refreshGlobalCount via coverage count=\(coverage.sessionCount, privacy: .public) ts=\(self.ts(), format: .fixed(precision: 3))"
      )
      return
    }
    if let meta = await indexer.currentMeta() {
      await MainActor.run { self.globalSessionCount = meta.sessionCount }
      diagLogger.log(
        "refreshGlobalCount via meta count=\(meta.sessionCount, privacy: .public) ts=\(self.ts(), format: .fixed(precision: 3))"
      )
      return
    }

    // Fallback: enumerate cached summaries (or re-index) when no coverage/meta is available.
    diagLogger.log("refreshGlobalCount fallback enumerate summaries")
    let codexSummaries: [SessionSummary]
    do {
      if let cached = try await indexer.cachedAllSummaries() {
        codexSummaries = cached
      } else {
        codexSummaries = []
      }
    } catch {
      diagLogger.error(
        "refreshGlobalCount failed to read codex cache: \(error.localizedDescription, privacy: .public)"
      )
      await MainActor.run { self.globalSessionCount = 0 }
      return
    }

    let claudeSummaries = (try? await claudeProvider.sessions(scope: .all)) ?? []
    let geminiSummaries = (try? await geminiProvider.sessions(scope: .all)) ?? []

    var idSet = Set<String>()
    for s in codexSummaries { idSet.insert(s.id) }
    for s in claudeSummaries { idSet.insert(s.id) }
    for s in geminiSummaries { idSet.insert(s.id) }

    var total = idSet.count
    let enabledHosts = preferences.enabledRemoteHosts
    if !enabledHosts.isEmpty {
      let startRemote = Date()
      let codexCount = await remoteProvider.countSessions(kind: .codex, enabledHosts: enabledHosts)
      let claudeCount = await remoteProvider.countSessions(
        kind: .claude, enabledHosts: enabledHosts)
      total += codexCount
      total += claudeCount
      let elapsed = Date().timeIntervalSince(startRemote)
      diagLogger.log(
        "refreshGlobalCount remote counts codex=\(codexCount, privacy: .public) claude=\(claudeCount, privacy: .public) in \(elapsed, format: .fixed(precision: 3))s ts=\(self.ts(), format: .fixed(precision: 3))"
      )
    }
    await MainActor.run { self.globalSessionCount = total }
  }

  /// User-driven refresh for usage status (status capsule tap / Command+R fallback).
  func requestUsageStatusRefresh(for provider: UsageProviderKind) {
    switch provider {
    case .codex:
      refreshCodexUsageStatus()
    case .claude:
      claudeUsageAutoRefreshEnabled = true
      refreshClaudeUsageStatus()
    case .gemini:
      refreshGeminiUsageStatus()
    }
  }

  private func setInitialClaudePlaceholder() {
    self.setClaudeUsagePlaceholder("Load Claude usage", action: .refresh)
  }

  private func setClaudeUsagePlaceholder(
    _ message: String,
    action: UsageProviderSnapshot.Action? = .refresh,
    availability: UsageProviderSnapshot.Availability = .empty
  ) {
    let snapshot = UsageProviderSnapshot(
      provider: .claude,
      title: UsageProviderKind.claude.displayName,
      availability: availability,
      metrics: [],
      updatedAt: nil,
      statusMessage: message,
      requiresReauth: false,
      origin: .builtin,
      action: action
    )
    setUsageSnapshot(.claude, snapshot)
  }

  private func setGeminiUsagePlaceholder(
    _ message: String,
    action: UsageProviderSnapshot.Action? = .refresh,
    availability: UsageProviderSnapshot.Availability = .empty
  ) {
    let snapshot = UsageProviderSnapshot(
      provider: .gemini,
      title: UsageProviderKind.gemini.displayName,
      availability: availability,
      metrics: [],
      updatedAt: nil,
      statusMessage: message,
      requiresReauth: false,
      origin: .builtin,
      action: action
    )
    setUsageSnapshot(.gemini, snapshot)
  }

  private func refreshCodexUsageStatus() {
    codexUsageTask?.cancel()
    let candidates = latestCodexSessions(limit: 12)
    codexUsageTask = Task { [weak self] in
      guard let self else { return }
      let origin = await self.providerOrigin(for: .codex)
      guard origin == .builtin else {
        await MainActor.run {
          self.codexUsageStatus = nil
          self.setUsageSnapshot(.codex, Self.thirdPartyUsageSnapshot(for: .codex))
        }
        return
      }

      async let rpcSnapshot = self.codexAppServerProbe.fetchIfStaleOrNil(maxAge: 90)
      async let tokenSnapshot: TokenUsageSnapshot? = {
        guard !candidates.isEmpty else { return nil }
        if let ripgrepSnapshot = await self.ripgrepStore.latestTokenUsage(in: candidates) {
          return ripgrepSnapshot
        }
        return await Task.detached(priority: .utility) {
          Self.fallbackTokenUsage(from: candidates)
        }.value
      }()

      let rpc = await rpcSnapshot
      let snapshot = await tokenSnapshot

      guard !Task.isCancelled else { return }
      await MainActor.run {
        let badge = Self.codexPlanBadge(from: rpc?.planType)

        var codexStatus: CodexUsageStatus?
        if let snapshot {
          codexStatus = CodexUsageStatus(snapshot: snapshot)
        } else if let rpc {
          // Allow showing Codex quotas even when no recent session logs exist.
          codexStatus = CodexUsageStatus(
            updatedAt: rpc.fetchedAt,
            contextUsedTokens: nil,
            contextLimitTokens: nil,
            primaryWindowUsedPercent: rpc.primaryUsedPercent,
            primaryWindowMinutes: rpc.primaryWindowMinutes,
            primaryResetAt: rpc.primaryResetAt,
            secondaryWindowUsedPercent: rpc.secondaryUsedPercent,
            secondaryWindowMinutes: rpc.secondaryWindowMinutes,
            secondaryResetAt: rpc.secondaryResetAt
          )
        }

        if let rpc, let existing = codexStatus {
          let mergedUpdatedAt = max(existing.updatedAt, rpc.fetchedAt)
          codexStatus = existing.overridingRateLimits(
            updatedAt: mergedUpdatedAt,
            primaryUsedPercent: rpc.primaryUsedPercent,
            primaryWindowMinutes: rpc.primaryWindowMinutes,
            primaryResetAt: rpc.primaryResetAt,
            secondaryUsedPercent: rpc.secondaryUsedPercent,
            secondaryWindowMinutes: rpc.secondaryWindowMinutes,
            secondaryResetAt: rpc.secondaryResetAt
          )
        }

        self.codexUsageStatus = codexStatus
        if let codex = codexStatus {
          self.setUsageSnapshot(.codex, codex.asProviderSnapshot(titleBadge: badge))
        } else {
          self.setUsageSnapshot(
            .codex,
            UsageProviderSnapshot(
              provider: .codex,
              title: UsageProviderKind.codex.displayName,
              availability: .empty,
              metrics: [],
              updatedAt: nil,
              statusMessage: "No Codex usage data available yet.",
              origin: .builtin,
              action: .refresh
            )
          )
        }
      }
    }
  }

  private static func codexPlanBadge(from rawPlanType: String?) -> String? {
    guard let raw = rawPlanType?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
    else {
      return nil
    }
    let plan = raw.lowercased()
    if plan.contains("free") || plan.contains("unknown") { return nil }
    if plan.contains("plus") { return "Plus" }
    if plan.contains("pro") { return "Pro" }
    if plan.contains("team") { return "Team" }
    if plan.contains("enterprise") { return "Ent" }
    return raw.prefix(1).uppercased() + raw.dropFirst()
  }

  nonisolated private static func fallbackTokenUsage(from sessions: [SessionSummary])
    -> TokenUsageSnapshot?
  {
    guard !sessions.isEmpty else { return nil }
    let loader = SessionTimelineLoader()
    for session in sessions {
      if let snapshot = loader.loadLatestTokenUsageWithFallback(url: session.fileURL) {
        return snapshot
      }
    }
    return nil
  }

  private func latestCodexSessions(limit: Int) -> [SessionSummary] {
    let sorted =
      allSessions
      .filter { $0.source == .codexLocal }
      .sorted { ($0.lastUpdatedAt ?? $0.startedAt) > ($1.lastUpdatedAt ?? $1.startedAt) }
    guard !sorted.isEmpty else { return [] }
    return Array(sorted.prefix(limit))
  }

  private func refreshClaudeUsageStatus() {
    claudeUsageTask?.cancel()
    claudeUsageTask = Task { [weak self] in
      guard let self else { return }
      let origin = await self.providerOrigin(for: .claude)
      guard origin == .builtin else {
        await MainActor.run {
          self.setUsageSnapshot(.claude, Self.thirdPartyUsageSnapshot(for: .claude))
        }
        return
      }
      await MainActor.run {
        self.setClaudeUsagePlaceholder("Refreshing …", action: nil, availability: .comingSoon)
      }
      let client = self.claudeUsageClient
      do {
        let status = try await client.fetchUsageStatus()
        guard !Task.isCancelled else { return }
        await MainActor.run {
          self.setUsageSnapshot(.claude, status.asProviderSnapshot())
        }
      } catch {
        NSLog("[ClaudeUsage] API fetch failed: \(error)")
        guard !Task.isCancelled else { return }
        let descriptor = Self.claudeUsageErrorState(from: error)
        await MainActor.run {
          self.setUsageSnapshot(
            .claude,
            UsageProviderSnapshot(
              provider: .claude,
              title: UsageProviderKind.claude.displayName,
              availability: .empty,
              metrics: [],
              updatedAt: nil,
              statusMessage: descriptor.message,
              requiresReauth: descriptor.requiresReauth,
              origin: .builtin,
              action: descriptor.action
            )
          )
        }
      }
    }
  }

  private func refreshGeminiUsageStatus() {
    geminiUsageTask?.cancel()
    geminiUsageTask = Task { [weak self] in
      guard let self else { return }
      let origin = await self.providerOrigin(for: .gemini)
      guard origin == .builtin else {
        await MainActor.run {
          self.setUsageSnapshot(.gemini, Self.thirdPartyUsageSnapshot(for: .gemini))
        }
        return
      }
      await MainActor.run {
        self.setGeminiUsagePlaceholder("Refreshing …", action: nil, availability: .comingSoon)
      }

      do {
        let status = try await self.geminiUsageClient.fetchUsageStatus()
        guard !Task.isCancelled else { return }
        await MainActor.run {
          self.setUsageSnapshot(.gemini, status.asProviderSnapshot())
        }
      } catch {
        NSLog("[GeminiUsage] API fetch failed: \(error)")
        guard !Task.isCancelled else { return }
        let descriptor = Self.geminiUsageErrorState(from: error)
        await MainActor.run {
          self.setUsageSnapshot(
            .gemini,
            UsageProviderSnapshot(
              provider: .gemini,
              title: UsageProviderKind.gemini.displayName,
              availability: .empty,
              metrics: [],
              updatedAt: nil,
              statusMessage: descriptor.message,
              requiresReauth: descriptor.requiresReauth,
              origin: .builtin,
              action: descriptor.action
            )
          )
        }
      }
    }
  }

  private struct ClaudeUsageErrorDescriptor {
    var message: String
    var requiresReauth: Bool
    var action: UsageProviderSnapshot.Action?
  }

  private static func claudeUsageErrorState(from error: Error) -> ClaudeUsageErrorDescriptor {
    guard let clientError = error as? ClaudeUsageAPIClient.ClientError else {
      return ClaudeUsageErrorDescriptor(
        message: "Unable to get Claude usage.",
        requiresReauth: false,
        action: .refresh
      )
    }
    switch clientError {
    case .credentialNotFound:
      return ClaudeUsageErrorDescriptor(
        message: "Not logged in to Claude. Run claude code to refresh.",
        requiresReauth: true,
        action: .refresh
      )
    case .keychainAccessRestricted:
      return ClaudeUsageErrorDescriptor(
        message: "CodMate needs access to Claude login records in the keychain.",
        requiresReauth: false,
        action: .authorizeKeychain
      )
    case .malformedCredential, .missingAccessToken:
      return ClaudeUsageErrorDescriptor(
        message: "Claude login information is invalid. Please log in again and refresh.",
        requiresReauth: true,
        action: .refresh
      )
    case .credentialExpired:
      return ClaudeUsageErrorDescriptor(
        message:
          "No Claude usage recently. ",
        requiresReauth: false,
        action: .refresh
      )
    case .requestFailed(let code):
      if code == 401 {
        return ClaudeUsageErrorDescriptor(
          message: "Claude rejected the usage request. Please log in again and refresh.",
          requiresReauth: true,
          action: .refresh
        )
      }
      return ClaudeUsageErrorDescriptor(
        message: "Claude usage request failed (HTTP \(code)).",
        requiresReauth: false,
        action: .refresh
      )
    case .emptyResponse, .decodingFailed:
      return ClaudeUsageErrorDescriptor(
        message: "Unable to parse Claude usage temporarily. Please try again later.",
        requiresReauth: false,
        action: .refresh
      )
    }
  }

  private struct GeminiUsageErrorDescriptor {
    var message: String
    var requiresReauth: Bool
    var action: UsageProviderSnapshot.Action?
  }

  private static func geminiUsageErrorState(from error: Error) -> GeminiUsageErrorDescriptor {
    guard let clientError = error as? GeminiUsageAPIClient.ClientError else {
      return GeminiUsageErrorDescriptor(
        message: "Unable to get Gemini usage.",
        requiresReauth: false,
        action: .refresh
      )
    }

    switch clientError {
    case .credentialNotFound:
      return GeminiUsageErrorDescriptor(
        message: "Not logged in to Gemini. Run gemini CLI to refresh and retry.",
        requiresReauth: true,
        action: .refresh
      )
    case .keychainAccess(let status):
      return GeminiUsageErrorDescriptor(
        message: SecCopyErrorMessageString(status, nil) as String? ?? "Keychain access denied.",
        requiresReauth: false,
        action: .authorizeKeychain
      )
    case .malformedCredential, .missingAccessToken:
      return GeminiUsageErrorDescriptor(
        message: "Gemini login info is invalid. Please log in again.",
        requiresReauth: true,
        action: .refresh
      )
    case .credentialExpired(let date):
      let formatter = DateFormatter()
      formatter.dateStyle = .medium
      formatter.timeStyle = .short
      return GeminiUsageErrorDescriptor(
        message: "Gemini login expired on \(formatter.string(from: date)).",
        requiresReauth: true,
        action: .refresh
      )
    case .projectNotFound:
      return GeminiUsageErrorDescriptor(
        message: "Gemini project not found. Run gemini login or set GOOGLE_CLOUD_PROJECT.",
        requiresReauth: true,
        action: .refresh
      )
    case .requestFailed(let code):
      let needsLogin = code == 401 || code == 403
      return GeminiUsageErrorDescriptor(
        message: needsLogin
          ? "Gemini rejected the usage request. Please log in again."
          : "Gemini usage request failed (HTTP \(code)).",
        requiresReauth: needsLogin,
        action: .refresh
      )
    case .emptyResponse, .decodingFailed:
      return GeminiUsageErrorDescriptor(
        message: "Unable to parse Gemini usage temporarily. Please try again later.",
        requiresReauth: false,
        action: .refresh
      )
    }
  }

  private func setUsageSnapshot(_ provider: UsageProviderKind, _ new: UsageProviderSnapshot) {
    if let old = usageSnapshots[provider], Self.usageSnapshotCoreEqual(old, new) {
      return
    }
    usageSnapshots[provider] = new
  }

  private func autoRefreshUsageIfNeeded(
    codexOrigin: UsageProviderOrigin,
    claudeOrigin: UsageProviderOrigin,
    geminiOrigin: UsageProviderOrigin
  ) {
    guard !didAutoRefreshUsage else { return }
    didAutoRefreshUsage = true

    let shouldRefresh: (UsageProviderKind) -> Bool = { provider in
      guard let snapshot = self.usageSnapshots[provider] else { return true }
      if snapshot.origin == .thirdParty { return false }
      if snapshot.availability == .ready { return false }
      return snapshot.updatedAt == nil
    }

    if codexOrigin == .builtin, shouldRefresh(.codex) {
      refreshCodexUsageStatus()
    }
    if claudeOrigin == .builtin, shouldRefresh(.claude) {
      refreshClaudeUsageStatus()
    }
    if geminiOrigin == .builtin, shouldRefresh(.gemini) {
      refreshGeminiUsageStatus()
    }
  }

  private static func usageSnapshotCoreEqual(_ a: UsageProviderSnapshot, _ b: UsageProviderSnapshot)
    -> Bool
  {
    if a.origin != b.origin { return false }
    if a.availability != b.availability { return false }
    if a.statusMessage != b.statusMessage { return false }
    if a.action != b.action { return false }
    let au = a.updatedAt?.timeIntervalSinceReferenceDate
    let bu = b.updatedAt?.timeIntervalSinceReferenceDate
    if au != bu { return false }
    let ap = a.urgentMetric()?.progress
    let bp = b.urgentMetric()?.progress
    if ap != bp { return false }
    let ar = a.urgentMetric()?.resetDate?.timeIntervalSinceReferenceDate
    let br = b.urgentMetric()?.resetDate?.timeIntervalSinceReferenceDate
    return ar == br
  }

  private func providerOrigin(for provider: UsageProviderKind) async -> UsageProviderOrigin {
    if provider == .gemini {
      // Gemini usage is always treated as built-in; no third-party override today.
      return .builtin
    }
    let consumer: ProvidersRegistryService.Consumer = {
      switch provider {
      case .codex: return .codex
      case .claude: return .claudeCode
      case .gemini: return .codex
      }
    }()
    let bindings = await providersRegistry.getBindings()
    if let raw = bindings.activeProvider?[consumer.rawValue]?.trimmingCharacters(
      in: .whitespacesAndNewlines),
      !raw.isEmpty
    {
      return .thirdParty
    }
    return .builtin
  }

  private static func thirdPartyUsageSnapshot(for provider: UsageProviderKind)
    -> UsageProviderSnapshot
  {
    UsageProviderSnapshot(
      provider: provider,
      title: provider.displayName,
      availability: .empty,
      metrics: [],
      updatedAt: nil,
      statusMessage: "Usage data isn't available while a custom provider is active.",
      origin: .thirdParty
    )
  }

  // MARK: - Sandbox Permission Helpers

  /// Ensure we have access to sessions directories in sandbox mode
  private func ensureSessionsAccess() async {
    guard SecurityScopedBookmarks.shared.isSandboxed else { return }

    // Check if sessions root path is under a known required directory
    let sessionsPath = preferences.sessionsRoot.path
    let realHome = getRealUserHome()
    let normalizedPath = sessionsPath.replacingOccurrences(of: "~", with: realHome)

    // Try to start access for Codex directory if sessions root is under ~/.codex
    if normalizedPath.hasPrefix(realHome + "/.codex") {
      SandboxPermissionsManager.shared.startAccessingIfAuthorized(directory: .codexSessions)
    }

    // Try to start access for Claude directory if needed
    SandboxPermissionsManager.shared.startAccessingIfAuthorized(directory: .claudeSessions)
    // Try to start access for Gemini directory if needed
    SandboxPermissionsManager.shared.startAccessingIfAuthorized(directory: .geminiSessions)

    // Try to start access for CodMate directory if needed
    SandboxPermissionsManager.shared.startAccessingIfAuthorized(directory: .codmateData)

    // Ensure SSH config directory access so remote mirroring can read keys/config
    SandboxPermissionsManager.shared.startAccessingIfAuthorized(directory: .sshConfig)
  }

  /// Get the real user home directory (not sandbox container)
  private func getRealUserHome() -> String {
    if let homeDir = getpwuid(getuid())?.pointee.pw_dir {
      return String(cString: homeDir)
    }
    if let home = ProcessInfo.processInfo.environment["HOME"] {
      return home
    }
    return NSHomeDirectory()
  }

  func timeline(for summary: SessionSummary) async -> [ConversationTurn] {
    if summary.source.baseKind == .claude {
      return await claudeProvider.timeline(for: summary) ?? []
    } else if summary.source.baseKind == .gemini {
      return await geminiProvider.timeline(for: summary) ?? []
    }
    let loader = SessionTimelineLoader()
    return (try? loader.load(url: summary.fileURL)) ?? []
  }

  // MARK: - Timeline Cache (in-memory)

  func cachedTimeline(for summary: SessionSummary) async -> [ConversationTurn]? {
    guard let entry = timelineCache[summary.id] else { return nil }
    let signature = timelineCacheSignature(for: summary)
    guard entry.signature == signature else { return nil }
    return entry.turns
  }

  func storeTimeline(_ turns: [ConversationTurn], for summary: SessionSummary) async {
    let signature = timelineCacheSignature(for: summary)
    timelineCache[summary.id] = TimelineCacheEntry(signature: signature, turns: turns)
  }

  private func timelineCacheSignature(for summary: SessionSummary) -> TimelineCacheSignature {
    // Prefer on-disk metadata for local sessions; fall back to summary hints.
    if !summary.source.isRemote,
      let attrs = try? FileManager.default.attributesOfItem(atPath: summary.fileURL.path)
    {
      let mtime = attrs[.modificationDate] as? Date
      let size = (attrs[.size] as? NSNumber)?.uint64Value
      return TimelineCacheSignature(modifiedAt: mtime, fileSize: size)
    }
    return TimelineCacheSignature(
      modifiedAt: summary.lastUpdatedAt, fileSize: summary.fileSizeBytes)
  }

  // MARK: - Timeline Previews

  /// Load lightweight timeline previews from cache. Returns nil if cache is invalid or missing.
  func loadTimelinePreviews(for summary: SessionSummary) async -> [ConversationTurnPreview]? {
    // Get file attributes for mtime validation
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: summary.fileURL.path),
      let mtime = attrs[.modificationDate] as? Date
    else {
      return nil
    }

    let size = (attrs[.size] as? NSNumber)?.uint64Value

    // Fetch from SQLite cache
    let previews = try? await indexer.fetchTimelinePreviews(
      sessionId: summary.id,
      fileModificationTime: mtime,
      fileSize: size
    )

    return previews
  }

  /// Update timeline preview cache for a session
  func updateTimelinePreviews(for summary: SessionSummary, turns: [ConversationTurn]) async {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: summary.fileURL.path),
      let mtime = attrs[.modificationDate] as? Date
    else {
      return
    }

    let size = (attrs[.size] as? NSNumber)?.uint64Value

    // Convert turns to previews
    let previews = turns.enumerated().map { index, turn in
      ConversationTurnPreview(from: turn, sessionId: summary.id, index: index)
    }

    // Store in SQLite
    do {
      try await indexer.upsertTimelinePreviews(
        previews,
        sessionId: summary.id,
        fileModificationTime: mtime,
        fileSize: size
      )
      diagLogger.log(
        "Timeline previews cached for session \(summary.id, privacy: .public): \(previews.count, privacy: .public) turns"
      )
    } catch {
      diagLogger.error(
        "Failed to cache timeline previews for \(summary.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  func ripgrepDiagnostics() async -> SessionRipgrepStore.Diagnostics {
    await ripgrepStore.diagnostics()
  }

  func rebuildRipgrepIndexes() async {
    coverageDebounceTasks.values.forEach { $0.cancel() }
    coverageDebounceTasks.removeAll()
    coverageLoadTasks.values.forEach { $0.cancel() }
    coverageLoadTasks.removeAll()
    await ripgrepStore.resetAll()
    updatedMonthCoverage.removeAll()
    monthCountsCache.removeAll()
    scheduleViewUpdate()
    if dateDimension == .updated {
      // Use current selected path for accurate cache key
      triggerCoverageLoad(
        for: sidebarMonthStart, dimension: dateDimension, projectPath: selectedPath)
    }
    scheduleApplyFilters()
  }

  /// Fully rebuild the session index (in-memory + on-disk caches) by
  /// clearing cached summaries and forcing a full refresh from JSONL logs.
  func rebuildSessionIndex() async {
    await indexer.resetAllCaches()
    enrichmentSnapshots.removeAll()
    await refreshSessions(force: true)
  }

  /// Force refresh coverage for current view scope (Cmd+R)
  func forceRefreshCurrentScope() async {
    let projectPath = selectedPath
    let monthStart = sidebarMonthStart

    // Cancel ongoing tasks for this scope
    let key = coverageCacheKey(monthStart, dateDimension, projectPath: projectPath)
    coverageDebounceTasks[key]?.cancel()
    coverageDebounceTasks.removeValue(forKey: key)
    coverageLoadTasks[key]?.cancel()
    coverageLoadTasks.removeValue(forKey: key)

    // Clear cache for this scope
    monthCountsCache.removeValue(forKey: cacheKey(monthStart, dateDimension))

    // Trigger fresh scan
    if dateDimension == .updated {
      triggerCoverageLoad(
        for: monthStart,
        dimension: dateDimension,
        projectPath: projectPath,
        forceRefresh: true
      )
    }

    scheduleApplyFilters()
  }

  /// Notify that a session file has been modified (for incremental cache invalidation)
  func notifySessionFileModified(at fileURL: URL) async {
    await ripgrepStore.markFileModified(fileURL.path)
  }

  // Invalidate all cached monthly counts; next access will recompute
  func invalidateCalendarCaches() {
    monthCountsCache.removeAll()
    scheduleViewUpdate()
  }
  private func performInitialRemoteSyncIfNeeded() async {
    guard !preferences.enabledRemoteHosts.isEmpty else { return }
    await syncRemoteHosts(force: false, refreshAfter: true)
  }

  func syncRemoteHosts(force: Bool = true, refreshAfter: Bool = true) async {
    let enabledHosts = preferences.enabledRemoteHosts
    guard !enabledHosts.isEmpty else { return }
    await remoteProvider.syncHosts(enabledHosts, force: force)
    await updateRemoteSyncStates()
    if refreshAfter {
      await refreshSessions(force: true)
    }
  }

  private func updateRemoteSyncStates() async {
    let snapshot = await remoteProvider.syncStatusSnapshot()
    await MainActor.run {
      self.remoteSyncStates = snapshot
    }
  }
}

extension SessionListViewModel {
  private func membershipKey(for id: String, source: ProjectSessionSource) -> String {
    "\(source.rawValue)|\(id)"
  }

  private func membershipKey(for summary: SessionSummary) -> String {
    membershipKey(for: summary.id, source: summary.source.projectSource)
  }

  func projectId(for summary: SessionSummary) -> String? {
    projectMemberships[membershipKey(for: summary)]
  }

  func projectId(for sessionId: String, source: ProjectSessionSource) -> String? {
    projectMemberships[membershipKey(for: sessionId, source: source)]
  }

  func cachedInstructions(for summary: SessionSummary) async -> String? {
    let projectId = projectId(for: summary)
    let keys = SessionIndexSQLiteStore.candidateProjectKeys(projectId: projectId, cwd: summary.cwd)
    return await indexer.cachedInstructions(forKeys: keys)
  }

  func sessionSummary(for id: String) -> SessionSummary? {
    sessionLookup[id]
  }

  func sessionDragIdentifier(for summary: SessionSummary) -> String {
    "session::\(summary.source.projectSource.rawValue)::\(summary.id)"
  }

  func sessionAssignment(forIdentifier identifier: String) -> SessionAssignment? {
    if let parsed = parseSessionIdentifier(identifier) {
      return parsed
    }
    if let summary = sessionSummary(for: identifier) {
      return SessionAssignment(id: summary.id, source: summary.source.projectSource)
    }
    return SessionAssignment(id: identifier, source: .codex)
  }

  private func parseSessionIdentifier(_ value: String) -> SessionAssignment? {
    let parts = value.components(separatedBy: "::")
    guard parts.count == 3, parts[0] == "session" else { return nil }
    guard let source = ProjectSessionSource(rawValue: parts[1]) else { return nil }
    return SessionAssignment(id: parts[2], source: source)
  }
}

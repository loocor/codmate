import Combine
import Foundation

@MainActor
final class ProjectOverviewViewModel: ObservableObject {
  @Published private(set) var snapshot: ProjectOverviewSnapshot = .empty

  private let sessionListViewModel: SessionListViewModel
  private var project: Project
  private var cancellables: Set<AnyCancellable> = []
  private var pendingRefreshTask: Task<Void, Never>? = nil

  init(sessionListViewModel: SessionListViewModel, project: Project) {
    self.sessionListViewModel = sessionListViewModel
    self.project = project
    bindPublishers()
    recomputeSnapshot()
  }

  deinit {
    pendingRefreshTask?.cancel()
  }

  func forceRefresh() {
    pendingRefreshTask?.cancel()
    pendingRefreshTask = nil
    recomputeSnapshot()
  }

  func updateProject(_ newProject: Project) {
      guard newProject.id == project.id else { return } // Only update if it's the same project
      project = newProject
      recomputeSnapshot()
  }

  private func bindPublishers() {
    sessionListViewModel.$sections
      .sink { [weak self] _ in self?.scheduleSnapshotRefresh() }
      .store(in: &cancellables)

    sessionListViewModel.$awaitingFollowupIDs
      .sink { [weak self] _ in self?.scheduleSnapshotRefresh() }
      .store(in: &cancellables)

    sessionListViewModel.$usageSnapshots
      .sink { [weak self] _ in self?.scheduleSnapshotRefresh() }
      .store(in: &cancellables)

    sessionListViewModel.$projects
      .sink { [weak self] _ in self?.scheduleSnapshotRefresh() }
      .store(in: &cancellables)
  }

  private func scheduleSnapshotRefresh() {
    pendingRefreshTask?.cancel()
    pendingRefreshTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 120_000_000)
      guard !Task.isCancelled else { return }
      guard let self else { return }
      
      // Capture data on MainActor
      // Filter sessions on MainActor because projectId(for:) accesses MainActor state
      let filteredSessions = self.sessionListViewModel.sections.flatMap { $0.sessions }
      let projectSessions: [SessionSummary] = filteredSessions
        .filter { self.sessionListViewModel.projectId(for: $0) == self.project.id }
      
      let usageSnapshots = self.sessionListViewModel.usageSnapshots
      
      // Run computation in background
      let newSnapshot = await Self.computeSnapshot(
        projectSessions: projectSessions,
        usageSnapshots: usageSnapshots
      )
      
      guard !Task.isCancelled else { return }
      await MainActor.run {
        self.snapshot = newSnapshot
      }
    }
  }

  private static func computeSnapshot(
    projectSessions: [SessionSummary],
    usageSnapshots: [UsageProviderKind: UsageProviderSnapshot]
  ) async -> ProjectOverviewSnapshot {
    let now = Date()
    
    func anchorDate(for session: SessionSummary) -> Date {
      session.lastUpdatedAt ?? session.startedAt
    }

    let totalDuration = projectSessions.reduce(0) { $0 + $1.duration }
    let totalTokens = projectSessions.reduce(0) { $0 + $1.turnContextCount }
    let userMessages = projectSessions.reduce(0) { $0 + $1.userMessageCount }
    let assistantMessages = projectSessions.reduce(0) { $0 + $1.assistantMessageCount }
    let totalToolInvocations = projectSessions.reduce(0) { $0 + $1.toolInvocationCount }

    let recentTop = Array(
      projectSessions
        .sorted { anchorDate(for: $0) > anchorDate(for: $1) }
        .prefix(5)
    )

    let sourceStats = buildSourceStats(from: projectSessions)
    let activityData = projectSessions.generateChartData()

    return ProjectOverviewSnapshot(
      totalSessions: projectSessions.count,
      totalDuration: totalDuration,
      totalTokens: totalTokens,
      userMessages: userMessages,
      assistantMessages: assistantMessages,
      totalToolInvocations: totalToolInvocations,
      recentSessions: recentTop,
      sourceStats: sourceStats,
      activityChartData: activityData,
      usageSnapshots: usageSnapshots,
      lastUpdated: now
    )
  }
  
  private static func buildSourceStats(from sessions: [SessionSummary]) -> [ProjectOverviewSnapshot.SourceStat] {
    var groups: [SessionSource.Kind: [SessionSummary]] = [:]
    for session in sessions {
      groups[session.source.baseKind, default: []].append(session)
    }
    
    let kinds: [SessionSource.Kind] = [.codex, .claude, .gemini]
    
    var stats: [ProjectOverviewSnapshot.SourceStat] = kinds.compactMap { kind in
      let group = groups[kind] ?? []
      let count = group.count
      guard count > 0 else { return nil }
      
      let totalDuration = group.reduce(0) { $0 + $1.duration }
      let totalTokens = group.reduce(0) { $0 + $1.turnContextCount }
      
      return ProjectOverviewSnapshot.SourceStat(
        kind: kind,
        sessionCount: count,
        totalTokens: totalTokens,
        avgTokens: 0, // Not used for display anymore
        avgDuration: count > 0 ? totalDuration / Double(count) : 0,
        isAll: false
      )
    }
    
    // Add "All" summary if there's data
    if !sessions.isEmpty {
      let totalDuration = sessions.reduce(0) { $0 + $1.duration }
      let totalTokens = sessions.reduce(0) { $0 + $1.turnContextCount }
      let count = sessions.count
      
      let allStat = ProjectOverviewSnapshot.SourceStat(
        kind: .codex, // Placeholder kind, ignored when isAll is true
        sessionCount: count,
        totalTokens: totalTokens,
        avgTokens: 0,
        avgDuration: count > 0 ? totalDuration / Double(count) : 0,
        isAll: true
      )
      stats.insert(allStat, at: 0)
    }
    
    return stats
  }

  private func recomputeSnapshot() {
    scheduleSnapshotRefresh()
  }

  func resolveProject(for session: SessionSummary) -> (id: String, name: String)? {
    // For ProjectOverview, it should always be THIS project
    return (id: project.id, name: project.name)
  }
}

struct ProjectOverviewSnapshot: Equatable {
  // SourceStat needs to be defined within ProjectOverviewSnapshot now
  struct SourceStat: Identifiable, Equatable {
    let kind: SessionSource.Kind
    let sessionCount: Int
    let totalTokens: Int
    let avgTokens: Double
    let avgDuration: TimeInterval
    var isAll: Bool = false
    
    var id: String { isAll ? "all" : kind.rawValue }
    
    var displayName: String {
      if isAll { return "All" }
      switch kind {
      case .codex: return "Codex"
      case .claude: return "Claude"
      case .gemini: return "Gemini"
      }
    }
  }

  var totalSessions: Int
  var totalDuration: TimeInterval
  var totalTokens: Int
  var userMessages: Int
  var assistantMessages: Int
  var totalToolInvocations: Int // New field
  var recentSessions: [SessionSummary]
  var sourceStats: [SourceStat]
  var activityChartData: ActivityChartData
  var usageSnapshots: [UsageProviderKind: UsageProviderSnapshot]
  var lastUpdated: Date

  static let empty = ProjectOverviewSnapshot(
    totalSessions: 0,
    totalDuration: 0,
    totalTokens: 0,
    userMessages: 0,
    assistantMessages: 0,
    totalToolInvocations: 0,
    recentSessions: [],
    sourceStats: [],
    activityChartData: .empty,
    usageSnapshots: [:],
    lastUpdated: .distantPast
  )
}

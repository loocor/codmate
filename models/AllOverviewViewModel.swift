import Combine
import Foundation
import OSLog

@MainActor
final class AllOverviewViewModel: ObservableObject {
  @Published private(set) var snapshot: AllOverviewSnapshot = .empty
  @Published private(set) var cacheCoverage: SessionIndexCoverage?
  @Published private(set) var isLoading: Bool = false

  private let sessionListViewModel: SessionListViewModel
  private var cancellables: Set<AnyCancellable> = []
  private var pendingRefreshTask: Task<Void, Never>? = nil
  private let logger = Logger(subsystem: "io.umate.codmate", category: "AllOverviewVM")

  init(sessionListViewModel: SessionListViewModel) {
    self.sessionListViewModel = sessionListViewModel
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

  private func bindPublishers() {
    sessionListViewModel.$sections
      .sink { [weak self] _ in self?.scheduleSnapshotRefresh() }
      .store(in: &cancellables)

    sessionListViewModel.$usageSnapshots
      .sink { [weak self] _ in self?.scheduleSnapshotRefresh() }
      .store(in: &cancellables)

    sessionListViewModel.$projects
      .sink { [weak self] _ in self?.scheduleSnapshotRefresh() }
      .store(in: &cancellables)

    sessionListViewModel.$isLoading
      .receive(on: DispatchQueue.main)
      .sink { [weak self] value in self?.isLoading = value }
      .store(in: &cancellables)

    sessionListViewModel.$cacheCoverage
      .receive(on: DispatchQueue.main)
      .sink { [weak self] value in self?.cacheCoverage = value }
      .store(in: &cancellables)
  }

  private func scheduleSnapshotRefresh() {
    pendingRefreshTask?.cancel()
    pendingRefreshTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 120_000_000)
      guard !Task.isCancelled else { return }
      guard let self else { return }
      let started = Date()
      
      // Capture data on MainActor
      let filteredSessions: [SessionSummary] = self.sessionListViewModel.sections.flatMap { $0.sessions }
      let usageSnapshots = self.sessionListViewModel.usageSnapshots
      let projectCount = self.sessionListViewModel.projects.count
      let scope = self.sessionListViewModel.overviewAggregateScope()
      let aggregate: OverviewAggregate?
      if let scope {
        aggregate = await self.sessionListViewModel.fetchOverviewAggregate(scope: scope)
      } else if self.sessionListViewModel.canUseGlobalOverviewAggregate {
        aggregate = await self.sessionListViewModel.fetchOverviewAggregate()
      } else {
        aggregate = nil
      }
      self.logger.log("overview snapshot refresh start sessions=\(filteredSessions.count, privacy: .public) scopeAggregate=\(scope != nil, privacy: .public) aggregateFetched=\(aggregate != nil, privacy: .public)")
      
      // Run computation in background
      let newSnapshot = await Self.computeSnapshot(
        sessions: filteredSessions,
        usageSnapshots: usageSnapshots,
        projectCount: projectCount,
        aggregate: aggregate
      )
      
      guard !Task.isCancelled else { return }
      await MainActor.run {
        self.snapshot = newSnapshot
      }
      let elapsed = Date().timeIntervalSince(started)
      self.logger.log("overview snapshot refresh done in \(elapsed, format: .fixed(precision: 3))s sessions=\(newSnapshot.totalSessions, privacy: .public) aggregate=\(aggregate != nil, privacy: .public)")
    }
  }

  private static func computeSnapshot(
    sessions: [SessionSummary],
    usageSnapshots: [UsageProviderKind: UsageProviderSnapshot],
    projectCount: Int,
    aggregate: OverviewAggregate?
  ) async -> AllOverviewSnapshot {
    let now = Date()
    
    func anchorDate(for session: SessionSummary) -> Date {
      session.lastUpdatedAt ?? session.startedAt
    }

    let totalDuration = aggregate?.totalDuration ?? sessions.reduce(0) { $0 + $1.duration }
    let totalTokens = aggregate?.totalTokens ?? sessions.reduce(0) { $0 + $1.actualTotalTokens }
    let userMessages = aggregate?.userMessages ?? sessions.reduce(0) { $0 + $1.userMessageCount }
    let assistantMessages = aggregate?.assistantMessages ?? sessions.reduce(0) { $0 + $1.assistantMessageCount }

    let recentTop = Array(
      sessions
        .sorted { anchorDate(for: $0) > anchorDate(for: $1) }
        .prefix(5)
    )

    let sourceStats = aggregate.map { buildSourceStats(from: $0) } ?? buildSourceStats(from: sessions)
    let activityData = aggregate.map { activityChartData(from: $0) } ?? sessions.generateChartData()

    return AllOverviewSnapshot(
      totalSessions: aggregate?.totalSessions ?? sessions.count,
      totalDuration: totalDuration,
      totalTokens: totalTokens,
      userMessages: userMessages,
      assistantMessages: assistantMessages,
      recentSessions: recentTop,
      sourceStats: sourceStats,
      activityChartData: activityData,
      usageSnapshots: usageSnapshots,
      projectCount: projectCount,
      lastUpdated: now
    )
  }
  
  private static func buildSourceStats(from aggregate: OverviewAggregate) -> [AllOverviewSnapshot.SourceStat] {
    var stats: [AllOverviewSnapshot.SourceStat] = []
    for item in aggregate.sources {
      stats.append(
        AllOverviewSnapshot.SourceStat(
          kind: item.kind,
          sessionCount: item.sessionCount,
          totalTokens: item.totalTokens,
          avgTokens: 0,
          avgDuration: item.sessionCount > 0 ? item.totalDuration / Double(item.sessionCount) : 0,
          isAll: false
        )
      )
    }
    if aggregate.totalSessions > 0 {
      let allStat = AllOverviewSnapshot.SourceStat(
        kind: .codex,  // placeholder when isAll=true
        sessionCount: aggregate.totalSessions,
        totalTokens: aggregate.totalTokens,
        avgTokens: 0,
        avgDuration: aggregate.totalSessions > 0 ? aggregate.totalDuration / Double(aggregate.totalSessions) : 0,
        isAll: true
      )
      stats.insert(allStat, at: 0)
    }
    return stats
  }

  private static func buildSourceStats(from sessions: [SessionSummary]) -> [AllOverviewSnapshot.SourceStat] {
    var groups: [SessionSource.Kind: [SessionSummary]] = [:]
    for session in sessions {
      groups[session.source.baseKind, default: []].append(session)
    }
    
    let kinds: [SessionSource.Kind] = [.codex, .claude, .gemini]
    
    var stats: [AllOverviewSnapshot.SourceStat] = kinds.compactMap { kind in
      let group = groups[kind] ?? []
      let count = group.count
      guard count > 0 else { return nil }
      
      let totalDuration = group.reduce(0) { $0 + $1.duration }
      let totalTokens = group.reduce(0) { $0 + $1.actualTotalTokens }
      
      return AllOverviewSnapshot.SourceStat(
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
      let totalTokens = sessions.reduce(0) { $0 + $1.actualTotalTokens }
      let count = sessions.count
      
      let allStat = AllOverviewSnapshot.SourceStat(
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

  private static func activityChartData(from aggregate: OverviewAggregate) -> ActivityChartData {
    guard !aggregate.daily.isEmpty else { return .empty }
    let points = aggregate.daily.map {
      ActivityChartDataPoint(
        date: $0.day,
        source: $0.kind,
        sessionCount: $0.sessionCount,
        duration: $0.totalDuration,
        totalTokens: $0.totalTokens
      )
    }
    return ActivityChartData(points: points.sorted { $0.date < $1.date }, unit: .day)
  }

  private func recomputeSnapshot() {
    scheduleSnapshotRefresh()
  }

  func resolveProject(for session: SessionSummary) -> (id: String, name: String)? {
    let projectId = sessionListViewModel.projectId(for: session)
    
    if projectId == SessionListViewModel.otherProjectId {
        return (id: projectId, name: "Unassigned") as? (id: String, name: String)
    }
    
    if let project = sessionListViewModel.projects.first(where: { $0.id == projectId }) {
        return (id: project.id, name: project.name)
    }
    return nil
  }
}

struct AllOverviewSnapshot: Equatable {
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
  var recentSessions: [SessionSummary]
  var sourceStats: [SourceStat]
  var activityChartData: ActivityChartData
  var usageSnapshots: [UsageProviderKind: UsageProviderSnapshot]
  var projectCount: Int
  var lastUpdated: Date

  static let empty = AllOverviewSnapshot(
    totalSessions: 0,
    totalDuration: 0,
    totalTokens: 0,
    userMessages: 0,
    assistantMessages: 0,
    recentSessions: [],
    sourceStats: [],
    activityChartData: .empty,
    usageSnapshots: [:],
    projectCount: 0,
    lastUpdated: .distantPast
  )
}

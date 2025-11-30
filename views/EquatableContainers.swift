import SwiftUI

// Equatable wrapper to minimize diffs for the Git Review panel when state is unchanged
struct EquatableGitChangesContainer: View, Equatable {
  struct Key: Equatable {
    var workingDirectoryPath: String
    var projectDirectoryPath: String?
    var state: ReviewPanelState
  }

  static func == (lhs: EquatableGitChangesContainer, rhs: EquatableGitChangesContainer) -> Bool {
    lhs.key == rhs.key
  }

  let key: Key
  let workingDirectory: URL
  let projectDirectory: URL?
  let presentation: GitChangesPanel.Presentation
  // Region layout: combined (default), leftOnly, or rightOnly
  var regionLayout: GitChangesPanel.RegionLayout = .combined
  let preferences: SessionPreferencesStore
  var onRequestAuthorization: (() -> Void)? = nil
  // Optional external shared VM; when nil, this container owns an internal VM
  var externalVM: GitChangesViewModel? = nil
  @Binding var savedState: ReviewPanelState

  @StateObject private var internalVM = GitChangesViewModel()

  var body: some View {
    let vm = externalVM ?? internalVM
    GitChangesPanel(
      workingDirectory: workingDirectory,
      projectDirectory: projectDirectory,
      presentation: presentation,
      regionLayout: regionLayout,
      preferences: preferences,
      onRequestAuthorization: onRequestAuthorization,
      savedState: $savedState,
      vm: vm
    )
  }
}

// Equatable wrapper for the Usage capsule to reduce AttributeGraph diffs.
struct EquatableUsageContainer: View, Equatable {
  struct UsageDigest: Equatable {
    var codexUpdatedAt: TimeInterval?
    var codexAvailability: Int
    var codexUrgentProgress: Double?
    var codexUrgentReset: TimeInterval?
    var codexOrigin: Int
    var codexStatusHash: Int
    var claudeUpdatedAt: TimeInterval?
    var claudeAvailability: Int
    var claudeUrgentProgress: Double?
    var claudeUrgentReset: TimeInterval?
    var claudeOrigin: Int
    var claudeStatusHash: Int
  }

  static func == (lhs: EquatableUsageContainer, rhs: EquatableUsageContainer) -> Bool {
    lhs.key == rhs.key
  }

  let key: UsageDigest

  var snapshots: [UsageProviderKind: UsageProviderSnapshot]
  @Binding var selectedProvider: UsageProviderKind
  var onRequestRefresh: (UsageProviderKind) -> Void

  init(
    snapshots: [UsageProviderKind: UsageProviderSnapshot],
    selectedProvider: Binding<UsageProviderKind>,
    onRequestRefresh: @escaping (UsageProviderKind) -> Void
  ) {
    self.snapshots = snapshots
    self._selectedProvider = selectedProvider
    self.onRequestRefresh = onRequestRefresh
    self.key = Self.digest(snapshots)
  }

  var body: some View {
    UsageStatusControl(
      snapshots: snapshots,
      selectedProvider: $selectedProvider,
      onRequestRefresh: onRequestRefresh
    )
  }

  private static func digest(_ snapshots: [UsageProviderKind: UsageProviderSnapshot]) -> UsageDigest
  {
    func parts(for provider: UsageProviderKind) -> (TimeInterval?, Int, Double?, TimeInterval?, Int, Int) {
      guard let snap = snapshots[provider] else { return (nil, -1, nil, nil, -1, 0) }
      let updated = snap.updatedAt?.timeIntervalSinceReferenceDate
      let availability: Int
      switch snap.availability {
      case .ready: availability = 1
      case .empty: availability = 2
      case .comingSoon: availability = 3
      }
      let urgentMetric = snap.urgentMetric()
      let urgent = urgentMetric?.progress
      let urgentReset = urgentMetric?.resetDate?.timeIntervalSinceReferenceDate
      let origin = snap.origin == .thirdParty ? 1 : 0
      var hasher = Hasher()
      if let message = snap.statusMessage {
        hasher.combine(message)
      }
      if let action = snap.action {
        hasher.combine(action)
      }
      let statusHash = hasher.finalize()
      return (updated, availability, urgent, urgentReset, origin, statusHash)
    }
    let cdx = parts(for: .codex)
    let cld = parts(for: .claude)
    return UsageDigest(
      codexUpdatedAt: cdx.0,
      codexAvailability: cdx.1,
      codexUrgentProgress: cdx.2,
      codexUrgentReset: cdx.3,
      codexOrigin: cdx.4,
      codexStatusHash: cdx.5,
      claudeUpdatedAt: cld.0,
      claudeAvailability: cld.1,
      claudeUrgentProgress: cld.2,
      claudeUrgentReset: cld.3,
      claudeOrigin: cld.4,
      claudeStatusHash: cld.5
    )
  }
}

// Digest for Sidebar state equality
struct SidebarDigest: Equatable {
  var projectsCount: Int
  var projectsIdsHash: Int
  var totalSessionCount: Int
  var selectedProjectsHash: Int
  var selectedDaysHash: Int
  var dateDimensionRaw: Int
  var monthStartInterval: TimeInterval
  var calendarCountsHash: Int
  var enabledDaysHash: Int
  var visibleAllCount: Int
  var projectWorkspaceMode: ProjectWorkspaceMode
}

// Equatable wrapper for the Sidebar content to minimize diffs while keeping
// the internal view hierarchy (which still uses EnvironmentObject) unchanged.
struct EquatableSidebarContainer<Content: View>: View, Equatable {
  static func == (lhs: EquatableSidebarContainer<Content>, rhs: EquatableSidebarContainer<Content>)
    -> Bool
  {
    lhs.key == rhs.key
  }

  let key: SidebarDigest
  let content: () -> Content

  var body: some View { content() }
}

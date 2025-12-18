import Foundation

enum UsageProviderKind: String, CaseIterable, Identifiable {
  case codex
  case claude
  case gemini

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .codex: return "Codex"
    case .claude: return "Claude"
    case .gemini: return "Gemini"
    }
  }

  var accentColorName: String {
    switch self {
    case .codex: return "accentColor"
    case .claude: return "purple"
    case .gemini: return "teal"
    }
  }
}

struct UsageMetricSnapshot: Identifiable, Equatable {
  enum Kind { case context, fiveHour, weekly, sessionExpiry, quota, snapshot }

  let id = UUID()
  let kind: Kind
  let label: String
  let usageText: String?
  let percentText: String?
  let progress: Double?
  let resetDate: Date?
  let fallbackWindowMinutes: Int?

  fileprivate var priorityDate: Date? { resetDate }
}

enum UsageProviderOrigin: String, Equatable {
  case builtin
  case thirdParty
}

struct UsageProviderSnapshot: Identifiable, Equatable {
  enum Availability { case ready, empty, comingSoon }
  enum Action: Hashable {
    case refresh
    case authorizeKeychain
  }

  let id = UUID()
  let provider: UsageProviderKind
  let title: String
  /// Optional short badge shown as a superscript next to the provider title (e.g., "Pro", "Plus").
  let titleBadge: String?
  let availability: Availability
  let metrics: [UsageMetricSnapshot]
  let updatedAt: Date?
  let statusMessage: String?
  let requiresReauth: Bool  // True when user needs to re-authenticate
  let origin: UsageProviderOrigin
  let action: Action?

  init(
    provider: UsageProviderKind,
    title: String,
    titleBadge: String? = nil,
    availability: Availability,
    metrics: [UsageMetricSnapshot],
    updatedAt: Date?,
    statusMessage: String? = nil,
    requiresReauth: Bool = false,
    origin: UsageProviderOrigin = .builtin,
    action: Action? = nil
  ) {
    self.provider = provider
    self.title = title
    self.titleBadge = titleBadge
    self.availability = availability
    self.metrics = metrics
    self.updatedAt = updatedAt
    self.statusMessage = statusMessage
    self.requiresReauth = requiresReauth
    self.origin = origin
    self.action = action
  }

  func urgentMetric(relativeTo now: Date = Date()) -> UsageMetricSnapshot? {
    let ordered =
      metrics
      .filter { $0.kind != .snapshot && $0.kind != .context }
      .sorted(by: { a, b in
        // For quota-style metrics, prioritize the lowest remaining fraction first.
        if a.kind == .quota && b.kind == .quota {
          let ap = a.progress ?? 1
          let bp = b.progress ?? 1
          if ap != bp { return ap < bp }
        }
        switch (a.priorityDate, b.priorityDate) {
        case (let lhs?, let rhs?): return lhs < rhs
        case (_?, nil): return true
        case (nil, _?): return false
        default: return a.kind == .fiveHour
        }
      })

    if let future = ordered.first(where: { metric in
      if let reset = metric.resetDate {
        return reset > now
      }
      if metric.resetDate == nil, let minutes = metric.fallbackWindowMinutes {
        return minutes > 0
      }
      return false
    }) {
      return future
    }
    return ordered.first
  }

  static func placeholder(
    _ provider: UsageProviderKind,
    message: String,
    action: Action? = .refresh
  ) -> UsageProviderSnapshot {
    UsageProviderSnapshot(
      provider: provider,
      title: provider.displayName,
      titleBadge: nil,
      availability: .comingSoon,
      metrics: [],
      updatedAt: nil,
      statusMessage: message,
      origin: .builtin,
      action: action
    )
  }
}

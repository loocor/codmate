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
    let candidates = metrics.filter { $0.kind != .snapshot && $0.kind != .context }
    guard !candidates.isEmpty else { return nil }

    // Step 1: If any limit is depleted (≤0.1%), prioritize the one with longest reset time
    // This ensures we show the most restrictive bottleneck
    let depleted = candidates.filter { ($0.progress ?? 1) <= 0.001 }
    if !depleted.isEmpty {
      return depleted.max(by: { a, b in
        let aReset = a.resetDate?.timeIntervalSince(now) ?? 0
        let bReset = b.resetDate?.timeIntervalSince(now) ?? 0
        return aReset < bReset
      })
    }

    // Step 2: Filter out metrics that reset very soon (<5 minutes)
    // They're not representative of the stable state
    let significant = candidates.filter { metric in
      guard let reset = metric.resetDate else { return true }
      let remaining = reset.timeIntervalSince(now)
      return remaining > 5 * 60 || remaining <= 0
    }

    // Step 3: Calculate urgency score and return the most urgent
    // Urgency = (consumption %) × log(1 + reset hours)
    // Higher score = more urgent = should be displayed
    return significant.max(by: { a, b in
      urgencyScore(for: a, relativeTo: now) < urgencyScore(for: b, relativeTo: now)
    })
  }

  private func urgencyScore(for metric: UsageMetricSnapshot, relativeTo now: Date) -> Double {
    // Calculate consumption (0..1, where 1 = fully consumed)
    let consumed = 1.0 - (metric.progress ?? 0)

    // Calculate reset time in minutes
    let resetMinutes: Double
    if let reset = metric.resetDate {
      resetMinutes = max(0, reset.timeIntervalSince(now) / 60)
    } else if let fallback = metric.fallbackWindowMinutes {
      resetMinutes = Double(fallback)
    } else {
      resetMinutes = 0
    }

    // Urgency score = consumption × log(1 + reset hours)
    // The log ensures diminishing importance for longer times
    // e.g., 10min→1h matters more than 1day→2days
    let resetHours = resetMinutes / 60.0
    return consumed * log(1.0 + resetHours)
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

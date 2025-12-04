import Foundation

struct OverviewSourceAggregate: Sendable {
  let kind: SessionSource.Kind
  let sessionCount: Int
  let totalTokens: Int
  let totalDuration: TimeInterval
  let userMessages: Int
  let assistantMessages: Int
  let toolInvocations: Int
}

struct OverviewDailyPoint: Sendable {
  let day: Date  // start of day in local time
  let kind: SessionSource.Kind
  let sessionCount: Int
  let totalTokens: Int
  let totalDuration: TimeInterval
}

struct OverviewAggregate: Sendable {
  let totalSessions: Int
  let totalTokens: Int
  let totalDuration: TimeInterval
  let userMessages: Int
  let assistantMessages: Int
  let toolInvocations: Int
  let sources: [OverviewSourceAggregate]
  let daily: [OverviewDailyPoint]
  let generatedAt: Date
}

struct SessionIndexCoverage: Sendable {
  let sessionCount: Int
  let lastFullIndexAt: Date?
  let sources: [SessionSource.Kind]
}

struct OverviewAggregateScope: Sendable {
  let dateDimension: DateDimension
  let start: Date
  let end: Date
  let projectIds: Set<String>?
}

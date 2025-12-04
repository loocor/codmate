import Foundation

enum SessionProviderCachePolicy: Sendable {
  case cacheOnly
  case refresh
}

struct SessionProviderContext: Sendable {
  let scope: SessionLoadScope
  /// Local sessions root (Codex) if applicable.
  let sessionsRoot: URL?
  /// Enabled remote hosts for remote providers.
  let enabledRemoteHosts: Set<String>
  /// Optional project directories (canonical paths) to narrow enumeration.
  let projectDirectories: [String]?
  /// Current date dimension for date-range filtering (created vs. updated).
  let dateDimension: DateDimension
  /// Optional date range filter (start/end, inclusive) derived from UI selection.
  let dateRange: (Date, Date)?
  /// Optional project filter (single project preferred).
  let projectIds: Set<String>?
  let cachePolicy: SessionProviderCachePolicy
}

struct SessionProviderResult: Sendable {
  let summaries: [SessionSummary]
  /// Best-effort coverage info if the provider can surface it (e.g., SQLite meta).
  let coverage: SessionIndexCoverage?
  /// True when results came fully from cache without touching the filesystem.
  let cacheHit: Bool
}

protocol SessionProvider: Sendable {
  var kind: SessionSource.Kind { get }
  var identifier: String { get }
  var label: String { get }
  func load(context: SessionProviderContext) async throws -> SessionProviderResult
}

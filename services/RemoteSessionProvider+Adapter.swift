import Foundation

struct RemoteSessionProviderAdapter: SessionProvider {
  let kind: SessionSource.Kind
  let identifier: String
  let label: String
  let remoteKind: RemoteSessionKind
  let provider: RemoteSessionProvider

  init(kind: SessionSource.Kind, remoteKind: RemoteSessionKind, provider: RemoteSessionProvider, label: String) {
    self.kind = kind
    self.remoteKind = remoteKind
    self.provider = provider
    self.identifier = "remote-\(label.lowercased())"
    self.label = label
  }

  func load(context: SessionProviderContext) async throws -> SessionProviderResult {
    let hosts = context.enabledRemoteHosts
    guard !hosts.isEmpty else {
      return SessionProviderResult(summaries: [], coverage: nil, cacheHit: true)
    }
    switch remoteKind {
    case .codex:
      let summaries = await provider.codexSessions(scope: context.scope, enabledHosts: hosts)
      return SessionProviderResult(summaries: summaries, coverage: nil, cacheHit: false)
    case .claude:
      let summaries = await provider.claudeSessions(scope: context.scope, enabledHosts: hosts)
      return SessionProviderResult(summaries: summaries, coverage: nil, cacheHit: false)
    }
  }
}

import Foundation

enum EmbeddedSessionNotification {
  static let sessionIdKey = "sessionId"
  static let sourceDataKey = "sourceData"

  static func postEmbeddedNewSession(sessionId: String, source: SessionSource) {
    NotificationCenter.default.post(
      name: .codMateStartEmbeddedNewSession,
      object: nil,
      userInfo: userInfo(sessionId: sessionId, source: source)
    )
  }

  static func userInfo(sessionId: String, source: SessionSource) -> [AnyHashable: Any] {
    var info: [AnyHashable: Any] = [sessionIdKey: sessionId]
    if let data = try? JSONEncoder().encode(source) {
      info[sourceDataKey] = data
    }
    return info
  }

  static func decodeSource(from userInfo: [AnyHashable: Any]?) -> SessionSource? {
    guard let data = userInfo?[sourceDataKey] as? Data else { return nil }
    return try? JSONDecoder().decode(SessionSource.self, from: data)
  }
}

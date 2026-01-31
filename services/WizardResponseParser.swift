import Foundation

enum WizardResponseParser {
  static func decode<T: Decodable>(_ raw: String) -> T? {
    let cleaned = stripCodeFences(raw)
    if let value: T = decodeJSON(cleaned) {
      return value
    }
    if let unwrapped = unwrapPayloadText(cleaned), unwrapped != cleaned {
      return decode(unwrapped)
    }
    return nil
  }

  static func decodeEnvelope<T: Decodable>(_ raw: String) -> WizardDraftEnvelope<T>? {
    let cleaned = stripCodeFences(raw)
    if let envelope: WizardDraftEnvelope<T> = decodeJSON(cleaned) {
      return envelope
    }
    if let unwrapped = unwrapPayloadText(cleaned), unwrapped != cleaned {
      return decodeEnvelope(unwrapped)
    }
    return nil
  }

  private static func decodeJSON<T: Decodable>(_ raw: String) -> T? {
    guard let data = raw.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
  }

  private static func unwrapPayloadText(_ raw: String) -> String? {
    guard let data = raw.data(using: .utf8) else { return nil }
    guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
    return extractText(from: json)
  }

  private static func extractText(from value: Any) -> String? {
    if let text = value as? String {
      return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let dict = value as? [String: Any] {
      let keys = ["result", "response", "content", "text", "message", "output"]
      for key in keys {
        if let nested = dict[key], let text = extractText(from: nested) {
          return text
        }
      }
    }
    if let array = value as? [Any] {
      for item in array {
        if let text = extractText(from: item) {
          return text
        }
      }
    }
    return nil
  }

  private static func stripCodeFences(_ raw: String) -> String {
    var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned.hasPrefix("```") {
      if let firstNewline = cleaned.firstIndex(of: "\n") {
        cleaned = String(cleaned[cleaned.index(after: firstNewline)...])
      }
      if let lastFence = cleaned.range(of: "```", options: .backwards) {
        cleaned = String(cleaned[..<lastFence.lowerBound])
      }
      cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return cleaned
  }
}

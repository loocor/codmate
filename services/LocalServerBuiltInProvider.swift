import Foundation

enum LocalServerBuiltInProvider: String, CaseIterable, Identifiable {
    case anthropic
    case gemini
    case openai

    var id: String { "local-builtin-\(rawValue)" }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic (built-in)"
        case .gemini: return "Gemini (built-in)"
        case .openai: return "OpenAI (built-in)"
        }
    }

    var ownedByHints: [String] {
        switch self {
        case .anthropic: return ["anthropic"]
        case .gemini: return ["google", "gemini"]
        case .openai: return ["openai"]
        }
    }

    func matchesOwnedBy(_ value: String?) -> Bool {
        let lower = (value ?? "").lowercased()
        return ownedByHints.contains { lower.contains($0) }
    }

    static func from(providerId: String?) -> LocalServerBuiltInProvider? {
        guard let providerId else { return nil }
        return LocalServerBuiltInProvider.allCases.first(where: { $0.id == providerId })
    }
}

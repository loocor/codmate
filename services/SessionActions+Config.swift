import Foundation

extension SessionActions {
    func normalizedCodexModelName(_ raw: String?) -> String? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        let lower = text.lowercased()
        switch lower {
        case "gpt-5", "gpt5":
            return "gpt-5.1"
        case "gpt-5-codex", "gpt5-codex":
            return "gpt-5.1-codex"
        case "gpt-5-codex-max", "gpt5-codex-max":
            return "gpt-5.1-codex-max"
        case "gpt-5-codex-mini", "gpt5-codex-mini":
            return "gpt-5.1-codex-mini"
        default:
            return text
        }
    }

    func listPersistedProfiles() -> Set<String> {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("config.toml", isDirectory: false)
        guard let data = try? Data(contentsOf: configURL),
            let raw = String(data: data, encoding: .utf8)
        else {
            return []
        }
        var out: Set<String> = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: CharacterSet.whitespaces)
            if t.hasPrefix("[profiles.") && t.hasSuffix("]") {
                let start = "[profiles.".count
                let endIndex = t.index(before: t.endIndex)
                let id = String(t[t.index(t.startIndex, offsetBy: start)..<endIndex])
                let trimmed = id.trimmingCharacters(in: CharacterSet.whitespaces)
                if !trimmed.isEmpty { out.insert(trimmed) }
            }
        }
        return out
    }

    func persistedProfileExists(_ id: String?) -> Bool {
        guard let id, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return listPersistedProfiles().contains(id)
    }

    func readTopLevelConfigString(_ key: String) -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("config.toml", isDirectory: false)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let t = raw.trimmingCharacters(in: CharacterSet.whitespaces)
            guard t.hasPrefix(key + " ") || t.hasPrefix(key + "=") else { continue }
            guard let eq = t.firstIndex(of: "=") else { continue }
            var value = String(t[t.index(after: eq)...]).trimmingCharacters(in: CharacterSet.whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") {
                value.removeFirst()
                value.removeLast()
            }
            return value
        }
        return nil
    }

    func effectiveCodexModel(for session: SessionSummary) -> String? {
        if let configured = normalizedCodexModelName(readTopLevelConfigString("model")) {
            return configured
        }
        if session.source.baseKind == .codex {
            if let normalized = normalizedCodexModelName(session.model) {
                return normalized
            }
        }
        return nil
    }

    func renderInlineProfileConfig(
        key id: String,
        model: String?,
        approvalPolicy: String?,
        sandboxMode: String?
    ) -> String? {
        var pairs: [String] = []
        if let normalized = normalizedCodexModelName(model) {
            let val = normalized.replacingOccurrences(of: "\"", with: "\\\"")
            pairs.append("model=\"\(val)\"")
        }
        if let approval = approvalPolicy,
            !approval.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            let val = approval.replacingOccurrences(of: "\"", with: "\\\"")
            pairs.append("approval_policy=\"\(val)\"")
        }
        if let sandbox = sandboxMode,
            !sandbox.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            let val = sandbox.replacingOccurrences(of: "\"", with: "\\\"")
            pairs.append("sandbox_mode=\"\(val)\"")
        }
        guard !pairs.isEmpty else { return nil }
        return "profiles.\(id)={ \(pairs.joined(separator: ", ")) }"
    }
}

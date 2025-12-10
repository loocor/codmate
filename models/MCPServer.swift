import Foundation

// MARK: - MCP Server Models

public enum MCPServerKind: String, Codable, Sendable { case stdio, sse, streamable_http }

public struct MCPCapability: Codable, Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var enabled: Bool
}

public struct MCPServerMeta: Codable, Equatable, Sendable {
    public var description: String?
    public var version: String?
    public var websiteUrl: String?
    public var repositoryURL: String?
}

public enum MCPServerTarget: String, Codable, CaseIterable, Sendable {
    case codex
    case claude
    case gemini
}

public struct MCPServerTargets: Codable, Equatable, Sendable {
    public var codex: Bool
    public var claude: Bool
    public var gemini: Bool

    public init(codex: Bool = true, claude: Bool = true, gemini: Bool = true) {
        self.codex = codex
        self.claude = claude
        self.gemini = gemini
    }

    public func isEnabled(for target: MCPServerTarget) -> Bool {
        switch target {
        case .codex: return codex
        case .claude: return claude
        case .gemini: return gemini
        }
    }

    public mutating func setEnabled(_ value: Bool, for target: MCPServerTarget) {
        switch target {
        case .codex:
            codex = value
        case .claude:
            claude = value
        case .gemini:
            gemini = value
        }
    }
}

public struct MCPServer: Codable, Identifiable, Equatable, Sendable {
    public var id: String { name }
    public var name: String
    public var kind: MCPServerKind

    // stdio
    public var command: String?
    public var args: [String]?
    public var env: [String: String]?

    // network
    public var url: String?
    public var headers: [String: String]?

    // meta
    public var meta: MCPServerMeta?

    // dynamic
    public var enabled: Bool
    public var capabilities: [MCPCapability]
    public var targets: MCPServerTargets?

    public init(
        name: String,
        kind: MCPServerKind,
        command: String? = nil,
        args: [String]? = nil,
        env: [String: String]? = nil,
        url: String? = nil,
        headers: [String: String]? = nil,
        meta: MCPServerMeta? = nil,
        enabled: Bool = true,
        capabilities: [MCPCapability] = [],
        targets: MCPServerTargets? = nil
    ) {
        self.name = name
        self.kind = kind
        self.command = command
        self.args = args
        self.env = env
        self.url = url
        self.headers = headers
        self.meta = meta
        self.enabled = enabled
        self.capabilities = capabilities
        self.targets = targets
    }

    public func isEnabled(for target: MCPServerTarget) -> Bool {
        guard enabled else { return false }
        return (targets?.isEnabled(for: target) ?? true)
    }

    public func withTargets(_ update: (inout MCPServerTargets) -> Void) -> MCPServer {
        var copy = self
        var current = copy.targets ?? MCPServerTargets()
        update(&current)
        copy.targets = current
        return copy
    }
}

// A lightweight draft parsed from import payloads before persistence
public struct MCPServerDraft: Codable, Sendable {
    public var name: String?
    public var kind: MCPServerKind
    public var command: String?
    public var args: [String]?
    public var env: [String: String]?
    public var url: String?
    public var headers: [String: String]?
    public var meta: MCPServerMeta?
}

public extension Array where Element == MCPServer {
    func enabledServers(for target: MCPServerTarget) -> [MCPServer] {
        filter { $0.isEnabled(for: target) }
    }
}

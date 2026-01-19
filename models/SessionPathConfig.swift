import Foundation

struct SessionPathConfig: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let kind: SessionSource.Kind
    var path: String
    var enabled: Bool
    var displayName: String?
    var ignoredSubpaths: [String]
    var disabledSubpaths: Set<String>

    var isDefault: Bool {
        displayName != nil
    }

    init(
        id: String = UUID().uuidString,
        kind: SessionSource.Kind,
        path: String,
        enabled: Bool = true,
        displayName: String? = nil,
        ignoredSubpaths: [String] = [],
        disabledSubpaths: Set<String> = []
    ) {
        self.id = id
        self.kind = kind
        self.path = path
        self.enabled = enabled
        self.displayName = displayName
        self.ignoredSubpaths = ignoredSubpaths
        self.disabledSubpaths = disabledSubpaths
    }

    // Custom Codable implementation for backward compatibility
    enum CodingKeys: String, CodingKey {
        case id, kind, path, enabled, displayName, ignoredSubpaths, disabledSubpaths
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(SessionSource.Kind.self, forKey: .kind)
        path = try container.decode(String.self, forKey: .path)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        ignoredSubpaths =
            try container.decodeIfPresent([String].self, forKey: .ignoredSubpaths) ?? []
        // Backward compatibility: if disabledSubpaths is missing, default to empty set
        disabledSubpaths =
            try container.decodeIfPresent(Set<String>.self, forKey: .disabledSubpaths) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(path, forKey: .path)
        try container.encode(enabled, forKey: .enabled)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encode(ignoredSubpaths, forKey: .ignoredSubpaths)
        try container.encode(disabledSubpaths, forKey: .disabledSubpaths)
    }
}

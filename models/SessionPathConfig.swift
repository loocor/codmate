import Foundation

struct SessionPathConfig: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let kind: SessionSource.Kind
    var path: String
    var enabled: Bool
    var displayName: String?
    var ignoredSubpaths: [String]
    
    var isDefault: Bool {
        displayName != nil
    }
    
    init(
        id: String = UUID().uuidString,
        kind: SessionSource.Kind,
        path: String,
        enabled: Bool = true,
        displayName: String? = nil,
        ignoredSubpaths: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.path = path
        self.enabled = enabled
        self.displayName = displayName
        self.ignoredSubpaths = ignoredSubpaths
    }
}

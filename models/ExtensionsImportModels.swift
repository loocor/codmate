import Foundation

enum ImportResolutionChoice: String, CaseIterable, Identifiable {
  case skip
  case overwrite
  case rename

  var id: String { rawValue }

  var title: String {
    switch self {
    case .skip: return "Skip"
    case .overwrite: return "Overwrite"
    case .rename: return "Rename"
    }
  }
}

enum ExtensionsImportScope: Hashable {
  case home
  case project(directory: URL)
}

struct CommandImportCandidate: Identifiable, Hashable {
  var id: String
  var name: String
  var description: String
  var prompt: String
  var metadata: CommandMetadata
  var sources: [String]
  var sourcePaths: [String: String]
  var isSelected: Bool
  var hasConflict: Bool
  var resolution: ImportResolutionChoice
  var renameId: String

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }

  static func == (lhs: CommandImportCandidate, rhs: CommandImportCandidate) -> Bool {
    lhs.id == rhs.id
  }
}

struct SkillImportCandidate: Identifiable, Hashable {
  var id: String
  var name: String
  var summary: String
  var sourcePath: String
  var sources: [String]
  var sourcePaths: [String: String]
  var isSelected: Bool
  var hasConflict: Bool
  var conflictDetail: String?
  var resolution: ImportResolutionChoice
  var renameId: String
  var suggestedId: String

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }

  static func == (lhs: SkillImportCandidate, rhs: SkillImportCandidate) -> Bool {
    lhs.id == rhs.id
  }
}

struct MCPImportCandidate: Identifiable {
  let id: UUID
  var name: String
  var kind: MCPServerKind
  var command: String?
  var args: [String]?
  var env: [String: String]?
  var url: String?
  var headers: [String: String]?
  var description: String?
  var sources: [String]
  var sourcePaths: [String: String]
  var isSelected: Bool
  var hasConflict: Bool
  var hasNameCollision: Bool
  var resolution: ImportResolutionChoice
  var renameName: String
  var signature: String
}

struct HookImportCandidate: Identifiable, Hashable {
  let id: UUID
  var rule: HookRule
  var sources: [String]
  var sourcePaths: [String: String]
  var isSelected: Bool
  var hasConflict: Bool
  var hasNameCollision: Bool
  var resolution: ImportResolutionChoice
  var renameName: String
  var signature: String

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }

  static func == (lhs: HookImportCandidate, rhs: HookImportCandidate) -> Bool {
    lhs.id == rhs.id
  }
}

import Foundation

enum InternalSkillIOMode: String, Codable, Sendable {
  case stdin
  case file
}

enum InternalSkillOutputMode: String, Codable, Sendable {
  case stdout
  case file
}

struct InternalSkillInvocation: Codable, Hashable, Sendable {
  var provider: SessionSource.Kind
  var executable: String?
  var args: [String]
  var inputMode: InternalSkillIOMode
  var outputMode: InternalSkillOutputMode
  var timeoutSeconds: Double?
}

struct InternalSkillAssetPaths: Codable, Hashable, Sendable {
  var skill: String?
  var prompt: String?
  var schema: String?
  var docs: String?
}

struct InternalSkillDefinition: Codable, Identifiable, Hashable, Sendable {
  var id: String
  var feature: WizardFeature
  var title: String
  var description: String?
  var version: String?
  var assets: InternalSkillAssetPaths?
  var invocations: [InternalSkillInvocation]
  var docsSources: [WizardDocSource]?

  var displayTitle: String { title.isEmpty ? id : title }
}

struct InternalSkillsIndex: Codable, Hashable, Sendable {
  var skills: [InternalSkillDefinition]
}

struct InternalSkillAsset: Hashable, Sendable {
  var definition: InternalSkillDefinition
  var rootURL: URL
  var skillMarkdown: String?
  var prompt: String?
  var schema: String?
  var docsOverrides: [WizardDocSource]
}

struct WizardDocSource: Codable, Hashable, Sendable {
  var feature: WizardFeature
  var provider: String?
  var url: String
  var maxChars: Int?
  var cacheTTLHours: Int?
}

struct WizardDocSnippet: Codable, Hashable, Sendable {
  var url: String
  var provider: String?
  var text: String
}

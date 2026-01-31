import Foundation
import AppKit

actor WizardDocsService {
  private struct DocsIndex: Codable {
    var sources: [WizardDocSource]
  }

  private struct CachedDoc: Codable {
    var url: String
    var fetchedAt: Date
    var text: String
  }

  private let fileManager: FileManager
  private let cacheURL: URL
  private var cache: [String: CachedDoc]
  private var globalSources: [WizardDocSource]

  init() {
    let fm = FileManager.default
    fileManager = fm
    cacheURL = Self.defaultCacheURL(using: fm)
    globalSources = Self.loadGlobalSourcesSync()
    cache = Self.loadCacheSync(cacheURL: cacheURL)
  }

  func snippets(
    feature: WizardFeature,
    provider: SessionSource.Kind,
    overrides: [WizardDocSource] = [],
    keywords: [String] = []
  ) async -> [WizardDocSnippet] {
    let sources = mergedSources(feature: feature, provider: provider, overrides: overrides)
    guard !sources.isEmpty else { return [] }
    var out: [WizardDocSnippet] = []
    for src in sources {
      let text = await loadText(from: src)
      guard !text.isEmpty else { continue }
      let filtered = extractRelevant(text: text, keywords: keywords, maxChars: src.maxChars)
      if !filtered.isEmpty {
        out.append(WizardDocSnippet(url: src.url, provider: src.provider, text: filtered))
      }
    }
    return out
  }

  // MARK: - Sources

  private func mergedSources(
    feature: WizardFeature,
    provider: SessionSource.Kind,
    overrides: [WizardDocSource]
  ) -> [WizardDocSource] {
    let providerKey = provider.rawValue
    var out: [WizardDocSource] = []
    let fromOverrides = overrides.filter {
      $0.feature == feature && ($0.provider == nil || $0.provider == providerKey)
    }
    if !fromOverrides.isEmpty { out.append(contentsOf: fromOverrides) }
    let fromGlobal = globalSources.filter {
      $0.feature == feature && ($0.provider == nil || $0.provider == providerKey)
    }
    out.append(contentsOf: fromGlobal)
    return out
  }

  private static func defaultCacheURL(using fileManager: FileManager) -> URL {
    let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
    return (caches ?? fileManager.temporaryDirectory)
      .appendingPathComponent("CodMate", isDirectory: true)
      .appendingPathComponent("wizard-docs-cache.json", isDirectory: false)
  }

  private static func loadGlobalSourcesSync() -> [WizardDocSource] {
    let bundle = Bundle.main
    var url = bundle.url(
      forResource: "wizard-docs",
      withExtension: "json",
      subdirectory: "payload/knowledge"
    )
    if url == nil, let devRoot = devPayloadRootURL() {
      url = devRoot
        .appendingPathComponent("knowledge", isDirectory: true)
        .appendingPathComponent("wizard-docs.json", isDirectory: false)
    }
    guard let resolved = url else { return [] }
    guard let data = try? Data(contentsOf: resolved) else { return [] }
    let decoder = JSONDecoder()
    let parsed = (try? decoder.decode(DocsIndex.self, from: data))?.sources ?? []
    return parsed
  }

  private static func devPayloadRootURL() -> URL? {
    let fm = FileManager.default
    let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
    if let found = findPayloadRoot(startingAt: cwd, fileManager: fm) {
      return found
    }
    if let execURL = Bundle.main.executableURL {
      let execDir = execURL.deletingLastPathComponent()
      if let found = findPayloadRoot(startingAt: execDir, fileManager: fm) {
        return found
      }
    }
    return nil
  }

  private static func findPayloadRoot(startingAt start: URL, fileManager: FileManager) -> URL? {
    var current = start
    for _ in 0..<6 {
      let candidate = current
        .appendingPathComponent("payload", isDirectory: true)
        .appendingPathComponent("knowledge", isDirectory: true)
        .appendingPathComponent("wizard-docs.json", isDirectory: false)
      if fileManager.fileExists(atPath: candidate.path) {
        return current.appendingPathComponent("payload", isDirectory: true)
      }
      current = current.deletingLastPathComponent()
    }
    return nil
  }

  // MARK: - Cache

  private static func loadCacheSync(cacheURL: URL) -> [String: CachedDoc] {
    guard let data = try? Data(contentsOf: cacheURL) else { return [:] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    if let list = try? decoder.decode([CachedDoc].self, from: data) {
      return Dictionary(uniqueKeysWithValues: list.map { ($0.url, $0) })
    }
    return [:]
  }

  private func saveCache() {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    let list = Array(cache.values)
    guard let data = try? encoder.encode(list) else { return }
    try? fileManager.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: cacheURL, options: .atomic)
  }

  // MARK: - Fetch

  private func loadText(from source: WizardDocSource) async -> String {
    let ttl = TimeInterval((source.cacheTTLHours ?? 72) * 3600)
    if let cached = cache[source.url], Date().timeIntervalSince(cached.fetchedAt) < ttl {
      return cached.text
    }

    guard let url = URL(string: source.url) else { return "" }
    do {
      let (data, _) = try await URLSession.shared.data(from: url)
      let text = decodeHTML(data) ?? String(data: data, encoding: .utf8) ?? ""
      if !text.isEmpty {
        cache[source.url] = CachedDoc(url: source.url, fetchedAt: Date(), text: text)
        saveCache()
      }
      return text
    } catch {
      return ""
    }
  }

  private func decodeHTML(_ data: Data) -> String? {
    let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
      .documentType: NSAttributedString.DocumentType.html,
      .characterEncoding: String.Encoding.utf8.rawValue
    ]
    if let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil) {
      return attributed.string
    }
    return nil
  }

  private func extractRelevant(text: String, keywords: [String], maxChars: Int?) -> String {
    let limit = maxChars ?? 3000
    let trimmed = text.replacingOccurrences(of: "\r", with: "")
    let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if keywords.isEmpty {
      return String(trimmed.prefix(limit))
    }
    let loweredKeywords = keywords.map { $0.lowercased() }
    var matched: [String] = []
    for (idx, line) in lines.enumerated() {
      let lower = line.lowercased()
      if loweredKeywords.contains(where: { lower.contains($0) }) {
        let prev = idx > 0 ? lines[idx - 1] : ""
        let next = idx + 1 < lines.count ? lines[idx + 1] : ""
        matched.append(prev)
        matched.append(line)
        matched.append(next)
      }
    }
    let joined = matched.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    if joined.isEmpty {
      return String(trimmed.prefix(limit))
    }
    return String(joined.prefix(limit))
  }
}

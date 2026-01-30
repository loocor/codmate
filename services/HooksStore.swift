import Foundation

actor HooksStore {
  struct Paths { let home: URL; let fileURL: URL }

  static func defaultPaths(fileManager: FileManager = .default) -> Paths {
    let home = SessionPreferencesStore.getRealUserHomeURL()
      .appendingPathComponent(".codmate", isDirectory: true)
    return Paths(home: home, fileURL: home.appendingPathComponent("hooks.json", isDirectory: false))
  }

  private let fm: FileManager
  private let paths: Paths
  private var cache: [HookRule]? = nil

  init(paths: Paths = HooksStore.defaultPaths(), fileManager: FileManager = .default) {
    self.paths = paths
    self.fm = fileManager
  }

  func list() -> [HookRule] { load() }

  func upsert(_ rule: HookRule) throws {
    var list = load()
    if let idx = list.firstIndex(where: { $0.id == rule.id }) {
      list[idx] = rule
    } else {
      list.append(rule)
    }
    try save(list)
  }

  func upsertMany(_ rules: [HookRule]) throws {
    var map: [String: HookRule] = [:]
    for item in load() { map[item.id] = item }
    for item in rules { map[item.id] = item }
    // Preserve stable ordering by updatedAt, then name.
    let sorted = map.values.sorted { lhs, rhs in
      if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
      return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
    try save(sorted)
  }

  func delete(id: String) throws {
    var list = load()
    list.removeAll { $0.id == id }
    try save(list)
  }

  func update(id: String, mutate: (inout HookRule) -> Void) throws {
    var list = load()
    guard let idx = list.firstIndex(where: { $0.id == id }) else { return }
    var updated = list[idx]
    mutate(&updated)
    list[idx] = updated
    try save(list)
  }

  // MARK: - Private

  private func load() -> [HookRule] {
    if let cache { return cache }
    guard let data = try? Data(contentsOf: paths.fileURL) else {
      cache = []
      return []
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    if let list = try? decoder.decode([HookRule].self, from: data) {
      cache = list
      return list
    }
    cache = []
    return []
  }

  private func save(_ list: [HookRule]) throws {
    try fm.createDirectory(at: paths.home, withIntermediateDirectories: true)
    let tmp = paths.fileURL.appendingPathExtension("tmp")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(list)
    try data.write(to: tmp, options: .atomic)
    if fm.fileExists(atPath: paths.fileURL.path) { try fm.removeItem(at: paths.fileURL) }
    try fm.moveItem(at: tmp, to: paths.fileURL)
    cache = list
  }
}


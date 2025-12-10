import Foundation

actor GeminiSettingsService {
  struct Paths {
    let directory: URL
    let file: URL

    static func `default`() -> Paths {
      let home = SessionPreferencesStore.getRealUserHomeURL()
      let dir = home.appendingPathComponent(".gemini", isDirectory: true)
      return Paths(directory: dir, file: dir.appendingPathComponent("settings.json", isDirectory: false))
    }
  }

  struct Snapshot: Sendable {
    var previewFeatures: Bool?
    var vimMode: Bool?
    var disableAutoUpdate: Bool?
    var enablePromptCompletion: Bool?
    var sessionRetentionEnabled: Bool?
    var modelName: String?
    var maxSessionTurns: Int?
    var compressionThreshold: Double?
    var skipNextSpeakerCheck: Bool?
  }

  private typealias JSONObject = [String: Any]

  private let paths: Paths
  private let fm: FileManager

  init(paths: Paths = .default(), fileManager: FileManager = .default) {
    self.paths = paths
    self.fm = fileManager
  }

  nonisolated var settingsFileURL: URL { paths.file }

  // MARK: - Public API

  func loadSnapshot() -> Snapshot {
    let object = loadJSONObject()
    return Snapshot(
      previewFeatures: boolValue(in: object, path: ["general", "previewFeatures"]),
      vimMode: boolValue(in: object, path: ["general", "vimMode"]),
      disableAutoUpdate: boolValue(in: object, path: ["general", "disableAutoUpdate"]),
      enablePromptCompletion: boolValue(in: object, path: ["general", "enablePromptCompletion"]),
      sessionRetentionEnabled: boolValue(in: object, path: ["general", "sessionRetention", "enabled"]),
      modelName: stringValue(in: object, path: ["model", "name"]),
      maxSessionTurns: intValue(in: object, path: ["model", "maxSessionTurns"]),
      compressionThreshold: doubleValue(in: object, path: ["model", "compressionThreshold"]),
      skipNextSpeakerCheck: boolValue(in: object, path: ["model", "skipNextSpeakerCheck"])
    )
  }

  func loadRawText() -> String {
    (try? String(contentsOf: paths.file, encoding: .utf8)) ?? ""
  }

  func setBool(_ value: Bool, at path: [String]) throws {
    try setValue(value, at: path)
  }

  func setOptionalBool(_ value: Bool?, at path: [String]) throws {
    try setValue(value, at: path)
  }

  func setInt(_ value: Int, at path: [String]) throws {
    try setValue(value, at: path)
  }

  func setDouble(_ value: Double, at path: [String]) throws {
    try setValue(value, at: path)
  }

  func setOptionalString(_ value: String?, at path: [String]) throws {
    try setValue(value, at: path)
  }

  // MARK: - MCP Servers

  func applyMCPServers(_ servers: [MCPServer]) throws {
    var object = loadJSONObject()
    let enabled = servers.enabledServers(for: .gemini)
    
    if enabled.isEmpty {
      object.removeValue(forKey: "mcpServers")
    } else {
      var mcpServers: JSONObject = [:]
      for server in enabled {
        var config: JSONObject = [:]
        if let command = server.command {
          config["command"] = command
        }
        if let args = server.args, !args.isEmpty {
          config["args"] = args
        }
        if let env = server.env, !env.isEmpty {
          config["env"] = env
        }
        if let url = server.url {
          config["url"] = url
        }
        if let headers = server.headers, !headers.isEmpty {
          config["headers"] = headers
        }
        mcpServers[server.name] = config
      }
      object["mcpServers"] = mcpServers
    }
    
    try writeJSONObject(object)
  }

  // MARK: - Internal helpers

  private func loadJSONObject() -> JSONObject {
    guard fm.fileExists(atPath: paths.file.path) else { return [:] }
    guard let text = try? String(contentsOf: paths.file, encoding: .utf8) else { return [:] }
    if let object = parseJSONObject(from: text) {
      return object
    }
    return [:]
  }

  private func parseJSONObject(from text: String) -> JSONObject? {
    if let data = text.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data, options: []),
      let dict = json as? JSONObject
    {
      return dict
    }
    let stripped = stripComments(from: text)
    guard let data = stripped.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data, options: []),
      let dict = json as? JSONObject
    else {
      return nil
    }
    return dict
  }

  private func writeJSONObject(_ object: JSONObject) throws {
    try fm.createDirectory(at: paths.directory, withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: paths.file, options: .atomic)
  }

  private func setValue(_ value: Any?, at path: [String]) throws {
    var object = loadJSONObject()
    update(&object, path: path, value: value)
    try writeJSONObject(object)
  }

  private func update(_ object: inout JSONObject, path: [String], value: Any?) {
    guard let first = path.first else { return }
    if path.count == 1 {
      if let value {
        object[first] = value
      } else {
        object.removeValue(forKey: first)
      }
      return
    }
    var child = object[first] as? JSONObject ?? JSONObject()
    update(&child, path: Array(path.dropFirst()), value: value)
    if child.isEmpty {
      object.removeValue(forKey: first)
    } else {
      object[first] = child
    }
  }

  private func value(in object: JSONObject, path: [String]) -> Any? {
    var current: Any? = object
    for component in path {
      guard let dict = current as? JSONObject else { return nil }
      current = dict[component]
    }
    return current
  }

  private func boolValue(in object: JSONObject, path: [String]) -> Bool? {
    if let v = value(in: object, path: path) as? Bool {
      return v
    }
    if let str = value(in: object, path: path) as? String {
      return (str as NSString).boolValue
    }
    return nil
  }

  private func stringValue(in object: JSONObject, path: [String]) -> String? {
    value(in: object, path: path) as? String
  }

  private func intValue(in object: JSONObject, path: [String]) -> Int? {
    if let v = value(in: object, path: path) as? Int { return v }
    if let number = value(in: object, path: path) as? NSNumber { return number.intValue }
    if let str = value(in: object, path: path) as? String { return Int(str) }
    return nil
  }

  private func doubleValue(in object: JSONObject, path: [String]) -> Double? {
    if let v = value(in: object, path: path) as? Double { return v }
    if let number = value(in: object, path: path) as? NSNumber { return number.doubleValue }
    if let str = value(in: object, path: path) as? String { return Double(str) }
    return nil
  }

  private func stripComments(from text: String) -> String {
    let scalars = Array(text.unicodeScalars)
    var result: [UnicodeScalar] = []
    var index = 0
    var inString = false
    var escapeNext = false
    let quote: UnicodeScalar = "\""
    let slash: UnicodeScalar = "/"
    let newlineScalar = "\n".unicodeScalars.first!

    while index < scalars.count {
      let scalar = scalars[index]

      if inString {
        result.append(scalar)
        if escapeNext {
          escapeNext = false
        } else if scalar == "\\" {
          escapeNext = true
        } else if scalar == quote {
          inString = false
        }
        index += 1
        continue
      }

      if scalar == quote {
        inString = true
        result.append(scalar)
        index += 1
        continue
      }

      if scalar == slash && index + 1 < scalars.count {
        let next = scalars[index + 1]
        if next == slash {
          index += 2
          while index < scalars.count, scalars[index] != newlineScalar {
            index += 1
          }
          if index < scalars.count {
            result.append(scalars[index])
            index += 1
          }
          continue
        } else if next == "*" {
          index += 2
          while index + 1 < scalars.count {
            if scalars[index] == "*" && scalars[index + 1] == slash {
              index += 2
              break
            }
            index += 1
          }
          continue
        }
      }

      result.append(scalar)
      index += 1
    }

    return String(String.UnicodeScalarView(result))
  }
}

import CryptoKit
import Foundation

enum InternalWizardPaths {
  static let internalFolderName = "internal"
  static let projectFolderName = "cli-project"

  static func internalRoot(home: URL = SessionPreferencesStore.getRealUserHomeURL()) -> URL {
    home
      .appendingPathComponent(".codmate", isDirectory: true)
      .appendingPathComponent(internalFolderName, isDirectory: true)
  }

  static func projectRoot(home: URL = SessionPreferencesStore.getRealUserHomeURL()) -> URL {
    internalRoot(home: home)
      .appendingPathComponent(projectFolderName, isDirectory: true)
  }

  static func ensureProjectRootExists(home: URL = SessionPreferencesStore.getRealUserHomeURL()) -> URL {
    let root = projectRoot(home: home)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  static func ignoredSubpaths(home: URL = SessionPreferencesStore.getRealUserHomeURL()) -> [String] {
    var paths: [String] = [projectRoot(home: home).path]
    if let geminiTmp = geminiTempPath(home: home) {
      paths.append(geminiTmp)
    }
    return paths
  }

  private static func geminiTempPath(home: URL) -> String? {
    let projectPath = projectRoot(home: home).path
    guard let hash = geminiProjectHash(for: projectPath) else { return nil }
    return home
      .appendingPathComponent(".gemini", isDirectory: true)
      .appendingPathComponent("tmp", isDirectory: true)
      .appendingPathComponent(hash, isDirectory: true)
      .path
  }

  private static func geminiProjectHash(for path: String) -> String? {
    let canonical = (path as NSString).expandingTildeInPath
    guard let data = canonical.data(using: .utf8) else { return nil }
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}

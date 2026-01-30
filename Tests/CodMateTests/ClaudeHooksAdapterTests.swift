import XCTest
@testable import CodMate

final class ClaudeHooksAdapterTests: XCTestCase {
  func testApplyHooksWritesClaudeSettingsHooks() async throws {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("codmate-claude-hooks-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    let settingsURL = tmp.appendingPathComponent("settings.json")

    let paths = ClaudeSettingsService.Paths(dir: tmp, file: settingsURL)
    let service = ClaudeSettingsService(fileManager: fm, paths: paths)
    let rule = HookRule(
      name: "PreToolUse · Write",
      event: "PreToolUse",
      matcher: "Write|Edit",
      commands: [HookCommand(command: "/usr/bin/echo", args: ["ok"], timeoutMs: 30_000)],
      enabled: true,
      targets: HookTargets(codex: false, claude: true, gemini: false)
    )

    let warnings = try await service.applyHooksFromCodMate([rule])
    XCTAssertTrue(warnings.isEmpty)

    let data = try Data(contentsOf: settingsURL)
    let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let hooks = obj?["hooks"] as? [String: Any]
    let pre = hooks?["PreToolUse"] as? [[String: Any]]
    XCTAssertEqual(pre?.count, 1)
    XCTAssertEqual(pre?.first?["matcher"] as? String, "Write|Edit")
    let nested = pre?.first?["hooks"] as? [[String: Any]]
    XCTAssertEqual(nested?.count, 1)
    XCTAssertEqual(nested?.first?["type"] as? String, "command")
    XCTAssertEqual(nested?.first?["command"] as? String, "/usr/bin/echo")
    XCTAssertEqual(nested?.first?["timeout"] as? Int, 30_000)
    XCTAssertNotNil(nested?.first?["name"] as? String)
  }

  func testAllowManagedHooksOnlySkipsApply() async throws {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("codmate-claude-hooks-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    let settingsURL = tmp.appendingPathComponent("settings.json")
    let initial = #"{"allowManagedHooksOnly":true}"#
    try initial.write(to: settingsURL, atomically: true, encoding: .utf8)

    let paths = ClaudeSettingsService.Paths(dir: tmp, file: settingsURL)
    let service = ClaudeSettingsService(fileManager: fm, paths: paths)
    let rule = HookRule(name: "Stop", event: "Stop", commands: [HookCommand(command: "/bin/echo")], enabled: true, targets: HookTargets(codex: false, claude: true, gemini: false))

    let warnings = try await service.applyHooksFromCodMate([rule])
    XCTAssertEqual(warnings.count, 1)
    let text = try String(contentsOf: settingsURL, encoding: .utf8)
    XCTAssertTrue(text.contains("allowManagedHooksOnly"))
    XCTAssertFalse(text.contains("codmate-hook:"))
  }

  func testApplyPrunesPreviouslyManagedHooks() async throws {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("codmate-claude-hooks-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    let settingsURL = tmp.appendingPathComponent("settings.json")
    let paths = ClaudeSettingsService.Paths(dir: tmp, file: settingsURL)
    let service = ClaudeSettingsService(fileManager: fm, paths: paths)

    let rule = HookRule(
      name: "Stop",
      event: "Stop",
      commands: [HookCommand(command: "/usr/bin/echo")],
      enabled: true,
      targets: HookTargets(codex: false, claude: true, gemini: false)
    )
    _ = try await service.applyHooksFromCodMate([rule])
    _ = try await service.applyHooksFromCodMate([rule])

    let data = try Data(contentsOf: settingsURL)
    let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let hooks = obj?["hooks"] as? [String: Any]
    let stop = hooks?["Stop"] as? [[String: Any]]
    let nested = stop?.first?["hooks"] as? [[String: Any]]
    let managed = (nested ?? []).filter { ($0["name"] as? String)?.hasPrefix("codmate-hook:") == true }
    XCTAssertEqual(managed.count, 1)
  }
}


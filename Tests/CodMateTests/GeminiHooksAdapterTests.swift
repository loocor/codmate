import XCTest
@testable import CodMate

final class GeminiHooksAdapterTests: XCTestCase {
  func testApplyHooksWritesGeminiSettingsHooksAndEnablesTools() async throws {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("codmate-gemini-hooks-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    let settingsURL = tmp.appendingPathComponent("settings.json")

    let paths = GeminiSettingsService.Paths(directory: tmp, file: settingsURL)
    let service = GeminiSettingsService(paths: paths, fileManager: fm)
    let rule = HookRule(
      name: "PreToolUse",
      event: "PreToolUse",
      matcher: "Write",
      commands: [HookCommand(command: "/usr/bin/echo", args: ["ok"], timeoutMs: 10_000)],
      enabled: true,
      targets: HookTargets(codex: false, claude: false, gemini: true)
    )

    let warnings = try await service.applyHooksFromCodMate([rule])
    XCTAssertTrue(warnings.isEmpty)

    let data = try Data(contentsOf: settingsURL)
    let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let hooks = obj?["hooks"] as? [String: Any]
    let pre = hooks?["PreToolUse"] as? [[String: Any]]
    XCTAssertEqual(pre?.count, 1)
    XCTAssertEqual(pre?.first?["matcher"] as? String, "Write")
    let nested = pre?.first?["hooks"] as? [[String: Any]]
    XCTAssertEqual(nested?.count, 1)
    XCTAssertTrue((nested?.first?["name"] as? String)?.hasPrefix("codmate-hook:") == true)

    let tools = obj?["tools"] as? [String: Any]
    XCTAssertEqual(tools?["enableHooks"] as? Bool, true)
    XCTAssertEqual(tools?["enableMessageBusIntegration"] as? Bool, true)
  }

  func testApplyPrunesPreviouslyManagedHooks() async throws {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("codmate-gemini-hooks-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    let settingsURL = tmp.appendingPathComponent("settings.json")

    let paths = GeminiSettingsService.Paths(directory: tmp, file: settingsURL)
    let service = GeminiSettingsService(paths: paths, fileManager: fm)
    let rule = HookRule(
      name: "Stop",
      event: "Stop",
      commands: [HookCommand(command: "/usr/bin/echo")],
      enabled: true,
      targets: HookTargets(codex: false, claude: false, gemini: true)
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


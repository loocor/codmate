import XCTest
@testable import CodMate

final class CodexHooksAdapterTests: XCTestCase {
  func testApplySingleStopHookWritesNotifyArray() async throws {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("codmate-codex-hooks-\(UUID().uuidString)", isDirectory: true)
    let home = tmp.appendingPathComponent(".codex", isDirectory: true)
    try fm.createDirectory(at: home, withIntermediateDirectories: true)
    let configURL = home.appendingPathComponent("config.toml")
    try "".write(to: configURL, atomically: true, encoding: .utf8)

    let service = CodexConfigService(paths: .init(home: home, configURL: configURL), fileManager: fm)
    let rule = HookRule(
      name: "Stop · echo",
      event: "Stop",
      commands: [HookCommand(command: "/usr/bin/echo", args: ["hello"])],
      enabled: true,
      targets: HookTargets(codex: true, claude: false, gemini: false)
    )
    let warnings = try await service.applyHooksFromCodMate([rule])
    XCTAssertTrue(warnings.isEmpty)

    let text = try String(contentsOf: configURL, encoding: .utf8)
    XCTAssertTrue(text.contains("notify = [\"/usr/bin/echo\", \"hello\"]"))
  }

  func testApplyMultipleCodexRulesDoesNotOverwriteExistingNotify() async throws {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("codmate-codex-hooks-\(UUID().uuidString)", isDirectory: true)
    let home = tmp.appendingPathComponent(".codex", isDirectory: true)
    try fm.createDirectory(at: home, withIntermediateDirectories: true)
    let configURL = home.appendingPathComponent("config.toml")
    try "notify = [\"old-notify\"]\n".write(to: configURL, atomically: true, encoding: .utf8)

    let service = CodexConfigService(paths: .init(home: home, configURL: configURL), fileManager: fm)
    let rules = [
      HookRule(name: "Stop A", event: "Stop", commands: [HookCommand(command: "/bin/echo", args: ["a"])], enabled: true, targets: HookTargets(codex: true, claude: false, gemini: false)),
      HookRule(name: "Stop B", event: "Stop", commands: [HookCommand(command: "/bin/echo", args: ["b"])], enabled: true, targets: HookTargets(codex: true, claude: false, gemini: false)),
    ]
    let warnings = try await service.applyHooksFromCodMate(rules)
    XCTAssertEqual(warnings.count, 1)

    let unchanged = await service.getNotifyArray()
    XCTAssertEqual(unchanged.first, "old-notify")
  }
}


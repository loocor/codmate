import XCTest
@testable import CodMate

final class HooksStoreTests: XCTestCase {
  func testUpsertListUpdateDelete() async throws {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("codmate-hooks-store-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    let paths = HooksStore.Paths(home: tmp, fileURL: tmp.appendingPathComponent("hooks.json"))
    let store = HooksStore(paths: paths, fileManager: fm)

    let rule = HookRule(
      name: "Stop · echo",
      event: "Stop",
      commands: [HookCommand(command: "/usr/bin/echo", args: ["hello"])],
      enabled: true,
      targets: HookTargets(codex: true, claude: true, gemini: true),
      source: "test"
    )

    try await store.upsert(rule)
    let list1 = await store.list()
    XCTAssertEqual(list1.count, 1)
    XCTAssertEqual(list1.first?.id, rule.id)

    try await store.update(id: rule.id) { r in
      r.enabled = false
    }
    let list2 = await store.list()
    XCTAssertEqual(list2.first?.enabled, false)

    try await store.delete(id: rule.id)
    let list3 = await store.list()
    XCTAssertEqual(list3.count, 0)
  }
}


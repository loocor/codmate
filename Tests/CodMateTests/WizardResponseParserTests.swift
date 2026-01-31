import XCTest
@testable import CodMate

final class WizardResponseParserTests: XCTestCase {
  func testDecodeEnvelope() {
    let raw = """
    {"mode":"draft","draft":{"event":"Stop","commands":[{"command":"/bin/echo"}]}}
    """
    let envelope: WizardDraftEnvelope<HookWizardDraft>? = WizardResponseParser.decodeEnvelope(raw)
    XCTAssertEqual(envelope?.mode, .draft)
    XCTAssertEqual(envelope?.draft?.event, "Stop")
  }

  func testDecodeWithCodeFence() {
    let raw = """
    ```json
    {"mode":"draft","draft":{"event":"Stop","commands":[{"command":"/bin/echo"}]}}
    ```
    """
    let envelope: WizardDraftEnvelope<HookWizardDraft>? = WizardResponseParser.decodeEnvelope(raw)
    XCTAssertEqual(envelope?.mode, .draft)
    XCTAssertEqual(envelope?.draft?.commands.count, 1)
  }

  func testDecodeEnvelopeFromWrapper() {
    let raw = """
    {"result":"{\\"mode\\":\\"draft\\",\\"draft\\":{\\"event\\":\\"Stop\\",\\"commands\\":[{\\"command\\":\\"/bin/echo\\"}]}}"}
    """
    let envelope: WizardDraftEnvelope<HookWizardDraft>? = WizardResponseParser.decodeEnvelope(raw)
    XCTAssertEqual(envelope?.mode, .draft)
    XCTAssertEqual(envelope?.draft?.event, "Stop")
  }
}

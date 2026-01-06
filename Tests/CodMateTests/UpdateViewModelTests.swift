import XCTest
@testable import CodMate

final class UpdateViewModelTests: XCTestCase {
  @MainActor
  func testInstallInstructions() {
    let vm = UpdateViewModel(service: UpdateService())
    XCTAssertTrue(vm.installInstructions.contains("Applications"))
  }
}

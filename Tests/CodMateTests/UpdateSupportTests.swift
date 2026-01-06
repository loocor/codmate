import XCTest
@testable import CodMate

final class UpdateSupportTests: XCTestCase {
  func testVersionCompare() {
    XCTAssertTrue(Version("1.2.3")! < Version("1.2.4")!)
    XCTAssertTrue(Version("1.2.3")! > Version("1.2.2")!)
    XCTAssertTrue(Version("1.2.0")! == Version("1.2")!)
  }

  func testAssetNameForArch() {
    XCTAssertEqual(UpdateAssetSelector.assetName(for: .arm64), "codmate-arm64.dmg")
    XCTAssertEqual(UpdateAssetSelector.assetName(for: .x86_64), "codmate-x86_64.dmg")
  }
}

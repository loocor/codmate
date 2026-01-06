import XCTest
@testable import CodMate

final class UpdateServiceTests: XCTestCase {
  func testParseLatestRelease() throws {
    let json = """
    {
      "tag_name": "v1.2.3",
      "html_url": "https://github.com/loocor/CodMate/releases/tag/v1.2.3",
      "draft": false,
      "prerelease": false,
      "assets": [
        {"name": "codmate-arm64.dmg", "browser_download_url": "https://example.com/codmate-arm64.dmg"}
      ]
    }
    """
    let data = Data(json.utf8)
    let release = try UpdateService.Release.decode(from: data)
    XCTAssertEqual(release.tagName, "v1.2.3")
    XCTAssertEqual(release.assets.first?.name, "codmate-arm64.dmg")
  }
}

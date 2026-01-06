# About Auto Update Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add update checking and download flow in Settings › About using GitHub Releases, with manual install guidance.

**Architecture:** Introduce UpdateService (actor) to fetch latest release, cache results, and download DMG. Add UpdateViewModel for UI state and wire it into About section. Trigger daily check on app launch and on About appearance.

**Tech Stack:** Swift 6, SwiftUI (macOS), URLSession, UserDefaults

---

### Task 1: Add SwiftPM test target scaffolding

**Files:**
- Modify: `Package.swift`
- Create: `Tests/CodMateTests/PlaceholderTests.swift`

**Step 1: Add test target**

```swift
.testTarget(
  name: "CodMateTests",
  dependencies: ["CodMate"]
)
```

**Step 2: Add placeholder test**

```swift
import XCTest
@testable import CodMate

final class PlaceholderTests: XCTestCase {
  func testPlaceholder() {
    XCTAssertTrue(true)
  }
}
```

**Step 3: Run tests**

Run: `swift test`

Expected: PASS

**Step 4: Commit**

```bash
git add Package.swift Tests/CodMateTests/PlaceholderTests.swift
git commit -m "test: add SwiftPM test target"
```

---

### Task 2: Add update support models and utilities

**Files:**
- Create: `utils/UpdateSupport.swift`
- Modify: `Tests/CodMateTests/PlaceholderTests.swift` → rename to `UpdateSupportTests.swift`

**Step 1: Write the failing test**

```swift
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
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter UpdateSupportTests`

Expected: FAIL with "use of unresolved identifier 'Version'" (or similar)

**Step 3: Write minimal implementation**

```swift
import Foundation

struct Version: Comparable, Sendable {
  let components: [Int]

  init?(_ raw: String) {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return nil }
    let noPrefix = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
    let core = noPrefix.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true).first ?? ""
    let parts = core.split(separator: ".").compactMap { Int($0) }
    if parts.isEmpty { return nil }
    self.components = parts
  }

  static func < (lhs: Version, rhs: Version) -> Bool {
    let maxCount = max(lhs.components.count, rhs.components.count)
    for idx in 0..<maxCount {
      let l = idx < lhs.components.count ? lhs.components[idx] : 0
      let r = idx < rhs.components.count ? rhs.components[idx] : 0
      if l != r { return l < r }
    }
    return false
  }
}

enum CPUArch: String, Sendable {
  case arm64
  case x86_64

  static var current: CPUArch {
    #if arch(arm64)
      return .arm64
    #else
      return .x86_64
    #endif
  }
}

enum UpdateAssetSelector {
  static func assetName(for arch: CPUArch) -> String {
    switch arch {
    case .arm64: return "codmate-arm64.dmg"
    case .x86_64: return "codmate-x86_64.dmg"
    }
  }
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter UpdateSupportTests`

Expected: PASS

**Step 5: Commit**

```bash
git add utils/UpdateSupport.swift Tests/CodMateTests/UpdateSupportTests.swift
git commit -m "feat: add update version and asset helpers"
```

---

### Task 3: Add UpdateService for GitHub Releases + cache

**Files:**
- Create: `services/UpdateService.swift`
- Create: `Tests/CodMateTests/UpdateServiceTests.swift`

**Step 1: Write the failing test**

```swift
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
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter UpdateServiceTests`

Expected: FAIL with "type 'UpdateService' has no member 'Release'"

**Step 3: Write minimal implementation**

```swift
import Foundation
import AppKit

actor UpdateService {
  static let shared = UpdateService()

  enum CheckTrigger: Sendable {
    case appLaunch
    case aboutAuto
    case manual
  }

  struct UpdateInfo: Sendable {
    let latestVersion: String
    let releaseURL: URL
    let assetName: String
    let assetURL: URL
  }

  enum UpdateState: Sendable {
    case idle
    case checking
    case upToDate(current: String, latest: String)
    case updateAvailable(UpdateInfo)
    case error(String)
  }

  struct Release: Decodable, Sendable {
    let tagName: String
    let htmlURL: URL
    let isDraft: Bool
    let isPrerelease: Bool
    let assets: [Asset]

    struct Asset: Decodable, Sendable {
      let name: String
      let browserDownloadURL: URL

      enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
      }
    }

    enum CodingKeys: String, CodingKey {
      case tagName = "tag_name"
      case htmlURL = "html_url"
      case isDraft = "draft"
      case isPrerelease = "prerelease"
      case assets
    }

    static func decode(from data: Data) throws -> Release {
      try JSONDecoder().decode(Release.self, from: data)
    }
  }

  private let defaults: UserDefaults
  private let session: URLSession
  private let calendar: Calendar

  private struct Keys {
    static let lastCheckDay = "codmate.update.lastCheckDay"
    static let latestVersion = "codmate.update.latestVersion"
    static let latestAssetURL = "codmate.update.latestAssetURL"
    static let latestAssetName = "codmate.update.latestAssetName"
    static let latestReleaseURL = "codmate.update.latestReleaseURL"
  }

  init(
    defaults: UserDefaults = .standard,
    session: URLSession = .shared,
    calendar: Calendar = .current
  ) {
    self.defaults = defaults
    self.session = session
    self.calendar = calendar
  }

  func cachedInfo() -> UpdateInfo? {
    guard
      let version = defaults.string(forKey: Keys.latestVersion),
      let assetURLString = defaults.string(forKey: Keys.latestAssetURL),
      let assetURL = URL(string: assetURLString),
      let assetName = defaults.string(forKey: Keys.latestAssetName),
      let releaseURLString = defaults.string(forKey: Keys.latestReleaseURL),
      let releaseURL = URL(string: releaseURLString)
    else { return nil }
    return UpdateInfo(latestVersion: version, releaseURL: releaseURL, assetName: assetName, assetURL: assetURL)
  }

  func checkIfNeeded(trigger: CheckTrigger) async -> UpdateState {
    if AppDistribution.isAppStore {
      return .error("Updates are disabled in the App Store build.")
    }

    let todayKey = dayKey(Date())
    let lastKey = defaults.string(forKey: Keys.lastCheckDay)
    if (trigger == .appLaunch || trigger == .aboutAuto), lastKey == todayKey {
      if let cached = cachedInfo() {
        return availability(for: cached)
      }
      return .idle
    }

    return await checkNow()
  }

  func checkNow() async -> UpdateState {
    if AppDistribution.isAppStore {
      return .error("Updates are disabled in the App Store build.")
    }

    do {
      let request = URLRequest(url: URL(string: "https://api.github.com/repos/loocor/CodMate/releases/latest")!)
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        return .error("Invalid response")
      }
      guard http.statusCode == 200 else {
        return .error("HTTP \(http.statusCode)")
      }

      let release = try Release.decode(from: data)
      if release.isDraft || release.isPrerelease {
        return .error("No stable release available")
      }
      let assetName = UpdateAssetSelector.assetName(for: .current)
      guard let asset = release.assets.first(where: { $0.name == assetName }) else {
        return .error("No asset for current architecture")
      }

      let latestVersion = release.tagName
      cache(latestVersion: latestVersion, asset: asset, releaseURL: release.htmlURL)
      defaults.set(dayKey(Date()), forKey: Keys.lastCheckDay)

      let info = UpdateInfo(
        latestVersion: latestVersion,
        releaseURL: release.htmlURL,
        assetName: asset.name,
        assetURL: asset.browserDownloadURL
      )
      return availability(for: info)
    } catch {
      return .error(error.localizedDescription)
    }
  }

  private func availability(for info: UpdateInfo) -> UpdateState {
    let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    guard let currentVersion = Version(current), let latestVersion = Version(info.latestVersion) else {
      return .updateAvailable(info)
    }
    if latestVersion > currentVersion {
      return .updateAvailable(info)
    }
    return .upToDate(current: current, latest: info.latestVersion)
  }

  private func cache(latestVersion: String, asset: Release.Asset, releaseURL: URL) {
    defaults.set(latestVersion, forKey: Keys.latestVersion)
    defaults.set(asset.name, forKey: Keys.latestAssetName)
    defaults.set(asset.browserDownloadURL.absoluteString, forKey: Keys.latestAssetURL)
    defaults.set(releaseURL.absoluteString, forKey: Keys.latestReleaseURL)
  }

  private func dayKey(_ date: Date) -> String {
    let comps = calendar.dateComponents([.year, .month, .day], from: date)
    let y = comps.year ?? 0
    let m = comps.month ?? 0
    let d = comps.day ?? 0
    return String(format: "%04d-%02d-%02d", y, m, d)
  }
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter UpdateServiceTests`

Expected: PASS

**Step 5: Commit**

```bash
git add services/UpdateService.swift Tests/CodMateTests/UpdateServiceTests.swift
git commit -m "feat: add update service and release parsing"
```

---

### Task 4: Add UpdateViewModel and download flow

**Files:**
- Create: `models/UpdateViewModel.swift`
- Create: `Tests/CodMateTests/UpdateViewModelTests.swift`

**Step 1: Write the failing test**

```swift
import XCTest
@testable import CodMate

final class UpdateViewModelTests: XCTestCase {
  func testInstallInstructions() {
    let vm = UpdateViewModel(service: UpdateService())
    XCTAssertTrue(vm.installInstructions.contains("Applications"))
  }
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter UpdateViewModelTests`

Expected: FAIL with "cannot find 'UpdateViewModel' in scope"

**Step 3: Write minimal implementation**

```swift
import Foundation
import AppKit

@MainActor
final class UpdateViewModel: ObservableObject {
  @Published private(set) var state: UpdateService.UpdateState = .idle
  @Published private(set) var isDownloading = false
  @Published var showInstallInstructions = false
  @Published var lastError: String?

  let installInstructions = "Download completed. Open the DMG and drag CodMate into Applications."

  private let service: UpdateService
  private var checkTask: Task<Void, Never>?
  private var downloadTask: Task<Void, Never>?

  init(service: UpdateService = .shared) {
    self.service = service
  }

  func loadCached() {
    if let cached = service.cachedInfo() {
      state = serviceAvailability(for: cached)
    }
  }

  func checkIfNeeded(trigger: UpdateService.CheckTrigger) {
    checkTask?.cancel()
    checkTask = Task { [weak self] in
      guard let self else { return }
      self.state = .checking
      let result = await self.service.checkIfNeeded(trigger: trigger)
      self.state = result
    }
  }

  func checkNow() {
    checkTask?.cancel()
    checkTask = Task { [weak self] in
      guard let self else { return }
      self.state = .checking
      let result = await self.service.checkNow()
      self.state = result
    }
  }

  func downloadIfNeeded() {
    guard case .updateAvailable(let info) = state else { return }
    downloadTask?.cancel()
    isDownloading = true
    lastError = nil
    downloadTask = Task { [weak self] in
      guard let self else { return }
      do {
        let targetURL = try await self.downloadAsset(info: info)
        await MainActor.run {
          NSWorkspace.shared.open(targetURL)
          self.showInstallInstructions = true
        }
      } catch {
        await MainActor.run { self.lastError = error.localizedDescription }
      }
      await MainActor.run { self.isDownloading = false }
    }
  }

  private func serviceAvailability(for info: UpdateService.UpdateInfo) -> UpdateService.UpdateState {
    let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    if let currentVersion = Version(current), let latestVersion = Version(info.latestVersion), latestVersion <= currentVersion {
      return .upToDate(current: current, latest: info.latestVersion)
    }
    return .updateAvailable(info)
  }

  private func downloadAsset(info: UpdateService.UpdateInfo) async throws -> URL {
    let (tempURL, _) = try await URLSession.shared.download(from: info.assetURL)
    let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    let baseName = info.assetName
    let targetDir = downloads ?? FileManager.default.temporaryDirectory
    var targetURL = targetDir.appendingPathComponent(baseName)
    if FileManager.default.fileExists(atPath: targetURL.path) {
      let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
      targetURL = targetDir.appendingPathComponent("\(stamp)-\(baseName)")
    }
    try FileManager.default.moveItem(at: tempURL, to: targetURL)
    return targetURL
  }
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter UpdateViewModelTests`

Expected: PASS

**Step 5: Commit**

```bash
git add models/UpdateViewModel.swift Tests/CodMateTests/UpdateViewModelTests.swift
git commit -m "feat: add update view model and download flow"
```

---

### Task 5: Wire About UI update section

**Files:**
- Modify: `views/SettingsView.swift`
- Modify: `views/AboutViews.swift`

**Step 1: Implement UI changes**

```swift
// In SettingsView (as a stored state)
@StateObject private var updateViewModel = UpdateViewModel()

// In aboutSettings view, insert a new update section
AboutUpdateSection(viewModel: updateViewModel)
  .onAppear {
    updateViewModel.loadCached()
    updateViewModel.checkIfNeeded(trigger: .aboutAuto)
  }
```

```swift
// In AboutViews.swift
struct AboutUpdateSection: View {
  @ObservedObject var viewModel: UpdateViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Update").font(.headline)
      content
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color.gray.opacity(0.06))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(Color.gray.opacity(0.15), lineWidth: 1)
    )
    .alert("Install", isPresented: $viewModel.showInstallInstructions) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(viewModel.installInstructions)
    }
  }

  @ViewBuilder
  private var content: some View {
    switch viewModel.state {
    case .idle:
      HStack { Text("Check for updates"); Spacer(); Button("Check Now") { viewModel.checkNow() } }
    case .checking:
      HStack { ProgressView(); Text("Checking...") }
    case .upToDate(let current, _):
      HStack { Text("Up to date (\(current))"); Spacer(); Button("Check Now") { viewModel.checkNow() } }
    case .updateAvailable(let info):
      HStack {
        VStack(alignment: .leading) {
          Text("New version available: \(info.latestVersion)")
          Text(info.assetName).font(.caption).foregroundColor(.secondary)
        }
        Spacer()
        if viewModel.isDownloading {
          ProgressView()
        } else {
          Button("Download & Install") { viewModel.downloadIfNeeded() }
        }
      }
    case .error(let message):
      HStack {
        Text("Update check failed: \(message)").foregroundColor(.red)
        Spacer()
        Button("Retry") { viewModel.checkNow() }
      }
    }
  }
}
```

**Step 2: Manual verification**

- Open Settings › About, ensure Update section visible and “Check Now” works.
- Simulate error (offline) and verify error state + Retry.

**Step 3: Commit**

```bash
git add views/SettingsView.swift views/AboutViews.swift
git commit -m "feat: add About update UI"
```

---

### Task 6: Trigger daily check on app launch

**Files:**
- Modify: `CodMateApp.swift`

**Step 1: Implement minimal change**

```swift
// In CodMateApp.init()
Task {
  _ = await UpdateService.shared.checkIfNeeded(trigger: .appLaunch)
}
```

**Step 2: Manual verification**

- Launch app twice in the same day; ensure second launch does not re-check if cached.

**Step 3: Commit**

```bash
git add CodMateApp.swift
git commit -m "feat: add daily update check on launch"
```

---

### Task 7: Acceptance script + freeze record

**Files:**
- Create: `scripts/bench/update-acceptance.sh`
- Create: `docs/deployment/freeze.md`

**Step 1: Add acceptance script**

```bash
#!/bin/sh
set -euo pipefail
swift test --filter UpdateSupportTests
swift test --filter UpdateServiceTests
swift test --filter UpdateViewModelTests
```

**Step 2: Add freeze record template**

```markdown
# Freeze Records

- Date: 2026-01-05
  Change: About auto update (GitHub Releases + download DMG + manual install)
  Commit: TBD
  Notes: Update check is disabled for App Store builds.
```

**Step 3: Commit**

```bash
git add scripts/bench/update-acceptance.sh docs/deployment/freeze.md
git commit -m "chore: add update acceptance script and freeze record"
```

---

### Task 8: Sync architecture canvas + AGENTS

**Files:**
- Modify: `architecture.canvas`
- Modify: `AGENTS.md`

**Step 1: Update canvas status**

- Mark Update System / Update UI / Update Flow / Update Cache as Implemented.

**Step 2: Update AGENTS.md**

- Add one bullet under “About Surface” noting About includes update check/download (non-App Store only).

**Step 3: Commit**

```bash
git add architecture.canvas AGENTS.md
git commit -m "docs: sync architecture canvas and About guidance"
```

---

### Task 9: Final verification

**Step 1: Run acceptance script**

Run: `scripts/bench/update-acceptance.sh`

Expected: PASS

**Step 2: Manual cold regression**

- Launch app → About → Check Now → Download & Install → DMG opens → instruction alert shows.

**Step 3: Commit (if any remaining changes)**

```bash
git status
```


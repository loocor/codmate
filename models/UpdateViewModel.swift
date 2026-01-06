import AppKit
import Foundation

@MainActor
final class UpdateViewModel: ObservableObject {
  @Published private(set) var state: UpdateService.UpdateState = .idle
  @Published private(set) var isDownloading = false
  @Published var showInstallInstructions = false
  @Published var lastError: String?
  @Published private(set) var lastCheckedAt: Date?

  let installInstructions = "Download completed. Open the DMG and drag CodMate into Applications."

  private let service: UpdateService
  private var checkTask: Task<Void, Never>?
  private var downloadTask: Task<Void, Never>?

  init(service: UpdateService = .shared) {
    self.service = service
  }

  func loadCached() {
    checkTask?.cancel()
    checkTask = Task { [weak self] in
      guard let self else { return }
      if let cached = await service.cachedInfo() {
        state = serviceAvailability(for: cached)
      }
      lastCheckedAt = await service.lastCheckedAt()
    }
  }

  func checkIfNeeded(trigger: UpdateService.CheckTrigger) {
    checkTask?.cancel()
    checkTask = Task { [weak self] in
      guard let self else { return }
      state = .checking
      let result = await service.checkIfNeeded(trigger: trigger)
      state = result
      lastCheckedAt = await service.lastCheckedAt()
    }
  }

  func checkNow() {
    checkTask?.cancel()
    checkTask = Task { [weak self] in
      guard let self else { return }
      state = .checking
      let result = await service.checkNow()
      state = result
      lastCheckedAt = await service.lastCheckedAt()
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
        let targetURL = try await downloadAsset(info: info)
        NSWorkspace.shared.open(targetURL)
        showInstallInstructions = true
      } catch {
        lastError = error.localizedDescription
      }
      isDownloading = false
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

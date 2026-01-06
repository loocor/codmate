import Foundation

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
    static let lastCheckTimestamp = "codmate.update.lastCheckTimestamp"
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

  func lastCheckedAt() -> Date? {
    let timestamp = defaults.double(forKey: Keys.lastCheckTimestamp)
    if timestamp == 0 { return nil }
    return Date(timeIntervalSince1970: timestamp)
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

    let now = Date()
    recordCheckAttempt(now)

    do {
      var request = URLRequest(url: URL(string: "https://api.github.com/repos/loocor/CodMate/releases/latest")!)
      request.setValue("CodMate", forHTTPHeaderField: "User-Agent")
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

  private func recordCheckAttempt(_ date: Date) {
    defaults.set(dayKey(date), forKey: Keys.lastCheckDay)
    defaults.set(date.timeIntervalSince1970, forKey: Keys.lastCheckTimestamp)
  }

  private func dayKey(_ date: Date) -> String {
    let comps = calendar.dateComponents([.year, .month, .day], from: date)
    let y = comps.year ?? 0
    let m = comps.month ?? 0
    let d = comps.day ?? 0
    return String(format: "%04d-%02d-%02d", y, m, d)
  }
}

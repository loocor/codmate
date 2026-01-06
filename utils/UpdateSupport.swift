import Foundation

struct Version: Comparable, Sendable {
  let components: [Int]

  init?(_ raw: String) {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return nil }
    let noPrefix = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
    let core = noPrefix.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true).first ?? ""
    var parts = core.split(separator: ".").compactMap { Int($0) }
    if parts.isEmpty { return nil }
    while parts.count > 1, parts.last == 0 {
      parts.removeLast()
    }
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

import Foundation

func externalTerminalOrderedProfiles(includeNone: Bool) -> [ExternalTerminalProfile] {
  let profiles = ExternalTerminalProfileStore.shared.availableProfiles(includeNone: includeNone)
  var ordered: [ExternalTerminalProfile] = []
  if includeNone, let none = profiles.first(where: { $0.isNone }) {
    ordered.append(none)
  }
  if let terminal = profiles.first(where: { $0.isTerminal }) {
    ordered.append(terminal)
  }
  let others = profiles
    .filter { !$0.isTerminal && !$0.isNone }
    .sorted {
      $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
    }
  return ordered + others
}

func externalTerminalMenuProfiles() -> [ExternalTerminalProfile] {
  externalTerminalOrderedProfiles(includeNone: false)
}

func externalTerminalMenuItems(
  idPrefix: String,
  titlePrefix: String? = nil,
  titleSuffix: String? = nil,
  profiles: [ExternalTerminalProfile]? = nil,
  action: @escaping (ExternalTerminalProfile) -> Void
) -> [SplitMenuItem] {
  let list = profiles ?? externalTerminalMenuProfiles()
  return list.map { profile in
    let title = (titlePrefix ?? "") + profile.displayTitle + (titleSuffix ?? "")
    return SplitMenuItem(
      id: "\(idPrefix)-\(profile.id)",
      kind: .action(title: title, run: { action(profile) })
    )
  }
}

import SwiftUI

struct HookWizardSheet: View {
  @ObservedObject var preferences: SessionPreferencesStore
  var onApply: (HookWizardDraft) -> Void
  var onCancel: () -> Void

  @StateObject private var vm: WizardConversationViewModel<HookWizardDraft>

  init(
    preferences: SessionPreferencesStore,
    onApply: @escaping (HookWizardDraft) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.preferences = preferences
    self.onApply = onApply
    self.onCancel = onCancel
    _vm = StateObject(
      wrappedValue: WizardConversationViewModel<HookWizardDraft>(
        feature: .hooks,
        preferences: preferences,
        summaryBuilder: HookWizardSheet.summaryLines
      )
    )
  }

  var body: some View {
    WizardConversationView(
      title: "Hook Wizard",
      subtitle: "Describe the hook behavior you want to create.",
      vm: vm,
      onApply: { draft in
        onApply(draft)
      },
      onCancel: onCancel
    )
  }

  private static func summaryLines(_ draft: HookWizardDraft) -> [String] {
    var lines: [String] = []
    lines.append("Event: \(draft.event)")
    if let matcher = draft.matcher, !matcher.isEmpty {
      lines.append("Matcher: \(matcher)")
    }
    let commandCount = draft.commands.count
    lines.append("Commands: \(commandCount)")
    if let targets = draft.targets {
      let codex = targets.codex ? "on" : "off"
      let claude = targets.claude ? "on" : "off"
      let gemini = targets.gemini ? "on" : "off"
      lines.append("Targets: Codex \(codex), Claude \(claude), Gemini \(gemini)")
    }
    return lines
  }
}

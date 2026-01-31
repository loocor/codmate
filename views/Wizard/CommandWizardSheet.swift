import SwiftUI

struct CommandWizardSheet: View {
  @ObservedObject var preferences: SessionPreferencesStore
  var onApply: (CommandWizardDraft) -> Void
  var onCancel: () -> Void

  @StateObject private var vm: WizardConversationViewModel<CommandWizardDraft>

  init(
    preferences: SessionPreferencesStore,
    onApply: @escaping (CommandWizardDraft) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.preferences = preferences
    self.onApply = onApply
    self.onCancel = onCancel
    _vm = StateObject(
      wrappedValue: WizardConversationViewModel<CommandWizardDraft>(
        feature: .commands,
        preferences: preferences,
        summaryBuilder: CommandWizardSheet.summaryLines
      )
    )
  }

  var body: some View {
    WizardConversationView(
      title: "Command Wizard",
      subtitle: "Describe the slash command you want to create.",
      vm: vm,
      onApply: { draft in
        onApply(draft)
      },
      onCancel: onCancel
    )
  }

  private static func summaryLines(_ draft: CommandWizardDraft) -> [String] {
    var lines: [String] = []
    lines.append("Name: \(draft.name)")
    lines.append("Description: \(draft.description)")
    lines.append("Prompt length: \(draft.prompt.count) chars")
    if !draft.tags.isEmpty {
      lines.append("Tags: \(draft.tags.joined(separator: ", "))")
    }
    if let targets = draft.targets {
      let codex = targets.codex ? "on" : "off"
      let claude = targets.claude ? "on" : "off"
      let gemini = targets.gemini ? "on" : "off"
      lines.append("Targets: Codex \(codex), Claude \(claude), Gemini \(gemini)")
    }
    return lines
  }
}

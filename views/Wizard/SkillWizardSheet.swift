import SwiftUI

struct SkillWizardSheet: View {
  @ObservedObject var preferences: SessionPreferencesStore
  var onApply: (SkillWizardDraft) -> Void
  var onCancel: () -> Void

  @StateObject private var vm: WizardConversationViewModel<SkillWizardDraft>

  init(
    preferences: SessionPreferencesStore,
    onApply: @escaping (SkillWizardDraft) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.preferences = preferences
    self.onApply = onApply
    self.onCancel = onCancel
    _vm = StateObject(
      wrappedValue: WizardConversationViewModel<SkillWizardDraft>(
        feature: .skills,
        preferences: preferences,
        summaryBuilder: SkillWizardSheet.summaryLines
      )
    )
  }

  var body: some View {
    WizardConversationView(
      title: "Skill Wizard",
      subtitle: "Describe the skill you want to create.",
      vm: vm,
      onApply: { draft in
        onApply(draft)
      },
      onCancel: onCancel
    )
  }

  private static func summaryLines(_ draft: SkillWizardDraft) -> [String] {
    var lines: [String] = []
    lines.append("Name: \(draft.name)")
    lines.append("Description: \(draft.description)")
    if let summary = draft.summary, !summary.isEmpty {
      lines.append("Summary: \(summary)")
    }
    if !draft.tags.isEmpty {
      lines.append("Tags: \(draft.tags.joined(separator: ", "))")
    }
    lines.append("Instructions: \(draft.instructions.count)")
    lines.append("Examples: \(draft.examples.count)")
    return lines
  }
}

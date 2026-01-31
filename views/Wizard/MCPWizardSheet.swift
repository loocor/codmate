import SwiftUI

struct MCPWizardSheet: View {
  @ObservedObject var preferences: SessionPreferencesStore
  var onApply: (MCPWizardDraft) -> Void
  var onCancel: () -> Void

  @StateObject private var vm: WizardConversationViewModel<MCPWizardDraft>

  init(
    preferences: SessionPreferencesStore,
    onApply: @escaping (MCPWizardDraft) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.preferences = preferences
    self.onApply = onApply
    self.onCancel = onCancel
    _vm = StateObject(
      wrappedValue: WizardConversationViewModel<MCPWizardDraft>(
        feature: .mcp,
        preferences: preferences,
        summaryBuilder: MCPWizardSheet.summaryLines
      )
    )
  }

  var body: some View {
    WizardConversationView(
      title: "MCP Server Wizard",
      subtitle: "Describe the MCP server you want to add.",
      vm: vm,
      onApply: { draft in
        onApply(draft)
      },
      onCancel: onCancel
    )
  }

  private static func summaryLines(_ draft: MCPWizardDraft) -> [String] {
    var lines: [String] = []
    lines.append("Name: \(draft.name)")
    lines.append("Kind: \(draft.kind.rawValue)")
    if let command = draft.command, !command.isEmpty {
      lines.append("Command: \(command)")
    }
    if let url = draft.url, !url.isEmpty {
      lines.append("URL: \(url)")
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

import Foundation

@MainActor
final class WizardConversationViewModel<Draft: Codable>: ObservableObject {
  @Published var messages: [WizardMessage] = []
  @Published var inputText: String = ""
  @Published var isRunning: Bool = false
  @Published var runEvents: [WizardRunEvent] = []
  @Published var draft: Draft? = nil
  @Published var draftTimestamp: Date? = nil
  @Published var questions: [String] = []
  @Published var warnings: [String] = []
  @Published var errorMessage: String? = nil
  @Published var selectedProvider: SessionSource.Kind

  let feature: WizardFeature
  private let preferences: SessionPreferencesStore
  private let runner = InternalSkillRunner()
  private let summaryBuilder: (Draft) -> [String]

  var availableProviders: [SessionSource.Kind] {
    SessionSource.Kind.allCases.filter { preferences.isCLIEnabled($0) }
  }

  init(
    feature: WizardFeature,
    preferences: SessionPreferencesStore,
    summaryBuilder: @escaping (Draft) -> [String]
  ) {
    self.feature = feature
    self.preferences = preferences
    self.summaryBuilder = summaryBuilder
    let fallback = WizardConversationViewModel.defaultProvider(preferences: preferences)
    let saved = SessionSource.Kind(rawValue: preferences.wizardPreferredProvider)
    self.selectedProvider = saved ?? fallback
  }

  func sendMessage() {
    let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    messages.append(WizardMessage(role: .user, text: trimmed))
    inputText = ""
    Task { await runSkill() }
  }

  func runSkill() async {
    errorMessage = nil
    questions = []
    draft = nil
    draftTimestamp = nil
    warnings = []
    runEvents = []
    isRunning = true

    appendEvent("Preparing skill input")
    appendEvent("Launching \(selectedProvider.displayName) CLI")

    do {
      let executable = preferences.preferredExecutablePath(for: selectedProvider)
      let result = try await runner.run(
        feature: feature,
        provider: selectedProvider,
        conversation: messages,
        defaultExecutable: executable,
        progress: { [weak self] event in
          self?.appendEvent(event)
        }
      )
      appendEvent("Parsing result")
      isRunning = false

      let raw = result.outputText.trimmingCharacters(in: .whitespacesAndNewlines)
      if let envelope: WizardDraftEnvelope<Draft> = WizardResponseParser.decodeEnvelope(raw) {
        handleEnvelope(envelope)
      } else if let draft: Draft = WizardResponseParser.decode(raw) {
        self.draft = draft
        self.draftTimestamp = Date()
      } else {
        errorMessage = "Failed to parse skill output."
      }
      preferences.wizardPreferredProvider = selectedProvider.rawValue
    } catch {
      isRunning = false
      errorMessage = error.localizedDescription
    }
  }

  func draftSummaryLines() -> [String] {
    guard let draft else { return [] }
    return summaryBuilder(draft)
  }

  private func handleEnvelope(_ envelope: WizardDraftEnvelope<Draft>) {
    warnings = envelope.warnings ?? []
    if envelope.mode == .question {
      let qs = envelope.questions ?? []
      questions = qs
      if !qs.isEmpty {
        messages.append(WizardMessage(role: .assistant, text: qs.joined(separator: "\n")))
      }
      return
    }
    if let draft = envelope.draft {
      self.draft = draft
      self.draftTimestamp = Date()
    }
  }

  private func appendEvent(_ message: String) {
    runEvents.append(WizardRunEvent(message: message, kind: .status))
  }

  private func appendEvent(_ event: WizardRunEvent) {
    runEvents.append(event)
  }

  private static func defaultProvider(preferences: SessionPreferencesStore) -> SessionSource.Kind {
    let candidates: [SessionSource.Kind] = [.codex, .claude, .gemini]
    if let found = candidates.first(where: { preferences.isCLIEnabled($0) }) {
      return found
    }
    return .codex
  }
}

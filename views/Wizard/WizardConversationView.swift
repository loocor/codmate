import SwiftUI

struct WizardConversationView<Draft: Codable>: View {
  let title: String
  let subtitle: String?
  @ObservedObject var vm: WizardConversationViewModel<Draft>
  var onApply: (Draft) -> Void
  var onCancel: () -> Void

  @FocusState private var inputFocused: Bool
  @EnvironmentObject private var wizardGuard: WizardGuard

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      conversationPanel

      if let error = vm.errorMessage, !error.isEmpty {
        ScrollView {
          Text(error)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.red)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 160)
      }
      actionBar
    }
    .padding(16)
    .frame(minWidth: 760, minHeight: 520, maxHeight: 720)
    .onAppear { wizardGuard.isActive = true }
    .onDisappear { wizardGuard.isActive = false }
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.title3)
          .fontWeight(.semibold)
        if let subtitle, !subtitle.isEmpty {
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Spacer()
      providerPicker
    }
  }

  private var providerPicker: some View {
    let providers =
      vm.availableProviders.isEmpty ? SessionSource.Kind.allCases : vm.availableProviders
    return Picker("Provider", selection: $vm.selectedProvider) {
      ForEach(providers, id: \.self) { provider in
        Text(provider.displayName).tag(provider)
      }
    }
    .pickerStyle(.segmented)
    .frame(width: 260)
  }

  private var conversationPanel: some View {
    VStack(spacing: 0) {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 10) {
          let items = timelineItems
          if items.isEmpty {
            Text("Describe what you want to create.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .center)
              .padding(.vertical, 32)
          }
          ForEach(items) { item in
            switch item.kind {
            case .message(let msg):
              messageRow(msg)
            case .draft(let draft):
              draftMessageRow(draft)
            case .runEvent(let event):
              runEventRow(event)
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
      }
      inputBar
    }
    .frame(maxHeight: .infinity)
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(Color(nsColor: .textBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.15)))
    )
  }

  private func messageRow(_ msg: WizardMessage) -> some View {
    HStack(alignment: .top, spacing: 8) {
      if msg.role == .user { Spacer(minLength: 0) }
      VStack(alignment: .leading, spacing: 4) {
        Text(msg.role == .user ? "You" : "Assistant")
          .font(.caption2)
          .foregroundStyle(.secondary)
        Text(msg.text)
          .font(.body)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(8)
      .background(
        RoundedRectangle(cornerRadius: 6)
          .fill(msg.role == .user ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08))
      )
      if msg.role != .user { Spacer(minLength: 0) }
    }
  }

  private func draftMessageRow(_ draft: Draft) -> some View {
    let lines = vm.draftSummaryLines()
    return HStack(alignment: .top, spacing: 8) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Assistant")
          .font(.caption2)
          .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 6) {
          Text("Draft preview")
            .font(.subheadline.weight(.semibold))
          ForEach(lines, id: \.self) { line in
            Text(line)
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          if !vm.warnings.isEmpty {
            ForEach(vm.warnings, id: \.self) { warning in
              Text("⚠︎ \(warning)")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
      }
      .padding(8)
      .background(
        RoundedRectangle(cornerRadius: 6)
          .fill(Color.secondary.opacity(0.08))
      )
      Spacer(minLength: 0)
    }
  }

  private var inputBar: some View {
    let canSend =
      !vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !vm.isRunning
    return ZStack(alignment: .bottomTrailing) {
      ZStack(alignment: .topLeading) {
        if vm.inputText.isEmpty {
          Text("Describe what you want to create…")
            .font(.body)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .allowsHitTesting(false)
        }
        TextEditor(text: $vm.inputText)
          .focused($inputFocused)
          .frame(minHeight: 72, maxHeight: 140)
          .padding(.horizontal, 8)
          .padding(.vertical, 6)
          .padding(.trailing, 36)
          .padding(.bottom, 24)
          .scrollContentBackground(.hidden)
          .background(Color.clear)
          .disabled(vm.isRunning)
      }
      Button(action: {
        vm.sendMessage()
      }) {
        Image(systemName: "paperplane.fill")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.white)
          .frame(width: 28, height: 28)
          .background(Circle().fill(canSend ? Color.accentColor : Color.secondary.opacity(0.35)))
      }
      .buttonStyle(.plain)
      .padding(8)
      .disabled(!canSend)
    }
    .background(
      RoundedRectangle(cornerRadius: 12)
        .fill(Color(nsColor: .textBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.15)))
    )
  }

  private func runEventRow(_ event: WizardRunEvent) -> some View {
    let isOutput = event.kind != .status
    let isErrorLine = event.kind == .stderr && isErrorMessage(event.message)
    let tint: Color = isErrorLine ? .red : .secondary
    let label: String = {
      switch event.kind {
      case .status: return "Tool"
      case .stdout: return "Tool Output"
      case .stderr: return isErrorLine ? "Tool Error" : "Tool Log"
      }
    }()
    return HStack(alignment: .top, spacing: 8) {
      VStack(alignment: .leading, spacing: 4) {
        Text(label)
          .font(.caption2)
          .foregroundStyle(tint)
        Text(event.message)
          .font(isOutput ? .system(size: 11, design: .monospaced) : .caption)
          .foregroundStyle(tint)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }
      .padding(8)
      .background(
        RoundedRectangle(cornerRadius: 6)
          .fill(Color.secondary.opacity(0.08))
      )
      Spacer(minLength: 0)
    }
  }

  private struct TimelineItem: Identifiable {
    enum Kind {
      case message(WizardMessage)
      case runEvent(WizardRunEvent)
      case draft(Draft)
    }

    let id: String
    let timestamp: Date
    let order: Int
    let kind: Kind
  }

  private var timelineItems: [TimelineItem] {
    var items: [TimelineItem] = []
    var order = 0
    for message in vm.messages {
      items.append(
        TimelineItem(
          id: "message-\(message.id.uuidString)",
          timestamp: message.createdAt,
          order: order,
          kind: .message(message)
        )
      )
      order += 1
    }
    for event in vm.runEvents {
      items.append(
        TimelineItem(
          id: "event-\(event.id.uuidString)",
          timestamp: event.timestamp,
          order: order,
          kind: .runEvent(event)
        )
      )
      order += 1
    }
    if let draft = vm.draft, let timestamp = vm.draftTimestamp, !vm.isRunning {
      items.append(
        TimelineItem(
          id: "draft-\(timestamp.timeIntervalSinceReferenceDate)",
          timestamp: timestamp,
          order: order,
          kind: .draft(draft)
        )
      )
      order += 1
    }
    return items.sorted { lhs, rhs in
      if lhs.timestamp == rhs.timestamp {
        return lhs.order < rhs.order
      }
      return lhs.timestamp < rhs.timestamp
    }
  }

  private func isErrorMessage(_ message: String) -> Bool {
    let lowercased = message.lowercased()
    return lowercased.contains("error")
      || lowercased.contains("failed")
      || lowercased.contains("invalid")
      || lowercased.contains("exception")
      || lowercased.contains("panic")
  }

  private var actionBar: some View {
    HStack {
      Spacer()
      Button("Cancel") { onCancel() }
      Button("Apply") {
        if let draft = vm.draft {
          onApply(draft)
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(vm.draft == nil || vm.isRunning)
    }
  }
}

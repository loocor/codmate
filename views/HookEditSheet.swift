import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct HookEditSheet: View {
  @ObservedObject var preferences: SessionPreferencesStore
  let rule: HookRule?
  let onSave: (HookRule) -> Void
  let onCancel: () -> Void

  @State private var name: String = ""
  @State private var descriptionText: String = ""
  @State private var enabled: Bool = true
  @State private var selectedEvent: String = ""
  @State private var customEvent: String = ""
  @State private var matcher: String = ""
  @State private var targets: HookTargets = HookTargets()
  @State private var commands: [EditableHookCommand] = []
  @State private var selectedTab: Int = 0
  @State private var errorMessage: String?
  @State private var hoveringCommandIds: Set<UUID> = []
  @State private var pendingDeleteCommand: PendingCommandDelete?
  @State private var eventPickerPresented: Bool = false
  @State private var eventQuery: String = ""
  @State private var eventFilter: HookEventFilter = .all
  @State private var variablePicker: VariablePickerContext?
  @State private var variableQuery: String = ""
  @State private var variableFilter: HookVariableFilter = .all
  @State private var wizardActive: Bool = false
  @State private var didHydrate: Bool = false
  @FocusState private var focusedField: FocusField?
  @FocusState private var eventSearchFocused: Bool
  private let variablePopoverSize: CGSize = CGSize(width: 360, height: 380)
  private let eventPopoverSize: CGSize = CGSize(width: 360, height: 380)
  @FocusState private var variableSearchFocused: Bool

  private enum FocusField {
    case name
  }

  private let customEventKey = "__custom__"
  private let sheetMaxHeight: CGFloat = 560
  private let generalRowMinHeight: CGFloat = 28

  var body: some View {
    if wizardActive {
      HookWizardSheet(preferences: preferences, onApply: { draft in
        applyDraft(draft)
        wizardActive = false
      }, onCancel: {
        wizardActive = false
      })
    } else {
      formBody
    }
  }

  private var formBody: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Text(rule == nil ? "New Hook" : "Edit Hook")
          .font(.title3)
          .fontWeight(.semibold)
        Spacer()
        Button {
          wizardActive = true
        } label: {
          Image(systemName: "sparkles")
        }
        .buttonStyle(.borderless)
        .help("AI Wizard")
      }

      if #available(macOS 15.0, *) {
        TabView(selection: $selectedTab) {
          Tab("General", systemImage: "slider.horizontal.3", value: 0) {
            SettingsTabContent { generalTab }
          }
          Tab("Commands", systemImage: "terminal", value: 1) {
            SettingsTabContent { commandsTab }
          }
        }
      } else {
        TabView(selection: $selectedTab) {
          SettingsTabContent { generalTab }
            .tabItem { Label("General", systemImage: "slider.horizontal.3") }
            .tag(0)
          SettingsTabContent { commandsTab }
            .tabItem { Label("Commands", systemImage: "terminal") }
            .tag(1)
        }
      }

      if let msg = errorMessage, !msg.isEmpty {
        Text(msg)
          .font(.caption)
          .foregroundStyle(.orange)
      }

      HStack {
        if selectedTab == 1 {
          Button("Add Command") {
            commands.append(EditableHookCommand())
          }
          .buttonStyle(.bordered)
        }
        Spacer()
        Button("Cancel") { onCancel() }
        Button(rule == nil ? "Create" : "Save") { save() }
          .buttonStyle(.borderedProminent)
          .disabled(!canSave)
      }
    }
    .padding(16)
    .frame(maxHeight: sheetMaxHeight)
    .onAppear {
      if rule == nil {
        DispatchQueue.main.async {
          focusedField = .name
        }
      }
    }
    .alert(item: $pendingDeleteCommand) { item in
      Alert(
        title: Text("Delete Command?"),
        message: Text("Remove this command from the hook?"),
        primaryButton: .destructive(Text("Delete")) {
          removeCommand(item.id)
          pendingDeleteCommand = nil
        },
        secondaryButton: .cancel { pendingDeleteCommand = nil }
      )
    }
    .onAppear {
      if !didHydrate {
        hydrateFromRule()
        didHydrate = true
      }
    }
  }

  private var canSave: Bool {
    let event = effectiveEvent
    guard !event.isEmpty else { return false }
    return commands.contains { !$0.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  }

  private var effectiveEvent: String {
    if selectedEvent == customEventKey {
      return customEvent.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return selectedEvent.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var eventLabelText: String {
    if selectedEvent == customEventKey {
      let trimmed = customEvent.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? "Custom…" : trimmed
    }
    return effectiveEvent.isEmpty ? "Select event" : effectiveEvent
  }

  private var eventPicker: some View {
    Button {
      eventPickerPresented = true
    } label: {
      HStack(spacing: 6) {
        Text(eventLabelText)
          .lineLimit(1)
        Spacer(minLength: 8)
        if let descriptor = HookEventCatalog.descriptor(for: effectiveEvent) {
          eventProviderIcons(for: descriptor)
        }
        Image(systemName: "chevron.down")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .background(
        RoundedRectangle(cornerRadius: 6)
          .fill(Color(nsColor: .textBackgroundColor))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 6)
          .stroke(Color.secondary.opacity(0.25))
      )
    }
    .buttonStyle(.plain)
    .help(HookEventCatalog.detailText(for: effectiveEvent))
    .popover(isPresented: $eventPickerPresented, arrowEdge: .bottom) {
      eventPickerView()
    }
  }

  @ViewBuilder private var generalTab: some View {
    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
      GridRow {
        Text("Name").font(.subheadline).fontWeight(.medium)
        TextField("Optional display name", text: $name)
          .focused($focusedField, equals: .name)
          .frame(minHeight: generalRowMinHeight)
          .frame(maxWidth: .infinity, alignment: .trailing)
      }

      GridRow {
        Text("Event").font(.subheadline).fontWeight(.medium)
        eventPicker
          .frame(minHeight: generalRowMinHeight)
          .frame(maxWidth: .infinity, alignment: .trailing)
      }

      if selectedEvent == customEventKey {
        GridRow {
          Text("Custom Event").font(.subheadline).fontWeight(.medium)
          TextField("Custom event name", text: $customEvent)
            .frame(minHeight: generalRowMinHeight)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
      }

      GridRow {
        Text("Matcher").font(.subheadline).fontWeight(.medium)
        Group {
          if HookEventCatalog.supportsMatcher(effectiveEvent, targets: targets) {
            let options = HookEventCatalog.matchers(for: effectiveEvent, targets: targets)
            HStack(spacing: 6) {
              TextField("Matcher (e.g., Write|Edit)", text: $matcher)
              if !options.isEmpty {
                Menu {
                  ForEach(options, id: \.value) { option in
                    Button(option.value) { matcher = option.value }
                  }
                } label: {
                  Image(systemName: "chevron.down")
                }
                .menuIndicator(.hidden)
                .buttonStyle(.borderless)
              }
            }
            .help(HookEventCatalog.matcherDescription(for: effectiveEvent, matcher: matcher) ?? "")
          } else {
            Text("Not applicable for this event")
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.tail)
          }
        }
        .frame(minHeight: generalRowMinHeight)
        .frame(maxWidth: .infinity, alignment: .trailing)
      }

      GridRow {
        Text("Description").font(.subheadline).fontWeight(.medium)
        descriptionEditor(text: $descriptionText)
          .frame(maxWidth: .infinity, alignment: .trailing)
      }

      GridRow {
        Text("Targets").font(.subheadline).fontWeight(.medium)
        HStack(spacing: 12) {
          Toggle(
            "Codex",
            isOn: Binding(
              get: { targets.codex },
              set: { targets.codex = $0 }
            )
          )
          .toggleStyle(.switch)
          .controlSize(.small)
          .disabled(!preferences.isCLIEnabled(.codex))

          Toggle(
            "Claude Code",
            isOn: Binding(
              get: { targets.claude },
              set: { targets.claude = $0 }
            )
          )
          .toggleStyle(.switch)
          .controlSize(.small)
          .disabled(!preferences.isCLIEnabled(.claude))

          Toggle(
            "Gemini",
            isOn: Binding(
              get: { targets.gemini },
              set: { targets.gemini = $0 }
            )
          )
          .toggleStyle(.switch)
          .controlSize(.small)
          .disabled(!preferences.isCLIEnabled(.gemini))
        }
        .frame(minHeight: generalRowMinHeight)
        .frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
  }

  @ViewBuilder private var commandsTab: some View {
    VStack(alignment: .leading, spacing: 12) {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(Array(commands.enumerated()), id: \.element.id) { index, _ in
            commandCard(index: index, id: commands[index].id)
          }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.top, 4)
      }
      .frame(maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private func hydrateFromRule() {
    guard let rule else {
      selectedEvent = HookEventCatalog.canonicalEvents.first ?? "Stop"
      commands = [EditableHookCommand()]
      targets = HookTargets()
      enabled = true
      descriptionText = ""
      return
    }

    name = rule.name
    descriptionText = rule.description ?? ""
    enabled = rule.enabled
    if let descriptor = HookEventCatalog.descriptor(for: rule.event) {
      selectedEvent = descriptor.name
      customEvent = ""
    } else {
      selectedEvent = customEventKey
      customEvent = rule.event
    }
    matcher = rule.matcher ?? ""
    targets = rule.targets ?? HookTargets()
    commands = rule.commands.map { EditableHookCommand(from: $0) }
    if commands.isEmpty { commands = [EditableHookCommand()] }
  }

  private func applyDraft(_ draft: HookWizardDraft) {
    name = draft.name ?? ""
    descriptionText = draft.description ?? ""
    enabled = true
    if let descriptor = HookEventCatalog.descriptor(for: draft.event) {
      selectedEvent = descriptor.name
      customEvent = ""
    } else {
      selectedEvent = customEventKey
      customEvent = draft.event
    }
    matcher = draft.matcher ?? ""
    targets = draft.targets ?? HookTargets()
    commands = draft.commands.map { EditableHookCommand(from: $0) }
    if commands.isEmpty { commands = [EditableHookCommand()] }
  }

  private func removeCommand(_ id: UUID) {
    commands.removeAll { $0.id == id }
    hoveringCommandIds.remove(id)
    if commands.isEmpty { commands = [EditableHookCommand()] }
  }

  private func confirmDeleteCommand(_ id: UUID) {
    pendingDeleteCommand = PendingCommandDelete(id: id)
  }

  private func commandCard(index: Int, id: UUID) -> some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 8) {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
          GridRow {
            Text("Command")
              .font(.caption)
              .foregroundStyle(.secondary)
            HStack(spacing: 8) {
              TextField("Select executable or type path", text: $commands[index].command)
              Button {
                chooseCommandPath(for: id)
              } label: {
                Image(systemName: "folder")
              }
              .buttonStyle(.borderless)
              .help("Choose executable")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
          }

          GridRow {
            Text("Args")
              .font(.caption)
              .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 8) {
              placeholderEditor(
                text: $commands[index].argsText,
                placeholder: "one argument per line",
                height: 88
              )
              variableInsertButton(commandId: id, target: .args)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
          }

          GridRow {
            Text("Env")
              .font(.caption)
              .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 8) {
              placeholderEditor(
                text: $commands[index].envText,
                placeholder: "KEY=VALUE, one per line",
                height: 88
              )
              variableInsertButton(commandId: id, target: .env)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
          }

          GridRow {
            Text("Timeout")
              .font(.caption)
              .foregroundStyle(.secondary)
            HStack(spacing: 8) {
              TextField("ms", text: $commands[index].timeoutMsText)
                .frame(width: 180, alignment: .trailing)
              Spacer()
              Button(role: .destructive) {
                confirmDeleteCommand(id)
              } label: {
                Image(systemName: "trash")
              }
              .buttonStyle(.borderless)
              .help("Remove command")
              .opacity(hoveringCommandIds.contains(id) ? 1 : 0)
              .scaleEffect(hoveringCommandIds.contains(id) ? 1.0 : 0.92)
              .offset(y: hoveringCommandIds.contains(id) ? 0 : 2)
              .allowsHitTesting(hoveringCommandIds.contains(id))
              .animation(.easeInOut(duration: 0.12), value: hoveringCommandIds.contains(id))
            }
          }
        }
      }
      .padding(4)
    }
    .onHover { hovering in
      if hovering {
        hoveringCommandIds.insert(id)
      } else {
        hoveringCommandIds.remove(id)
      }
    }
  }

  private func descriptionEditor(text: Binding<String>) -> some View {
    ZStack(alignment: .topLeading) {
      if text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Text("Describe what this hook is for…")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .padding(.top, 6)
          .padding(.leading, 4)
      }
      TextEditor(text: text)
        .font(.body)
        .frame(height: 64)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .textBackgroundColor))
    }
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .stroke(Color.secondary.opacity(0.15))
    )
  }

  private func placeholderEditor(
    text: Binding<String>,
    placeholder: String,
    height: CGFloat = 44
  ) -> some View {
    ZStack(alignment: .topLeading) {
      if text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Text(placeholder)
          .font(.caption)
          .foregroundStyle(.tertiary)
          .padding(.top, 6)
          .padding(.leading, 4)
      }
      TextEditor(text: text)
        .font(.system(.caption, design: .monospaced))
        .frame(height: height)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .textBackgroundColor))
    }
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .stroke(Color.secondary.opacity(0.15))
    )
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func variableInsertButton(commandId: UUID, target: VariableInsertTarget) -> some View {
    Button {
      variablePicker = VariablePickerContext(commandId: commandId, target: target)
    } label: {
      Image(systemName: "curlybraces.square")
    }
    .buttonStyle(.borderless)
    .help("Insert variable")
    .popover(
      isPresented: popoverBinding(for: commandId, target: target),
      arrowEdge: .bottom
    ) {
      variablePickerView(commandId: commandId, target: target)
    }
  }

  private func popoverBinding(for commandId: UUID, target: VariableInsertTarget) -> Binding<Bool> {
    Binding(
      get: { variablePicker?.commandId == commandId && variablePicker?.target == target },
      set: { isPresented in
        if isPresented {
          variablePicker = VariablePickerContext(commandId: commandId, target: target)
        } else if variablePicker?.commandId == commandId && variablePicker?.target == target {
          variablePicker = nil
        }
      }
    )
  }

  private func variablePickerView(commandId: UUID, target: VariableInsertTarget) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Hook variables")
        .font(.headline)
      Text("Selecting a variable inserts it into the field.")
        .font(.footnote)
        .foregroundStyle(.secondary)
      Picker("Filter", selection: $variableFilter) {
        ForEach(HookVariableFilter.allCases) { filter in
          Text(filter.title).tag(filter)
        }
      }
      .labelsHidden()
      .pickerStyle(.segmented)
      .controlSize(.small)
      TextField("Search variables", text: $variableQuery)
        .textFieldStyle(.roundedBorder)
        .focused($variableSearchFocused)
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          let rows = filteredVariables(for: target)
          ForEach(rows.indices, id: \.self) { idx in
            variableRow(rows[idx], index: idx, commandId: commandId, target: target)
          }
          if rows.isEmpty {
            Text("No variables match this filter.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .padding(.vertical, 8)
              .frame(maxWidth: .infinity, alignment: .center)
          }
        }
      }
      .frame(minHeight: 160, maxHeight: .infinity)
      .layoutPriority(1)
    }
    .padding(12)
    .frame(width: variablePopoverSize.width, height: variablePopoverSize.height, alignment: .topLeading)
    .onAppear {
      DispatchQueue.main.async { variableSearchFocused = true }
    }
  }

  private func eventPickerView() -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Hook events")
        .font(.headline)
      Text("Select the event that should trigger this hook.")
        .font(.footnote)
        .foregroundStyle(.secondary)
      Picker("Filter", selection: $eventFilter) {
        ForEach(HookEventFilter.allCases) { filter in
          Text(filter.title).tag(filter)
        }
      }
      .labelsHidden()
      .pickerStyle(.segmented)
      .controlSize(.small)
      TextField("Search events", text: $eventQuery)
        .textFieldStyle(.roundedBorder)
        .focused($eventSearchFocused)
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          let rows = filteredEvents()
          ForEach(rows.indices, id: \.self) { idx in
            eventRow(rows[idx], index: idx)
          }
          if rows.isEmpty {
            Text("No events match this filter.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .padding(.vertical, 8)
              .frame(maxWidth: .infinity, alignment: .center)
          }
        }
      }
      .frame(minHeight: 160, maxHeight: .infinity)
      .layoutPriority(1)
      Divider()
      Button("Custom…") {
        selectedEvent = customEventKey
        eventPickerPresented = false
      }
      .buttonStyle(.borderless)
    }
    .padding(12)
    .frame(width: eventPopoverSize.width, height: eventPopoverSize.height, alignment: .topLeading)
    .onAppear {
      DispatchQueue.main.async { eventSearchFocused = true }
    }
  }

  private func filteredEvents() -> [HookEventDescriptor] {
    let candidates = HookEventCatalog.all.filter { matchesEventFilter($0) }
    let trimmed = eventQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return candidates }
    let query = trimmed.lowercased()
    return candidates.filter {
      if $0.name.lowercased().contains(query) { return true }
      if $0.description.lowercased().contains(query) { return true }
      if let note = $0.note?.lowercased(), note.contains(query) { return true }
      return false
    }
  }

  private func matchesEventFilter(_ event: HookEventDescriptor) -> Bool {
    switch eventFilter {
    case .all:
      return true
    case .common:
      return event.providers.contains(.claude) && event.providers.contains(.gemini)
    case .codex:
      return event.providers.contains(.codex)
    case .claude:
      return event.providers.contains(.claude)
    case .gemini:
      return event.providers.contains(.gemini)
    }
  }

  private func eventRow(_ event: HookEventDescriptor, index: Int) -> some View {
    let detail = HookEventCatalog.detailText(for: event.name)
    return Button {
      selectedEvent = event.name
      customEvent = ""
      eventPickerPresented = false
    } label: {
      HStack(spacing: 8) {
        eventProviderIcons(for: event)
        VStack(alignment: .leading, spacing: 2) {
          Text(event.name)
            .font(.system(.caption, design: .monospaced))
            .lineLimit(1)
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.leading, 8)
      .padding(.trailing, 12)
      .padding(.vertical, 6)
      .frame(minHeight: 44)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(index % 2 == 0 ? Color.secondary.opacity(0.06) : Color.clear)
      .contentShape(Rectangle())
      .help("\(event.name) — \(detail)")
    }
    .buttonStyle(.plain)
  }

  private func filteredVariables(for target: VariableInsertTarget) -> [HookVariableDescriptor] {
    let candidates = HookCommandVariableCatalog.all.filter {
      matchesTarget($0, target: target) && matchesFilter($0)
    }
    let trimmed = variableQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return candidates }
    let query = trimmed.lowercased()
    return candidates.filter { matchesQuery($0, query: query) }
  }

  private func variableRow(
    _ variable: HookVariableDescriptor,
    index: Int,
    commandId: UUID,
    target: VariableInsertTarget
  ) -> some View {
    let detail = variableDetailText(variable)
    return Button {
      insertVariable(variable, into: target, commandId: commandId)
      variablePicker = nil
    } label: {
      HStack(spacing: 8) {
        providerIcons(for: variable)
        VStack(alignment: .leading, spacing: 2) {
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(variable.name)
              .font(.system(.caption, design: .monospaced))
              .lineLimit(1)
            Spacer(minLength: 8)
            kindBadge(variable.kind)
          }
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.leading, 8)
      .padding(.trailing, 12)
      .padding(.vertical, 6)
      .frame(minHeight: 44)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(index % 2 == 0 ? Color.secondary.opacity(0.06) : Color.clear)
      .contentShape(Rectangle())
      .help("\(variable.name) — \(detail)")
    }
    .buttonStyle(.plain)
  }

  private func providerIcons(for variable: HookVariableDescriptor) -> some View {
    HStack(spacing: 4) {
      providerIcon(.codex, variable: variable)
      providerIcon(.claude, variable: variable)
      providerIcon(.gemini, variable: variable)
    }
  }

  private func providerIcon(_ provider: HookVariableProvider, variable: HookVariableDescriptor) -> some View {
    let supported = variable.providers.contains(provider)
    let supportText = supported ? "Supported" : "Not supported"
    return providerIcon(provider, supported: supported)
      .help("\(provider.displayName) · \(supportText)")
  }

  private func eventProviderIcons(for event: HookEventDescriptor) -> some View {
    HStack(spacing: 4) {
      eventProviderIcon(.codex, event: event)
      eventProviderIcon(.claude, event: event)
      eventProviderIcon(.gemini, event: event)
    }
  }

  private func eventProviderIcon(_ provider: HookVariableProvider, event: HookEventDescriptor) -> some View {
    let supported = event.providers.contains(provider)
    let supportText = supported ? "Supported" : "Not supported"
    return providerIcon(provider, supported: supported)
      .help("\(provider.displayName) · \(supportText)")
  }

  private func providerIcon(_ provider: HookVariableProvider, supported: Bool) -> some View {
    let opacity: Double = supported ? 1.0 : 0.2
    let saturation: Double = supported ? 1.0 : 0.0
    let grayscale: Double = supported ? 0.0 : 1.0
    return ProviderIconView(
      provider: usageProvider(for: provider),
      size: 12,
      cornerRadius: 2,
      saturation: saturation,
      opacity: opacity
    )
    .grayscale(grayscale)
  }

  private func usageProvider(for provider: HookVariableProvider) -> UsageProviderKind {
    switch provider {
    case .codex: return .codex
    case .claude: return .claude
    case .gemini: return .gemini
    }
  }

  private func variableDetailText(_ variable: HookVariableDescriptor) -> String {
    if let note = variable.note, !note.isEmpty {
      return "\(variable.description) (\(note))"
    }
    return variable.description
  }

  private func matchesFilter(_ variable: HookVariableDescriptor) -> Bool {
    switch variableFilter {
    case .all:
      return true
    case .common:
      return variable.providers.contains(.claude) && variable.providers.contains(.gemini)
    case .codex:
      return variable.providers.contains(.codex)
    case .claude:
      return variable.providers.contains(.claude)
    case .gemini:
      return variable.providers.contains(.gemini)
    }
  }

  private func matchesTarget(_ variable: HookVariableDescriptor, target: VariableInsertTarget) -> Bool {
    switch target {
    case .args:
      return true
    case .env:
      return variable.kind == .env
    }
  }

  private func matchesQuery(_ variable: HookVariableDescriptor, query: String) -> Bool {
    if variable.name.lowercased().contains(query) { return true }
    if variable.description.lowercased().contains(query) { return true }
    if let note = variable.note?.lowercased(), note.contains(query) { return true }
    return false
  }

  private func kindBadge(_ kind: HookVariableKind) -> some View {
    Text(kind.shortLabel)
      .font(.system(size: 9, weight: .semibold))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .background(Color.secondary.opacity(0.12))
      .clipShape(Capsule())
  }

  private func insertVariable(_ variable: HookVariableDescriptor, into target: VariableInsertTarget, commandId: UUID) {
    let token = variableInsertToken(variable)
    updateCommand(commandId) { editable in
      switch target {
      case .args:
        editable.argsText = appendToken(token, to: editable.argsText, separator: "\n")
      case .env:
        editable.envText = appendToken(token, to: editable.envText, separator: "\n")
      }
    }
  }

  private func updateCommand(_ commandId: UUID, mutate: (inout EditableHookCommand) -> Void) {
    guard let index = commands.firstIndex(where: { $0.id == commandId }) else { return }
    mutate(&commands[index])
  }

  private func appendToken(_ token: String, to text: String, separator: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return token }
    if text.hasSuffix(separator) { return text + token }
    return text + separator + token
  }

  private func variableInsertToken(_ variable: HookVariableDescriptor) -> String {
    switch variable.kind {
    case .env:
      return "$\(variable.name)"
    case .stdin:
      return stdinToken(for: variable.name)
    }
  }

  private func stdinToken(for name: String) -> String {
    let objectFields: Set<String> = ["tool_input", "tool_response", "llm_request", "llm_response", "details", "mcp_context"]
    let flag = objectFields.contains(name) ? "-c" : "-r"
    return "$(jq \(flag) '.\(name)')"
  }

  private func chooseCommandPath(for id: UUID) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.treatsFilePackagesAsDirectories = false
    panel.prompt = "Choose"
    panel.message = "Choose an executable to run for this hook"
    panel.allowedContentTypes = [.executable]
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      guard FileManager.default.isExecutableFile(atPath: url.path) else {
        errorMessage = "Selected file is not executable."
        return
      }
      guard let index = commands.firstIndex(where: { $0.id == id }) else { return }
      commands[index].command = url.path
      errorMessage = nil
    }
  }

  private func parseLines(_ text: String) -> [String] {
    text
      .split(whereSeparator: \.isNewline)
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  private func parseEnv(_ text: String) -> [String: String] {
    var env: [String: String] = [:]
    for line in parseLines(text) {
      guard let eq = line.firstIndex(of: "=") else { continue }
      let key = String(line[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
      let value = String(line[line.index(after: eq)...]).trimmingCharacters(
        in: .whitespacesAndNewlines)
      guard !key.isEmpty else { continue }
      env[key] = value
    }
    return env
  }

  private func save() {
    errorMessage = nil

    let event = effectiveEvent
    guard !event.isEmpty else {
      errorMessage = "Event is required."
      return
    }

    let finalMatcher: String? = {
      let trimmed = matcher.trimmingCharacters(in: .whitespacesAndNewlines)
      guard HookEventCatalog.supportsMatcher(event, targets: targets) else { return nil }
      return trimmed.isEmpty ? nil : trimmed
    }()

    let finalCommands: [HookCommand] = commands.compactMap { editable in
      let program = editable.command.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !program.isEmpty else { return nil }
      let args = parseLines(editable.argsText)
      let env = parseEnv(editable.envText)
      let timeout = Int(editable.timeoutMsText.trimmingCharacters(in: .whitespacesAndNewlines))
      return HookCommand(
        command: program,
        args: args.isEmpty ? nil : args,
        env: env.isEmpty ? nil : env,
        timeoutMs: (timeout ?? 0) > 0 ? timeout : nil
      )
    }
    guard !finalCommands.isEmpty else {
      errorMessage = "At least one command is required."
      return
    }

    var finalName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if finalName.isEmpty {
      finalName = HookEventCatalog.defaultName(
        event: event, matcher: finalMatcher, command: finalCommands.first)
    }
    let finalDescriptionText = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
    let finalDescription = finalDescriptionText.isEmpty ? nil : finalDescriptionText

    let resolvedTargets = targets.allEnabled ? nil : targets
    let now = Date()
    let out = HookRule(
      id: rule?.id ?? UUID().uuidString,
      name: finalName,
      description: finalDescription,
      event: event,
      matcher: finalMatcher,
      commands: finalCommands,
      enabled: enabled,
      targets: resolvedTargets,
      source: rule?.source ?? "user",
      createdAt: rule?.createdAt ?? now,
      updatedAt: now
    )
    onSave(out)
  }
}

private enum VariableInsertTarget: Sendable {
  case args
  case env
}

private enum HookVariableFilter: String, CaseIterable, Identifiable {
  case all
  case common
  case codex
  case claude
  case gemini

  var id: String { rawValue }

  var title: String {
    switch self {
    case .all: return "All"
    case .common: return "Common"
    case .codex: return "Codex"
    case .claude: return "Claude"
    case .gemini: return "Gemini"
    }
  }
}

private enum HookEventFilter: String, CaseIterable, Identifiable {
  case all
  case common
  case codex
  case claude
  case gemini

  var id: String { rawValue }

  var title: String {
    switch self {
    case .all: return "All"
    case .common: return "Common"
    case .codex: return "Codex"
    case .claude: return "Claude"
    case .gemini: return "Gemini"
    }
  }
}

private struct VariablePickerContext: Identifiable {
  let id = UUID()
  let commandId: UUID
  let target: VariableInsertTarget
}

private struct PendingCommandDelete: Identifiable {
  let id: UUID
}

private struct EditableHookCommand: Identifiable {
  let id: UUID
  var command: String
  var argsText: String
  var envText: String
  var timeoutMsText: String

  init(
    id: UUID = UUID(),
    command: String = "",
    argsText: String = "",
    envText: String = "",
    timeoutMsText: String = ""
  ) {
    self.id = id
    self.command = command
    self.argsText = argsText
    self.envText = envText
    self.timeoutMsText = timeoutMsText
  }

  init(from command: HookCommand) {
    self.id = UUID()
    self.command = command.command
    self.argsText = (command.args ?? []).joined(separator: "\n")
    self.envText = (command.env ?? [:]).map { "\($0.key)=\($0.value)" }.sorted().joined(
      separator: "\n")
    self.timeoutMsText = command.timeoutMs.map(String.init) ?? ""
  }
}

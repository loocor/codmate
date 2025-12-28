import SwiftUI

struct CommandsSettingsView: View {
  @StateObject private var vm = CommandsViewModel()
  @State private var searchFocused = false
  @State private var pendingAction: PendingCommandAction?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      headerRow
      contentRow
    }
    .sheet(isPresented: $vm.showAddSheet) {
      CommandEditSheet(
        command: nil,
        onSave: { command in
          Task {
            await vm.addCommand(command)
            vm.showAddSheet = false
          }
        },
        onCancel: { vm.showAddSheet = false }
      )
      .frame(minWidth: 760, minHeight: 480)
    }
    .sheet(item: $vm.editingCommand) { command in
      CommandEditSheet(
        command: command,
        onSave: { updated in
          Task {
            await vm.updateCommand(updated)
            vm.editingCommand = nil
          }
        },
        onCancel: { vm.editingCommand = nil }
      )
      .frame(minWidth: 760, minHeight: 480)
    }
    .alert(item: $pendingAction) { action in
      Alert(
        title: Text("Delete Command?"),
        message: Text("Remove \"\(action.command.name)\" from the commands list?"),
        primaryButton: .destructive(Text("Delete")) {
          Task {
            await vm.deleteCommand(id: action.command.id)
            pendingAction = nil
          }
        },
        secondaryButton: .cancel { pendingAction = nil }
      )
    }
    .task { await vm.load() }
  }

  private var headerRow: some View {
    HStack(spacing: 8) {
      Spacer(minLength: 0)
      ToolbarSearchField(
        placeholder: "Search commands",
        text: $vm.searchText,
        onFocusChange: { focused in searchFocused = focused },
        onSubmit: {}
      )
      .frame(width: 240)

      Button {
        vm.showAddSheet = true
      } label: {
        Label("Add", systemImage: "plus")
      }
    }
  }

  private var contentRow: some View {
    HStack(alignment: .top, spacing: 12) {
      commandsList
        .frame(minWidth: 260, maxWidth: 320)
      detailPanel
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var commandsList: some View {
    Group {
      if vm.isLoading {
        VStack(spacing: 8) {
          ProgressView()
          Text("Loading commands…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if vm.filteredCommands.isEmpty {
        VStack(spacing: 10) {
          Image(systemName: "command")
            .font(.system(size: 32))
            .foregroundStyle(.secondary)
          Text("No Commands")
            .font(.title3)
            .fontWeight(.medium)
          Text("Add a command to get started.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(selection: $vm.selectedCommandId) {
          ForEach(vm.filteredCommands) { command in
            HStack(alignment: .center, spacing: 8) {
              Toggle(
                "",
                isOn: Binding(
                  get: { command.isEnabled },
                  set: { value in
                    vm.updateCommandEnabled(id: command.id, value: value)
                  }
                )
              )
              .labelsHidden()
              .controlSize(.small)

              VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                  Text(command.name)
                    .font(.body.weight(.medium))
                }
                Text(command.description)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(2)
              }
              Spacer(minLength: 8)
              HStack(spacing: 6) {
                MCPServerTargetToggle(
                  provider: .codex,
                  isOn: Binding(
                    get: { vm.isCommandTargetEnabled(id: command.id, target: .codex) },
                    set: { value in
                      vm.updateCommandTarget(id: command.id, target: .codex, value: value)
                    }
                  ),
                  disabled: false
                )
                MCPServerTargetToggle(
                  provider: .claude,
                  isOn: Binding(
                    get: { vm.isCommandTargetEnabled(id: command.id, target: .claude) },
                    set: { value in
                      vm.updateCommandTarget(id: command.id, target: .claude, value: value)
                    }
                  ),
                  disabled: false
                )
                MCPServerTargetToggle(
                  provider: .gemini,
                  isOn: Binding(
                    get: { vm.isCommandTargetEnabled(id: command.id, target: .gemini) },
                    set: { value in
                      vm.updateCommandTarget(id: command.id, target: .gemini, value: value)
                    }
                  ),
                  disabled: false
                )
              }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture { vm.selectedCommandId = command.id }
            .tag(command.id as String?)
            .contextMenu {
              Button("Edit") { vm.editingCommand = command }
              Divider()
              Button("Reveal in Finder") {
                revealInFinder(path: command.path)
              }
              Divider()
              Button("Delete", role: .destructive) { confirmDelete(command) }
            }
          }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
      }
    }
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color(nsColor: .textBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.15)))
    )
  }

  private var detailPanel: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let command = vm.selectedCommand {
        CommandDetailExplorerView(
          command: command,
          onEdit: { vm.editingCommand = command },
          onDelete: { confirmDelete(command) },
          onSync: { Task { await vm.manualSync() } }
        )
        .id(command.id)
      } else {
        VStack(spacing: 12) {
          Image(systemName: "command")
            .font(.system(size: 32))
            .foregroundStyle(.secondary)
          Text("Select a command to view details")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color(nsColor: .textBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.15)))
    )
  }

  private func confirmDelete(_ command: CommandRecord) {
    pendingAction = PendingCommandAction(command: command)
  }

  private func revealInFinder(path: String) {
    guard !path.isEmpty else { return }
    let url = URL(fileURLWithPath: path)
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }
}

private struct PendingCommandAction: Identifiable {
  let id = UUID()
  let command: CommandRecord
}

// MARK: - Command Detail Explorer View
struct CommandDetailExplorerView: View {
  let command: CommandRecord
  let onEdit: () -> Void
  let onDelete: () -> Void
  let onSync: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          promptSection
          if hasMetadata {
            metadataSection
          }
          if !command.metadata.tags.isEmpty {
            tagsSection
          }
          infoSection
        }
      }
    }
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 6) {
        Text(command.name)
          .font(.title3.weight(.semibold))
        Text(command.description)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      Spacer()
      HStack(spacing: 8) {
        Button {
          onSync()
        } label: {
          Image(systemName: "arrow.triangle.2.circlepath")
        }
        .buttonStyle(.borderless)
        .help("Sync commands to AI CLI providers")

        Button {
          onEdit()
        } label: {
          Image(systemName: "pencil")
        }
        .buttonStyle(.borderless)
        .help("Edit")

        Button(role: .destructive) {
          onDelete()
        } label: {
          Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .help("Delete")
      }
    }
  }

  private var promptSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Prompt")
        .font(.headline)
      Text(command.prompt)
        .font(.system(size: 13))
        .textSelection(.enabled)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
  }

  private var hasMetadata: Bool {
    command.metadata.argumentHint != nil ||
    command.metadata.model != nil ||
    (command.metadata.allowedTools?.isEmpty == false)
  }

  private var metadataSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Metadata")
        .font(.headline)

      VStack(alignment: .leading, spacing: 6) {
        if let hint = command.metadata.argumentHint {
          metadataRow(label: "Argument Hint", value: hint)
        }
        if let model = command.metadata.model {
          metadataRow(label: "Model", value: model)
        }
        if let tools = command.metadata.allowedTools, !tools.isEmpty {
          metadataRow(label: "Allowed Tools", value: tools.joined(separator: ", "))
        }
      }
    }
  }

  private func metadataRow(label: String, value: String) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(width: 100, alignment: .leading)
      Text(value)
        .font(.caption)
        .textSelection(.enabled)
      Spacer()
    }
  }

  private var tagsSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Tags")
        .font(.headline)
      HStack(spacing: 6) {
        ForEach(command.metadata.tags, id: \.self) { tag in
          Text(tag)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
      }
    }
  }

  private var infoSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Divider()
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Source")
            .font(.caption2)
            .foregroundStyle(.tertiary)
          Text(command.source)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 4) {
          Text("Installed")
            .font(.caption2)
            .foregroundStyle(.tertiary)
          Text(command.installedAt.formatted(date: .abbreviated, time: .omitted))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }
}

// MARK: - Command Edit Sheet
struct CommandEditSheet: View {
  let command: CommandRecord?
  let onSave: (CommandRecord) -> Void
  let onCancel: () -> Void

  @State private var id: String = ""
  @State private var name: String = ""
  @State private var description: String = ""
  @State private var prompt: String = ""
  @State private var argumentHint: String = ""
  @State private var model: String = ""
  @State private var allowedTools: String = ""
  @State private var tags: String = ""
  @State private var codexEnabled = true
  @State private var claudeEnabled = true
  @State private var geminiEnabled = false
  @State private var selectedTab: Int = 0

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      // Header (title only)
      HStack(alignment: .firstTextBaseline) {
        Text(command == nil ? "New Command" : "Edit Command")
          .font(.title3)
          .fontWeight(.semibold)
        Spacer()
      }

      // Tabs
      if #available(macOS 15.0, *) {
        TabView(selection: $selectedTab) {
          Tab("General", systemImage: "slider.horizontal.3", value: 0) {
            SettingsTabContent { generalTab }
          }
          Tab("Metadata", systemImage: "info.circle", value: 1) {
            SettingsTabContent { metadataTab }
          }
        }
      } else {
        TabView(selection: $selectedTab) {
          SettingsTabContent { generalTab }
            .tabItem { Label("General", systemImage: "slider.horizontal.3") }
            .tag(0)
          SettingsTabContent { metadataTab }
            .tabItem { Label("Metadata", systemImage: "info.circle") }
            .tag(1)
        }
      }

      // Bottom buttons
      HStack {
        Spacer()
        Button("Cancel") {
          onCancel()
        }
        Button(command == nil ? "Create" : "Save") {
          saveCommand()
        }
        .buttonStyle(.borderedProminent)
        .disabled(name.isEmpty || description.isEmpty || prompt.isEmpty)
      }
    }
    .padding(16)
    .onAppear {
      if let cmd = command {
        id = cmd.id
        name = cmd.name
        description = cmd.description
        prompt = cmd.prompt
        argumentHint = cmd.metadata.argumentHint ?? ""
        model = cmd.metadata.model ?? ""
        allowedTools = cmd.metadata.allowedTools?.joined(separator: ", ") ?? ""
        tags = cmd.metadata.tags.joined(separator: ", ")
        codexEnabled = cmd.targets.codex
        claudeEnabled = cmd.targets.claude
        geminiEnabled = cmd.targets.gemini
      }
    }
  }

  @ViewBuilder private var generalTab: some View {
    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
      GridRow {
        Text("Name").font(.subheadline).fontWeight(.medium)
        TextField("command-name", text: $name)
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
      GridRow {
        Text("Description").font(.subheadline).fontWeight(.medium)
        TextField("Short description", text: $description)
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
      GridRow {
        Text("Prompt").font(.subheadline).fontWeight(.medium)
        TextEditor(text: $prompt)
          .font(.system(.caption, design: .monospaced))
          .frame(height: 180)
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
      GridRow {
        Text("Targets").font(.subheadline).fontWeight(.medium)
        HStack(spacing: 12) {
          Toggle("Codex", isOn: $codexEnabled)
            .toggleStyle(.switch)
            .controlSize(.small)
          Toggle("Claude Code", isOn: $claudeEnabled)
            .toggleStyle(.switch)
            .controlSize(.small)
          Toggle("Gemini", isOn: $geminiEnabled)
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
  }

  @ViewBuilder private var metadataTab: some View {
    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
      GridRow {
        Text("Argument Hint").font(.subheadline).fontWeight(.medium)
        TextField("[file-path]", text: $argumentHint)
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
      GridRow {
        Text("Model").font(.subheadline).fontWeight(.medium)
        TextField("claude-opus-4-5", text: $model)
          .help("Claude Code only")
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
      GridRow {
        Text("Allowed Tools").font(.subheadline).fontWeight(.medium)
        TextField("Read, Grep", text: $allowedTools)
          .help("Comma-separated list (Claude Code only)")
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
      GridRow {
        Text("Tags").font(.subheadline).fontWeight(.medium)
        TextField("tag1, tag2", text: $tags)
          .help("Comma-separated list")
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
  }

  private func saveCommand() {
    let finalId = command?.id ?? name.lowercased().replacingOccurrences(of: " ", with: "-")
    let metadata = CommandMetadata(
      argumentHint: argumentHint.isEmpty ? nil : argumentHint,
      model: model.isEmpty ? nil : model,
      allowedTools: allowedTools.isEmpty ? nil : allowedTools.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
      tags: tags.isEmpty ? [] : tags.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) }
    )
    let targets = CommandTargets(codex: codexEnabled, claude: claudeEnabled, gemini: geminiEnabled)

    let record = CommandRecord(
      id: finalId,
      name: name,
      description: description,
      prompt: prompt,
      metadata: metadata,
      targets: targets,
      isEnabled: command?.isEnabled ?? true,
      source: command?.source ?? "user",
      installedAt: command?.installedAt ?? Date()
    )

    onSave(record)
  }
}

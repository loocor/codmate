import SwiftUI

struct HooksSettingsView: View {
  @ObservedObject var preferences: SessionPreferencesStore
  @StateObject private var vm = HooksViewModel()
  @State private var searchFocused = false
  @State private var pendingAction: PendingHookAction?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      headerRow
      contentRow
    }
    .sheet(isPresented: $vm.showAddSheet) {
      HookEditSheet(
        preferences: preferences,
        rule: nil,
        onSave: { rule in
          Task {
            await vm.addRule(rule)
            vm.showAddSheet = false
          }
        },
        onCancel: { vm.showAddSheet = false }
      )
      .frame(minWidth: 760, minHeight: 520)
    }
    .sheet(isPresented: $vm.showImportSheet) {
      HooksImportSheet(
        candidates: $vm.importCandidates,
        isImporting: vm.isImporting,
        statusMessage: vm.importStatusMessage,
        title: "Import Hooks",
        subtitle: "Scan Home for existing Codex/Claude/Gemini hooks and import into CodMate.",
        onCancel: { vm.cancelImport() },
        onImport: { Task { await vm.importSelectedHooks() } }
      )
      .frame(minWidth: 760, minHeight: 480)
    }
    .sheet(item: $vm.editingRule) { rule in
      HookEditSheet(
        preferences: preferences,
        rule: rule,
        onSave: { updated in
          Task {
            await vm.updateRule(updated)
            vm.editingRule = nil
          }
        },
        onCancel: { vm.editingRule = nil }
      )
      .frame(minWidth: 760, minHeight: 520)
    }
    .alert(item: $pendingAction) { action in
      Alert(
        title: Text("Delete Hook?"),
        message: Text("Remove \"\(action.rule.name)\" from the hooks list?"),
        primaryButton: .destructive(Text("Delete")) {
          Task {
            await vm.deleteRule(id: action.rule.id)
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
        placeholder: "Search hooks",
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
      Button {
        vm.beginImportFromHome()
      } label: {
        Label("Import", systemImage: "tray.and.arrow.down")
      }
    }
  }

  private var contentRow: some View {
    HStack(alignment: .top, spacing: 12) {
      hooksList
        .frame(minWidth: 260, maxWidth: 320)
      detailPanel
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var hooksList: some View {
    Group {
      if vm.isLoading {
        VStack(spacing: 8) {
          ProgressView()
          Text("Loading hooks…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if vm.filteredRules.isEmpty {
        VStack(spacing: 10) {
          Image(systemName: "link")
            .font(.system(size: 32))
            .foregroundStyle(.secondary)
          Text("No Hooks")
            .font(.title3)
            .fontWeight(.medium)
          Text("Add a hook to get started.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(selection: $vm.selectedRuleId) {
          ForEach(vm.filteredRules) { rule in
            HookRuleRow(
              preferences: preferences,
              rule: rule,
              isSelected: vm.selectedRuleId == rule.id,
              onSelect: { vm.selectedRuleId = rule.id },
              onEdit: { vm.editingRule = rule },
              onDelete: { confirmDelete(rule) },
              onToggleEnabled: { value in vm.updateRuleEnabled(id: rule.id, value: value) },
              onToggleTarget: { target, value in vm.updateRuleTarget(id: rule.id, target: target, value: value) }
            )
            .tag(rule.id as String?)
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
      if let rule = vm.selectedRule {
        HookDetailPane(
          rule: rule,
          warnings: vm.syncWarnings.filter { $0.provider == .codex && rule.isEnabled(for: .codex) }
            + vm.syncWarnings.filter { $0.provider == .claude && rule.isEnabled(for: .claude) }
            + vm.syncWarnings.filter { $0.provider == .gemini && rule.isEnabled(for: .gemini) },
          onSync: { Task { await vm.applyToProviders() } },
          onEdit: { vm.editingRule = rule },
          onDelete: { confirmDelete(rule) }
        )
        .id(rule.id)
      } else {
        VStack(spacing: 12) {
          Image(systemName: "link")
            .font(.system(size: 32))
            .foregroundStyle(.secondary)
          Text("Select a hook to view details")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }

      if !vm.syncWarnings.isEmpty {
        Divider()
        VStack(alignment: .leading, spacing: 6) {
          Label("Apply warnings", systemImage: "exclamationmark.triangle")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.orange)
          ForEach(vm.syncWarnings) { warning in
            Text("\(warning.provider.displayName): \(warning.message)")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }

      if let msg = vm.errorMessage, !msg.isEmpty {
        Divider()
        Text(msg)
          .font(.caption)
          .foregroundStyle(.secondary)
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

  private func confirmDelete(_ rule: HookRule) {
    pendingAction = PendingHookAction(rule: rule)
  }
}

private struct PendingHookAction: Identifiable {
  let id = UUID()
  let rule: HookRule
}

private struct HookRuleRow: View {
  @ObservedObject var preferences: SessionPreferencesStore
  let rule: HookRule
  let isSelected: Bool
  var onSelect: () -> Void
  var onEdit: () -> Void
  var onDelete: () -> Void
  var onToggleEnabled: (Bool) -> Void
  var onToggleTarget: (HookTarget, Bool) -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 8) {
      Toggle(
        "",
        isOn: Binding(
          get: { rule.enabled },
          set: { value in onToggleEnabled(value) }
        )
      )
      .labelsHidden()
      .controlSize(.small)

      VStack(alignment: .leading, spacing: 4) {
        Text(rule.name.isEmpty ? rule.event : rule.name)
          .font(.body.weight(.medium))
          .lineLimit(1)
        Text(ruleSummary(rule))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      Spacer(minLength: 8)
      HStack(spacing: 6) {
        ForEach(HookTarget.allCases, id: \.self) { target in
          MCPServerTargetToggle(
            provider: target.usageProvider,
            isOn: Binding(
              get: { rule.targets?.isEnabled(for: target) ?? true },
              set: { value in onToggleTarget(target, value) }
            ),
            disabled: !preferences.isCLIEnabled(target.baseKind)
          )
        }
      }
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
    .onTapGesture { onSelect() }
    .contextMenu {
      Button("Edit") { onEdit() }
      Button("Delete", role: .destructive) { onDelete() }
    }
  }

  private func ruleSummary(_ rule: HookRule) -> String {
    let event = rule.event.isEmpty ? "Event" : rule.event
    if let matcher = rule.matcher, !matcher.isEmpty {
      return "\(event) · \(matcher) · \(rule.commands.count) command(s)"
    }
    return "\(event) · \(rule.commands.count) command(s)"
  }
}

private struct HookDetailPane: View {
  let rule: HookRule
  let warnings: [HookSyncWarning]
  var onSync: () -> Void
  var onEdit: () -> Void
  var onDelete: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          commandsSection
          if !warnings.isEmpty {
            providerWarningsSection
          }
        }
      }
    }
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(rule.name.isEmpty ? rule.event : rule.name)
          .font(.title3.weight(.semibold))
        Text(descriptionText.isEmpty ? "No description provided" : descriptionText)
          .font(.subheadline)
          .foregroundStyle(descriptionText.isEmpty ? .tertiary : .secondary)
          .lineLimit(3)
          .help(descriptionText.isEmpty ? "No description provided" : descriptionText)
        Text(detailSubtitle)
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
        .help("Apply hooks to AI CLI providers")

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

  private var commandsSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Commands")
        .font(.headline)
      ForEach(Array(rule.commands.enumerated()), id: \.offset) { (_, cmd) in
        VStack(alignment: .leading, spacing: 2) {
          Text(cmd.command)
            .font(.caption)
            .textSelection(.enabled)
          if let args = cmd.args, !args.isEmpty {
            Text("Args: \(args.joined(separator: " "))")
              .font(.caption2)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
          if let timeout = cmd.timeoutMs {
            Text("Timeout: \(timeout)ms")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
        .padding(.vertical, 4)
      }
    }
  }

  private var providerWarningsSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Divider()
      Label("Provider warnings", systemImage: "exclamationmark.triangle")
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.orange)
      ForEach(warnings) { w in
        Text("\(w.provider.displayName): \(w.message)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var detailSubtitle: String {
    if let matcher = rule.matcher, !matcher.isEmpty {
      return "\(rule.event) · matcher: \(matcher)"
    }
    return rule.event
  }

  private var descriptionText: String {
    rule.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }
}

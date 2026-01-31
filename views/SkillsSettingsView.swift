import SwiftUI
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

struct SkillsSettingsView: View {
  @ObservedObject var preferences: SessionPreferencesStore
  @StateObject private var vm = SkillsLibraryViewModel()
  @State private var searchFocused = false
  @State private var pendingAction: PendingSkillAction?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      headerRow
      contentRow
    }
    .onDrop(of: [UTType.fileURL, UTType.url, UTType.plainText], isTargeted: nil) { providers in
      vm.handleDrop(providers)
    }
    .sheet(isPresented: $vm.showInstallSheet) {
      SkillsInstallSheet(vm: vm)
        .frame(minWidth: 520, minHeight: 340)
    }
    .sheet(isPresented: $vm.showCreateSheet) {
      SkillCreateSheet(preferences: preferences, vm: vm, startInWizard: vm.createStartsWithWizard)
        .frame(minWidth: 760, minHeight: 520, maxHeight: 720)
    }
    .sheet(isPresented: $vm.showImportSheet) {
      SkillsImportSheet(
        candidates: $vm.importCandidates,
        isImporting: vm.isImporting,
        statusMessage: vm.importStatusMessage,
        title: "Import Skills",
        subtitle: "Scan Home for existing Codex/Claude/Gemini skills and import into CodMate.",
        onCancel: { vm.cancelImport() },
        onImport: { Task { await vm.importSelectedSkills() } }
      )
      .frame(minWidth: 760, minHeight: 480)
    }
    .sheet(item: $vm.installConflict) { conflict in
      SkillConflictResolutionSheet(conflict: conflict, onResolve: { resolution in
        vm.resolveInstallConflict(resolution)
        vm.installConflict = nil
      }, onCancel: {
        vm.installConflict = nil
      })
      .frame(minWidth: 420, minHeight: 240)
    }
    .alert(item: $pendingAction) { action in
      Alert(
        title: Text("Move to Trash?"),
        message: Text("Move \(action.skill.displayName) to Trash?"),
        primaryButton: .destructive(Text("Move to Trash"), action: { vm.uninstall(id: action.skill.id) }),
        secondaryButton: .cancel()
      )
    }
    .task { await vm.load() }
  }

  private var headerRow: some View {
    HStack(spacing: 8) {
      Spacer(minLength: 0)
      ToolbarSearchField(
        placeholder: "Search skills",
        text: $vm.searchText,
        onFocusChange: { focused in searchFocused = focused },
        onSubmit: {}
      )
      .frame(width: 240)

      Button {
        vm.prepareInstall(mode: vm.installMode)
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
      skillsList
        .frame(minWidth: 260, maxWidth: 320)
      detailPanel
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var skillsList: some View {
    Group {
      if vm.isLoading {
        VStack(spacing: 8) {
          ProgressView()
          Text("Loading skills…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if vm.filteredSkills.isEmpty {
        VStack(spacing: 10) {
          Image(systemName: "sparkles")
            .font(.system(size: 32))
            .foregroundStyle(.secondary)
          Text("No Skills")
            .font(.title3)
            .fontWeight(.medium)
          Text("Install skills from folder, zip, or URL to get started.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(selection: $vm.selectedSkillId) {
          ForEach(vm.filteredSkills) { skill in
            HStack(alignment: .center, spacing: 8) {
              Toggle(
                "",
                isOn: Binding(
                  get: { skill.isSelected },
                  set: { value in
                    vm.updateSkillSelection(id: skill.id, value: value)
                  }
                )
              )
              .labelsHidden()
              .controlSize(.small)

              VStack(alignment: .leading, spacing: 4) {
                Text(skill.displayName)
                  .font(.body.weight(.medium))
                Text(skill.summary)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(2)
                if !skill.tags.isEmpty {
                  Text(skill.tags.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
              }
              Spacer(minLength: 8)
              HStack(spacing: 6) {
                MCPServerTargetToggle(
                  provider: .codex,
                  isOn: Binding(
                    get: { skill.targets.codex },
                    set: { value in
                      vm.updateSkillTarget(id: skill.id, target: .codex, value: value)
                    }
                  ),
                  disabled: !preferences.isCLIEnabled(.codex)
                )
                MCPServerTargetToggle(
                  provider: .claude,
                  isOn: Binding(
                    get: { skill.targets.claude },
                    set: { value in
                      vm.updateSkillTarget(id: skill.id, target: .claude, value: value)
                    }
                  ),
                  disabled: !preferences.isCLIEnabled(.claude)
                )
                MCPServerTargetToggle(
                  provider: .gemini,
                  isOn: Binding(
                    get: { skill.targets.gemini },
                    set: { value in
                      vm.updateSkillTarget(id: skill.id, target: .gemini, value: value)
                    }
                  ),
                  disabled: !preferences.isCLIEnabled(.gemini)
                )
              }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture { vm.selectedSkillId = skill.id }
            .tag(skill.id as String?)
            .contextMenu {
#if canImport(AppKit)

              let editors = EditorApp.installedEditors
              openInEditorMenu(editors: editors) { editor in
                vm.openInEditor(skill, using: editor)
              }
#endif
              Button("Reveal in Finder") { revealInFinder(skill) }
              Button("Move to Trash", role: .destructive) { confirmUninstall(skill) }
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
      if let skill = vm.selectedSkill {
        SkillPackageExplorerView(
          skill: skill,
          onReveal: { revealInFinder(skill) },
          onUninstall: { confirmUninstall(skill) }
        )
        .id(skill.id)
      } else {
        VStack(spacing: 12) {
          Image(systemName: "doc.text")
            .font(.system(size: 32))
            .foregroundStyle(.secondary)
          Text("Select a skill to view details")
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

  private func revealInFinder(_ skill: SkillSummary) {
    guard let path = skill.path, !path.isEmpty else { return }
    let url = URL(fileURLWithPath: path, isDirectory: true)
#if canImport(AppKit)
    NSWorkspace.shared.activateFileViewerSelecting([url])
#endif
  }

  private func confirmUninstall(_ skill: SkillSummary) {
    pendingAction = PendingSkillAction(skill: skill)
  }
}

private struct PendingSkillAction: Identifiable {
  let id = UUID()
  let skill: SkillSummary
}

private struct SkillsInstallSheet: View {
  @ObservedObject var vm: SkillsLibraryViewModel
  @State private var importerPresented = false
  @State private var isDropTargeted = false
  @FocusState private var urlFieldFocused: Bool
  private let rowWidth: CGFloat = 420
  private let fieldWidth: CGFloat = 320

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .firstTextBaseline) {
        Text("Install Skill")
          .font(.title3)
          .fontWeight(.semibold)
        Spacer()
        Button {
          vm.cancelInstall()
          vm.prepareCreateSkill(startWithWizard: true)
        } label: {
          Image(systemName: "sparkles")
        }
        .buttonStyle(.borderless)
        .help("AI Wizard")
      }

      dropArea

      HStack {
        Spacer(minLength: 0)
        Picker("", selection: $vm.installMode) {
          ForEach(SkillInstallMode.allCases, id: \.self) { mode in
            Text(mode.title).tag(mode)
          }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 240)
        Spacer(minLength: 0)
      }

      Group {
        switch vm.installMode {
        case .folder:
          sourceRow(value: vm.pendingInstallURL?.path ?? "Choose a folder…") {
            importerPresented = true
          }
        case .zip:
          sourceRow(value: vm.pendingInstallURL?.path ?? "Choose a zip file…") {
            importerPresented = true
          }
        case .url:
          HStack {
            Spacer(minLength: 0)
            TextField("https://example.com/skill.zip", text: $vm.pendingInstallText)
              .focused($urlFieldFocused)
              .textFieldStyle(.roundedBorder)
              .frame(width: rowWidth)
            Spacer(minLength: 0)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Spacer(minLength: 0)

      VStack(alignment: .leading, spacing: 6) {
        if let status = vm.installStatusMessage, !status.isEmpty {
          Text(status)
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Text(" ")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .frame(height: 64)

      HStack {
        Spacer()
        Button("Cancel") { vm.cancelInstall() }
        Button("Install") { vm.finishInstall() }
          .buttonStyle(.borderedProminent)
          .disabled(!canInstall)
      }
    }
    .padding(16)
    .onAppear {
      urlFieldFocused = false
    }
    .onChange(of: vm.installMode) { _ in
      urlFieldFocused = false
    }
    .onDrop(of: [UTType.fileURL, UTType.url, UTType.plainText], isTargeted: $isDropTargeted) {
      providers in
      handleDrop(providers)
    }
    .fileImporter(
      isPresented: $importerPresented,
      allowedContentTypes: allowedTypes,
      allowsMultipleSelection: false
    ) { result in
      if case .success(let urls) = result {
        vm.pendingInstallURL = urls.first
      }
    }
  }

  private var dropArea: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(
          isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
          style: StrokeStyle(lineWidth: 1, dash: [6, 4])
        )
        .frame(height: 120)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isDropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        )
      VStack(spacing: 6) {
        Image(systemName: "tray.and.arrow.down")
          .font(.system(size: 28))
          .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary)
        Text("Drop a skill folder, zip file, or URL")
          .font(.subheadline)
          .foregroundStyle(.secondary)
        if let url = vm.pendingInstallURL {
          Text(url.path)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        } else if !vm.pendingInstallText.isEmpty {
          Text(vm.pendingInstallText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      .padding(.horizontal, 16)
    }
  }

  private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
    for provider in providers {
      if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
          guard let data = item as? Data,
            let url = URL(dataRepresentation: data, relativeTo: nil)
          else { return }
          Task { @MainActor in
            applyFileURL(url)
          }
        }
        return true
      }
      if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
        provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
          if let url = item as? URL {
            Task { @MainActor in
              vm.installMode = .url
              vm.pendingInstallText = url.absoluteString
            }
          }
        }
        return true
      }
      if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
        provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
          let text: String?
          if let data = item as? Data {
            text = String(data: data, encoding: .utf8)
          } else {
            text = item as? String
          }
          guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
          else { return }
          Task { @MainActor in
            vm.installMode = .url
            vm.pendingInstallText = text
          }
        }
        return true
      }
    }
    return false
  }

  private func applyFileURL(_ url: URL) {
    let isZip = url.pathExtension.lowercased() == "zip"
    let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    if isDirectory {
      vm.installMode = .folder
      vm.pendingInstallURL = url
    } else if isZip {
      vm.installMode = .zip
      vm.pendingInstallURL = url
    } else {
      vm.installMode = .zip
      vm.pendingInstallURL = url
    }
  }

  private var canInstall: Bool {
    switch vm.installMode {
    case .folder, .zip:
      return vm.pendingInstallURL != nil
    case .url:
      return !vm.pendingInstallText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  private var allowedTypes: [UTType] {
    switch vm.installMode {
    case .folder:
      return [.folder]
    case .zip:
      return [.zip]
    case .url:
      return [.data]
    }
  }

  private func sourceRow(value: String, action: @escaping () -> Void) -> some View {
    HStack(spacing: 8) {
      Spacer(minLength: 0)
      HStack(spacing: 8) {
        Text(value)
          .font(.body)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .frame(width: fieldWidth, alignment: .leading)
          .padding(.horizontal, 8)
          .padding(.vertical, 6)
          .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .fill(Color(nsColor: .textBackgroundColor))
              .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                  .stroke(Color.secondary.opacity(0.2))
              )
          )
        Button("Choose…") { action() }
      }
      .frame(width: rowWidth, alignment: .center)
      Spacer(minLength: 0)
    }
  }
}

private struct SkillConflictResolutionSheet: View {
  let conflict: SkillInstallConflict
  var onResolve: (SkillConflictResolution) -> Void
  var onCancel: () -> Void

  @State private var selection: Int = 0
  @State private var renameText: String

  init(conflict: SkillInstallConflict, onResolve: @escaping (SkillConflictResolution) -> Void, onCancel: @escaping () -> Void) {
    self.conflict = conflict
    self.onResolve = onResolve
    self.onCancel = onCancel
    _renameText = State(initialValue: conflict.suggestedId)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Skill Already Exists")
        .font(.title3)
        .fontWeight(.semibold)
      Text("A skill named \"\(conflict.proposedId)\" already exists at this location.")
        .font(.subheadline)
        .foregroundStyle(.secondary)

      Picker("", selection: $selection) {
        Text("Overwrite").tag(0)
        Text("Skip").tag(1)
        Text("Rename").tag(2)
      }
      .labelsHidden()
      .pickerStyle(.segmented)

      if selection == 2 {
        TextField("New name", text: $renameText)
          .textFieldStyle(.roundedBorder)
      }

      Spacer()

      HStack {
        Button("Cancel") { onCancel() }
        Spacer()
        Button("Continue") {
          switch selection {
          case 0: onResolve(.overwrite)
          case 1: onResolve(.skip)
          default:
            let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalName = trimmed.isEmpty ? conflict.suggestedId : trimmed
            onResolve(.rename(finalName))
          }
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .padding(16)
  }
}

private struct SkillCreateSheet: View {
  @ObservedObject var preferences: SessionPreferencesStore
  @ObservedObject var vm: SkillsLibraryViewModel
  private let startInWizard: Bool
  @State private var wizardActive: Bool

  init(
    preferences: SessionPreferencesStore,
    vm: SkillsLibraryViewModel,
    startInWizard: Bool = false
  ) {
    self.preferences = preferences
    self.vm = vm
    self.startInWizard = startInWizard
    _wizardActive = State(initialValue: startInWizard)
  }

  var body: some View {
    if wizardActive {
      SkillWizardSheet(preferences: preferences, onApply: { draft in
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
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .firstTextBaseline) {
        Text("Create Skill")
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
      if vm.pendingWizardDraft == nil {
        Text("Run the AI wizard to generate a draft, then review before creating.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("Skill Name")
          .font(.subheadline)
          .fontWeight(.medium)
        TextField("e.g., data-analysis or custom-formatter", text: $vm.newSkillName)
          .textFieldStyle(.roundedBorder)
        Text("Name will be converted to lowercase with hyphens (kebab-case)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("Description")
          .font(.subheadline)
          .fontWeight(.medium)
        TextField("Describe what this skill does and when to use it", text: $vm.newSkillDescription)
          .textFieldStyle(.roundedBorder)
      }
      if let preview = vm.wizardPreviewSkill {
        SkillPackageExplorerView(
          skill: preview,
          onReveal: {},
          onUninstall: {},
          showsHeader: false,
          showsActions: false
        )
        .id(preview.id)
        .frame(minHeight: 220, maxHeight: 320)
      }

      if let error = vm.createErrorMessage {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
      }

      Spacer(minLength: 0)

      HStack {
        Button("Cancel") { vm.cancelCreateSkill() }
        Spacer()
        Button("Create") { vm.createSkill() }
          .buttonStyle(.borderedProminent)
          .disabled(
            vm.pendingWizardDraft == nil
              || vm.newSkillName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          )
      }
    }
    .padding(16)
    .frame(minWidth: 480, minHeight: 280)
    .onChange(of: vm.newSkillName) { _ in
      if vm.pendingWizardDraft != nil {
        vm.refreshWizardPreview()
      }
    }
    .onChange(of: vm.newSkillDescription) { _ in
      if vm.pendingWizardDraft != nil {
        vm.refreshWizardPreview()
      }
    }
  }

  private func applyDraft(_ draft: SkillWizardDraft) {
    vm.applyWizardDraft(draft)
  }
}

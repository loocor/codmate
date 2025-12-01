import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ProjectsListView: View {
  @EnvironmentObject private var viewModel: SessionListViewModel
  @State private var editingProject: Project? = nil
  @State private var showEdit = false
  @State private var showNewProject = false
  @State private var newParentProject: Project? = nil
  @State private var pendingDelete: Project? = nil
  @State private var showDeleteConfirm = false
  @State private var draftTaskForNew: CodMateTask? = nil

  var body: some View {
    let countsDisplay = viewModel.projectCountsDisplay()
    let tree = buildProjectTree(viewModel.projects)
    let selectionBinding: Binding<Set<String>> = Binding(
      get: { viewModel.selectedProjectIDs },
      set: { viewModel.setSelectedProjects($0) }
    )

    let expandedBinding = Binding(
      get: { viewModel.expandedProjectIDs },
      set: { viewModel.expandedProjectIDs = $0 }
    )

    return List(selection: selectionBinding) {
      if tree.isEmpty {
        ContentUnavailableView("No Projects", systemImage: "square.grid.2x2")
      } else {
        ForEach(tree) { node in
          ProjectTreeNodeView(
            node: node,
            countsDisplay: countsDisplay,
            displayName: displayName(_:),
            expanded: expandedBinding,
            onTap: { handleSelection(for: $0) },
            onDoubleTap: {
              editingProject = $0
              showEdit = true
            },
            onNewSession: { viewModel.newSession(project: $0) },
            onNewSubproject: { parent in
              newParentProject = parent
              showNewProject = true
            },
            onNewTask: { project in
              guard project.id != SessionListViewModel.otherProjectId else { return }
              draftTaskForNew = CodMateTask(
                title: "",
                description: nil,
                projectId: project.id
              )
            },
            onEdit: {
              editingProject = $0
              showEdit = true
            },
            onDelete: { project in
              pendingDelete = project
              showDeleteConfirm = true
            },
            onReveal: { viewModel.revealProjectDirectory($0) },
            onOpenInEditor: { project, editor in
              viewModel.openProjectInEditor(project, using: editor)
            },
            onAssignSessions: { projectId, ids in
              Task { await viewModel.assignSessions(to: projectId, ids: ids) }
            },
            onChangeParent: { projectId, newParentId in
              Task {
                await viewModel.changeProjectParent(projectId: projectId, newParentId: newParentId)
              }
            }
          )
        }
        // Synthetic "Other" bucket for unassigned sessions
        let otherId = SessionListViewModel.otherProjectId
        let otherProject = Project(
          id: otherId, name: "Other", directory: nil, trustLevel: nil, overview: nil,
          instructions: nil, profileId: nil, profile: nil, parentId: nil,
          sources: ProjectSessionSource.allSet)
        ProjectRow(
          project: otherProject,
          displayName: "Other",
          visible: countsDisplay[otherId]?.visible ?? 0,
          total: countsDisplay[otherId]?.total ?? 0,
          onNewSession: {},
          onEdit: {},
          onDelete: {}
        )
        .listRowInsets(EdgeInsets())
        .contentShape(Rectangle())
        .onTapGesture { handleSelection(for: otherProject) }
        .tag(otherId)
      }
    }
    .listStyle(.sidebar)
    .padding(.horizontal, -10)
    .environment(\.defaultMinListRowHeight, 16)
    .environment(\.controlSize, .small)
    .dropDestination(for: String.self) { items, _ in
      // Handle drop on list background (outside any project row)
      // This removes the parent from the dragged project (moves to top level)
      let all = items.flatMap { $0.split(separator: "\n").map(String.init) }
      let projectDrags = all.filter { $0.hasPrefix("project:") }
      if let firstProjectDrag = projectDrags.first {
        let draggedProjectId = String(firstProjectDrag.dropFirst("project:".count))

        // Don't allow dragging Other project
        guard draggedProjectId != SessionListViewModel.otherProjectId else { return false }

        Task {
          await viewModel.changeProjectParent(projectId: draggedProjectId, newParentId: nil)
        }
        return true
      }
      return false
    }
    .onAppear {
      if viewModel.expandedProjectIDs.isEmpty {
        viewModel.expandedProjectIDs = Set(tree.map(\.id))
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .codMateExpandProjectTree)) { note in
      if let ids = note.userInfo?["ids"] as? [String] {
        var merged = viewModel.expandedProjectIDs
        merged.formUnion(ids)
        viewModel.expandedProjectIDs = merged
      }
    }
    .sheet(isPresented: $showEdit) {
      if let project = editingProject {
        ProjectEditorSheet(isPresented: $showEdit, mode: .edit(existing: project))
          .environmentObject(viewModel)
      }
    }
    .sheet(isPresented: $showNewProject, onDismiss: { newParentProject = nil }) {
      ProjectEditorSheet(
        isPresented: $showNewProject,
        mode: .new,
        prefill: ProjectEditorSheet.Prefill(
          name: newParentProject == nil ? nil : "New Subproject",
          directory: newParentProject?.directory,
          trustLevel: nil,
          overview: nil,
          instructions: nil,
          profileId: nil,
          parentId: newParentProject?.id
        )
      )
      .environmentObject(viewModel)
    }
    .sheet(item: $draftTaskForNew) { task in
      EditTaskSheet(
        task: task,
        mode: .new,
        onSave: { updatedTask in
          Task {
            if let workspaceVM = viewModel.workspaceVM {
              await workspaceVM.updateTask(updatedTask)
            }
            draftTaskForNew = nil
          }
        },
        onCancel: {
          draftTaskForNew = nil
        }
      )
    }
    .confirmationDialog(
      "Delete project?",
      isPresented: $showDeleteConfirm,
      titleVisibility: .visible,
      presenting: pendingDelete
    ) { prj in
      let hasChildren = viewModel.projects.contains { $0.parentId == prj.id }
      if hasChildren {
        Button("Delete Project and Subprojects", role: .destructive) {
          Task { await viewModel.deleteProjectCascade(id: prj.id) }
          pendingDelete = nil
        }
        Button("Move Subprojects to Top Level") {
          Task { await viewModel.deleteProjectMoveChildrenUp(id: prj.id) }
          pendingDelete = nil
        }
        Button("Cancel", role: .cancel) { pendingDelete = nil }
      } else {
        Button("Delete", role: .destructive) {
          Task { await viewModel.deleteProject(id: prj.id) }
          pendingDelete = nil
        }
        Button("Cancel", role: .cancel) { pendingDelete = nil }
      }
    } message: { prj in
      Text(
        "Sessions remain intact. This only removes the project record. This action cannot be undone."
      )
    }
  }

  private func handleSelection(for project: Project) {
    #if os(macOS)
      let commandDown = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
    #else
      let commandDown = false
    #endif
    if commandDown {
      viewModel.toggleProjectSelection(project.id)
    } else {
      viewModel.setSelectedProject(project.id)
    }
  }

  private func displayName(_ p: Project) -> String {
    if !p.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return p.name }
    if let dir = p.directory, !dir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let base = URL(fileURLWithPath: dir, isDirectory: true).lastPathComponent
      return base.isEmpty ? p.id : base
    }
    return p.id
  }
}

extension View {
  @ViewBuilder
  fileprivate func applyAlternatingRows() -> some View {
    if #available(macOS 14.0, *) {
      self.alternatingRowBackgrounds(.enabled)
    } else {
      self
    }
  }
}

private func stripeBackground(for id: String) -> Color {
  // Make one stripe transparent and the other a subtle separator tint
  let isOdd = (id.hashValue & 1) != 0
  if isOdd {
    return Color(nsColor: .separatorColor).opacity(0.08)
  } else {
    return .clear
  }
}

private struct ProjectRow: View {
  let project: Project
  let displayName: String
  let visible: Int
  let total: Int
  var onNewSession: () -> Void
  var onEdit: () -> Void
  var onDelete: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      let iconName =
        (project.id == SessionListViewModel.otherProjectId) ? "ellipsis" : "square.grid.2x2"
      Image(systemName: iconName)
        .foregroundStyle(.secondary)
        .font(.caption)
      Text(displayName)
        .font(.caption)
        .lineLimit(1)
      Spacer(minLength: 4)
      let showCount = (visible > 0) || (total > 0)
      if showCount {
        Text("\(visible)/\(total)")
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.tertiary)
      }
    }
    .frame(height: 16)
    .padding(.vertical, 8)
    .padding(.trailing, 8)
    // Thin top hairline to separate items, matching sessions list aesthetic
    .overlay(alignment: .top) {
      Rectangle()
        .fill(Color(nsColor: .separatorColor).opacity(0.18))
        .frame(height: 1)
    }
  }
}

private struct ProjectTreeNodeView: View {
  let node: ProjectTreeNode
  let countsDisplay: [String: (visible: Int, total: Int)]
  let displayName: (Project) -> String
  @Binding var expanded: Set<String>
  let onTap: (Project) -> Void
  let onDoubleTap: (Project) -> Void
  let onNewSession: (Project) -> Void
  let onNewSubproject: (Project) -> Void
  let onNewTask: (Project) -> Void
  let onEdit: (Project) -> Void
  let onDelete: (Project) -> Void
  let onReveal: (Project) -> Void
  let onOpenInEditor: (Project, EditorApp) -> Void
  let onAssignSessions: (String, [String]) -> Void
  let onChangeParent: (String, String?) -> Void

  var body: some View {
    Group {
      if let children = node.children, !children.isEmpty {
        DisclosureGroup(isExpanded: binding(for: node.project.id)) {
          ForEach(children) { child in
            ProjectTreeNodeView(
              node: child,
              countsDisplay: countsDisplay,
              displayName: displayName,
              expanded: $expanded,
              onTap: onTap,
              onDoubleTap: onDoubleTap,
              onNewSession: onNewSession,
              onNewSubproject: onNewSubproject,
              onNewTask: onNewTask,
              onEdit: onEdit,
              onDelete: onDelete,
              onReveal: onReveal,
              onOpenInEditor: onOpenInEditor,
              onAssignSessions: onAssignSessions,
              onChangeParent: onChangeParent
            )
          }
        } label: {
          row(for: node.project)
        }
        .tag(node.project.id)
      } else {
        row(for: node.project)
          .tag(node.project.id)
      }
    }
  }

  private func binding(for id: String) -> Binding<Bool> {
    Binding(
      get: { expanded.contains(id) },
      set: { value in
        if value {
          expanded.insert(id)
        } else {
          expanded.remove(id)
        }
      }
    )
  }

  private func row(for project: Project) -> some View {
    let pair = countsDisplay[project.id] ?? (visible: 0, total: 0)
    let isOtherProject = project.id == SessionListViewModel.otherProjectId

    return ProjectRow(
      project: project,
      displayName: displayName(project),
      visible: pair.visible,
      total: pair.total,
      onNewSession: { onNewSession(project) },
      onEdit: { onEdit(project) },
      onDelete: { onDelete(project) }
    )
    .listRowInsets(EdgeInsets())
    .contentShape(Rectangle())
    .onDrag {
      // Only allow dragging real projects (not Other)
      guard !isOtherProject else {
        return NSItemProvider()
      }
      return NSItemProvider(object: "project:\(project.id)" as NSString)
    }
    .onTapGesture { onTap(project) }
    .onTapGesture(count: 2) { onDoubleTap(project) }
    .contextMenu { contextMenu(for: project) }
    // Drop destination for sessions and projects
    .dropDestination(for: String.self) { items, _ in
      // Don't allow dropping onto Other project
      guard !isOtherProject else { return false }

      let all = items.flatMap { $0.split(separator: "\n").map(String.init) }
      // Check if any item is a project drag (starts with "project:")
      let projectDrags = all.filter { $0.hasPrefix("project:") }
      if let firstProjectDrag = projectDrags.first {
        let draggedProjectId = String(firstProjectDrag.dropFirst("project:".count))

        // Prevent dropping onto self
        guard draggedProjectId != project.id else { return false }

        // Set this project as the parent of the dragged project
        onChangeParent(draggedProjectId, project.id)
        return true
      }
      // Otherwise, treat as session assignment
      let sessionIds = all.filter { !$0.hasPrefix("project:") }
      if !sessionIds.isEmpty {
        onAssignSessions(project.id, sessionIds)
        return true
      }
      return false
    }
  }

  @ViewBuilder
  private func contextMenu(for project: Project) -> some View {
    Button {
      onNewSession(project)
    } label: {
      Label("New Session", systemImage: "plus")
    }
    Button {
      onNewTask(project)
    } label: {
      Label("New Task…", systemImage: "checklist")
    }
    Button {
      onNewSubproject(project)
    } label: {
      Label("New Subproject…", systemImage: "plus.square.on.square")
    }
    Divider()
    let editors = EditorApp.installedEditors
    if !editors.isEmpty {
      Menu {
        ForEach(editors) { editor in
          Button {
            onOpenInEditor(project, editor)
          } label: {
            Label(editor.title, systemImage: "chevron.left.forwardslash.chevron.right")
          }
        }
      } label: {
        Label("Open in", systemImage: "arrow.up.forward.app")
      }
      .disabled(project.directory == nil || project.directory?.isEmpty == true)
    }

    Button {
      onReveal(project)
    } label: {
      Label("Reveal in Finder", systemImage: "finder")
    }
    .disabled(project.directory == nil || project.directory?.isEmpty == true)

    Button {
      onEdit(project)
    } label: {
      Label("Edit Project / Property", systemImage: "pencil")
    }
    Divider()
    Button(role: .destructive) {
      onDelete(project)
    } label: {
      Label("Delete Project", systemImage: "trash")
    }
  }
}

struct ProjectEditorSheet: View {
  enum Mode {
    case new
    case edit(existing: Project)
  }
  @EnvironmentObject private var viewModel: SessionListViewModel
  @Binding var isPresented: Bool
  let mode: Mode
  struct Prefill: Sendable {
    var name: String?
    var directory: String?
    var trustLevel: String?
    var overview: String?
    var instructions: String?
    var profileId: String?
    var parentId: String?
  }
  var prefill: Prefill? = nil
  var autoAssignSessionIDs: [String]? = nil
  @State private var showCloseConfirm = false
  @State private var original: Snapshot? = nil

  @State private var name: String = ""
  @State private var directory: String = ""
  @State private var trustLevel: String = ""
  @State private var overview: String = ""
  @State private var instructions: String = ""
  @State private var profileId: String = ""
  @State private var profileModel: String? = nil
  @State private var profileSandbox: SandboxMode? = nil
  @State private var profileApproval: ApprovalPolicy? = nil
  @State private var profileFullAuto: Bool? = nil
  @State private var profileDangerBypass: Bool? = nil
  @State private var profilePathPrependText: String = ""
  @State private var profileEnvText: String = ""
  @State private var parentProjectId: String? = nil
  @State private var sources: Set<ProjectSessionSource> = ProjectSessionSource.allSet

  private struct Snapshot: Equatable {
    var name: String
    var directory: String
    var trustLevel: String
    var overview: String
    var instructions: String
    var profileModel: String?
    var profileSandbox: SandboxMode?
    var profileApproval: ApprovalPolicy?
    var profileFullAuto: Bool?
    var profileDangerBypass: Bool?
    var profilePathPrependText: String
    var profileEnvText: String
    var parentProjectId: String?
    var sources: Set<ProjectSessionSource>
  }

  // Unified layout constants for aligned labels/fields across tabs
  private let labelColWidth: CGFloat = 120
  private let fieldColWidth: CGFloat = 360

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(modeTitle).font(.title3).fontWeight(.semibold)

      TabView {
        Tab("General", systemImage: "gearshape") {
          VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
              GridRow {
                Text("Name")
                  .font(.subheadline)
                  .frame(width: labelColWidth, alignment: .trailing)
                TextField("Display name", text: $name)
                  .textFieldStyle(.roundedBorder)
                  .frame(width: fieldColWidth, alignment: .leading)
              }
              GridRow {
                Text("Directory")
                  .font(.subheadline)
                  .frame(width: labelColWidth, alignment: .trailing)
                HStack(spacing: 8) {
                  TextField("/absolute/path", text: $directory)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                  Button("Choose…") { chooseDirectory() }
                }
                .frame(width: fieldColWidth, alignment: .leading)
              }
              GridRow {
                Text("Parent Project")
                  .font(.subheadline)
                  .frame(width: labelColWidth, alignment: .trailing)
                Picker(
                  "",
                  selection: Binding(
                    get: { parentProjectId ?? "(none)" },
                    set: { parentProjectId = $0 == "(none)" ? nil : $0 })
                ) {
                  Text("(none)").tag("(none)")
                  ForEach(viewModel.projects.filter { $0.id != (modeSelfId()) }, id: \.id) { p in
                    Text(p.name.isEmpty ? p.id : p.name).tag(p.id)
                  }
                }
                .labelsHidden()
                .frame(width: fieldColWidth, alignment: .leading)
              }
              GridRow {
                Text("Trust Level")
                  .font(.subheadline)
                  .frame(width: labelColWidth, alignment: .trailing)
                Picker("", selection: trustLevelBinding) {
                  Text("trusted").tag("trusted")
                  Text("untrusted").tag("untrusted")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: .infinity, alignment: .leading)
              }
              GridRow {
                Text("Sources")
                  .font(.subheadline)
                  .frame(width: labelColWidth, alignment: .trailing)
                HStack(spacing: 16) {
                  ForEach(ProjectSessionSource.allCases) { source in
                    Toggle(source.displayName, isOn: binding(for: source))
                      .toggleStyle(.checkbox)
                  }
                }
                .frame(width: fieldColWidth, alignment: .leading)
              }
              GridRow(alignment: .top) {
                Text("Overview")
                  .font(.subheadline)
                  .frame(width: labelColWidth, alignment: .trailing)
                VStack(alignment: .leading, spacing: 6) {
                  TextEditor(text: $overview)
                    .font(.body)
                    .frame(minHeight: 88, maxHeight: 120)
                    .overlay(
                      RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.2))
                    )
                }
                .frame(width: fieldColWidth, alignment: .leading)
              }
            }
          }
          .padding(16)
        }
        Tab("Profile", systemImage: "person.crop.square") {
          VStack(alignment: .leading, spacing: 12) {
            Text("Project Profile (applies to new sessions)")
              .font(.subheadline)
              .foregroundStyle(.secondary)

            // Sandbox + Approval (left-aligned)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
              GridRow {
                Text("Sandbox")
                  .font(.subheadline)
                  .frame(width: labelColWidth, alignment: .trailing)
                Picker(
                  "",
                  selection: Binding(
                    get: { profileSandbox ?? .workspaceWrite }, set: { profileSandbox = $0 })
                ) {
                  ForEach(SandboxMode.allCases) { s in Text(s.title).tag(s) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: .infinity, alignment: .leading)
              }
              GridRow {
                Text("Approval")
                  .font(.subheadline)
                  .frame(width: labelColWidth, alignment: .trailing)
                Picker(
                  "",
                  selection: Binding(
                    get: { profileApproval ?? .onRequest }, set: { profileApproval = $0 })
                ) {
                  ForEach(ApprovalPolicy.allCases) { a in Text(a.title).tag(a) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: .infinity, alignment: .leading)
              }
              GridRow {
                Text("Presets")
                  .font(.subheadline)
                  .frame(width: labelColWidth, alignment: .trailing)
                HStack(spacing: 12) {
                  Toggle(
                    "Full Auto",
                    isOn: Binding(get: { profileFullAuto ?? false }, set: { profileFullAuto = $0 }))
                  Toggle(
                    "Danger Bypass",
                    isOn: Binding(
                      get: { profileDangerBypass ?? false }, set: { profileDangerBypass = $0 }))
                }
                .frame(width: fieldColWidth, alignment: .leading)
              }
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
              GridRow {
                Text("PATH Prepend")
                  .font(.subheadline)
                  .frame(width: labelColWidth, alignment: .trailing)
                TextField("/opt/custom/bin:/project/bin", text: $profilePathPrependText)
                  .textFieldStyle(.roundedBorder)
                  .frame(width: fieldColWidth, alignment: .leading)
              }
              GridRow(alignment: .top) {
                Text("Environment")
                  .font(.subheadline)
                  .frame(width: labelColWidth, alignment: .trailing)
                VStack(alignment: .leading, spacing: 6) {
                  TextEditor(text: $profileEnvText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 100, maxHeight: 180)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                  Text("One per line: KEY=VALUE. Will export as export KEY='VALUE'.").font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(width: fieldColWidth, alignment: .leading)
              }
            }
            Text(
              "These settings apply to new sessions of this project and map to --model / -s / -a / --full-auto / --dangerously-bypass-approvals-and-sandbox. The CLI may also load the named profile (auto-mapped to project ID)."
            ).font(.caption).foregroundStyle(.secondary)
          }
          .padding(16)
        }
      }
      .padding(.bottom, 4)

      HStack {
        if case .edit(let p) = mode {
          Text("ID: \(p.id)").font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button("Cancel") { attemptClose() }
          .keyboardShortcut(.cancelAction)
        Button(primaryActionTitle) { save() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(16)
    .frame(minWidth: 640, minHeight: 420)
    .onAppear(perform: load)
    .alert("Discard changes?", isPresented: $showCloseConfirm) {
      Button("Keep Editing", role: .cancel) {}
      Button("Discard", role: .destructive) { isPresented = false }
    } message: {
      Text("Your edits will be lost.")
    }
  }

  private var modeTitle: String {
    if case .edit = mode { return "Edit Project" } else { return "New Project" }
  }
  private var primaryActionTitle: String {
    if case .edit = mode { return "Save" } else { return "Create" }
  }

  private func chooseDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url { directory = url.path }
  }

  private func load() {
    switch mode {
    case .edit(let p):
      name = p.name
      directory = p.directory ?? ""
      trustLevel = p.trustLevel ?? "trusted"
      parentProjectId = p.parentId
      overview = p.overview ?? ""
      instructions = p.instructions ?? ""
      profileId = p.profileId ?? ""
      let initialSources = p.sources.isEmpty ? ProjectSessionSource.allSet : p.sources
      sources = initialSources
      if let pr = p.profile {
        profileModel = pr.model
        profileSandbox = pr.sandbox
        profileApproval = pr.approval
        profileFullAuto = pr.fullAuto
        profileDangerBypass = pr.dangerouslyBypass
        if let pp = pr.pathPrepend { profilePathPrependText = pp.joined(separator: ":") }
        if let env = pr.env {
          let lines = env.keys.sorted().map { k in
            let v = env[k] ?? ""
            return "\(k)=\(v)"
          }
          profileEnvText = lines.joined(separator: "\n")
        }
      }
    case .new:
      sources = ProjectSessionSource.allSet
      if let pf = prefill {
        if let v = pf.name { name = v }
        if let v = pf.directory { directory = v }
        if let v = pf.trustLevel { trustLevel = v } else { trustLevel = "trusted" }
        if let v = pf.overview { overview = v }
        if let v = pf.instructions { instructions = v }
        if let v = pf.profileId { profileId = v }
        if let v = pf.parentId { parentProjectId = v }
      }
    }
    original = currentSnapshot()
  }

  private func slugify(_ s: String) -> String {
    let lower = s.lowercased()
    let allowed = "abcdefghijklmnopqrstuvwxyz0123456789-"
    let chars = lower.map { ch -> Character in
      if allowed.contains(ch) { return ch }
      if ch.isLetter || ch.isNumber { return "-" }
      return "-"
    }
    var str = String(chars)
    while str.contains("--") { str = str.replacingOccurrences(of: "--", with: "-") }
    str = str.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return str.isEmpty ? "project" : str
  }

  private func generateId() -> String {
    let baseName: String = {
      let n = name.trimmingCharacters(in: .whitespaces)
      if !n.isEmpty { return n }
      let base = URL(fileURLWithPath: directory, isDirectory: true).lastPathComponent
      return base.isEmpty ? "project" : base
    }()
    var candidate = slugify(baseName)
    let existing = Set(viewModel.projects.map(\.id))
    var i = 1
    while existing.contains(candidate) {
      i += 1
      candidate = slugify(baseName) + "-\(i)"
    }
    return candidate
  }

  private func save() {
    let trust = trustLevel.trimmingCharacters(in: .whitespaces).isEmpty ? nil : trustLevel
    let ov = overview.trimmingCharacters(in: .whitespaces).isEmpty ? nil : overview
    let instr = instructions.trimmingCharacters(in: .whitespaces).isEmpty ? nil : instructions
    // Profile ID: auto map to project ID by default
    let cleanedProfileId = profileId.trimmingCharacters(in: .whitespaces)
    let profile: String? = cleanedProfileId.isEmpty ? nil : cleanedProfileId
    let dirOpt: String? = {
      let d = directory.trimmingCharacters(in: .whitespacesAndNewlines)
      return d.isEmpty ? nil : directory
    }()
    let finalSources = sources.isEmpty ? ProjectSessionSource.allSet : sources

    switch mode {
    case .new:
      let id = generateId()
      let projProfile = buildProjectProfile()
      let finalProfileId = profile ?? id
      let p = Project(
        id: id,
        name: (name.isEmpty ? id : name),
        directory: dirOpt,
        trustLevel: trust,
        overview: ov,
        instructions: instr,
        profileId: finalProfileId,
        profile: projProfile,
        parentId: parentProjectId,
        sources: finalSources
      )
      Task {
        await viewModel.createOrUpdateProject(p)
        if let ids = autoAssignSessionIDs, !ids.isEmpty {
          await viewModel.assignSessions(to: id, ids: ids)
        }
        isPresented = false
      }
    case .edit(let old):
      let projProfile = buildProjectProfile()
      let finalProfileId = profile ?? old.id
      let p = Project(
        id: old.id,
        name: name,
        directory: dirOpt,
        trustLevel: trust,
        overview: ov,
        instructions: instr,
        profileId: finalProfileId,
        profile: projProfile,
        parentId: parentProjectId,
        sources: finalSources
      )
      Task {
        await viewModel.createOrUpdateProject(p)
        isPresented = false
      }
    }
  }

  private var trustLevelSegment: String { trustLevel == "untrusted" ? "untrusted" : "trusted" }
  private var trustLevelBinding: Binding<String> {
    Binding<String>(
      get: { trustLevelSegment },
      set: { newValue in trustLevel = (newValue == "untrusted") ? "untrusted" : "trusted" }
    )
  }

  private func binding(for source: ProjectSessionSource) -> Binding<Bool> {
    Binding<Bool>(
      get: { sources.contains(source) },
      set: { newValue in
        if newValue {
          sources.insert(source)
        } else {
          if sources.count == 1 && sources.contains(source) { return }
          sources.remove(source)
        }
      }
    )
  }

  private func modeSelfId() -> String? {
    if case .edit(let p) = mode { return p.id }
    return nil
  }

  private func buildProjectProfile() -> ProjectProfile? {
    if (profileId.trimmingCharacters(in: .whitespaces).isEmpty)
      && (profileModel?.isEmpty ?? true)
      && profileSandbox == nil
      && profileApproval == nil
      && profileFullAuto == nil
      && profileDangerBypass == nil
    {
      return nil
    }
    return ProjectProfile(
      model: profileModel?.trimmingCharacters(in: .whitespaces).isEmpty == true
        ? nil : profileModel,
      sandbox: profileSandbox,
      approval: profileApproval,
      fullAuto: profileFullAuto,
      dangerouslyBypass: profileDangerBypass,
      pathPrepend: parsePathPrepend(profilePathPrependText),
      env: parseEnv(profileEnvText)
    )
  }

  private func parsePathPrepend(_ text: String) -> [String]? {
    let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !s.isEmpty else { return nil }
    return s.split(separator: ":").map { String($0).trimmingCharacters(in: .whitespaces) }.filter {
      !$0.isEmpty
    }
  }

  private func parseEnv(_ text: String) -> [String: String]? {
    let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init)
    var dict: [String: String] = [:]
    for line in lines {
      let t = line.trimmingCharacters(in: .whitespaces)
      guard !t.isEmpty, let eq = t.firstIndex(of: "=") else { continue }
      let key = String(t[..<eq]).trimmingCharacters(in: .whitespaces)
      let val = String(t[t.index(after: eq)...])
      if !key.isEmpty { dict[key] = val }
    }
    return dict.isEmpty ? nil : dict
  }

  private func currentSnapshot() -> Snapshot {
    Snapshot(
      name: name,
      directory: directory,
      trustLevel: trustLevel,
      overview: overview,
      instructions: instructions,
      profileModel: profileModel,
      profileSandbox: profileSandbox,
      profileApproval: profileApproval,
      profileFullAuto: profileFullAuto,
      profileDangerBypass: profileDangerBypass,
      profilePathPrependText: profilePathPrependText,
      profileEnvText: profileEnvText,
      parentProjectId: parentProjectId,
      sources: sources
    )
  }

  private func attemptClose() {
    if let original, original != currentSnapshot() {
      showCloseConfirm = true
    } else {
      isPresented = false
    }
  }

}
private struct ProjectTreeNode: Identifiable, Hashable {
  let id: String
  let project: Project
  var children: [ProjectTreeNode]?
}

private func buildProjectTree(_ projects: [Project]) -> [ProjectTreeNode] {
  var map: [String: ProjectTreeNode] = [:]
  var roots: [ProjectTreeNode] = []
  for p in projects {
    map[p.id] = ProjectTreeNode(id: p.id, project: p, children: [])
  }
  for p in projects {
    if let pid = p.parentId, let parent = map[pid] {
      let copy = map[p.id]!
      // attach under parent
      var parentCopy = parent
      parentCopy.children?.append(copy)
      map[pid] = parentCopy
    }
  }
  // rebuild roots (those without a valid parent)
  for p in projects.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
    if let pid = p.parentId, projects.contains(where: { $0.id == pid }) {
      continue
    }
    // gather children from map updated above
    let node = map[p.id] ?? ProjectTreeNode(id: p.id, project: p, children: nil)
    roots.append(fixChildren(node, map: map))
  }
  return roots
}

private func fixChildren(_ node: ProjectTreeNode, map: [String: ProjectTreeNode]) -> ProjectTreeNode
{
  var out = node
  let project = node.project
  let children = map.values.filter { $0.project.parentId == project.id }
    .sorted { $0.project.name.localizedStandardCompare($1.project.name) == .orderedAscending }
    .map { fixChildren($0, map: map) }
  out.children = children.isEmpty ? nil : children
  return out
}

import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct MCPServersSettingsPane: View {
    @StateObject private var vm = MCPServersViewModel()
    @ObservedObject var preferences: SessionPreferencesStore
    @State private var showImportConfirmation = false
    @State private var showNewSheet = false
    // New unified editor sheet
    @State private var showEditorSheet = false
    @State private var editorIsEditingExisting = false
    var openMCPMateDownload: () -> Void
    var showHeader: Bool = true
    @State private var pendingDeleteName: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showHeader {
                Text("MCP Servers").font(.title2).fontWeight(.bold)
                Text("Manage MCP servers. Add via Uni‑Import or configure capabilities.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            // List header with Add + Import button (match Providers style)
            HStack {
                Spacer()
                Button { editorIsEditingExisting = false; vm.startNewForm(); showEditorSheet = true } label: { Label("Add", systemImage: "plus") }
                Button { vm.beginImportFromHome() } label: { Label("Import", systemImage: "tray.and.arrow.down") }
            }

            serversList
            Spacer(minLength: 0)
        }
        .onAppear { Task { await vm.loadServers() } }
        .onChange(of: showNewSheet) { newVal in
            if newVal == false {
                Task { await vm.loadServers() }
            }
        }
        .onChange(of: showEditorSheet) { newVal in
            if newVal == false {
                Task { await vm.loadServers() }
            }
        }
        .sheet(isPresented: $showNewSheet) {
            NewMCPServerSheet(vm: vm, onClose: { showNewSheet = false })
                .frame(minWidth: 640, minHeight: 420)
        }
        .sheet(isPresented: $showEditorSheet) {
            MCPServerEditorSheet(
                vm: vm,
                preferences: preferences,
                isEditing: editorIsEditingExisting,
                onClose: { showEditorSheet = false }
            )
                .frame(minWidth: 760, minHeight: 480)
        }
        .sheet(isPresented: $vm.showImportSheet) {
            MCPImportSheet(
                candidates: $vm.importCandidates,
                isImporting: vm.isImporting,
                statusMessage: vm.importStatusMessage,
                title: "Import MCP Servers",
                subtitle: "Scan Home for existing Codex/Claude/Gemini MCP servers and import into CodMate.",
                onCancel: { vm.cancelImport() },
                onImport: { Task { await vm.importSelectedServers() } }
            )
            .frame(minWidth: 760, minHeight: 480)
        }
    }

    // Extracted: Import view used inside New window
    private var mcpImportTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Uni-Import").font(.headline).fontWeight(.semibold)
            Text("Paste or drop JSON/TOML payloads to stage MCP servers before importing.")
                .font(.caption)
                .foregroundColor(.secondary)

            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [5]))
                    .foregroundStyle(.quaternary)
                    .frame(height: 120)
                VStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down").font(.title3)
                    Text("Drop text files or snippets here")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .onDrop(of: [UTType.json, UTType.plainText, UTType.fileURL], isTargeted: nil) { providers in
                handleImportProviders(providers)
            }

            HStack(spacing: 8) {
                PasteButton(payloadType: String.self) { strings in
                    if let text = strings.first(where: { !$0.isEmpty }) {
                        vm.loadText(text)
                    }
                }
                .buttonBorderShape(.roundedRectangle)
                .controlSize(.small)

                Button {
                    vm.clearImport()
                } label: {
                    Label("Clear", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(vm.importText.isEmpty && vm.drafts.isEmpty && vm.importError == nil)
            }

            if vm.isParsing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Parsing input…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else if let err = vm.importError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.red)
            } else if !vm.drafts.isEmpty {
                Label("Detected \(vm.drafts.count) server(s). Review details below.", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundColor(.green)
            }

            TextEditor(text: Binding(get: { vm.importText }, set: { _ in }))
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 200)
                .disabled(true)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            if !vm.drafts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Detected: \(vm.drafts.count) server(s)").font(.subheadline).fontWeight(.medium)
                    ForEach(Array(vm.drafts.enumerated()), id: \.offset) { (_, draft) in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Image(systemName: draft.kind == .stdio ? "terminal" : (draft.kind == .sse ? "dot.radiowaves.left.and.right" : "globe"))
                                Text(draft.name ?? "(unnamed)")
                                    .font(.subheadline)
                                Spacer()
                            }
                            if let url = draft.url, !url.isEmpty {
                                Text(url)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            if let description = draft.meta?.description, !description.isEmpty {
                                Text(description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Button(action: { showImportConfirmation = true }) {
                    Label("Import", systemImage: "tray.and.arrow.down.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.isParsing)
            }
        }
        .padding(8)
    }

    private var serversList: some View {
        Group {
            if vm.servers.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "server.rack").font(.system(size: 48)).foregroundStyle(.secondary)
                    Text("No MCP Servers")
                        .font(.title3).fontWeight(.medium)
                    Text("Click Add to import a server.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 200)
            } else {
                List(selection: $vm.selectedServerName) {
                    ForEach(vm.servers) { s in
                        HStack(alignment: .center, spacing: 0) {
                            Toggle("", isOn: Binding(get: { s.enabled }, set: { v in Task { await vm.setServerEnabled(s, v) } }))
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .controlSize(.small)
                                .padding(.trailing, 8)
                            HStack(alignment: .center, spacing: 8) {
                                Image(systemName: s.kind == .stdio ? "terminal" : (s.kind == .sse ? "dot.radiowaves.left.and.right" : "globe"))
                                Text(s.name).font(.body.weight(.medium))
                            }
                            .frame(minWidth: 120, alignment: .leading)
                            Spacer(minLength: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                if let desc = s.meta?.description, !desc.isEmpty { Text(desc).font(.caption).foregroundStyle(.secondary) }
                                HStack(spacing: 12) {
                                    if let url = s.url, !url.isEmpty { Label(url, systemImage: "link").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                                    if let cmd = s.command, !cmd.isEmpty { Label(cmd, systemImage: "terminal").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            HStack(spacing: 6) {
                                MCPServerTargetToggle(
                                    provider: .codex,
                                    isOn: Binding(
                                        get: { vm.isServerEnabled(s, for: .codex) },
                                        set: { value in Task { await vm.setServerTargetEnabled(s, target: .codex, enabled: value) } }
                                    ),
                                    disabled: !s.enabled || !preferences.isCLIEnabled(.codex)
                                )
                                MCPServerTargetToggle(
                                    provider: .claude,
                                    isOn: Binding(
                                        get: { vm.isServerEnabled(s, for: .claude) },
                                        set: { value in Task { await vm.setServerTargetEnabled(s, target: .claude, enabled: value) } }
                                    ),
                                    disabled: !s.enabled || !preferences.isCLIEnabled(.claude)
                                )
                                MCPServerTargetToggle(
                                    provider: .gemini,
                                    isOn: Binding(
                                        get: { vm.isServerEnabled(s, for: .gemini) },
                                        set: { value in Task { await vm.setServerTargetEnabled(s, target: .gemini, enabled: value) } }
                                    ),
                                    disabled: !s.enabled || !preferences.isCLIEnabled(.gemini)
                                )
                            }
                            .padding(.trailing, 8)
                            Button {
                                editorIsEditingExisting = true
                                vm.startEditForm(from: s)
                                showEditorSheet = true
                            } label: { Image(systemName: "pencil").font(.body) }
                            .buttonStyle(.borderless)
                            .help("Edit server")
                        }
                        .padding(.vertical, 8)
                        .tag(s.name as String?)
                        .contextMenu {
                            Button("Edit…") {
                                editorIsEditingExisting = true
                                vm.startEditForm(from: s)
                                showEditorSheet = true
                            }
                            Divider()
                            Button(role: .destructive) { pendingDeleteName = s.name } label: { Text("Delete") }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .frame(minHeight: 200, maxHeight: .infinity, alignment: .top)
            }
        }
        .task { await vm.loadServers() }
        .padding(.horizontal, -8)
        .alert("Delete MCP Server?", isPresented: Binding(get: { pendingDeleteName != nil }, set: { if !$0 { pendingDeleteName = nil } })) {
            Button("Delete", role: .destructive) {
                if let name = pendingDeleteName { Task { await vm.deleteServer(named: name) } }
                pendingDeleteName = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteName = nil }
        } message: {
            if let name = pendingDeleteName { Text("Are you sure you want to delete \"\(name)\"? This action cannot be undone.") } else { Text("") }
        }
    }

    private var mcpAdvancedTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                Image("MCPMateLogo")
                    .resizable()
                    .frame(width: 48, height: 48)
                    .cornerRadius(12)
                VStack(alignment: .leading, spacing: 0) {
                    Text("MCPMate").font(.headline)
                    Text("A 'Maybe All-in-One' MCP service manager for developers and creators.")
                        .font(.subheadline).fontWeight(.semibold)
                }
            }
            Text("MCPMate offers advanced MCP server management beyond CodMate's basic import and enable/disable controls.")
                .font(.body).foregroundColor(.secondary)
            Text("Download MCPMate to configure MCP servers alongside CodMate.")
                .font(.subheadline).foregroundColor(.secondary)
            Button(action: openMCPMateDownload) { Label("Download MCPMate", systemImage: "arrow.down.circle.fill").labelStyle(.titleAndIcon) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .font(.body.weight(.semibold))
        }
        .padding(8)
    }

    private func handleImportProviders(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                    guard let text = readText(from: data) else { return }
                    handled = true
                    DispatchQueue.main.async {
                        vm.loadText(text)
                    }
                }
                handled = true
                continue
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.json.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.json.identifier, options: nil) { data, _ in
                    guard let text = readText(from: data) else { return }
                    handled = true
                    DispatchQueue.main.async {
                        vm.loadText(text)
                    }
                }
                handled = true
                continue
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { data, _ in
                    guard let text = readText(from: data) else { return }
                    handled = true
                    DispatchQueue.main.async {
                        vm.loadText(text)
                    }
                }
                handled = true
                continue
            }
            if provider.canLoadObject(ofClass: String.self) {
                _ = provider.loadObject(ofClass: String.self) { string, _ in
                    guard let string = string else { return }
                    handled = true
                    DispatchQueue.main.async {
                        vm.loadText(string)
                    }
                }
                handled = true
            }
        }
        return handled
    }

    private func readText(from representation: (any NSSecureCoding)?) -> String? {
        if let string = representation as? String { return string }
        if let url = representation as? URL {
            return try? String(contentsOf: url, encoding: .utf8)
        }
        if let data = representation as? Data {
            if let url = URL(dataRepresentation: data, relativeTo: nil) {
                return try? String(contentsOf: url, encoding: .utf8)
            }
            return String(data: data, encoding: .utf8)
        }
        return nil
    }
}

// MARK: - New MCP Server Sheet (Import + Form placeholder)
private struct NewMCPServerSheet: View {
    @ObservedObject var vm: MCPServersViewModel
    var onClose: () -> Void
    @State private var showImportConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("New MCP Server").font(.title3).fontWeight(.semibold)
                Spacer()
                Button("Close") { onClose() }.buttonStyle(.borderless)
            }
            SettingsTabContent { mcpImportContent }
            HStack {
                Spacer()
                Button("Import") { showImportConfirmation = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.isParsing || (vm.drafts.isEmpty && vm.importText.isEmpty))
            }
        }
        .padding(12)
        .alert("Import Servers?", isPresented: $showImportConfirmation) {
            Button("Import", role: .none) { Task { await vm.importDrafts(); onClose() } }
            Button("Discard Drafts", role: .destructive) { vm.clearImport() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Import \(vm.drafts.count) server(s) into CodMate?") }
    }

    @ViewBuilder
    private var mcpImportContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Uni-Import").font(.headline).fontWeight(.semibold)
            Text("Paste or drop JSON/TOML payloads to stage MCP servers before importing.")
                .font(.caption).foregroundColor(.secondary)
            ZStack {
                RoundedRectangle(cornerRadius: 8).stroke(style: StrokeStyle(lineWidth: 1, dash: [5])).foregroundStyle(.quaternary).frame(height: 120)
                VStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down").font(.title3)
                    Text("Drop text files or snippets here").font(.caption).foregroundColor(.secondary)
                }
            }
            .onDrop(of: [UTType.json, UTType.plainText, UTType.fileURL], isTargeted: nil) { providers in
                handleDropProviders(providers)
            }
            HStack(spacing: 8) {
                PasteButton(payloadType: String.self) { strings in if let text = strings.first(where: { !$0.isEmpty }) { vm.loadText(text) } }
                    .buttonBorderShape(.roundedRectangle).controlSize(.small)
                Button { vm.clearImport() } label: { Label("Clear", systemImage: "xmark.circle") }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(vm.importText.isEmpty && vm.drafts.isEmpty && vm.importError == nil)
            }
            if vm.isParsing {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Parsing input…").font(.caption).foregroundColor(.secondary) }
            } else if let err = vm.importError {
                Label(err, systemImage: "exclamationmark.triangle").font(.caption).foregroundColor(.red)
            } else if !vm.drafts.isEmpty {
                Label("Detected \(vm.drafts.count) server(s). Review details below.", systemImage: "checkmark.circle").font(.caption).foregroundColor(.green)
            }
            TextEditor(text: Binding(get: { vm.importText }, set: { _ in }))
                .font(.system(.body, design: .monospaced)).frame(minHeight: 200).disabled(true)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            if !vm.drafts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Detected: \(vm.drafts.count) server(s)").font(.subheadline).fontWeight(.medium)
                    ForEach(Array(vm.drafts.enumerated()), id: \.offset) { (_, draft) in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Image(systemName: draft.kind == .stdio ? "terminal" : (draft.kind == .sse ? "dot.radiowaves.left.and.right" : "globe"))
                                Text(draft.name ?? "—").font(.subheadline).fontWeight(.medium)
                                Spacer()
                            }
                            if let desc = draft.meta?.description { Text(desc).font(.caption).foregroundColor(.secondary) }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .controlSize(.small)
            }
        }
    }
    // Local drop handler (sheet scope)
    private func handleDropProviders(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                    guard let data = data,
                          let url = data as? URL,
                          let text = try? String(contentsOf: url, encoding: .utf8)
                    else { return }
                    handled = true
                    DispatchQueue.main.async { vm.loadText(text) }
                }
                handled = true
                continue
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.json.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.json.identifier, options: nil) { data, _ in
                    guard let text = readText(from: data) else { return }
                    handled = true
                    DispatchQueue.main.async { vm.loadText(text) }
                }
                handled = true
                continue
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { data, _ in
                    guard let text = readText(from: data) else { return }
                    handled = true
                    DispatchQueue.main.async { vm.loadText(text) }
                }
                handled = true
                continue
            }
        }
        return handled
    }

    private func handleImportProviders(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                    guard let text = readText(from: data) else { return }
                    handled = true
                    DispatchQueue.main.async {
                        vm.loadText(text)
                    }
                }
                handled = true
                continue
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.json.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.json.identifier, options: nil) { data, _ in
                    guard let text = readText(from: data) else { return }
                    handled = true
                    DispatchQueue.main.async {
                        vm.loadText(text)
                    }
                }
                handled = true
                continue
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { data, _ in
                    guard let text = readText(from: data) else { return }
                    handled = true
                    DispatchQueue.main.async {
                        vm.loadText(text)
                    }
                }
                handled = true
                continue
            }
            if provider.canLoadObject(ofClass: String.self) {
                _ = provider.loadObject(ofClass: String.self) { string, _ in
                    guard let string = string else { return }
                    handled = true
                    DispatchQueue.main.async {
                        vm.loadText(string)
                    }
                }
                handled = true
            }
        }
        return handled
    }

    private func readText(from representation: (any NSSecureCoding)?) -> String? {
        if let string = representation as? String { return string }
        if let url = representation as? URL {
            return try? String(contentsOf: url, encoding: .utf8)
        }
        if let data = representation as? Data {
            if let url = URL(dataRepresentation: data, relativeTo: nil) {
                return try? String(contentsOf: url, encoding: .utf8)
            }
            return String(data: data, encoding: .utf8)
        }
        return nil
    }
}

// MARK: - Unified Editor Sheet (JSON + Form)
private struct MCPServerEditorSheet: View {
    @ObservedObject var vm: MCPServersViewModel
    @ObservedObject var preferences: SessionPreferencesStore
    var isEditing: Bool
    var onClose: () -> Void
    @State private var selectedTab: Int = 0 // 0=Form, 1=JSON
    @State private var isDropTargeted: Bool = false
    @State private var breathing: Bool = false
    @State private var wizardActive: Bool = false
    @FocusState private var focusedField: FocusField?

    private enum FocusField {
        case name
    }

    var body: some View {
        if wizardActive {
            MCPWizardSheet(preferences: preferences, onApply: { draft in
                applyDraft(draft)
                wizardActive = false
            }, onCancel: {
                wizardActive = false
            })
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(isEditing ? "Edit MCP Server" : "New MCP Server").font(.title3).fontWeight(.semibold)
                    Spacer()
                    Button {
                        wizardActive = true
                    } label: {
                        Image(systemName: "sparkles")
                    }
                    .buttonStyle(.borderless)
                    .help("AI Wizard")
                }
                if !isEditing {
                    SettingsTabContent { importArea }
                }
                if #available(macOS 15.0, *) {
                    TabView(selection: $selectedTab) {
                        Tab("Form", systemImage: "slider.horizontal.3", value: 0) {
                            SettingsTabContent { formTab }
                        }
                        Tab("JSON", systemImage: "doc.text", value: 1) {
                            SettingsTabContent { jsonConfigTab }
                        }
                    }
                } else {
                    TabView(selection: $selectedTab) {
                        SettingsTabContent { formTab }
                            .tabItem { Label("Form", systemImage: "slider.horizontal.3") }
                            .tag(0)
                        SettingsTabContent { jsonConfigTab }
                            .tabItem { Label("JSON", systemImage: "doc.text") }
                            .tag(1)
                    }
                }
                if let msg = vm.testMessage, !msg.isEmpty {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(msg.hasPrefix("Connected") ? .green : .red)
                }
                HStack {
                    if vm.testInProgress {
                        Button("Stop") { vm.cancelTest() }
                            .buttonStyle(.bordered)
                    } else {
                        Button("Test") { vm.startTest() }
                            .buttonStyle(.bordered)
                    }
                    Spacer()
                    Button("Cancel") { onClose() }
                    Button(isEditing ? "Save" : "Create") {
                        Task { if await vm.saveForm() { onClose() } }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!vm.formCanSave())
                }
            }
            .padding(16)
            .onAppear {
                if !isEditing {
                    DispatchQueue.main.async {
                        focusedField = .name
                    }
                }
            }
        }
    }

    // MARK: - Import area (top, new-only)
    @ViewBuilder private var importArea: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                // No border/background
                VStack(spacing: 10) {
                    Image(systemName: "target")
                        .font(.system(size: 48))
                        .scaleEffect(breathing ? 1.08 : 1.0)
                        .brightness(breathing ? 0.2 : -0.2)
                        .foregroundStyle(breathing ? Color.accentColor.opacity(0.8) : Color.secondary)
                    Text("Paste or drop JSON payloads to stage MCP servers; detected entries will autofill the form below.")
                        .font(.caption)
                        .foregroundStyle(breathing ? Color.accentColor.opacity(0.85) : Color.secondary)
                        .multilineTextAlignment(.center)
                        .scaleEffect(breathing ? 1.02 : 1.0)
                        .brightness(breathing ? 0.2 : -0.2)
                    Group {
                        if vm.isParsing {
                            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Parsing input…").font(.caption).foregroundStyle(.secondary) }
                        } else if let err = vm.importError {
                            Label(err, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
                        } else if !vm.drafts.isEmpty {
                            Label("Detected \(vm.drafts.count) server(s)", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
                        }
                    }
                    // paste/clear moved to context menu
                }
                .frame(maxWidth: .infinity)
                .frame(height: 140)
            }
            .contentShape(Rectangle())
            .allowsHitTesting(true)
            .frame(maxWidth: .infinity, minHeight: 140)
            // Native NSView-based drop catcher for precise hover (drag-in) detection
            .overlay(
                DropCatcher(
                    isTargeted: $isDropTargeted,
                    onString: { vm.loadText($0) },
                    onURL: { url in if let text = try? String(contentsOf: url, encoding: .utf8) { vm.loadText(text) } }
                )
            )
            .contextMenu {
                Button("Paste JSON") {
                    let pb = NSPasteboard.general
                    if let s = pb.string(forType: .string), !s.isEmpty { vm.loadText(s) }
                }
                Button("Clean") { vm.clearImport() }
            }
            // SwiftUI drop as fallback (kept minimal to avoid conflicting hover state)
            .onDrop(of: [UTType.json, UTType.plainText, UTType.fileURL, UTType.text], isTargeted: .constant(false)) { providers in
                handleDropProviders(providers)
            }
            .onChange(of: isDropTargeted) { now in
                if now {
                    withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                        breathing = true
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { breathing = false }
                }
            }
            .onChange(of: vm.isParsing) { parsing in
                // Stop breathing once parsing finishes (drop completed)
                if parsing == false {
                    isDropTargeted = false
                    withAnimation(.easeOut(duration: 0.2)) { breathing = false }
                }
            }
            .onChange(of: vm.drafts.count) { _ in
                // Any detected entries imply drop completed; stop highlight
                isDropTargeted = false
                withAnimation(.easeOut(duration: 0.2)) { breathing = false }
            }
            .onChange(of: vm.importError) { _ in
                // Error also ends the hover state; stop highlight
                isDropTargeted = false
                withAnimation(.easeOut(duration: 0.2)) { breathing = false }
            }
        }
    }

    // MARK: - Form Tab (primary)
    @ViewBuilder private var formTab: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
            GridRow {
                Text("Name").font(.subheadline).fontWeight(.medium)
                TextField("server-id", text: $vm.formName)
                    .focused($focusedField, equals: .name)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            GridRow {
                Text("Kind").font(.subheadline).fontWeight(.medium)
                Picker("", selection: $vm.formKind) {
                    Text("stdio").tag(MCPServerKind.stdio)
                    Text("sse").tag(MCPServerKind.sse)
                    Text("streamable_http").tag(MCPServerKind.streamable_http)
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            // Network endpoint (visible for non-stdio kinds)
            if vm.formKind != .stdio {
                GridRow { Text("URL").font(.subheadline).fontWeight(.medium); TextField("https://…", text: $vm.formURL).frame(maxWidth: .infinity, alignment: .trailing) }
            }
            // Process endpoint (visible for stdio)
            if vm.formKind == .stdio {
                GridRow { Text("Command").font(.subheadline).fontWeight(.medium); TextField("/usr/local/bin/mcp-server", text: $vm.formCommand).frame(maxWidth: .infinity, alignment: .trailing) }
                GridRow {
                    Text("Args").font(.subheadline).fontWeight(.medium)
                    TextEditor(text: $vm.formArgs)
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 80)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            // Env (both kinds)
            GridRow {
                Text("Env").font(.subheadline).fontWeight(.medium)
                TextEditor(text: $vm.formEnvText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 80)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            // Headers (only for network kinds)
            if vm.formKind != .stdio {
                GridRow {
                    Text("Headers").font(.subheadline).fontWeight(.medium)
                    TextEditor(text: $vm.formHeadersText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 80)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            if isEditing {
                GridRow {
                    Text("Targets").font(.subheadline).fontWeight(.medium)
                    HStack(spacing: 12) {
                        Toggle("Codex", isOn: $vm.formTargetsCodex)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        Toggle("Claude Code", isOn: $vm.formTargetsClaude)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        Toggle("Gemini", isOn: $vm.formTargetsGemini)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            // Enabled is controlled in list view only
        }
    }

    // MARK: - JSON config Tab (preview)
    @ViewBuilder private var jsonConfigTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Server JSON preview (read-only)").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(vm.formJSONPreview())
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(8)
            }
            .frame(minHeight: 220)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        }
    }

    // Local drop handler for JSON tab
    private func handleDropProviders(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                    guard let data = data,
                          let url = data as? URL,
                          let text = try? String(contentsOf: url, encoding: .utf8)
                    else { return }
                    handled = true
                    DispatchQueue.main.async { vm.loadText(text) }
                }
                handled = true
                continue
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.json.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.json.identifier, options: nil) { data, _ in
                    guard let text = readText(from: data) else { return }
                    handled = true
                    DispatchQueue.main.async { vm.loadText(text) }
                }
                handled = true
                continue
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { data, _ in
                    guard let text = readText(from: data) else { return }
                    handled = true
                    DispatchQueue.main.async { vm.loadText(text) }
                }
                handled = true
                continue
            }
        }
        return handled
    }

    private func readText(from representation: (any NSSecureCoding)?) -> String? {
        if let string = representation as? String { return string }
        if let url = representation as? URL { return try? String(contentsOf: url, encoding: .utf8) }
        if let data = representation as? Data {
            if let url = URL(dataRepresentation: data, relativeTo: nil) { return try? String(contentsOf: url, encoding: .utf8) }
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    private func applyDraft(_ draft: MCPWizardDraft) {
        vm.formName = draft.name
        vm.formKind = draft.kind
        vm.formURL = draft.url ?? ""
        vm.formCommand = draft.command ?? ""
        vm.formArgs = (draft.args ?? []).joined(separator: "\n")
        vm.formEnvText = formatPairs(draft.env)
        vm.formHeadersText = formatPairs(draft.headers)
        if let targets = draft.targets {
            vm.formTargetsCodex = targets.codex
            vm.formTargetsClaude = targets.claude
            vm.formTargetsGemini = targets.gemini
        }
    }

    private func formatPairs(_ dict: [String: String]?) -> String {
        guard let dict, !dict.isEmpty else { return "" }
        return dict.keys.sorted().map { "\($0)=\(dict[$0]!)" }.joined(separator: "\n")
    }
}

// MARK: - NSViewRepresentable Drop Catcher
private struct DropCatcher: NSViewRepresentable {
    @Binding var isTargeted: Bool
    var onString: (String) -> Void
    var onURL: (URL) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = DropCatcherView()
        v.onString = onString
        v.onURL = onURL
        v.onHoverChange = { targeted in
            DispatchQueue.main.async { self.isTargeted = targeted }
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DropCatcherView: NSView {
        var onString: ((String) -> Void)?
        var onURL: ((URL) -> Void)?
        var onHoverChange: ((Bool) -> Void)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            registerForDraggedTypes([
                .fileURL,
                .URL,
                .string
            ])
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            onHoverChange?(true)
            return .copy
        }
        override func draggingExited(_ sender: NSDraggingInfo?) {
            onHoverChange?(false)
        }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            onHoverChange?(false)
            let pb = sender.draggingPasteboard
            if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], let url = urls.first {
                onURL?(url); return true
            }
            if let str = pb.string(forType: .string), !str.isEmpty {
                onString?(str); return true
            }
            return false
        }
    }
}

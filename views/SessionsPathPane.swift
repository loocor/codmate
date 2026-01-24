import SwiftUI
import AppKit

struct SessionsPathPane: View {
    @ObservedObject var preferences: SessionPreferencesStore
    let fixedKind: SessionSource.Kind?
    @State private var diagnostics: [String: SessionsDiagnostics.Probe] = [:]
    @State private var loadingDiagnostics = false
    @State private var showingAddPath = false
    @State private var selectedKind: SessionSource.Kind
    
    init(preferences: SessionPreferencesStore, fixedKind: SessionSource.Kind? = nil) {
        self.preferences = preferences
        self.fixedKind = fixedKind
        _selectedKind = State(initialValue: fixedKind ?? .codex)
    }
    
    var body: some View {
        let isFixed = fixedKind != nil

        VStack(alignment: .leading, spacing: 18) {
            // Default Paths Section
            VStack(alignment: .leading, spacing: 10) {
                Text("Default Paths").font(.headline).fontWeight(.semibold)
                
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(defaultPaths.indices, id: \.self) { index in
                        let config = defaultPaths[index]
                        SessionPathGroup(
                            config: Binding(
                                get: { 
                                    if let idx = findConfigIndex(config) {
                                        return preferences.sessionPathConfigs[idx]
                                    }
                                    return config
                                },
                                set: { updateConfig($0) }
                            ),
                            diagnostics: diagnostics[config.id],
                            canDelete: false,
                            showToggle: !isFixed,
                            showHeader: !isFixed
                        )
                        .disabled(!preferences.isCLIEnabled(config.kind))
                        .opacity(preferences.isCLIEnabled(config.kind) ? 1.0 : 0.6)
                    }
                }
            }
            
            // Custom Paths Section
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Custom Paths").font(.headline).fontWeight(.semibold)
                    Spacer(minLength: 8)
                    Button {
                        showingAddPath = true
                    } label: {
                        Label("Add Custom Path", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                }
                
                if customPaths.isEmpty {
                    Text("No custom paths added yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(customPaths.indices, id: \.self) { index in
                        let config = customPaths[index]
                        SessionPathGroup(
                            config: Binding(
                                get: { 
                                    if let idx = findConfigIndex(config) {
                                            return preferences.sessionPathConfigs[idx]
                                        }
                                        return config
                                    },
                                    set: { updateConfig($0) }
                            ),
                            diagnostics: diagnostics[config.id],
                            canDelete: true,
                            showToggle: true,
                            showHeader: true,
                            onDelete: {
                                deleteConfig(config)
                            }
                        )
                        .disabled(!preferences.isCLIEnabled(config.kind))
                        .opacity(preferences.isCLIEnabled(config.kind) ? 1.0 : 0.6)
                    }
                }
            }
        }
        }
        .task {
            ensureDefaultEnabled()
            await refreshDiagnostics()
        }
        .sheet(isPresented: $showingAddPath) {
            AddSessionPathSheet(
                selectedKind: $selectedKind,
                preferences: preferences,
                fixedKind: fixedKind,
                onAdd: { kind, path in
                    addCustomPath(kind: kind, path: path)
                }
            )
        }
    }
    
    private var scopedConfigs: [SessionPathConfig] {
        preferences.sessionPathConfigs.filter { config in
            guard let fixedKind else { return true }
            return config.kind == fixedKind
        }
    }
    
    private var defaultPaths: [SessionPathConfig] {
        scopedConfigs.filter { $0.isDefault }
            .sorted { $0.kind.rawValue < $1.kind.rawValue }
    }
    
    private var customPaths: [SessionPathConfig] {
        scopedConfigs.filter { !$0.isDefault }
            .sorted { $0.path < $1.path }
    }
    
    private func updateConfig(_ newConfig: SessionPathConfig) {
        var configs = preferences.sessionPathConfigs
        if let index = configs.firstIndex(where: { $0.id == newConfig.id }) {
            configs[index] = newConfig
            preferences.sessionPathConfigs = configs
        }
        Task {
            ensureDefaultEnabled()
            await refreshDiagnostics()
        }
    }
    
    private func deleteConfig(_ config: SessionPathConfig) {
        var configs = preferences.sessionPathConfigs
        configs.removeAll { $0.id == config.id }
        preferences.sessionPathConfigs = configs
        Task {
            await refreshDiagnostics()
        }
    }
    
    private func findConfigIndex(_ config: SessionPathConfig) -> Int? {
        preferences.sessionPathConfigs.firstIndex { $0.id == config.id }
    }
    
    private func addCustomPath(kind: SessionSource.Kind, path: String) {
        let newConfig = SessionPathConfig(
            kind: kind,
            path: path,
            enabled: true,
            displayName: nil
        )
        var configs = preferences.sessionPathConfigs
        configs.append(newConfig)
        preferences.sessionPathConfigs = configs
        Task {
            await refreshDiagnostics()
        }
    }
    
    private func ensureDefaultEnabled() {
        guard let fixedKind else { return }
        var configs = preferences.sessionPathConfigs
        var didChange = false
        for index in configs.indices {
            if configs[index].isDefault && configs[index].kind == fixedKind && !configs[index].enabled {
                configs[index].enabled = true
                didChange = true
            }
        }
        if didChange {
            preferences.sessionPathConfigs = configs
        }
    }
    
    private func refreshDiagnostics() async {
        loadingDiagnostics = true
        defer { loadingDiagnostics = false }
        
        let diagnosticsService = SessionsDiagnosticsService()
        var newDiagnostics: [String: SessionsDiagnostics.Probe] = [:]
        
        for config in scopedConfigs {
            let url = URL(fileURLWithPath: config.path)
            let probe = await diagnosticsService.probe(root: url, fileExtension: fileExtension(for: config.kind))
            newDiagnostics[config.id] = probe
        }
        
        await MainActor.run {
            diagnostics = newDiagnostics
        }
    }
    
    private func fileExtension(for kind: SessionSource.Kind) -> String {
        switch kind {
        case .codex, .claude: return "jsonl"
        case .gemini: return "json"
        }
    }
}

// MARK: - Add Session Path Sheet

struct AddSessionPathSheet: View {
    @Binding var selectedKind: SessionSource.Kind
    @ObservedObject var preferences: SessionPreferencesStore
    let fixedKind: SessionSource.Kind?
    let onAdd: (SessionSource.Kind, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPath: String = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add Custom Session Path")
                .font(.title2)
                .fontWeight(.bold)
            
            if fixedKind == nil {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Type")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Picker("", selection: $selectedKind) {
                        Text("Codex").tag(SessionSource.Kind.codex)
                        Text("Claude").tag(SessionSource.Kind.claude)
                        Text("Gemini").tag(SessionSource.Kind.gemini)
                    }
                    .pickerStyle(.segmented)
                }
            }
            
            VStack(alignment: .leading, spacing: 12) {
                Text("Path")
                    .font(.subheadline)
                    .fontWeight(.medium)
                HStack {
                    TextField("Select directory...", text: $selectedPath)
                        .textFieldStyle(.roundedBorder)
                        .disabled(true)
                    Button("Choose...") {
                        selectDirectory()
                    }
                    .buttonStyle(.bordered)
                }
            }
            
            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                Button("Add") {
                    guard !selectedPath.isEmpty else { return }
                    onAdd(selectedKind, selectedPath)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedPath.isEmpty || !preferences.isCLIEnabled(selectedKind))
            }
        }
        .padding(20)
        .frame(width: 500)
    }
    
    private func selectDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        
        if panel.runModal() == .OK, let url = panel.url {
            selectedPath = url.path
        }
    }
}

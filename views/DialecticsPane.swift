import SwiftUI
import AppKit

@available(macOS 15.0, *)
struct DialecticsPane: View {
    @ObservedObject var preferences: SessionPreferencesStore
    @StateObject private var vm = DialecticsVM()
    @StateObject private var permissionsManager = SandboxPermissionsManager.shared
    @EnvironmentObject private var listViewModel: SessionListViewModel
    @State private var ripgrepReport: SessionRipgrepStore.Diagnostics?
    @State private var ripgrepLoading = false
    @State private var ripgrepRebuilding = false
    @State private var sessionIndexRebuilding = false
    @State private var activeRebuildAlert: RebuildAlert?

    enum RebuildAlert: Identifiable {
        case ripgrepCoverage
        case sessionIndex

        var id: String {
            switch self {
            case .ripgrepCoverage: return "ripgrepCoverage"
            case .sessionIndex: return "sessionIndex"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Dialectics")
                            .font(.title2)
                            .fontWeight(.bold)
                        Text("Deep diagnostics for sessions, providers, and environment")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button {
                        Task { await vm.runAll(preferences: preferences) }
                    } label: {
                        Label("Run Diagnostics", systemImage: "stethoscope")
                    }
                    .buttonStyle(.bordered)
                    Button {
                        vm.saveReport(preferences: preferences)
                    } label: {
                        Label("Save Report…", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                }

                // App & OS
                VStack(alignment: .leading, spacing: 10) {
                    Text("Environment").font(.headline).fontWeight(.semibold)
                    settingsCard {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Text("App Version").font(.subheadline)
                            Text(vm.appVersion).frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        GridRow {
                            Text("Build Time").font(.subheadline)
                            Text(vm.buildTime).frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        GridRow {
                            Text("macOS").font(.subheadline)
                            Text(vm.osVersion).frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        GridRow {
                            Text("App Sandbox").font(.subheadline)
                            Text(vm.sandboxOn ? "On" : "Off")
                                .foregroundStyle(vm.sandboxOn ? .green : .secondary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Ripgrep Indexes").font(.headline).fontWeight(.semibold)
                    settingsCard {
                        if let report = ripgrepReport {
                            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                                gridRow(label: "Cached Coverage Entries", value: "\(report.cachedCoverageEntries)")
                                gridRow(label: "Cached Tool Entries", value: "\(report.cachedToolEntries)")
                                gridRow(label: "Cached Token Entries", value: "\(report.cachedTokenEntries)")
                                gridRow(label: "Last Coverage Scan", value: timestampLabel(report.lastCoverageScan))
                                gridRow(label: "Last Tool Scan", value: timestampLabel(report.lastToolScan))
                                gridRow(label: "Last Token Scan", value: timestampLabel(report.lastTokenScan))
                            }
                        } else {
                            Text("Ripgrep stats not loaded yet.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Divider()
                        HStack(spacing: 12) {
                            Button {
                                Task { await refreshRipgrepDiagnostics() }
                            } label: {
                                Label("Refresh Ripgrep Stats", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)
                            .disabled(ripgrepLoading || ripgrepRebuilding || sessionIndexRebuilding)
                            if ripgrepLoading || ripgrepRebuilding || sessionIndexRebuilding {
                                ProgressView().controlSize(.small)
                            }
                            Button {
                                activeRebuildAlert = .ripgrepCoverage
                            } label: {
                                Label("Rebuild Coverage", systemImage: "hammer")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            .disabled(ripgrepRebuilding || sessionIndexRebuilding)

                            Button {
                                activeRebuildAlert = .sessionIndex
                            } label: {
                                Label("Rebuild Session Index", systemImage: "arrow.counterclockwise.circle")
                            }
                            .buttonStyle(.bordered)
                            .tint(.orange)
                            .disabled(sessionIndexRebuilding || ripgrepRebuilding)
                        }
                    }
                }

                // Sandbox Permissions (only show if sandboxed and missing permissions)
                if vm.sandboxOn && permissionsManager.needsAuthorization {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Directory Access Required")
                                .font(.headline)
                                .fontWeight(.semibold)
                        }

                        settingsCard {
                            VStack(alignment: .leading, spacing: 16) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("CodMate needs access to the following directories to function properly:")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)

                                    // Show actual resolved paths for debugging
                                    if vm.sandboxOn {
                                        Text("Note: These are the real user directories, not sandbox container paths.")
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                            .padding(.vertical, 4)
                                    }
                                }

                                ForEach(permissionsManager.missingPermissions) { directory in
                                    HStack(spacing: 12) {
                                        Image(systemName: permissionsManager.hasPermission(for: directory) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(permissionsManager.hasPermission(for: directory) ? .green : .secondary)
                                            .font(.system(size: 16))

                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(directory.displayName)
                                                .font(.subheadline)
                                                .fontWeight(.medium)
                                            Text(directory.description)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            Text(directory.rawValue)
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                                .monospaced()
                                        }

                                        Spacer()

                                        if !permissionsManager.hasPermission(for: directory) {
                                            Button {
                                                Task {
                                                    let granted = await permissionsManager.requestPermission(for: directory)
                                                    if granted {
                                                        permissionsManager.checkPermissions()
                                                    }
                                                }
                                            } label: {
                                                Text("Grant Access")
                                                    .font(.caption)
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .controlSize(.small)
                                        }
                                    }
                                    .padding(.vertical, 8)
                                }

                                Divider()

                                HStack {
                                    Text("Click \"Grant Access\" to select each directory when prompted.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    Spacer()

                                    Button {
                                        Task {
                                            _ = await permissionsManager.requestAllMissingPermissions()
                                        }
                                    } label: {
                                        Text("Grant All Access")
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                }
                            }
                            .padding(.vertical, 8)
                        }
                    }
                }

                // Codex sessions diagnostics
                VStack(alignment: .leading, spacing: 10) {
                    Text("Codex Sessions Root").font(.headline).fontWeight(.semibold)
                    if let s = vm.sessions {
                        settingsCard {
                            DiagnosticsReportView(result: s)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    } else {
                        Text("No data yet. Click Run Diagnostics.").font(.caption).foregroundStyle(
                            .secondary)
                    }
                }

                // Claude sessions diagnostics (moved above Notes)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Claude Sessions Directory").font(.headline).fontWeight(.semibold)
                    if let s = vm.sessions {
                        settingsCard {
                            if let cc = s.claudeCurrent {
                                DataPairReportView(current: cc, defaultProbe: s.claudeDefault)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                            } else {
                                DataPairReportView(current: s.claudeDefault, defaultProbe: s.claudeDefault)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                        }
                    } else {
                        Text("No data yet. Click Run Diagnostics.").font(.caption).foregroundStyle(.secondary)
                    }
                }

                // Notes diagnostics
                VStack(alignment: .leading, spacing: 10) {
                    Text("Notes Directory").font(.headline).fontWeight(.semibold)
                    if let s = vm.sessions {
                        settingsCard {
                            DataPairReportView(current: s.notesCurrent, defaultProbe: s.notesDefault)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    } else {
                        Text("No data yet. Click Run Diagnostics.").font(.caption).foregroundStyle(.secondary)
                    }
                }

                // Projects diagnostics
                VStack(alignment: .leading, spacing: 10) {
                    Text("Projects Directory").font(.headline).fontWeight(.semibold)
                    if let s = vm.sessions {
                        settingsCard {
                            DataPairReportView(current: s.projectsCurrent, defaultProbe: s.projectsDefault)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    } else {
                        Text("No data yet. Click Run Diagnostics.").font(.caption).foregroundStyle(.secondary)
                    }
                }


                // CLI diagnostics
                VStack(alignment: .leading, spacing: 10) {
                    Text("CLI & PATH").font(.headline).fontWeight(.semibold)
                    settingsCard {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Text("codex on PATH").font(.subheadline)
                            Text(vm.codexPresent ? (vm.codexVersion ?? "Yes") : "N/A")
                                .font(.caption)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        GridRow {
                            Text("claude on PATH").font(.subheadline)
                            Text(vm.claudePresent ? (vm.claudeVersion ?? "Yes") : "N/A")
                                .font(.caption)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        GridRow {
                            Text("PATH").font(.subheadline)
                            Text(vm.pathEnv).font(.caption).lineLimit(2).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        }
                    }
                }

                // Removed: Authorization Shortcuts — unify to on-demand authorization in context
            }
            .task { await vm.runAll(preferences: preferences) }
            .task { await refreshRipgrepDiagnostics() }
            .alert(item: $activeRebuildAlert) { alert in
            switch alert {
            case .ripgrepCoverage:
                return Alert(
                    title: Text("Rebuild Ripgrep Coverage?"),
                    message: Text(
                        "This will clear all cached ripgrep coverage, tool, and token indexes and recompute them from your current Codex and Claude session logs. It may temporarily increase CPU usage, but it does not modify any session files, notes, or projects."
                    ),
                    primaryButton: .destructive(Text("Rebuild")) {
                        Task { await rebuildRipgrepIndexes() }
                    },
                    secondaryButton: .cancel()
                )
            case .sessionIndex:
                return Alert(
                    title: Text("Rebuild Session Index?"),
                    message: Text(
                        "This will clear in-memory and on-disk session index caches and rebuild them by re-parsing all session JSONL files under the configured sessions root. It may take time for large histories but does not delete or change any session logs, notes, or projects. Use this if timestamps or statistics look incorrect after changing how sessions are indexed."
                    ),
                    primaryButton: .destructive(Text("Rebuild")) {
                        Task { await rebuildSessionIndex() }
                    },
                    secondaryButton: .cancel()
                )
            }
        }
    }

    // Helper function to create settings card
    @ViewBuilder
    private func settingsCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .padding(10)
        .background(Color(nsColor: .separatorColor).opacity(0.35))
        .cornerRadius(10)
    }
}

@available(macOS 15.0, *)
extension DialecticsPane {
    private func authorizeFolder(_ suggested: URL) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = suggested
        panel.message = "Authorize this folder for sandboxed access"
        panel.prompt = "Authorize"
        panel.begin { resp in
            if resp == .OK, let url = panel.url {
                SecurityScopedBookmarks.shared.saveDynamic(url: url)
                NotificationCenter.default.post(name: .codMateRepoAuthorizationChanged, object: nil)
            }
        }
    }

    @ViewBuilder
    private func gridRow(label: String, value: String) -> some View {
        GridRow {
            Text(label).font(.subheadline)
            Text(value)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func timestampLabel(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func refreshRipgrepDiagnostics() async {
        await MainActor.run { ripgrepLoading = true }
        let report = await listViewModel.ripgrepDiagnostics()
        await MainActor.run {
            ripgrepReport = report
            ripgrepLoading = false
        }
    }

    private func rebuildRipgrepIndexes() async {
        await MainActor.run { ripgrepRebuilding = true }
        await listViewModel.rebuildRipgrepIndexes()
        await refreshRipgrepDiagnostics()
        await MainActor.run { ripgrepRebuilding = false }
    }

    private func rebuildSessionIndex() async {
        await MainActor.run { sessionIndexRebuilding = true }
        await listViewModel.rebuildSessionIndex()
        await refreshRipgrepDiagnostics()
        await MainActor.run { sessionIndexRebuilding = false }
    }
}

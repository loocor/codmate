import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SessionDetailView: View {
    let summary: SessionSummary
    let isProcessing: Bool
    let onResume: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void
    @Binding var columnVisibility: NavigationSplitViewVisibility

    @EnvironmentObject private var viewModel: SessionListViewModel
    @ObservedObject var preferences: SessionPreferencesStore
    @State private var turns: [ConversationTurn] = []  // filtered + sorted for display
    @State private var allTurns: [ConversationTurn] = []  // raw full timeline
    @State private var loadingTimeline = false
    @State private var isConversationExpanded = false
    @State private var expandedTurnIDs: Set<String> = []
    @State private var autoExpandVisible = false
    @State private var searchText: String = ""
    @State private var expandAllOnSearch = false
    @State private var nowModeEnabled = true  // Auto-scroll to bottom when enabled
    @State private var timelineRefreshToken = 0
    @State private var lastLocalChangeAt: Date? = nil
    @State private var localActivityClearTask: Task<Void, Never>? = nil
    @State private var inlineFiltersExpanded = false
    @State private var sessionVisibleKinds: Set<MessageVisibilityKind> = MessageVisibilityKind.timelineDefault
    @State private var hasSessionVisibleKindsOverride = false
    @Environment(\.openWindow) private var openWindow
    @State private var monitor: DirectoryMonitor? = nil
    @State private var debounceReloadTask: Task<Void, Never>? = nil
    @State private var filterTask: Task<Void, Never>? = nil
    @State private var loadTask: Task<[ConversationTurn], Never>? = nil
    @State private var environmentExpanded = false
    @State private var environmentLoading = false
    @State private var environmentInfo: EnvironmentContextInfo?
    private let loader = SessionTimelineLoader()

    // Three-stage loading support
    @State private var previewTurns: [ConversationTurnPreview] = []
    @State private var loadingStage: LoadingStage = .initial

    enum LoadingStage {
        case initial      // Not started
        case preview      // Showing preview from cache
        case loading      // Loading full data
        case full         // Full data loaded
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 16) {
                if !isConversationExpanded {
                    sessionInfoCard
                    environmentSection
                    instructionsSection
                    Divider()
                }

                conversationHeader
                if inlineFiltersExpanded {
                    inlineFiltersPanel
                }
                conversationScrollView
            }
            .padding(16)
            .frame(
                width: proxy.size.width,
                height: proxy.size.height,
                alignment: .topLeading
            )
        }
        .task(id: summary.id) { await initialLoadAndMonitor() }
        .onChange(of: searchText, initial: true) { _ in applyFilterAndSort() }
        .onChange(of: preferences.timelineVisibleKinds, initial: true) { newValue in
            guard !hasSessionVisibleKindsOverride else { return }
            sessionVisibleKinds = newValue
            applyFilterAndSort()
        }
        .onReceive(NotificationCenter.default.publisher(for: .codMateConversationFilter)) { note in
            guard let target = note.userInfo?["sessionId"] as? String, target == summary.id else { return }
            guard let term = note.userInfo?["term"] as? String else { return }
            DispatchQueue.main.async {
                searchText = term
                expandAllOnSearch = false
            }
        }
    }

    // moved actions to fixed top bar

    private var sessionInfoCard: some View {
        GroupBox {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), alignment: .topLeading),
                    GridItem(.flexible(), alignment: .topLeading),
                    GridItem(.flexible(), alignment: .topLeading),
                    GridItem(.flexible(), alignment: .topLeading),
                ], spacing: 12
            ) {
                infoRow(
                    title: "STARTED",
                    value: summary.startedAt.formatted(date: .numeric, time: .shortened),
                    icon: "calendar")
                infoRow(title: "DURATION", value: summary.readableDuration, icon: "clock")

                if let model = summary.displayModel ?? summary.model {
                    infoRow(title: "MODEL", value: model, icon: "cpu")
                }
                if let approval = summary.approvalPolicy {
                    infoRow(title: "APPROVAL", value: approval, icon: "checkmark.shield")
                }

                infoRow(title: "CLI VERSION", value: summary.cliVersion, icon: "terminal")
                infoRow(title: "ORIGINATOR", value: summary.originator, icon: "person.circle")

                infoRow(
                    title: "WORKING DIRECTORY",
                    value: viewModel.displayWorkingDirectory(for: summary),
                    icon: "folder")
                infoRow(title: "FILE SIZE", value: summary.fileSizeDisplay, icon: "externaldrive")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // metrics moved to list row per request

    private func infoRow(title: String, value: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.body)
            }
        }
    }

    

    @State private var instructionsExpanded = false
    @State private var instructionsLoading = false
    @State private var instructionsText: String?

    private var environmentSection: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $environmentExpanded) {
                Group {
                    if environmentLoading {
                        ProgressView("Loading environment context…")
                    } else if let info = environmentInfo, info.hasContent {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(info.entries) { entry in
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(entry.key.uppercased())
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 120, alignment: .trailing)
                                    Text(entry.value)
                                        .font(.body)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            if let raw = info.rawText, !raw.isEmpty, info.entries.isEmpty {
                                Text(raw)
                                    .font(.body)
                                    .textSelection(.enabled)
                            }
                            Text(
                                "Captured · \(info.timestamp.formatted(date: .abbreviated, time: .shortened))"
                            )
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                    } else {
                        Text("No environment context captured.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .task(id: environmentExpanded) {
                    guard environmentExpanded else { return }
                    guard !summary.source.isRemote else {
                        environmentInfo = nil
                        environmentLoading = false
                        return
                    }
                    guard environmentInfo == nil else { return }
                    environmentLoading = true
                    defer { environmentLoading = false }

                    // Load environment context based on source type
                    if summary.source.baseKind == .gemini {
                        environmentInfo = await viewModel.geminiProvider.environmentContext(for: summary)
                    } else if summary.source.baseKind == .claude {
                        // Claude sessions can also benefit from the new method if needed
                        environmentInfo = try? loader.loadEnvironmentContext(url: summary.fileURL)
                    } else {
                        // Codex sessions use the file-based method
                        environmentInfo = try? loader.loadEnvironmentContext(url: summary.fileURL)
                    }
                }
            } label: {
                Label("Environment Context", systemImage: "macwindow")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { environmentExpanded.toggle() }
                    .hoverHand()
            }
        }
    }

    private var instructionsSection: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $instructionsExpanded) {
                Group {
                    if instructionsLoading {
                        ProgressView("Loading instructions…")
                    } else if let text = instructionsText ?? summary.instructions, !text.isEmpty {
                        Text(text)
                            .font(.system(.body, design: .rounded))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 2)
                    } else {
                        Text("No instructions found.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .task(id: instructionsExpanded) {
                    guard instructionsExpanded else { return }
                    guard instructionsText == nil else { return }

                    if let cached = await viewModel.cachedInstructions(for: summary), !cached.isEmpty {
                        instructionsText = cached
                        return
                    }

                    guard !summary.source.isRemote else {
                        instructionsLoading = false
                        return
                    }

                    instructionsLoading = true
                    defer { instructionsLoading = false }
                    if let loaded = try? loader.loadInstructions(url: summary.fileURL) {
                        instructionsText = loaded
                    }
                }
            } label: {
                Label("Task Instructions", systemImage: "list.bullet.rectangle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { instructionsExpanded.toggle() }
                    .hoverHand()
            }
        }
    }

    private var conversationHeader: some View {
        HStack(spacing: 12) {
            Label("Conversation", systemImage: "bubble.left.and.text.bubble.right")
                .font(.headline)

            Spacer()

            // Search (inline magnifier and clear button, custom style for compatibility)
            conversationSearchField

            Button {
                openWindow(id: "settings")
            } label: {
                Label(
                    "Filters",
                    systemImage: "line.3.horizontal.decrease.circle"
                )
                .font(.callout)
            }
            .buttonStyle(.borderless)
            .help("Open Settings to configure message type filters")
            .hoverHand()

            // Now mode toggle (mimics Console.app)
            Button {
                nowModeEnabled.toggle()
            } label: {
                Label {
                    Text("Now")
                } icon: {
                    ZStack {
                        // Background circle
                        Circle()
                            .fill(nowModeEnabled ? Color.primary : Color.clear)
                            .frame(width: 14, height: 14)

                        // Border circle (only visible when disabled)
                        if !nowModeEnabled {
                            Circle()
                                .strokeBorder(Color.primary, lineWidth: 1.5)
                                .frame(width: 14, height: 14)
                        }

                        // Arrow icon
                        Image(systemName: "arrow.up.backward")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(nowModeEnabled ? Color(nsColor: .controlBackgroundColor) : Color.primary)
                    }
                }
                .font(.callout)
            }
            .buttonStyle(.borderless)
            .help(nowModeEnabled ? "Auto-scroll to latest (Now mode enabled)" : "Enable auto-scroll to latest")
            .hoverHand()

            Button {
                autoExpandVisible.toggle()
                expandedTurnIDs.removeAll()
            } label: {
                Label(
                    autoExpandVisible ? "Collapse Visible" : "Expand Visible",
                    systemImage: autoExpandVisible ? "rectangle.compress.vertical" : "rectangle.expand.vertical"
                )
                .font(.callout)
            }
            .buttonStyle(.borderless)
            .disabled(turns.isEmpty)
            .help(autoExpandVisible ? "Collapse visible turns" : "Expand only visible turns")
            .hoverHand()

            // Refresh current conversation file (match borderless style for consistency)
            Button {
                Task { await reloadConversation() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.callout)
            }
            .buttonStyle(.borderless)
            .help("Reload latest records from this session file")
            .hoverHand()

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    // Expand/collapse conversation without altering sidebar visibility
                    isConversationExpanded.toggle()
                }
            } label: {
                Image(
                    systemName: isConversationExpanded
                        ? "arrow.up.right.and.arrow.down.left"  // show Restore icon
                        : "arrow.down.left.and.arrow.up.right"  // show Expand icon
                )
                .font(.body)
            }
            .buttonStyle(.borderless)
            .help(isConversationExpanded ? "Restore layout" : "Expand conversation")
            .hoverHand()
        }
    }

    private var conversationScrollView: some View {
        Group {
            switch loadingStage {
            case .initial, .loading:
                ScrollView {
                    ProgressView("Loading session content…")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 32)
                }

            case .preview:
                ScrollView {
                    if previewTurns.isEmpty {
                        ProgressView("Loading preview…")
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 32)
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(previewTurns) { preview in
                                ConversationTurnPreviewCard(preview: preview, branding: summary.source.branding)
                            }
                        }
                        .opacity(0.85)  // Visual hint that this is preview data
                    }
                }

            case .full:
                if turns.isEmpty {
                    Group {
                        if #available(macOS 14.0, *) {
                            ContentUnavailableView("No messages to display", systemImage: "text.bubble")
                        } else {
                            UnavailableStateView(
                                "No messages to display",
                                systemImage: "text.bubble",
                                imageFont: .title3,
                                titleFont: .headline
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    ConversationTimelineView(
                        turns: turns,
                        expandedTurnIDs: $expandedTurnIDs,
                        refreshToken: timelineRefreshToken,
                        ascending: true,  // Fixed: oldest first (newest at bottom)
                        branding: summary.source.branding,
                        allowManualToggle: !autoExpandVisible,
                        autoExpandVisible: autoExpandVisible,
                        isActive: isConversationActive,
                        nowModeEnabled: nowModeEnabled,
                        onNowModeChange: { newValue in
                            nowModeEnabled = newValue
                        }
                    )
                    .id(autoExpandVisible)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

// MARK: - Export
extension SessionDetailView {
    // Custom search field to ensure macOS compatibility
    private var conversationSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            TextField("Filter in conversation", text: $searchText)
                .textFieldStyle(.plain)
                .frame(minWidth: 160)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .hoverHand()
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )
        )
        .frame(minWidth: 220)
    }

    private var inlineFiltersPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Message Type", systemImage: "line.3.horizontal.decrease.circle")
                    .font(.headline)
                Spacer()
                if hasSessionVisibleKindsOverride {
                    Button("Reset") { resetInlineFilters() }
                        .buttonStyle(.borderless)
                        .help("Reset to global defaults and clear session overrides")
                }
            }

            ForEach(visibilityGroups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: filterColumns, alignment: .leading, spacing: 8) {
                        ForEach(group.items, id: \.kind) { item in
                            FilterToggleRow(
                                title: item.title,
                                isOn: visibilityBinding(for: item.kind)
                            )
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
        )
        .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 4)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private struct VisibilityGroup {
        let title: String
        let items: [VisibilityItem]
    }

    private struct VisibilityItem: Hashable {
        let kind: MessageVisibilityKind
        let title: String
    }

    private struct FilterToggleRow: View {
        let title: String
        @Binding var isOn: Bool

        var body: some View {
            HStack(spacing: 8) {
                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.primary)
            }
        }
    }

    private var filterColumns: [GridItem] {
        [
            GridItem(.flexible(minimum: 120), spacing: 12, alignment: .leading),
            GridItem(.flexible(minimum: 120), spacing: 12, alignment: .leading),
            GridItem(.flexible(minimum: 120), spacing: 12, alignment: .leading),
            GridItem(.flexible(minimum: 120), spacing: 12, alignment: .leading)
        ]
    }

    private var visibilityGroups: [VisibilityGroup] {
        [
            VisibilityGroup(title: "Core", items: [
                VisibilityItem(kind: .user, title: MessageVisibilityKind.user.settingsLabel),
                VisibilityItem(kind: .assistant, title: MessageVisibilityKind.assistant.settingsLabel)
            ]),
            VisibilityGroup(title: "Reasoning & Edits", items: [
                VisibilityItem(kind: .reasoning, title: MessageVisibilityKind.reasoning.settingsLabel),
                VisibilityItem(kind: .codeEdit, title: MessageVisibilityKind.codeEdit.settingsLabel)
            ]),
            VisibilityGroup(title: "Tools & Tokens", items: [
                VisibilityItem(kind: .tool, title: MessageVisibilityKind.tool.settingsLabel),
                VisibilityItem(kind: .tokenUsage, title: MessageVisibilityKind.tokenUsage.settingsLabel)
            ]),
            VisibilityGroup(title: "Other Info", items: [
                VisibilityItem(kind: .infoOther, title: MessageVisibilityKind.infoOther.settingsLabel)
            ])
        ]
    }

    private func visibilityBinding(for kind: MessageVisibilityKind) -> Binding<Bool> {
        Binding(
            get: { sessionVisibleKinds.contains(kind) },
            set: { isOn in
                if isOn {
                    sessionVisibleKinds.insert(kind)
                } else {
                    sessionVisibleKinds.remove(kind)
                }
                hasSessionVisibleKindsOverride = true
                Task { await viewModel.updateTimelineVisibleKindsOverride(for: summary.id, kinds: sessionVisibleKinds) }
                applyFilterAndSort()
            }
        )
    }

    private func resetInlineFilters() {
        hasSessionVisibleKindsOverride = false
        sessionVisibleKinds = preferences.timelineVisibleKinds
        Task { await viewModel.clearTimelineVisibleKindsOverride(for: summary.id) }
        applyFilterAndSort()
    }

    // MARK: - Loading helpers
    private func initialLoadAndMonitor() async {
        let override = viewModel.timelineVisibleKindsOverride(for: summary.id)
        sessionVisibleKinds = override ?? preferences.timelineVisibleKinds
        hasSessionVisibleKindsOverride = override != nil
        autoExpandVisible = false
        expandedTurnIDs.removeAll()
        lastLocalChangeAt = nil
        localActivityClearTask?.cancel()

        // Stage 1: Try to load previews from cache (fast path)
        if let previews = await viewModel.loadTimelinePreviews(for: summary) {
            await MainActor.run {
                previewTurns = previews
                loadingStage = .preview
            }
        }

        // Stage 2: Load full timeline in background
        await reloadConversation(resetUI: true)

        // Configure file monitor for live reload
        monitor?.cancel()
        monitor = DirectoryMonitor(url: summary.fileURL) { [fileURL = summary.fileURL] in
            // Debounce rapid write events
            debounceReloadTask?.cancel()
            debounceReloadTask = Task { @MainActor in
                let activityStamp = Date()
                markLocalActivity(activityStamp)
                try? await Task.sleep(nanoseconds: 300_000_000)  // 300ms
                // Confirm file still the same session file
                guard fileURL == summary.fileURL else { return }
                await reloadConversation()
            }
        }
    }

    @MainActor
    private func reloadConversation(resetUI: Bool = false) async {
        loadingTimeline = true
        if loadingStage == .initial {
            loadingStage = .loading
        }
        defer { loadingTimeline = false }

        loadTask?.cancel()

        if let cached = await viewModel.cachedTimeline(for: summary) {
            allTurns = cached
            loadingStage = .full
            if resetUI {
                expandedTurnIDs = []
                environmentExpanded = false
                environmentInfo = nil
                environmentLoading = false
            }
            applyFilterAndSort(markRefresh: true)
            return
        }

        let shouldLoadDirectlyFromFile = summary.source.baseKind == .codex && !summary.source.isRemote
        let loaded: [ConversationTurn]
        if shouldLoadDirectlyFromFile {
            let fileURL = summary.fileURL
            let task: Task<[ConversationTurn], Never> = Task.detached(priority: .userInitiated) {
                if Task.isCancelled { return [] }
                let loader = SessionTimelineLoader()
                return (try? loader.load(url: fileURL)) ?? []
            }
            loadTask = task
            loaded = await task.value
        } else {
            loaded = await viewModel.timeline(for: summary)
        }

        loadTask = nil
        allTurns = loaded
        loadingStage = .full

        if resetUI {
            expandedTurnIDs = []
            environmentExpanded = false
            environmentInfo = nil
            environmentLoading = false
        }

        applyFilterAndSort(markRefresh: true)

        if !loaded.isEmpty {
            Task {
                await viewModel.storeTimeline(loaded, for: summary)
                await viewModel.updateTimelinePreviews(for: summary, turns: loaded)
            }
        }
    }

    @MainActor
    private func applyFilterAndSort(markRefresh: Bool = false) {
        filterTask?.cancel()
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let all = allTurns
        let kinds = effectiveVisibleKinds
        let expandOnSearch = expandAllOnSearch
        let shouldMarkRefresh = markRefresh

        filterTask = Task.detached(priority: .userInitiated) {
            var filtered = all
            if !term.isEmpty {
                filtered = filtered.filter { turn in
                    containsTerm(turn, term: term)
                }
            }
            filtered = filtered.filtering(visibleKinds: kinds)
            // Fixed: always sort oldest first (newest at bottom)
            filtered.sort { a, b in a.timestamp < b.timestamp }
            let result = filtered
            await MainActor.run {
                turns = result
                if expandOnSearch {
                    autoExpandVisible = true
                    expandedTurnIDs.removeAll()
                    expandAllOnSearch = false
                }
                if shouldMarkRefresh {
                    timelineRefreshToken &+= 1
                }
            }
        }
    }

    private var isConversationActive: Bool {
        viewModel.isActivelyUpdating(summary.id) || isLocallyActive
    }

    private var isLocallyActive: Bool {
        guard let lastLocalChangeAt else { return false }
        return Date().timeIntervalSince(lastLocalChangeAt) < 3.0
    }

    private func markLocalActivity(_ stamp: Date) {
        lastLocalChangeAt = stamp
        localActivityClearTask?.cancel()
        localActivityClearTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            if lastLocalChangeAt == stamp {
                lastLocalChangeAt = nil
            }
        }
    }

    private var effectiveVisibleKinds: Set<MessageVisibilityKind> {
        if hasSessionVisibleKindsOverride {
            return sessionVisibleKinds
                .intersection(preferences.timelineVisibleKinds)
                .subtracting([.turnContext])
        }
        return preferences.timelineVisibleKinds.subtracting([.turnContext])
    }

    private func exportMarkdown() {
        let panel = NSSavePanel()
        panel.title = "Export Markdown"
        panel.allowedContentTypes = [.plainText]
        let base = sanitizedExportFileName(summary.effectiveTitle, fallback: summary.displayName)
        panel.nameFieldStringValue = base + ".md"
        if panel.runModal() == .OK, let url = panel.url {
            let md = MarkdownExportBuilder.build(
                session: summary,
                turns: allTurns,
                visibleKinds: preferences.markdownVisibleKinds,
                exportURL: url
            )
            try? md.data(using: String.Encoding.utf8)?.write(to: url)
        }
    }

}

// MARK: - Helpers
private func containsTerm(_ turn: ConversationTurn, term: String) -> Bool {
    func contains(_ s: String?) -> Bool { (s ?? "").lowercased().contains(term) }
    if contains(turn.userMessage?.text) { return true }
    for e in turn.outputs {
        if contains(e.title) || contains(e.text) { return true }
        if let md = e.metadata,
           md.values.contains(where: { $0.lowercased().contains(term) }) {
            return true
        }
    }
    return false
}

private func sanitizedExportFileName(_ s: String, fallback: String, maxLength: Int = 120) -> String
{
    var text = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { return fallback }
    let disallowed = CharacterSet(charactersIn: "/:")
        .union(.newlines)
        .union(.controlCharacters)
    text = text.unicodeScalars.map { disallowed.contains($0) ? Character(" ") : Character($0) }
        .reduce(into: String(), { $0.append($1) })
    while text.contains("  ") { text = text.replacingOccurrences(of: "  ", with: " ") }
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { text = fallback }
    if text.count > maxLength {
        let idx = text.index(text.startIndex, offsetBy: maxLength)
        text = String(text[..<idx])
    }
    return text
}

#if DEBUG
private struct SessionDetailPreviewContainer: View {
    @State private var visibility: NavigationSplitViewVisibility = .all
    let summary: SessionSummary
    let isProcessing: Bool

    var body: some View {
        SessionDetailView(
            summary: summary,
            isProcessing: isProcessing,
            onResume: { print("Resume session") },
            onReveal: { print("Reveal in Finder") },
            onDelete: { print("Delete session") },
            columnVisibility: $visibility,
            preferences: SessionPreferencesStore()
        )
    }
}

#Preview {
    // Mock SessionSummary data
    let mockSummary = SessionSummary(
        id: "session-123",
        fileURL: URL(fileURLWithPath: "/Users/developer/.codex/sessions/session-123.json"),
        fileSizeBytes: 15420,
        startedAt: Date().addingTimeInterval(-3600),  // 1 hour ago
        endedAt: Date().addingTimeInterval(-1800),  // 30 minutes ago
        activeDuration: nil,
        cliVersion: "1.2.3",
        cwd: "/Users/developer/projects/codmate",
        originator: "developer",
        instructions:
            "Please help optimize this SwiftUI app's performance, especially list scroll stutter.",
        model: "gpt-4o-mini",
        approvalPolicy: "auto",
        userMessageCount: 5,
        assistantMessageCount: 4,
        toolInvocationCount: 3,
        responseCounts: ["reasoning": 2],
        turnContextCount: 8,
        totalTokens: 1200,
        eventCount: 12,
        lineCount: 156,
        lastUpdatedAt: Date().addingTimeInterval(-1800),
        source: .codexLocal,
        remotePath: nil
    )

    SessionDetailPreviewContainer(summary: mockSummary, isProcessing: false)
        .frame(width: 600, height: 800)
}
#endif

// MARK: - Preview Card Component

/// Lightweight preview card for conversation turns, shown during initial loading
private struct ConversationTurnPreviewCard: View {
    let preview: ConversationTurnPreview
    let branding: SessionSourceBranding

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: timestamp and metadata badges
            HStack(spacing: 8) {
                Text(preview.timestamp, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if preview.hasToolCalls {
                    Label("Tools", systemImage: "hammer.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .labelStyle(.iconOnly)
                }

                if preview.hasThinking {
                    Label(MessageVisibilityKind.reasoning.settingsLabel, systemImage: "brain")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .labelStyle(.iconOnly)
                }

                Text("\(preview.outputCount) output\(preview.outputCount == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Spacer()
            }

            // User message preview
            if let userPreview = preview.userPreview {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "person.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(userPreview)
                        .font(.callout)
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                }
            }

            // Assistant/output preview
            if let outputsPreview = preview.outputsPreview {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: branding.symbolName)
                        .font(.caption)
                        .foregroundStyle(branding.iconColor)

                    Text(outputsPreview)
                        .font(.callout)
                        .lineLimit(2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
    }
}

#if DEBUG
#Preview("Processing State") {
    let mockSummary = SessionSummary(
        id: "session-456",
        fileURL: URL(fileURLWithPath: "/Users/developer/.codex/sessions/session-456.json"),
        fileSizeBytes: 8200,
        startedAt: Date().addingTimeInterval(-7200),
        endedAt: nil,
        activeDuration: nil,
        cliVersion: "1.2.3",
        cwd: "/Users/developer/projects/test",
        originator: "developer",
        instructions: "Create a simple to-do app",
        model: "gpt-4o",
        approvalPolicy: "manual",
        userMessageCount: 3,
        assistantMessageCount: 2,
        toolInvocationCount: 1,
        responseCounts: [:],
        turnContextCount: 5,
        totalTokens: 650,
        eventCount: 6,
        lineCount: 89,
        lastUpdatedAt: Date().addingTimeInterval(-300),
        source: .codexLocal,
        remotePath: nil
    )

    SessionDetailPreviewContainer(summary: mockSummary, isProcessing: true)
        .frame(width: 600, height: 800)
}
#endif

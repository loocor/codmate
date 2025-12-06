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
    @State private var turns: [ConversationTurn] = []  // filtered + sorted for display
    @State private var allTurns: [ConversationTurn] = []  // raw full timeline
    @State private var loadingTimeline = false
    @State private var isConversationExpanded = false
    @State private var expandedTurnIDs: Set<String> = []
    @State private var searchText: String = ""
    @State private var expandAllOnSearch = false
    @State private var sortAscending: Bool = false
    @State private var monitor: DirectoryMonitor? = nil
    @State private var debounceReloadTask: Task<Void, Never>? = nil
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
        .onChange(of: searchText) { _, _ in applyFilterAndSort() }
        .onChange(of: sortAscending) { _, _ in applyFilterAndSort() }
        .onChange(of: viewModel.preferences.timelineVisibleKinds) { _, _ in
            // Re-apply current search + sort with new visibility
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
                    guard !summary.source.isRemote else {
                        instructionsText = nil
                        instructionsLoading = false
                        return
                    }
                    if instructionsText == nil
                        && (summary.instructions == nil || summary.instructions?.isEmpty == true)
                    {
                        instructionsLoading = true
                        defer { instructionsLoading = false }
                        if let loaded = try? loader.loadInstructions(url: summary.fileURL) {
                            instructionsText = loaded
                        }
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

            // Sort order toggle
            Button {
                sortAscending.toggle()
            } label: {
                Label(
                    sortAscending ? "Oldest First" : "Newest First",
                    systemImage: sortAscending ? "arrow.up" : "arrow.down"
                )
                .font(.callout)
            }
            .buttonStyle(.borderless)
            .help(sortAscending ? "Sort oldest → newest" : "Sort newest → oldest")
            .hoverHand()

            let allExpanded = !turns.isEmpty && expandedTurnIDs.count == turns.count
            Button {
                if allExpanded {
                    expandedTurnIDs.removeAll()
                } else {
                    expandedTurnIDs = Set(turns.map(\.id))
                }
            } label: {
                Label(
                    allExpanded ? "Collapse All" : "Expand All",
                    systemImage: allExpanded ? "chevron.up" : "chevron.down"
                )
                .font(.callout)
            }
            .buttonStyle(.borderless)
            .disabled(turns.isEmpty)
            .help(allExpanded ? "Collapse all turns" : "Expand all turns")
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
        ScrollView {
            Group {
                switch loadingStage {
                case .initial, .loading:
                    ProgressView("Loading session content…")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 32)

                case .preview:
                    // Show lightweight preview cards while loading full data
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

                case .full:
                    if turns.isEmpty {
                        ContentUnavailableView("No messages to display", systemImage: "text.bubble")
                            .frame(maxWidth: .infinity, alignment: .center)
                    } else {
                        ConversationTimelineView(
                            turns: turns,
                            expandedTurnIDs: $expandedTurnIDs,
                            ascending: sortAscending,
                            branding: summary.source.branding
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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

    // MARK: - Loading helpers
    private func initialLoadAndMonitor() async {
        // Stage 1: Try to load previews from cache (fast path)
        // TEMPORARILY DISABLED FOR PERFORMANCE TESTING
        // if let previews = await viewModel.loadTimelinePreviews(for: summary) {
        //     await MainActor.run {
        //         previewTurns = previews
        //         loadingStage = .preview
        //     }
        // }

        // Stage 2: Load full timeline in background
        await reloadConversation(resetUI: true)

        // Configure file monitor for live reload
        monitor?.cancel()
        monitor = DirectoryMonitor(url: summary.fileURL) { [fileURL = summary.fileURL] in
            // Debounce rapid write events
            debounceReloadTask?.cancel()
            debounceReloadTask = Task { @MainActor in
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
        loadingStage = .loading
        defer { loadingTimeline = false }

        let shouldLoadDirectlyFromFile = summary.source.baseKind == .codex && !summary.source.isRemote
        let loaded: [ConversationTurn]
        if shouldLoadDirectlyFromFile {
            loaded = (try? loader.load(url: summary.fileURL)) ?? []
        } else {
            loaded = await viewModel.timeline(for: summary)
        }

        allTurns = loaded
        loadingStage = .full

        if resetUI {
            expandedTurnIDs = []
            environmentExpanded = false
            environmentInfo = nil
            environmentLoading = false
        }

        applyFilterAndSort()

        // Stage 3: Update preview cache in background (async, non-blocking)
        // TEMPORARILY DISABLED FOR PERFORMANCE TESTING
        // if !loaded.isEmpty {
        //     Task {
        //         await viewModel.updateTimelinePreviews(for: summary, turns: loaded)
        //     }
        // }
    }

    @MainActor
    private func applyFilterAndSort() {
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered: [ConversationTurn]
        if term.isEmpty {
            filtered = allTurns
        } else {
            filtered = allTurns.filter { turn in
                func contains(_ s: String?) -> Bool { (s ?? "").lowercased().contains(term) }
                if contains(turn.userMessage?.text) { return true }
                for e in turn.outputs {
                    if contains(e.title) || contains(e.text) { return true }
                    if let md = e.metadata,
                        md.values.contains(where: { $0.lowercased().contains(term) })
                    {
                        return true
                    }
                }
                return false
            }
        }
        let sorted = filtered.sorted { a, b in
            sortAscending ? (a.timestamp < b.timestamp) : (a.timestamp > b.timestamp)
        }
        // Apply visibility filter for timeline display
        let kinds = viewModel.preferences.timelineVisibleKinds

        // Find the first Environment Context to exclude (already shown in dedicated section)
        let firstEnvContextID = findFirstEnvironmentContextID(in: sorted)

        turns = sorted.compactMap {
            filterTurn($0, visible: kinds, excludingFirstEnvContext: firstEnvContextID)
        }
        if expandAllOnSearch {
            expandedTurnIDs = Set(turns.map(\.id))
            expandAllOnSearch = false
        }
    }

    private func exportMarkdown() {
        let md = buildMarkdown()
        let panel = NSSavePanel()
        panel.title = "Export Markdown"
        panel.allowedContentTypes = [.plainText]
        let base = sanitizedExportFileName(summary.effectiveTitle, fallback: summary.displayName)
        panel.nameFieldStringValue = base + ".md"
        if panel.runModal() == .OK, let url = panel.url {
            try? md.data(using: .utf8)?.write(to: url)
        }
    }

    private func buildMarkdown() -> String {
        var lines: [String] = []
        lines.append("# \(summary.displayName)")
        lines.append("")
        lines.append("- Started: \(summary.startedAt)")
        if let end = summary.lastUpdatedAt { lines.append("- Last Updated: \(end)") }
        if let model = summary.displayModel ?? summary.model { lines.append("- Model: \(model)") }
        if let approval = summary.approvalPolicy { lines.append("- Approval Policy: \(approval)") }
        lines.append("")
        // Use full timeline, filtered by markdown preferences (independent of UI search)
        let kinds = viewModel.preferences.markdownVisibleKinds
        // Also exclude first Environment Context from export (already shown in header)
        let firstEnvContextID = findFirstEnvironmentContextID(in: allTurns)
        let exportTurns = allTurns.compactMap {
            filterTurn($0, visible: kinds, excludingFirstEnvContext: firstEnvContextID)
        }
        for turn in exportTurns {
            if let user = turn.userMessage {  // already filtered
                lines.append("**User** · \(user.timestamp)")
                if let text = user.text, !text.isEmpty { lines.append(text) }
            }
            let assistantLabel = summary.source.branding.displayName
            for event in turn.outputs {
                let prefix: String
                switch event.actor {
                case .assistant: prefix = "**\(assistantLabel)**"
                case .tool: prefix = "**Tool**"
                case .info: prefix = "**Info**"
                case .user: prefix = "**User**"
                }
                lines.append("")
                lines.append("\(prefix) · \(event.timestamp)")
                if let title = event.title { lines.append("> \(title)") }
                if let text = event.text, !text.isEmpty { lines.append(text) }
                if let meta = event.metadata, !meta.isEmpty {
                    for key in meta.keys.sorted() { lines.append("- \(key): \(meta[key] ?? "")") }
                }
                if event.repeatCount > 1 { lines.append("- repeated: ×\(event.repeatCount)") }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Visibility filtering helpers

    /// Finds the ID of the first Environment Context event in the timeline
    /// (to exclude it since it's already shown in the dedicated section above)
    private func findFirstEnvironmentContextID(in turns: [ConversationTurn]) -> String? {
        for turn in turns {
            // Check outputs for Environment Context or Context Updated (from turnContext)
            for output in turn.outputs {
                if output.title == TimelineEvent.environmentContextTitle || output.title == "Context Updated" {
                    return output.id
                }
            }
        }
        return nil
    }

    private func filterTurn(
        _ turn: ConversationTurn,
        visible: Set<MessageVisibilityKind>,
        excludingFirstEnvContext firstEnvContextID: String? = nil
    ) -> ConversationTurn? {
        let userAllowed = turn.userMessage.flatMap { visible.contains(event: $0) } ?? false
        let keptOutputs = turn.outputs.filter { output in
            // Always exclude the first Environment Context (shown in dedicated section)
            if let firstID = firstEnvContextID, output.id == firstID {
                return false
            }
            return visible.contains(event: output)
        }
        if !userAllowed && keptOutputs.isEmpty { return nil }
        return ConversationTurn(
            id: turn.id,
            timestamp: turn.timestamp,
            userMessage: userAllowed ? turn.userMessage : nil,
            outputs: keptOutputs
        )
    }
}

// MARK: - Helpers
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

#Preview {
    @Previewable @State var visibility: NavigationSplitViewVisibility = .all

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

    SessionDetailView(
        summary: mockSummary,
        isProcessing: false,
        onResume: { print("Resume session") },
        onReveal: { print("Reveal in Finder") },
        onDelete: { print("Delete session") },
        columnVisibility: $visibility
    )
    .frame(width: 600, height: 800)
}

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
                    Label("Thinking", systemImage: "brain")
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

#Preview("Processing State") {
    @Previewable @State var visibility: NavigationSplitViewVisibility = .all

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

    SessionDetailView(
        summary: mockSummary,
        isProcessing: true,
        onResume: { print("Resume session") },
        onReveal: { print("Reveal in Finder") },
        onDelete: { print("Delete session") },
        columnVisibility: $visibility
    )
    .frame(width: 600, height: 800)
}

import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {
    // Split helpers to keep ContentView.swift lean

    var focusedSummary: SessionSummary? {
        guard !selection.isEmpty else {
            return viewModel.sections.first?.sessions.first
        }
        let all = summaryLookup
        if let pid = selectionPrimaryId, selection.contains(pid), let s = all[pid] {
            return s
        }
        return selection
            .compactMap { all[$0] }
            .sorted { lhs, rhs in
                (lhs.lastUpdatedAt ?? lhs.startedAt) > (rhs.lastUpdatedAt ?? rhs.startedAt)
            }
            .first
    }

    var summaryLookup: [SessionSummary.ID: SessionSummary] {
        Dictionary(
            uniqueKeysWithValues: viewModel.sections
                .flatMap(\.sessions)
                .map { ($0.id, $0) }
        )
    }

    func fallbackRunningAnchorId() -> String? {
        let realIds = Set(summaryLookup.keys)
        if let id = runningSessionIDs.first(where: { $0.hasPrefix("new-anchor:") }) { return id }
        return runningSessionIDs.first(where: { !realIds.contains($0) })
    }

    func synchronizeSelectedTerminalKey() {
        #if canImport(SwiftTerm) && !APPSTORE
            if let key = selectedTerminalKey, runningSessionIDs.contains(key) { return }
            selectedTerminalKey = runningSessionIDs.first
        #else
            selectedTerminalKey = nil
        #endif
    }

    func activeTerminalKey() -> String? {
        #if canImport(SwiftTerm) && !APPSTORE
            if let key = selectedTerminalKey, runningSessionIDs.contains(key) {
                return key
            }
            return runningSessionIDs.first
        #else
            return nil
        #endif
    }

    func hasAvailableEmbeddedTerminal() -> Bool {
        #if canImport(SwiftTerm) && !APPSTORE
            // Check if there's a terminal available for the focused session
            guard let focused = focusedSummary else {
                // No focused session, check if there are any anchor terminals (new sessions)
                return fallbackRunningAnchorId() != nil
            }
            // Check if focused session has a running terminal
            return runningSessionIDs.contains(focused.id)
        #else
            return false
        #endif
    }

    func normalizeDetailTabForTerminalAvailability() {
        #if canImport(SwiftTerm) && !APPSTORE
            if selectedDetailTab == .terminal && activeTerminalKey() == nil {
                selectedDetailTab = .timeline
            }
        #else
            if selectedDetailTab == .terminal {
                selectedDetailTab = .timeline
            }
        #endif
    }

    func terminalHostInitialCommands(for key: String) -> String {
        if let stored = embeddedInitialCommands[key] { return stored }
        if let summary = summaryLookup[key] {
            return viewModel.buildResumeCommands(session: summary)
        }
        return ""
    }

    func consoleSpecForTerminalKey(_ key: String) -> TerminalHostView.ConsoleSpec? {
        #if canImport(SwiftTerm) && !APPSTORE
            if key.hasPrefix("new-anchor:"), let spec = consoleSpecForAnchor(key) {
                return spec
            }
            if let summary = summaryLookup[key] {
                return consoleSpecForResume(summary)
            }
        #endif
        return nil
    }

    func canonicalizePath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        var standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        if standardized.count > 1 && standardized.hasSuffix("/") { standardized.removeLast() }
        return standardized
    }

    func exportMarkdownForFocused() {
        guard let focused = focusedSummary else { return }
        exportMarkdownForSession(focused)
    }

    func exportMarkdownForSession(_ session: SessionSummary) {
        Task {
            let loader = SessionTimelineLoader()
            let allTurns = await loadConversationTurnsForExport(
                session: session,
                loader: loader
            )
            await MainActor.run {
                presentMarkdownExport(for: session, allTurns: allTurns)
            }
        }
    }
    
    private func loadConversationTurnsForExport(
        session: SessionSummary,
        loader: SessionTimelineLoader
    ) async -> [ConversationTurn] {
        if session.source.baseKind == .claude {
            if let parsed = ClaudeSessionParser().parse(at: session.fileURL) {
                return loader.turns(from: parsed.rows)
            }
            return []
        } else if session.source.baseKind == .gemini {
            return await viewModel.timeline(for: session)
        } else {
            return (try? loader.load(url: session.fileURL)) ?? []
        }
    }
    
    @MainActor
    private func presentMarkdownExport(for session: SessionSummary, allTurns: [ConversationTurn]) {
        let kinds = viewModel.preferences.markdownVisibleKinds
        let turns: [ConversationTurn] = allTurns.compactMap { turn in
            let userAllowed = turn.userMessage.flatMap { kinds.contains(event: $0) } ?? false
            let keptOutputs = turn.outputs.filter { kinds.contains(event: $0) }
            if !userAllowed && keptOutputs.isEmpty { return nil }
            return ConversationTurn(
                id: turn.id,
                timestamp: turn.timestamp,
                userMessage: userAllowed ? turn.userMessage : nil,
                outputs: keptOutputs
            )
        }
        // Fallback: if Claude session produced non-empty turns but all filtered out by current preferences,
        // relax filter to include assistant messages to avoid empty exports.
        let finalTurns: [ConversationTurn]
        if turns.isEmpty, session.source.baseKind == .claude, !allTurns.isEmpty {
            let relaxed: Set<MessageVisibilityKind> = [.user, .assistant]
            finalTurns = allTurns.compactMap { turn in
                let userAllowed = turn.userMessage.flatMap { relaxed.contains(event: $0) } ?? false
                let keptOutputs = turn.outputs.filter { relaxed.contains(event: $0) }
                if !userAllowed && keptOutputs.isEmpty { return nil }
                return ConversationTurn(id: turn.id, timestamp: turn.timestamp, userMessage: userAllowed ? turn.userMessage : nil, outputs: keptOutputs)
            }
        } else {
            finalTurns = turns
        }
        var lines: [String] = []
        lines.append("# \(session.displayName)")
        lines.append("")
        lines.append("- Started: \(session.startedAt)")
        if let end = session.lastUpdatedAt { lines.append("- Last Updated: \(end)") }
        if let model = session.model { lines.append("- Model: \(model)") }
        if let approval = session.approvalPolicy { lines.append("- Approval Policy: \(approval)") }
        lines.append("")
        for turn in finalTurns {
            if let user = turn.userMessage {
                lines.append("**User** · \(user.timestamp)")
                if let text = user.text, !text.isEmpty { lines.append(text) }
            }
            let assistantLabel = session.source.branding.displayName
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
                    for key in meta.keys.sorted() {
                        lines.append("- \(key): \(meta[key] ?? "")")
                    }
                }
                if event.repeatCount > 1 {
                    lines.append("- repeated: ×\(event.repeatCount)")
                }
            }
            lines.append("")
        }
        let md = lines.joined(separator: "\n")
        let panel = NSSavePanel()
        panel.title = "Export Markdown"
        panel.allowedContentTypes = [.plainText]
        let base = sanitizedExportFileName(session.effectiveTitle, fallback: session.displayName)
        panel.nameFieldStringValue = base + ".md"
        if panel.runModal() == .OK, let url = panel.url {
            try? md.data(using: .utf8)?.write(to: url)
        }
    }

    func sanitizedExportFileName(_ s: String, fallback: String, maxLength: Int = 120) -> String {
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
    
    func applyIncrementalHint(for source: SessionSource, directory: String?) {
        switch source.baseKind {
        case .codex:
            viewModel.setIncrementalHintForCodexToday()
        case .gemini:
            viewModel.setIncrementalHintForGeminiToday()
        case .claude:
            if let directory {
                viewModel.setIncrementalHintForClaudeProject(directory: directory)
            }
        }
    }
    
    func scheduleIncrementalRefresh(for source: SessionSource, directory: String?) {
        guard let action = incrementalRefreshAction(for: source, directory: directory) else { return }
        let schedule = incrementalRefreshSchedule(for: source.baseKind)
        Task {
            for delay in schedule {
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay)
                }
                await action()
            }
        }
    }
    
    private func incrementalRefreshAction(
        for source: SessionSource,
        directory: String?
    ) -> (() async -> Void)? {
        switch source.baseKind {
        case .codex:
            return { await viewModel.refreshIncrementalForNewCodexToday() }
        case .gemini:
            return { await viewModel.refreshIncrementalForGeminiToday() }
        case .claude:
            guard let directory else { return nil }
            return { await viewModel.refreshIncrementalForClaudeProject(directory: directory) }
        }
    }
    
    private func incrementalRefreshSchedule(for kind: SessionSource.Kind) -> [UInt64] {
        switch kind {
        case .claude:
            return [
                0,
                600_000_000,
                1_500_000_000,
                3_000_000_000,
                5_000_000_000,
                10_000_000_000,
            ]
        case .codex, .gemini:
            return [0, 600_000_000, 1_500_000_000]
        }
    }

    func sourceButtonLabel(title: String, source: SessionSource) -> some View {
        Text(title)
    }

    func providerMenuLabel(prefix: String, source: SessionSource) -> some View {
        Text("\(prefix) \(source.branding.displayName)")
    }
}

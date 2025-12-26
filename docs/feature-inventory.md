# CodMate Feature Inventory

> Purpose: Provide a traceable feature inventory with code evidence (file paths) for value/advantage/use-case synthesis. Each feature includes code evidence (file paths).

## Coverage and Methodology
- Coverage sources: `README.md`, `AGENTS.md`, `docs/` specification documents + `views/` (UI entry points) + `services/` (capability implementations) + `models/` (data/state).
- Evidence format: Each feature is annotated with `Evidence:`, containing minimal necessary file paths (traceable item by item).
- Note: This inventory focuses on "feature points", not marketing copy; it can be used to extract "value/advantage/scenarios" later.

---

## 1) Session Sources and Collection (Multi-CLI Unified Management)
- Codex session parsing and provider (local `.jsonl`). Evidence: `services/SessionProvider.swift`, `services/CodexConfigService.swift`, `services/SessionIndexer.swift`
- Claude Code session parsing and provider. Evidence: `services/ClaudeSessionParser.swift`, `services/ClaudeSessionProvider.swift`
- Gemini CLI session parsing and provider. Evidence: `services/GeminiSessionParser.swift`, `services/GeminiSessionProvider.swift`
- Remote session mirroring (SSH sync of remote sessions). Evidence: `services/RemoteSessionMirror.swift`, `services/RemoteSessionProvider.swift`, `services/SSHConfigResolver.swift`
- Directory change monitoring (incremental session/index updates). Evidence: `services/DirectoryMonitor.swift`
- Session activity tracking and statistics. Evidence: `services/SessionActivityTracker.swift`, `models/OverviewAggregate.swift`

## 2) Indexing, Caching, and Performance Paths
- Session indexing (SQLite) with incremental updates. Evidence: `services/SessionIndexSQLiteStore.swift`, `services/SessionIndexer.swift`
- Lightweight caching and disk cache strategies. Evidence: `services/SessionCacheStore.swift`, `services/RipgrepDiskCache.swift`
- Full-text scanning (ripgrep) and search caching. Evidence: `services/SessionRipgrepStore.swift`, `services/RipgrepRunner.swift`
- Session timeline loading and incremental parsing. Evidence: `services/SessionTimelineLoader.swift`, `services/SessionEnrichmentService.swift`
- Context pruning and optimization (avoiding oversized contexts). Evidence: `services/ContextTreeshaker.swift`

## 3) Main Interface Structure and Navigation (3-Column Layout + Sidebar)
- Three-column structure: Sidebar / List / Detail. Evidence: `views/Content/ContentView.swift`, `views/SessionNavigationView.swift`, `views/Content/ContentView+Sidebar.swift`
- Sidebar top "All Sessions" entry and count. Evidence: `views/Content/ContentView+Sidebar.swift`, `models/SidebarState.swift`
- Directory tree navigation (aggregated by cwd statistics). Evidence: `models/PathTree.swift`, `services/PathTreeStore.swift`, `views/PathTreeView.swift`
- Calendar month view (daily statistics + multi-select). Evidence: `views/CalendarMonthView.swift`, `models/DateDimension.swift`
- Overview cards and activity charts. Evidence: `views/OverviewCard.swift`, `views/OverviewActivityChart.swift`, `models/ActivityChartData.swift`

## 4) Session List and Filtering
- Session list row information (title/time/snippet/metrics). Evidence: `views/SessionListRowView.swift`, `models/SessionSummary.swift`
- Sorting and scope (Today/Recent, etc.). Evidence: `models/SessionLoadScope.swift`, `models/SessionListViewModel.swift`
- List filtering, status indicators, running sessions. Evidence: `models/SessionListViewModel.swift`, `models/SessionNavigation.swift`
- Multi-dimensional filtering by project/directory/date. Evidence: `models/SessionListViewModel+Projects.swift`, `models/SessionListViewModel.swift`

## 5) Session Details and Timeline
- Conversation timeline view (user/assistant/tool/info). Evidence: `views/ConversationTimelineView.swift`, `models/TimelineEvent.swift`, `models/ConversationTurn.swift`
- Timeline attachment parsing and opening. Evidence: `services/TimelineAttachmentDecoder.swift`, `services/TimelineAttachmentOpener.swift`
- Environment Context/Turn Context display. Evidence: `models/EnvironmentContextInfo.swift`, `views/SessionDetailView.swift`
- Task Instructions collapsible display. Evidence: `views/SessionDetailView.swift`

## 6) Global Search and Content Retrieval
- Global search panel (shortcuts/progress/cancel). Evidence: `views/Search/GlobalSearchPanel.swift`, `models/GlobalSearchViewModel.swift`
- Search index service and incremental scanning. Evidence: `services/GlobalSearchService.swift`, `services/SessionRipgrepStore.swift`
- Repository content search (repo-level scanning). Evidence: `services/RepoContentSearchService.swift`
- Toolbar search entry. Evidence: `views/Search/ToolbarSearchField.swift`

## 7) Projects / Tasks / Session Archiving
- Project management (create/edit/select). Evidence: `views/ProjectsListView.swift`, `services/ProjectsStore.swift`, `models/Project.swift`
- Task management and grouping. Evidence: `views/TaskListView.swift`, `services/TasksStore.swift`, `models/Task.swift`
- Session assignment to projects/tasks. Evidence: `models/SessionListViewModel+Projects.swift`, `models/SessionListViewModel.swift`
- Project-level Overview container and statistics. Evidence: `views/ProjectSpecificOverviewContainerView.swift`, `models/ProjectOverviewViewModel.swift`

## 8) Session Metadata (Rename/Comment)
- Session title/comment editing. Evidence: `views/EditSessionMetaView.swift`, `models/SessionListViewModel+Notes.swift`
- Notes storage and migration. Evidence: `services/SessionNotesStore.swift`, `utils/FilenameSanitizer.swift`

## 9) Resume / New / Terminal Workflow
- Resume session (external terminal or embedded terminal). Evidence: `services/SessionActions+Terminal.swift`, `views/EmbeddedTerminalView.swift`, `views/CodMateTerminalView.swift`
- New session (reuse cwd / model / policy). Evidence: `services/SessionActions+Commands.swift`, `models/SessionListViewModel+Commands.swift`
- Terminal session management (keep running per session). Evidence: `services/TerminalSessionManager.swift`
- External terminal configuration (Terminal/iTerm2/Warp). Evidence: `services/ExternalTerminalProfileStore.swift`, `views/ExternalTerminalMenuHelpers.swift`
- Copy "real command" (full parameters). Evidence: `views/Content/ContentView+DetailActionBar.swift`, `services/SessionActions+Commands.swift`

## 10) Prompt System and Quick Commands
- Prompts Picker (insert into terminal input). Evidence: `views/Content/ContentView.swift`, `views/Content/ContentView+DetailActionBar.swift`
- Prompt presets and merging (project-level/user-level/built-in). Evidence: `services/PresetPromptsStore.swift`
- Prompt maintenance (add/delete/hide). Evidence: `services/PresetPromptsStore.swift`, `views/Content/ContentView.swift`
- Warp title prompt (prompt title). Evidence: `utils/WarpTitlePrompt.swift`, `services/SessionPreferencesStore.swift`

## 11) Git Review (Review Mode)
- Git changes tree + diff preview. Evidence: `views/GitChanges/GitChangesPanel.swift`, `services/GitService.swift`
- Stage / Unstage, operations by file/directory. Evidence: `views/GitChanges/GitChangesPanel+DiffTree.swift`, `services/GitService.swift`
- Commit editing and execution. Evidence: `views/GitChanges/GitChangesPanel.swift`, `models/GitChangesViewModel.swift`
- AI-generated Commit Message. Evidence: `models/GitChangesViewModel.swift`, `services/LLMHTTPService.swift`
- Git history graph and commit details. Evidence: `views/GitChanges/GitChangesPanel+Graph.swift`, `models/GitGraphViewModel.swift`
- Review panel state and persistence. Evidence: `models/ReviewPanelState.swift`, `views/GitChanges/GitChangesPanel+Lifecycle.swift`

## 12) Providers / Models / Usage
- Providers registry (unified management of API Key / Base URL / models). Evidence: `services/ProvidersRegistryService.swift`, `views/ProvidersSettingsView.swift`
- Provider icon/display. Evidence: `views/ProviderIconView.swift`
- Usage API clients and status. Evidence: `services/ClaudeUsageAPIClient.swift`, `services/CodexFeaturesService.swift`, `services/GeminiUsageAPIClient.swift`
- Usage status UI and triple-ring indicator. Evidence: `views/UsageStatusControl.swift`, `views/TripleUsageDonutView.swift`

## 13) MCP Servers and Extensions
- MCP Servers list, enable, edit. Evidence: `models/MCPServer.swift`, `services/MCPServersStore.swift`, `views/MCPServersSettingsView.swift`
- MCP Uni-Import (import/normalization). Evidence: `services/UniImportMCPNormalizer.swift`, `views/MCPServersSettingsView.swift`
- MCP connection testing and capability detection. Evidence: `services/MCPQuickTestService.swift`
- Extensions settings entry (MCP / Skills). Evidence: `views/ExtensionsSettingsView.swift`, `models/ExtensionsSettingsTab.swift`

## 14) Skills (Skill Packages)
- Skills list, loading, configuration. Evidence: `services/SkillsStore.swift`, `views/SkillsSettingsView.swift`
- Skills synchronization and application to projects. Evidence: `services/SkillsSyncService.swift`, `services/ProjectExtensionsApplier.swift`
- Skills package preview and details. Evidence: `views/Skills/SkillPackageExplorerView.swift`, `models/SkillsModels.swift`
- Project-level Skills settings. Evidence: `views/ProjectsListView.swift`, `models/ProjectExtensionsViewModel.swift`

## 15) Notification System
- System notification wrapper. Evidence: `services/SystemNotifier.swift`, `services/EmbeddedNotifySniffer.swift`
- Claude Code notification hook setup. Evidence: `models/ClaudeCodeVM.swift`, `services/ClaudeSettingsService.swift`
- Gemini notification settings. Evidence: `views/GeminiSettingsView.swift`, `models/GeminiVM.swift`

## 16) Diagnostics and Advanced Settings
- Dialectics diagnostics panel (data directories/index/reports). Evidence: `views/DialecticsPane.swift`, `services/SessionsDiagnosticsService.swift`
- Advanced Settings: Path / Dialectics. Evidence: `views/AdvancedSettingsView.swift`, `views/AdvancedPathPane.swift`
- Diagnostics report export. Evidence: `views/DiagnosticsViews.swift`, `services/SessionsDiagnosticsService.swift`

## 17) Settings System (Multi-Page/Multi-Tab)
- Settings main entry and categorization. Evidence: `views/SettingsView.swift`, `models/SettingCategory.swift`

### 17.1 General
- System menu bar icon display policy. Evidence: `views/SettingsView.swift`, `models/SystemMenuVisibility.swift`
- Default editor selection (for quick opening in Review, etc.). Evidence: `views/SettingsView.swift`, `models/EditorApp.swift`
- Global search panel style (⌘F display mode). Evidence: `views/SettingsView.swift`, `models/GlobalSearchModels.swift`
- Timeline/Markdown message type visibility configuration (with "Restore Defaults"). Evidence: `views/SettingsView.swift`, `models/SessionPreferencesStore.swift`, `models/TimelineEvent.swift`

### 17.2 Terminal
- Embedded terminal toggle (non-sandboxed version), CLI console mode. Evidence: `views/SettingsView.swift`, `services/TerminalSessionManager.swift`
- Terminal font and cursor style selection. Evidence: `views/SettingsView.swift`, `utils/TerminalFontResolver.swift`, `models/TerminalCursorStyleOption.swift`
- External terminal default app and auto-open. Evidence: `views/SettingsView.swift`, `services/ExternalTerminalProfileStore.swift`
- New/resume command auto-copy to clipboard. Evidence: `views/SettingsView.swift`, `services/SessionPreferencesStore.swift`
- Warp tab title prompt. Evidence: `views/SettingsView.swift`, `utils/WarpTitlePrompt.swift`

### 17.3 Command (Codex CLI Default Parameters)
- Sandbox policy and Approval policy defaults. Evidence: `views/SettingsView.swift`, `models/ExecutionPolicy.swift`
- `--full-auto` and dangerous bypass (bypass approvals/sandbox) toggle. Evidence: `views/SettingsView.swift`

### 17.4 Providers (Global Provider Management)
- Provider list, template add, edit/delete. Evidence: `views/ProvidersSettingsView.swift`, `services/ProvidersRegistryService.swift`
- Provider editor: Codex/Claude Base URL, API Key Env, Wire API. Evidence: `views/ProvidersSettingsView.swift`
- Model catalog editing: add/delete, default model, capability tags (reasoning/tool/vision/long context). Evidence: `views/ProvidersSettingsView.swift`, `services/ProvidersRegistryService.swift`
- Connection testing and documentation entry. Evidence: `views/ProvidersSettingsView.swift`

### 17.5 Codex Settings
- Provider binding (Active Provider + Model). Evidence: `views/CodexSettingsView.swift`, `models/CodexVM.swift`
- Runtime defaults: Reasoning Effort/Summary, Verbosity, Sandbox, Approval. Evidence: `views/CodexSettingsView.swift`, `models/CodexVM.swift`
- Feature Flags: fetch and per-item override toggles. Evidence: `views/CodexSettingsView.swift`, `services/CodexFeaturesService.swift`
- Notifications: TUI notifications, system notifications, notify bridge self-test. Evidence: `views/CodexSettingsView.swift`, `services/SystemNotifier.swift`
- Privacy/environment policy: inheritance scope, include/exclude, environment variable overrides, hide/show reasoning. Evidence: `views/CodexSettingsView.swift`, `models/CodexVM.swift`
- Raw Config read-only view and quick open. Evidence: `views/CodexSettingsView.swift`

### 17.6 Claude Code Settings
- Provider: Active Provider, default model and aliases (Haiku/Sonnet/Opus), login method. Evidence: `views/ClaudeCodeSettingsView.swift`, `models/ClaudeCodeVM.swift`
- Runtime: Permission Mode, Skip Permissions, Debug/Verbose, tool allow/deny, IDE auto-connect, Strict MCP, Fallback Model. Evidence: `views/ClaudeCodeSettingsView.swift`, `models/ClaudeCodeVM.swift`
- Notifications: install hook, hook command preview and self-test. Evidence: `views/ClaudeCodeSettingsView.swift`, `services/ClaudeSettingsService.swift`
- Raw Config: settings.json read-only view and open. Evidence: `views/ClaudeCodeSettingsView.swift`

### 17.7 Gemini CLI Settings
- General: Preview Features, Prompt Completion, Vim Mode, Disable Auto Update, Session Retention. Evidence: `views/GeminiSettingsView.swift`, `models/GeminiVM.swift`
- Runtime: Sandbox/Approval defaults. Evidence: `views/GeminiSettingsView.swift`, `models/ExecutionPolicy.swift`
- Model: model selection, Max Session Turns, Compression Threshold, Skip Next Speaker Check. Evidence: `views/GeminiSettingsView.swift`, `models/GeminiVM.swift`
- Notifications: system notifications and self-test. Evidence: `views/GeminiSettingsView.swift`
- Raw Config: settings.json read-only view and open. Evidence: `views/GeminiSettingsView.swift`

### 17.8 Extensions Settings
- MCP Servers: list, enable/disable, Uni‑Import, form/JSON editing, connection testing. Evidence: `views/MCPServersSettingsView.swift`, `services/MCPQuickTestService.swift`
- Skills: search, install (folder/Zip/URL/drag-drop), enable/disable, reinstall/uninstall, details preview. Evidence: `views/SkillsSettingsView.swift`, `models/SkillsLibraryViewModel.swift`

### 17.9 Git Review Settings
- Diff display (line numbers, soft wrap). Evidence: `views/GitReviewSettingsView.swift`, `services/GitService.swift`
- Commit generation (Provider/Model selection). Evidence: `views/GitReviewSettingsView.swift`, `services/ProvidersRegistryService.swift`
- Commit Prompt template. Evidence: `views/GitReviewSettingsView.swift`, `services/SessionPreferencesStore.swift`

### 17.10 Remote Hosts
- SSH host list and enable toggle (from `~/.ssh/config`). Evidence: `views/RemoteHostsSettingsView.swift`, `services/SSHConfigResolver.swift`
- One-click sync/refresh, unavailable host prompts and permission guidance. Evidence: `views/RemoteHostsSettingsView.swift`, `services/SandboxPermissionsManager.swift`

### 17.11 Advanced
- Path: Projects/Notes root directory switching. Evidence: `views/AdvancedPathPane.swift`, `models/SessionPreferencesStore.swift`
- CLI path overrides and auto-detection, PATH snapshot. Evidence: `views/AdvancedPathPane.swift`, `models/CLIPathVM.swift`
- Dialectics: environment info, ripgrep statistics, index rebuild, sessions/notes/projects directory diagnostics, report export. Evidence: `views/DialecticsPane.swift`, `services/SessionsDiagnosticsService.swift`, `services/SessionRipgrepStore.swift`

### 17.12 About
- Version/build time, project link, license viewing. Evidence: `views/AboutViews.swift`

## 18) Menu Bar (Status Bar)
- Status bar menu and quick actions. Evidence: `services/MenuBarController.swift`
- Provider/model/usage display. Evidence: `services/MenuBarController.swift`, `models/UsageProviderSnapshot.swift`
- Recent projects/sessions entry. Evidence: `services/MenuBarController.swift`, `views/RecentSessionsListView.swift`

## 19) Security and Authorization
- Security Scoped Bookmarks management. Evidence: `services/SecurityScopedBookmarks.swift`, `services/AuthorizationHub.swift`
- Sandbox permissions management and prompts. Evidence: `services/SandboxPermissionsManager.swift`, `views/SandboxPermissionsView.swift`
- External URL routing (codmate://). Evidence: `services/ExternalURLRouter.swift`

## 20) Data Export and Formatting
- Markdown export builder. Evidence: `utils/MarkdownExportBuilder.swift`, `views/SessionDetailView.swift`
- Token/time/duration formatting. Evidence: `utils/TokenFormatter.swift`, `models/SessionEvent.swift`
- Configurable Timeline/Markdown visibility. Evidence: `models/SessionPreferencesStore.swift`, `views/SettingsView.swift`

## 21) Statistics and Display Helpers
- Usage / Stats cards and aggregation. Evidence: `models/OverviewAggregate.swift`, `views/OverviewCard.swift`
- Usage status models (Codex/Claude/Gemini). Evidence: `models/CodexUsageStatus.swift`, `models/ClaudeUsageStatus.swift`, `models/GeminiUsageStatus.swift`
- Dual/triple-column statistics display components. Evidence: `views/TripleUsageDonutView.swift`, `views/UsageStatusControl.swift`

## 22) Compatibility and Runtime Environment
- CLI PATH environment setup and snapshot. Evidence: `utils/CLIEnvironment.swift`, `views/AdvancedPathPane.swift`
- App distribution/environment identification. Evidence: `utils/AppDistribution.swift`, `utils/AppAvailability.swift`
- Window/state persistence. Evidence: `services/WindowStateStore.swift`, `utils/WindowConfigurator.swift`

## 23) Claude Web / Browser Integration (Auxiliary Capabilities)
- Chrome/Safari cookie reading (Claude sessionKey). Evidence: `services/BrowserCookies/ChromeCookieImporter.swift`, `services/BrowserCookies/SafariCookieImporter.swift`
- Claude Web API client (sessions/usage, etc.). Evidence: `services/ClaudeWebAPIClient.swift`, `services/LLMHTTPService.swift`

---

## 24) Value/Advantage Tag Library and Mapping (For Synthesis)
> Note: The following tags can be used directly as "value point" titles or cards; features can be mapped to values later.

### 24.1 Value Tag Library (Suggested Terms)
- Efficiency and Speed (fast retrieval/fast resume/fast navigation)
- Context Continuity (uninterrupted across terminals, across CLIs)
- Traceability and Knowledge Accumulation (searchable, exportable, reviewable)
- Customization and Control (Provider/Model/policy/permissions)
- Security and Compliance (Sandbox, permissions, environment variables)
- Collaboration and Standardization (projects/tasks/skills/prompt library)
- Quality and Delivery Loop (Review/Commit)
- Operations and Remote (SSH mirroring, remote sessions)
- Ecosystem Compatibility (Codex/Claude/Gemini multi-source)
- Diagnosability and Recoverability (diagnostics/index rebuild/reports)

### 24.2 Feature → Value Mapping (Summary)
- **Multi-source session unified management + remote mirroring** → Ecosystem compatibility, operations and remote, traceability
  Evidence: `services/SessionProvider.swift`, `services/RemoteSessionMirror.swift`
- **Global search + high-performance indexing** → Efficiency and speed, traceability
  Evidence: `services/GlobalSearchService.swift`, `services/SessionIndexSQLiteStore.swift`
- **Projects/Tasks organization** → Collaboration and standardization, context continuity
  Evidence: `services/ProjectsStore.swift`, `services/TasksStore.swift`
- **Resume/New + terminal integration** → Context continuity, efficiency and speed
  Evidence: `services/SessionActions+Terminal.swift`, `views/EmbeddedTerminalView.swift`
- **Review (Git Changes)** → Quality and delivery loop
  Evidence: `views/GitChanges/GitChangesPanel.swift`, `services/GitService.swift`
- **Providers/Models/Policies** → Customization and control, ecosystem compatibility
  Evidence: `views/ProvidersSettingsView.swift`, `views/CodexSettingsView.swift`
- **Notification system** → Efficiency and speed (reduced waiting and switching)
  Evidence: `services/SystemNotifier.swift`, `views/ClaudeCodeSettingsView.swift`
- **Diagnostics/Dialectics** → Diagnosability and recoverability, stability
  Evidence: `views/DialecticsPane.swift`, `services/SessionsDiagnosticsService.swift`
- **Sandbox/permissions/environment policy** → Security and compliance
  Evidence: `views/CodexSettingsView.swift`, `services/SandboxPermissionsManager.swift`

---

## 25) Use Case Matrix (Suggested)
> Note: For "recommended use cases" synthesis; can be rewritten as marketing descriptions.

| Scenario | Key Requirements | Corresponding Capabilities (Examples) |
|---|---|---|
| Personal daily development | Quick history retrieval/continue context | Global search, Resume/New, timeline |
| Team collaboration and standardization | Shared standards and prompts | Projects/Tasks, Skills, Prompts, Providers |
| Multi-model/multi-vendor switching | Unified API/model management | Providers Registry, model catalog/capability tags |
| Security-sensitive environments | Access/permission control | Sandbox/Approval/permission management/environment policy |
| Remote development/operations | Unified remote session archiving | SSH remote mirroring, Remote Hosts |
| Code review and delivery | Diff/Commit loop | Review mode, Stage/Unstage, AI Commit |
| Large-scale history review | Traceability and export | Timeline, Markdown export, Notes |
| Diagnostics and repair | Index/data anomaly troubleshooting | Dialectics, index rebuild, report export |

---

## 26) Secondary Inventory Supplements (Search / Terminal / Review)

### 26.1 Search (Global Search)
- Search scope switching (Scope segmented selection). Evidence: `views/Search/GlobalSearchPanel.swift`, `models/GlobalSearchModels.swift`
- Search panel style (floating window / Popover). Evidence: `views/Search/GlobalSearchPanel.swift`, `models/GlobalSearchModels.swift`
- Progress/statistics/cancel (files/matches). Evidence: `views/Search/GlobalSearchPanel.swift`, `services/SessionRipgrepStore.swift`
- Result types and summaries (session/notes/project summaries). Evidence: `views/Search/GlobalSearchPanel.swift`, `models/GlobalSearchViewModel.swift`

### 26.2 Terminal
- Embedded terminal (SwiftTerm) and external terminal coexistence. Evidence: `views/EmbeddedTerminalView.swift`, `views/CodMateTerminalView.swift`
- Theme synchronization (dark/light) and font strategy (CJK-friendly). Evidence: `views/EmbeddedTerminalView.swift`
- Initial command injection and one-click copy/open external terminal. Evidence: `views/EmbeddedTerminalView.swift`
- Terminal running and session binding (no exit on switch). Evidence: `services/TerminalSessionManager.swift`, `views/Content/ContentView+Detail.swift`

### 26.3 Review (Git Changes)
- Multi-mode layout: Diff / Graph / Explorer (or preview). Evidence: `views/GitChanges/GitChangesPanel.swift`, `views/GitChanges/GitChangesPanel+Graph.swift`
- File tree and staged/unstaged view separation. Evidence: `views/GitChanges/GitChangesPanel+LeftPane.swift`
- Line numbers/soft wrap settings. Evidence: `views/GitReviewSettingsView.swift`
- Commit message generation and template. Evidence: `views/GitReviewSettingsView.swift`, `models/GitChangesViewModel.swift`

---

## To Be Refined Later (Optional)
- Fine-grained UI entry inventory (function mapping for each Button/ToolbarItem).
- Feature points → marketing copy (rewritten for different audiences).
- Case-based implementation of typical scenarios (real project stories or flowcharts).

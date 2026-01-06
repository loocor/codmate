CodMate – AGENTS Guidelines

Purpose
- This document tells AI/code agents how to work inside the CodMate repository (macOS desktop GUI for Codex session management).
- Scope: applies to the entire repo. Prefer macOS SwiftUI/AppKit APIs; avoid iOS‑only placements or components.

Architecture
- App type: macOS SwiftUI app (min macOS 13.5). SwiftPM-only build (no Xcode project).
- Layering (MVVM):
  - Models: pure data structures (SessionSummary, SessionEvent, DateDimension, SessionLoadScope, …)
  - Services: IO and side effects (SessionIndexer, SessionCacheStore, SessionActions, SessionTimelineLoader, LLMClient)
  - ViewModels: async orchestration, filtering, state (SessionListViewModel)
  - Views: SwiftUI views only (no business logic)

UI Rules (macOS specific)
- Use macOS SwiftUI and AppKit bridges; do NOT use iOS‑only placements such as `.navigationBarTrailing`.
- Settings uses macOS 15's new TabView API (`Tab("…", systemImage: "…")`) when available; provide a macOS 13.5/14 fallback with `tabItem` + `tag`. Container padding is unified (horizontal 16pt, top 16pt).
  - Tab content uniformly uses `SettingsTabContent` container (top-aligned, overall 8pt padding) to ensure consistent layout and spacing across pages.
- Notifications is a top-level Settings page between Terminal and Providers; sections are Common, Codex, Claude Code, and Gemini CLI. Common toggles commit message, title/comment, and copy New/Resume command notifications.
- Providers has been separated from the Codex tab into a top-level Settings page: Settings › Providers manages API key providers, OAuth providers, and Codex/Claude bindings; Settings › Codex only retains Runtime/Privacy/Raw Config (notifications live in Settings › Notifications).
  - OAuth providers (Codex/Claude/Gemini/Antigravity/Qwen) are added from the Providers “Add” menu and appear under an OAuth list section with login status and info actions.
  - CLI Proxy API status, reroute, and public access live under Providers as shared capabilities; deep diagnostics and installation details live under Settings › Advanced › CLI Proxy API.
  - Built-in providers are auto-loaded from an app-bundled `payload/providers.json` (managedByCodMate=true). This avoids hardcoding and lets users simply provide API keys; base URLs/models come pre-filled. The list merges bundled entries with `~/.codmate/providers.json` (user overrides win).
  - Schema note: use a single provider-level `envKey` (preferred) for both Codex and Claude Code connectors. Connector-level `envKey` remains tolerated for backward compatibility but is considered deprecated and will be ignored at save time to avoid duplication.
- Extensions page (aligned with Providers style):
  - Settings › Extensions replaces the old MCP Server page (icon: puzzlepiece.extension).
  - Tab 1: MCP Servers (existing list/editor/Uni‑Import UI kept as-is inside the tab); add an Import button to scan Home MCP configs into CodMate.
  - Tab 2: Skills (left list + right details split; Add menu supports folder/zip/URL; auto‑sync on changes); add an Import button to scan Home skills into CodMate.
  - Commands tab includes Add and Import buttons (Import scans Home command folders into CodMate).
  - Import sheets show a vertical list; each row has a right‑aligned strategy control (Skip/Overwrite/Rename) and a context menu “Open in…” to review source files.
  - MCP Servers tab keeps: enable toggle on left, edit on right, fixed "Add" button, Uni‑Import preview and confirmation.
  - Advanced capabilities (MCPMate download and instructions) remain as a footer/section in MCP Servers tab.
- Search: prefer a toolbar `SearchField` in macOS, not `.searchable` when exact placement (far right) matters.
- Toolbars: place refresh as the last ToolbarItem to pin it at the far right. Keep destructive actions in the detail pane, not in the main toolbar. Command+R and the refresh button also invalidate and recompute global sidebar statistics (projects/path tree and calendar day counts) to reflect new sessions immediately.
- Menu Bar (status item): keep it lightweight with status + quick actions. Show provider/model/sandbox/approval, New/Resume/Search/Open, Recent Projects/Sessions (max 5), Usage summary, Provider switch, Settings/Quit; avoid destructive actions.
- Sidebar (left):
  - Top (fixed): "All Sessions" row showing total count and selection state.
  - Middle (scrollable): path tree built from `cwd` counts. Rows are compact: default min row height 18, small control size, reduced insets. Single-click selects/expands; double-click applies filter (enter the directory).
  - Projects mode mirrors the compact list style; Cmd-click toggles multi-selection so users can filter sessions by several projects simultaneously (descendants remain included).
  - Bottom (fixed): calendar month view (240pt height) with per-day counts (created/last-updated switch). Always pinned to the bottom with 8pt spacing above. Supports multi-select via Command-click to toggle multiple days; plain click selects a single day (click the same day to clear).
  - Only the middle path tree scrolls; top "All Sessions" and bottom calendar remain fixed.
  - Sidebar width: min 220pt, max 25% of window width, ideal 260pt.
- Content (middle):
  - Default scope loads “today” only for speed.
  - Sorting picker is left‑aligned with list content.
  - Each row shows: title, timestamps/duration, snippet, and compact metrics (user/assistant/tool/reasoning).
- Status bar (bottom console):
  - Docked console bar spans the right-side area (list + detail); sidebar stays full height.
  - Resizable via a drag handle; single-line header collapses/expands to multi-line log history.
  - Auto mode collapses when idle (no interaction); View menu supports Always Show/Hide.
- Detail (right):
  - Sticky action bar at top: Resume, Reveal in Finder, Delete, Export Markdown.
  - Add “New” button next to Resume to start a fresh Codex session using the current session’s working directory and model.
  - When an embedded terminal is running, show a “Prompts” button beside the folder (Reveal in Finder) icon. Clicking opens a searchable popover of preset command texts; selecting one inserts it into the embedded terminal input (does not auto-execute). User presses Return to run.
  - Project-level Extensions are configured in **Edit Project**: tabs are General, Profile, MCP Servers, Skills (auto‑sync; Gemini project-level toggles disabled). MCP Servers/Skills tabs include Import buttons that scan the project directory. Edit Project window should be resizable.
  - Review mode: the list.bullet.rectangle button toggles a full-area Review view (third mode, alongside Conversation and Internal Terminal). In Review mode the detail area is fully occupied by a Git Changes surface. It:
    - Auto-detects the Git repo at the session’s working directory (uses `/usr/bin/env git` and a robust PATH).
    - Lists changed files with stage/unstage toggles and shows a unified diff or a raw file preview (updates on save). Preview is text-only in phase 1.
    - Provides a commit box. In full-area mode it uses a multi-line editor with more space.
    - Repository authorization is on-demand: when opening Review, the app resolves the repository root (the folder containing `.git`) and, if needed, prompts the user with an NSOpenPanel to authorize that folder via a security-scoped bookmark. The Settings page no longer lists authorized repositories; authorization and revoke are managed inline in the Review header.
  - “Task Instructions” uses a DisclosureGroup; load lazily when expanded.
  - Conversation timeline uses LazyVStack; differentiate user/assistant/tool/info bubbles.
- Timeline & Markdown visibility: Settings › General provides per-surface checkboxes to choose which message types are shown in the conversation timeline and included when exporting Markdown. Defaults: Timeline shows User, Assistant, Reasoning, and Code Edit; Tool Invocation, Token Usage, and Other Info are off by default. Markdown includes only User and Assistant. Environment Context and Turn Context are surfaced in dedicated sections and not configurable; Task Instructions remain in the detail DisclosureGroup; Ghost Snapshot is ignored. Code edits are surfaced as their own message type (extracted from tool calls) and have a separate toggle.
  - Turn Context is surfaced in the Environment Context card and is not exposed as a separate toggle or timeline item.
  - Context menu in list rows adds: “Generate Title & 100-char Summary” to run LLM on-demand for the selected session.
- Embedded Terminal: One live shell per session when resumed in-app; switching sessions in the middle list switches the attached terminal. The shell keeps running when you navigate away. “Return to history” closes the running shell for the focused session.
  - Prompt picker: When embedded terminal is running, a Prompts button opens a searchable list. Prompts are merged from per-project `.codmate/prompts.json` (if present) and `~/.codmate/prompts.json` (user), de-duplicated by command, then layered with a few built‑ins. Items accept either `{ "label": "…", "command": "…" }` or a plain string (used for both). Selection inserts into the terminal input without executing. The header wrench button opens the preferred file (project if exists, else user). Typing a new command shows “Add …” to create a prompt in the preferred file. Deleting a built‑in prompt records it in a hidden list (`prompts-hidden.json` at project if project prompts exist, else at user), which suppresses that built‑in in the UI.
  - Terminal shortcuts: (none for now). Clearing via shortcut is not implemented.

Performance Contract
- Fast path indexing: memory‑mapped reads; parse first ~400 lines + read tail ~64KB to correct `lastUpdatedAt`.
- Background enrichment: full parse in a constrained task group; batch UI updates (≈10 items per flush).
- Full‑text search: chunked stream scan (128 KB), case‑insensitive; avoid `lowercased()` on whole file.
- Disk cache: `~/Library/Caches/CodMate/sessionIndex-v1.json` keyed by path+mtime; prefer cache hits before parsing.
- Sidebar statistics (calendar/tree) must be global and computed independently of the current list scope to keep navigation usable.
 - Embedded terminals: keep shells alive when not visible; only render the selected session’s terminal. Users explicitly close shells via “Return to history” to release resources.

Coding Guidelines
- Concurrency: use `actor` for services managing shared caches; UI updates on MainActor only.
- Cancellation: cancel previous tasks on new search/scope changes. Name tasks (`fulltextTask`, `enrichmentTask`) and guard `Task.isCancelled` in loops.
- File IO: prefer `Data(mappedIfSafe:)` or `FileHandle.read(upToCount:)`; never load huge files into Strings.
- Error handling: surface user‑visible errors through `ViewModel.errorMessage` and macOS system notifications/alerts; do not crash the UI.
- Testability: keep parsers and small helpers pure; avoid `Process()`/AppKit in ViewModel.
- Provider Icon Theme Handling:
  - Use `ProviderIconThemeHelper` (in `utils/ProviderIconThemeHelper.swift`) for consistent dark/light mode icon adaptation.
  - Icons that are black or dark-colored (ChatGPTIcon/Codex, KimiIcon, ZaiIcon, OpenRouterIcon) must be inverted in dark mode for visibility.
  - For SwiftUI views: use `.providerIconTheme(iconName:)` modifier or `ProviderIconDarkModeModifier` directly.
  - For AppKit menus: use `ProviderIconThemeHelper.menuImage(named:)` which automatically handles resizing and dark mode inversion.
  - Do NOT manually check dark mode and invert icons; always use the helper to ensure consistency across the app.

CLI Integration (codex)
- Prefer invoking via `/usr/bin/env codex` (or `claude`) so resolution happens on system `PATH`.
- Allow optional user-specified command path overrides; use the override when valid, otherwise fall back to PATH resolution.
- New/Resume command strings must use the bare CLI name unless the user explicitly set a CLI Command Path override; only then emit an absolute path.
- Always set `PATH` to include `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin` before launching for robustness.
- `resume` runs with `currentDirectoryURL` = original session `cwd` when it exists (fallback: log file directory).
- New command options exposed in Settings › Command:
   - Sandbox policy (`-s/--sandbox`): `read-only`, `workspace-write`, `danger-full-access`.
   - Approval policy (`-a/--ask-for-approval`): `untrusted`, `on-failure`, `on-request`, `never`.
   - `--full-auto` convenience alias (maps to `-a on-failure` + `--sandbox workspace-write`).
   - `--dangerously-bypass-approvals-and-sandbox` (overrides other flags; only for externally sandboxed envs).
- UI adds a "Copy real command" button in the detail action bar when the embedded terminal is active; this copies the exact `codex resume <id>` invocation including flags.
- Provide a “New” command (detail toolbar) that launches `codex` in the session’s working directory while preserving the configured sandbox/approval defaults and `SessionSummary.model`.

Codex Settings
- Settings › Codex only manages Codex CLI runtime-related configuration (Model & Reasoning, Sandbox & Approvals, Notifications, Privacy, Raw Config).
- Providers page is independent: Settings › Providers (cross-application shared, for Codex and Claude Code selection/configuration, including OAuth).
- Provider selection uses the unified provider picker (same list as Git Review), backed by CLI Proxy API when chosen; Auto keeps CLI defaults.
- Provider tab includes a separate Model List setting under Active Provider with an editor to add/remove model IDs per provider (empty = default list).
- Notifications: TUI notifications toggle; system notifications bridge via the bundled Swift `codmate-notify` helper (installed to `~/Library/Application Support/CodMate/bin/`).
- Privacy: expose `shell_environment_policy`, reasoning visibility, OTEL exporter; do not surface history persistence in phase 1.
- Projects auto‑create a same‑id Profile on creation; renaming a project synchronizes the profile name. Conflict prompts are required.

Claude Settings
- Settings › Claude splits into Provider, Runtime, Notifications, and Raw Config tabs.
- Provider selection uses the unified provider picker (same list as Git Review), backed by CLI Proxy API when chosen; Auto keeps CLI defaults.
- Provider tab includes a Model List setting with Default/Opus/Sonnet/Haiku mappings (edited via the mapping sheet); mappings write to Claude env keys in `~/.claude/settings.json`.
- Notifications tab mirrors Codex UX: single toggle to install/remove macOS notification hooks, health indicator, and self-test button.
- Hooks write to `~/.claude/settings.json` under `hooks.Notification` and `hooks.Stop`, pointing to `/usr/bin/open -g "codmate://notify?source=claude&event=…&title64=…&body64=…"`.
- Always request Home directory access through `AuthorizationHub` before mutating the hooks file when sandboxed.

Gemini Settings
- Settings › Gemini adds a Provider tab with the unified provider picker (same list as Git Review); Gemini CLI model selection remains in the Model tab.
- Provider tab includes a Model List setting for CLI Proxy providers; the Model tab remains the source of truth for Gemini CLI model selection.

Session Metadata (Rename/Comment)
- Users can rename any session and attach a short comment.
- Trigger: click the title at the top-left of the detail pane to open the editor.
- Persistence: stored per file under `~/.codmate/notes/<sessionId-sanitized>.json`. A first-run migration copies entries from the legacy Application Support JSON and migrates from the legacy `~/.codex/notes` directory when present.
- Display: the name replaces the ID in the detail header and list; the comment is used as the row snippet when present.

About Surface
- Settings › About shows app version, build timestamp (derived from the app executable’s modification date), and project URL.
- Settings › About includes update checking/downloading for non-App Store builds and guides manual install.
- “About CodMate” menu item should open Settings pre-selecting the About tab.
 - Include an “Open Source Licenses” entry that displays `THIRD-PARTY-NOTICES.md` (bundled if present; falls back to repository URL if missing).

Diagnostics
- Settings › General adds “Diagnose Data Directories” to probe Sessions (`~/.codex/sessions`, `.jsonl`), Notes (`~/.codmate/notes`, `.json`), and Projects (`~/.codmate/projects`, `.json`) — existence, counts, sample files, and enumerator errors.
  - Also probes Claude Code sessions (`~/.claude/projects`, `.jsonl`) for presence and counts.
- When the current root has 0 sessions but the default has files, the UI suggests switching to the default path.
- Users can “Save Report…” to export a JSON diagnostics file for troubleshooting.

File/Folder Layout
- assets/             – Assets + Info.plist
- CodMateApp.swift    – App entry point
- models/             – data types
- services/           – IO, indexing, cache, codex actions
- utils/              – helpers
- views/              – SwiftUI views only
- payload/            – bundled presets (providers/terminals)
- notify/             – Swift command-line helper (codmate-notify)
- SwiftTerm/          – embedded terminal dependency (local package)
- .github/workflows/  – CI + release pipelines
- scripts/            – build/packaging scripts
- docs/               – design notes and investigation docs

Advanced Page
- Settings › Advanced (between MCP Server and About) uses a TabView with Path, CLI Proxy API, and Dialectics tabs.
- Path tab:
  - File paths (Projects/Notes) and CLI command path overrides (codex/claude/gemini)
  - CLI environment snapshot (auto-detected paths + PATH)
- CLI Proxy API tab:
  - Binary location + install/reinstall
  - Config/Auth/Logs paths (reveal in Finder)
- Dialectics tab aggregates diagnostics:
  - Codex sessions root probe (current vs default), counts and sample files, enumerator errors
  - Claude sessions directory probe (default path), counts and samples
  - Notes and Projects directories probes (current vs default), counts and sample files
  - Does not mutate config automatically; changes only happen via explicit user actions

Build & Run
- SwiftPM is the source of truth. Use `swift build` to validate compile.
- Build the app bundle with `make app` or `BASE_VERSION=1.2.3 ./scripts/create-app-bundle.sh`.
- Build a DMG with `make dmg` or `BASE_VERSION=1.2.3 ./scripts/macos-build-notarized-dmg.sh`.

Commit Conventions

Follow conventional commits pattern:

- `feat:` - New feature
- `fix:` - Bug fix
- `docs:` - Documentation change
- `style:` - Formatting, missing semicolons, etc.
- `refactor:` - Code change that neither fixes a bug nor adds a feature
- `perf:` - Performance improvement
- `test:` - Adding or updating tests
- `chore:` - Changes to build process or auxiliary tools

> Tip: Before writing your commit message, first try to summarize the main theme and motivation of your staged changes (the "why" and "core focus"). This helps ensure your commit message highlights the real intent and impact of the change, making the subject and body more focused and valuable. For AI-assisted commit generation, always let the AI attempt this summary step first.

Commit Subject Focus Principles

- The commit subject (title) should concisely highlight the "core focus" or the most important substantive change of the commit.
- Avoid generic descriptions like "update docs" or "fix bug"; the title should make the main purpose and impact of the change clear at a glance.
- If the change involves bilingual documentation, syncing with code implementation, or architectural adjustments, make this explicit in the title.
- Recommended format: "what was done + why/for what". For example:
  - `docs: sync EN/CN README and align config docs with codebase`
  - `feat: support multi-suit config management for flexible scenarios`
  - `fix: resolve SSE connection issue in bridge module`

Example:
```
Feature: Expand MCP API documentation with detailed instance and system management

Where:
- Updated README.md files across the API, handlers, models, and routes directories to include comprehensive details on new instance and system management functionalities.
- Added specific sections for MCP handlers, models, and routes to clarify the operations available for managing servers and instances.

Why:
- To enhance the clarity and usability of the API documentation, ensuring users can easily understand and utilize the new features.

What:
- Documented new API endpoints for instance management, including listing, retrieving, and managing instance health.
- Provided detailed descriptions of the handlers and models associated with MCP server and instance management.
- Updated routing information to reflect the new structure and capabilities of the API.

Issues:
- This documentation update supports ongoing development and user engagement by providing clear guidance on the API's capabilities.
```

PR / Change Policy for Agents
- Keep changes minimal and focused; do not refactor broadly without need.
- Maintain macOS compliance first; avoid iOS‑only modifiers/placements.
- When changing UI structure, update this AGENTS.md and the in‑app Settings if applicable.
- Validate performance: measure large session trees; ensure first paint is fast and enrichment is incremental.

Known Pitfalls
- `.searchable` may hijack the trailing toolbar slot on macOS; use `SearchField` in a `ToolbarItem` to control placement.
- OutlineGroup row height is affected by control size and insets; tighten with `.environment(\.defaultMinListRowHeight, 18)` and `.listRowInsets(...)` inside the row content.
- Swift KeyPath escaping when patching: do not double-escape the leading backslash in typed key paths. Always write single-backslash literals like `\ProvidersVM.codexBaseURL` in Swift sources. The apply_patch tool takes plain text; extra escaping (e.g., `\\ProvidersVM...`) will compile-fail and break symbol discovery across files.
- Prefer dot-shorthand KeyPaths in Swift (clearer, avoids escaping pitfalls): use `\.codexBaseURL` instead of `\ProvidersVM.codexBaseURL` when the generic context already constrains the base type (e.g., `ReferenceWritableKeyPath<ProvidersVM, String>`). This makes patches safer and reduces chances of accidental extra backslashes.
- String interpolation gotcha: do not escape quotes inside `\( ... )`. Write `Text("Codex: \(dict["codex"] ?? "")")`, not `Text("Codex: \(dict[\"codex\"] ?? \"\")")`. Escaping quotes inside interpolation confuses the outer string literal and can cause “Unterminated string literal”.
- SwiftUI view extensions live in separate files; properties that those extensions need must be internal (default) or `fileprivate`. Marking them `private` will make the extension fail to build (“is inaccessible due to 'private'”).
- Toolbar popovers must manage their own `@State` visibility. Binding `isPresented` directly to a view model flag tied to focus/search states causes the popover to close immediately when other columns steal focus or the toolbar re-renders.

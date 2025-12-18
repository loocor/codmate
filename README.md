# CodMate

![CodMate Screenshot](screenshot.png)

CodMate is a macOS SwiftUI app for **managing CLI AI sessions**: browse, search, organize, resume, and review work produced by **Codex**, **Claude Code**, and **Gemini CLI**.

It focuses on speed (incremental indexing + caching), a compact three-column UI, and “ship it” workflows like **Project Review (Git Changes)** and **one-click Resume/New**.

Status: **macOS 15+**, **Swift 6**, **Xcode 16**. Universal binary (arm64 + x86_64).

## Download
- **Latest release (DMG)**: [GitHub Releases](https://github.com/loocor/CodMate/releases/latest)

## Why CodMate
- **Find anything fast**: a global search panel (⌘F) with scoped search + progress/cancel, plus quick list filtering.
- **Keep work organized**: Projects + Tasks let you group sessions by repo and by goal, with a shareable task context file.
- **Continue instantly**: Resume/New into Terminal/iTerm2/Warp (or embedded terminal in non-sandbox builds), with copyable exact commands.
- **Review & commit without leaving the app**: Project Review shows diffs, staging state, and supports commit (with optional AI commit message generation).

## Features (organized by value)

### Organize and understand sessions across CLIs
- **Multi-source session browsing**:
  - **Codex**: `~/.codex/sessions` (`.jsonl`)
  - **Claude Code**: `~/.claude/projects` (`.jsonl`)
  - **Gemini CLI**: `~/.gemini/tmp` (Gemini’s session storage)
- **Sidebar navigation**:
  - **Projects** list with counts, including “All” and an **unassigned/Other** bucket.
  - **Calendar** (pinned bottom) with per-day counts and a Created/Updated toggle.
  - Directory-based navigation built from session `cwd` statistics.
- **Session list**:
  - Default scope is **Today** for fast first paint.
  - Sorting: Most Recent (created/updated aware), Duration, Activity, etc.
  - Rows show title, timestamps/duration, snippet, and compact metrics (user/assistant/tool/reasoning), plus states like running/updating/awaiting follow-up.

### Projects + Tasks (workspaces instead of loose logs)
- **Projects**:
  - Create/edit projects (name, directory, overview, trust level, optional runtime profile).
  - Assign sessions to projects via row actions/context menus.
  - Storage: `~/.codmate/projects/` (project metadata + memberships mapping).
  - “New” sessions started inside a project can be **auto-assigned** to that project.
- **Tasks (within projects)**:
  - Create/edit/delete tasks, collapse/expand task groups, and assign/move sessions into tasks.
  - **Task context sync**: generates/updates a shareable context file and prepares a prompt pointing to it.
  - Storage: `~/.codmate/tasks/` (task metadata + relationships mapping).

### Resume/New (local, remote, embedded)
- **Resume**:
  - Launch in **Terminal.app / iTerm2 / Warp**, or **embedded terminal** (non-App Store / non-sandbox builds).
  - When embedded is active, CodMate can show a **Copy real command** action for reproducibility.
- **New**:
  - Start a fresh session from the focused session’s `cwd` (and project profile when available).
  - Start sessions directly from a selected project, even without a focused session.
- **Remote Hosts (SSH mirroring)**:
  - Enable hosts from `~/.ssh/config`, then mirror remote sessions over SSH.
  - Remote bases:
    - Codex remote: `$HOME/.codex/sessions`
    - Claude remote: `$HOME/.claude/projects`
  - Mirror cache is stored under `~/Library/Caches/CodMate/remote/`.

### Search, export, and metadata (make history useful)
- **Global Search (⌘F)**:
  - Floating window or toolbar popover style (configurable).
  - Scope picker + progress/cancel for long searches.
- **Rename/comment**:
  - Click the session title in the detail pane to edit title/comment.
  - Storage: `~/.codmate/notes/<sessionId-sanitized>.json` (with automatic migration from legacy locations).
- **Conversation export**:
  - Export Markdown from the detail pane.
  - Settings allow choosing which message types appear in the timeline and which are included in Markdown export.

### Project Review (Git Changes) + AI commit message generation
- **Git Changes surface** (Project Review mode):
  - Lists changed files, supports **stage/unstage**, and shows **unified diff** or raw preview.
  - Commit UI with message editor and **Commit** action.
  - Optional **AI generate commit message** (uses your selected Provider/Model and a prompt template from settings).
  - Repo authorization is **on-demand** (especially relevant in sandboxed builds).
- **Settings › Git Review**:
  - Diff options (line numbers, soft wrap).
  - Commit generation: choose Provider/Model and an optional prompt template.

### Providers, MCP, notifications, diagnostics (make the ecosystem manageable)
- **Providers (Settings › Providers)**:
  - Add/edit providers with Codex + Claude endpoints, shared API key env var, wire API (Chat/Responses), and model catalog with capability flags.
  - Built-in templates are bundled from `payload/providers.json`; user registry is stored at `~/.codmate/providers.json`.
  - Built-in health check: **Test** endpoints before saving.
- **MCP Servers (Settings › MCP Server)**:
  - Uni-Import (paste/drag JSON), per-server enable toggle, per-target toggles (Codex/Claude/Gemini), and connectivity **Test**.
  - Storage: `~/.codmate/mcp-servers.json`
  - Exports enabled servers into `~/.claude/settings.json` (and writes a helper file `~/.codmate/mcp-enabled-claude.json`).
- **Claude Code notifications (Settings › Claude Code › Notifications)**:
  - Installs/removes hooks that forward permission/completion events via `codmate://notify` and provides a self-test.
- **Dialectics (Settings › Dialectics)**:
  - Deep diagnostics for session roots, notes/projects dirs, environment, and ripgrep indexes.
  - One-click “Save Report…” plus rebuild actions for coverage/session index.

## Keyboard shortcuts
- **⌘,**: Settings
- **⌘F**: Global Search
- **⌘R**: Refresh (also recomputes global sidebar statistics)
- **⌘1**: Toggle sidebar
- **⌘2**: Toggle session list

## Data locations (quick reference)
- **Codex sessions**: `~/.codex/sessions`
- **Claude sessions**: `~/.claude/projects`
- **Gemini sessions**: `~/.gemini/tmp`
- **Notes**: `~/.codmate/notes/`
- **Projects**: `~/.codmate/projects/`
- **Tasks**: `~/.codmate/tasks/`
- **Providers registry**: `~/.codmate/providers.json`
- **MCP servers**: `~/.codmate/mcp-servers.json`
- **Session index cache (SQLite)**: `~/.codmate/sessionIndex-v4.db`
- **Additional caches**: `~/Library/Caches/CodMate/` (includes remote mirrors and best-effort caches)

## Performance
- Fast path indexing: memory‑mapped reads; parse the first ~64 lines plus tail sampling (up to ~1 MB) to fix `lastUpdatedAt`.
- Background enrichment: full parse in constrained task groups; batched UI updates.
- Full‑text search: chunked scan (128 KB), case‑insensitive; avoids lowercasing the whole file.
- Caching: persistent SQLite index + best-effort caches to keep subsequent launches fast.
- Sidebar statistics are global and decoupled from the list scope to keep navigation snappy.

## Architecture
- App: macOS SwiftUI (min macOS 15). Xcode project `CodMate.xcodeproj` and SwiftPM manifest.
- MVVM layering
  - Models: `SessionSummary`, `SessionEvent`, `DateDimension`, `SessionLoadScope`, …
  - Services: `SessionIndexer`, `SessionCacheStore`, `SessionActions`, `SessionTimelineLoader`, `CodexConfigService`, `SessionsDiagnosticsService`
  - ViewModel: `SessionListViewModel`
  - Views: SwiftUI only (no business logic)
- Concurrency & IO
  - Services that share caches are `actor`s; UI updates on MainActor only.
  - Cancel previous tasks on search/scope changes; guard `Task.isCancelled` in loops.
  - File IO prefers `Data(mappedIfSafe:)` and chunked reads; avoids loading huge files into Strings.

## Build
Prerequisites
- macOS 15+, Xcode 16 (or Swift 6 toolchain). Install the CLIs you use (Codex / Claude / Gemini) somewhere on your `PATH`.

Option A — Xcode
- Open `CodMate.xcodeproj`, select the “CodMate” scheme, destination “My Mac”, then Run or Archive.

Option B — CLI universal Release
```sh
xcodebuild \
  -project CodMate.xcodeproj \
  -scheme CodMate \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath build/DerivedData \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
  MARKETING_VERSION=0.1.2 CURRENT_PROJECT_VERSION=1 \
  build
```
The app will be at `build/DerivedData/Build/Products/Release/CodMate.app`.

Option C — SwiftPM (developer run)
```sh
swift run CodMate
```
SwiftPM produces a console executable (`.build/*/CodMate`). Running it launches the SwiftUI app; no `.app` bundle is created by SwiftPM.

## Package DMG
Create a DMG with an Applications link:
```sh
APP=build/DerivedData/Build/Products/Release/CodMate.app
STAGE=artifacts/.stage-dmg
OUT=artifacts/release/CodMate-0.1.2-universal.dmg
rm -rf "$STAGE" && mkdir -p "$STAGE" "$(dirname "$OUT")"
cp -R "$APP" "$STAGE/" && ln -s /Applications "$STAGE/Applications"
hdiutil create -volname CodMate -srcfolder "$STAGE" -ov -format UDZO -imagekey zlib-level=9 "$OUT"
rm -rf "$STAGE"
```

Sign (optional, for distribution):
```sh
IDENTITY='Developer ID Application: Chengdu Wake.Link Technology Co., Ltd. (AN5X2K46ER)'
codesign --force --options runtime --timestamp -s "$IDENTITY" build/DerivedData/Build/Products/Release/CodMate.app
codesign -dv --verbose=2 build/DerivedData/Build/Products/Release/CodMate.app
codesign -f -s "$IDENTITY" --timestamp "$OUT"
```

Notarize (optional):
```sh
# Assuming you have stored a notarytool profile already
xcrun notarytool submit "$OUT" --keychain-profile <your-profile-name> --wait
xcrun stapler staple "$OUT"
xcrun stapler staple build/DerivedData/Build/Products/Release/CodMate.app
```

### Versioning strategy (build script)
- Marketing version (CFBundleShortVersionString): set with `BASE_VERSION` (e.g., `1.4.0`).
- Build number (CFBundleVersion): controlled by `BUILD_NUMBER_STRATEGY`:
  - `date` (default): `yyyymmddHHMM` (e.g., `202510291430`).
  - `git`: `git rev-list --count HEAD`.
  - `counter`: monotonically increments a file counter at `$BUILD_DIR/build-number` (override path via `BUILD_COUNTER_FILE`).
- DMG name: `CodMate-<BASE_VERSION>+<BUILD_NUMBER>-<ARCH>.dmg`.
- Override via environment variables when running the build script:
```sh
BASE_VERSION=1.4.0 BUILD_NUMBER_STRATEGY=date \
  ./scripts/macos-build-notarized-dmg.sh
```
This sets CFBundleShortVersionString to `1.4.0`, CFBundleVersion to the computed build number, and names the DMG accordingly.

## CLI Integration (Codex / Claude / Gemini)
- Executable resolution: CodMate launches CLIs via `/usr/bin/env codex` (and `claude` / `gemini`) to respect your system `PATH` (no user-configurable CLI path).
- PATH robustness: before launching, CodMate ensures `PATH` includes `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin`.
- Resume:
  - Uses the original session `cwd` when it exists; otherwise falls back to the log file directory.
  - Can launch into Terminal.app / iTerm2 / Warp, and (in non-sandbox builds) an embedded terminal.
  - When embedded is active, CodMate can copy the **exact** invocation it used (e.g. `codex resume <id>`).
- New:
  - Starts a fresh session in the focused session’s working directory (or the selected project directory).
  - When a Project Profile is present, its model/sandbox/approval defaults are applied when generating commands.
- Command flags exposed by the UI:
  - Codex: sandbox policy (`-s/--sandbox`), approval policy (`-a/--ask-for-approval`), `--full-auto`, `--dangerously-bypass-approvals-and-sandbox`.
  - Claude: common runtime/permission flags plus MCP strict mode (see Settings › Claude Code and Settings › Command).
- MCP integration:
  - CodMate can export enabled MCP servers into `~/.claude/settings.json` and also writes `~/.codmate/mcp-enabled-claude.json` for explicit `--mcp-config` usage.

## Project Layout
```
CodMate.xcodeproj/          # Xcode project (single app target “CodMate”)
CodMate/                    # Assets and Info.plist (not in Copy Bundle Resources)
CodMateApp.swift            # App entry point
models/                     # Data models (pure types)
services/                   # IO + indexing + integrations
utils/                      # Helpers (shell, sandbox, formatting, etc.)
views/                      # SwiftUI views
payload/                    # Bundled presets (e.g. providers.json templates)
CodMateNotify/             # Swift command-line helper installed as `codmate-notify`
SwiftTerm/                  # Embedded terminal dependency (local package)
scripts/                    # Helper scripts (icons, build flows)
docs/                       # Design notes and investigation docs
Tests/                      # XCTest (light coverage)
```

## Known Pitfalls
- Prefer a toolbar search field (far‑right aligned) over `.searchable` to avoid hijacking toolbar slots on macOS.
- Keep `Info.plist` out of Copy Bundle Resources (Xcode otherwise warns and build fails).
- Outline row height needs explicit tightening (see `defaultMinListRowHeight` and insets in the row views).

## Development Tips
- Run tests: `swift test`.
- Formatting: follow existing code style; keep changes minimal and focused.
- Performance: measure large trees; first paint should be fast; enrichment is incremental.

## License
- Apache License 2.0. See `LICENSE` for full text.
- `NOTICE` includes project attribution. SPDX: `Apache-2.0`.
- Third-party attributions and license texts: see `THIRD-PARTY-NOTICES.md`.

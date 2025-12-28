import AppKit
import SwiftUI

extension ContentView {
  // Sticky detail action bar at the top of the detail column
  var detailActionBar: some View {
    HStack(spacing: 12) {
      // Left: view mode segmented (Timeline | Git Review | Terminal)
      Group {
        #if canImport(SwiftTerm) && !APPSTORE
          if viewModel.preferences.defaultResumeUseEmbeddedTerminal {
            let items: [SegmentedIconPicker<ContentView.DetailTab>.Item] = [
              .init(title: "Timeline", systemImage: "clock", tag: .timeline),
              .init(title: "Terminal", systemImage: "terminal", tag: .terminal),
            ]
            let selection = Binding<ContentView.DetailTab>(
              get: { selectedDetailTab },
              set: { newValue in
                if newValue == .terminal {
                  if hasAvailableEmbeddedTerminal() {
                    if let focused = focusedSummary, runningSessionIDs.contains(focused.id) {
                      selectedTerminalKey = focused.id
                    } else if let anchorId = fallbackRunningAnchorId() {
                      selectedTerminalKey = anchorId
                    } else {
                      selectedTerminalKey = runningSessionIDs.first
                    }
                    selectedDetailTab = .terminal
                  } else if let focused = focusedSummary {
                    pendingTerminalLaunch = PendingTerminalLaunch(session: focused)
                  }
                } else {
                  selectedDetailTab = newValue
                }
              }
            )
            SegmentedIconPicker(items: items, selection: selection)
          } else {
            let items: [SegmentedIconPicker<ContentView.DetailTab>.Item] = [
              .init(title: "Timeline", systemImage: "clock", tag: .timeline)
            ]
            SegmentedIconPicker(items: items, selection: $selectedDetailTab)
          }
        #else
          let items: [SegmentedIconPicker<ContentView.DetailTab>.Item] = [
            .init(title: "Timeline", systemImage: "clock", tag: .timeline)
          ]
          SegmentedIconPicker(items: items, selection: $selectedDetailTab)
        #endif
      }

      Spacer(minLength: 12)

      // Right: New…, Resume…, Reveal, Prompts, Export/Return, Max
      if let focused = focusedSummary {
        // New split control: hidden in Terminal tab
        if selectedDetailTab != .terminal {
          let embeddedPreferredNew =
            viewModel.preferences.defaultResumeUseEmbeddedTerminal && !AppSandbox.isEnabled
          SplitPrimaryMenuButton(
            title: "New",
            systemImage: "plus",
            primary: {
              if embeddedPreferredNew {
                startEmbeddedNew(for: focused)
              } else {
                // default: external terminal flow
                startNewSession(for: focused)
              }
            },
            items: {
              let allowed = Set(viewModel.allowedSources(for: focused))
              let requestedOrder: [ProjectSessionSource] = [.claude, .codex, .gemini]
              let enabledRemoteHosts = viewModel.preferences.enabledRemoteHosts.sorted()
              let embeddedEnabled = viewModel.preferences.isEmbeddedTerminalEnabled

              func sourceKey(_ source: SessionSource) -> String {
                switch source {
                case .codexLocal: return "codex-local"
                case .codexRemote(let host): return "codex-\(host)"
                case .claudeLocal: return "claude-local"
                case .claudeRemote(let host): return "claude-\(host)"
                case .geminiLocal: return "gemini-local"
                case .geminiRemote(let host): return "gemini-\(host)"
                }
              }

              func launchItems(for source: SessionSource) -> [SplitMenuItem] {
                let key = sourceKey(source)
                var items = externalTerminalMenuItems(idPrefix: key) { profile in
                  launchNewSession(for: focused, using: source, profile: profile)
                }
                if embeddedEnabled {
                  let embedded = embeddedTerminalProfile()
                  items.insert(
                    .init(
                      id: "\(key)-\(embedded.id)",
                      kind: .action(
                        title: embedded.displayTitle,
                        systemImage: "macwindow",
                        run: { launchNewSession(for: focused, using: source, profile: embedded) }
                      )
                    ),
                    at: 0
                  )
                }
                return items
              }

              func remoteSource(for base: ProjectSessionSource, host: String) -> SessionSource {
                switch base {
                case .codex: return .codexRemote(host: host)
                case .claude: return .claudeRemote(host: host)
                case .gemini: return .geminiRemote(host: host)
                }
              }

              func providerAssetIcon(_ source: ProjectSessionSource) -> String {
                switch source {
                case .codex: return "ChatGPTIcon"
                case .claude: return "ClaudeIcon"
                case .gemini: return "GeminiIcon"
                }
              }

              func assetIconForSessionSource(_ source: SessionSource) -> String {
                switch source.baseKind {
                case .codex: return "ChatGPTIcon"
                case .claude: return "ClaudeIcon"
                case .gemini: return "GeminiIcon"
                }
              }

              var menuItems: [SplitMenuItem] = []

              for base in requestedOrder where allowed.contains(base) {
                var providerItems = launchItems(for: base.sessionSource)
                if !enabledRemoteHosts.isEmpty {
                  providerItems.append(.init(kind: .separator))
                  for host in enabledRemoteHosts {
                    let remote = remoteSource(for: base, host: host)
                    providerItems.append(
                      .init(kind: .submenu(title: host, systemImage: "network", items: launchItems(for: remote)))
                    )
                  }
                }
                menuItems.append(
                  .init(
                    kind: .submenu(
                      title: base.displayName,
                      assetImage: providerAssetIcon(base),
                      items: providerItems
                    )
                  )
                )
              }

              if menuItems.isEmpty {
                let fallbackSource = focused.source
                menuItems.append(
                  .init(
                    kind: .submenu(
                      title: fallbackSource.branding.displayName,
                      assetImage: assetIconForSessionSource(fallbackSource),
                      items: launchItems(for: fallbackSource)
                    )
                  )
                )
              }
              return menuItems
            }()
          )
        }

        // Resume split control: hidden in Terminal tab
        if selectedDetailTab != .terminal {
          let embeddedPreferred =
            viewModel.preferences.defaultResumeUseEmbeddedTerminal && !AppSandbox.isEnabled
          SplitPrimaryMenuButton(
            title: "Resume",
            systemImage: "play.fill",
            primary: {
              if embeddedPreferred {
                startEmbedded(for: focused)
              } else {
                openPreferredExternal(for: focused)
              }
            },
            items: {
              var items: [SplitMenuItem] = []
              let embeddedEnabled = viewModel.preferences.isEmbeddedTerminalEnabled
              func sourceKey(_ source: SessionSource) -> String {
                switch source {
                case .codexLocal: return "codex-local"
                case .codexRemote(let host): return "codex-\(host)"
                case .claudeLocal: return "claude-local"
                case .claudeRemote(let host): return "claude-\(host)"
                case .geminiLocal: return "gemini-local"
                case .geminiRemote(let host): return "gemini-\(host)"
                }
              }

              if embeddedEnabled {
                items.append(
                  .init(
                    id: "resume-embedded-\(focused.id)",
                    kind: .action(
                      title: "CodMate",
                      systemImage: "macwindow",
                      run: { startEmbedded(for: focused) }
                    )
                  )
                )
              }

              items.append(
                contentsOf: externalTerminalMenuItems(idPrefix: "resume-\(sourceKey(focused.source))") {
                  profile in
                  launchResume(for: focused, using: focused.source, profile: profile)
                })
              let enabledRemoteHosts = viewModel.preferences.enabledRemoteHosts
              if !enabledRemoteHosts.isEmpty {
                items.append(.init(kind: .separator))
                let currentKind = focused.source.projectSource
                for host in enabledRemoteHosts.sorted() {
                  let remoteSrc: SessionSource =
                    (currentKind == .codex)
                    ? .codexRemote(host: host)
                    : .claudeRemote(host: host)
                  let remoteName = remoteSrc.branding.displayName
                  items.append(
                    contentsOf: externalTerminalMenuItems(
                      idPrefix: "resume-\(sourceKey(remoteSrc))",
                      titlePrefix: "\(remoteName) with "
                    ) { profile in
                      launchResume(for: focused, using: remoteSrc, profile: profile)
                    })
                }
              }
              return items
            }()
          )
        }

        // Reveal in Finder (chromed icon)
        ChromedIconButton(systemImage: "finder", help: "Reveal in Finder") {
          viewModel.reveal(session: focused)
        }

        // Prompts (insert into embedded terminal when available, fallback to clipboard copy)
        let promptsMode: PromptsPopover.Mode? = {
          if selectedDetailTab == .terminal {
            guard runningSessionIDs.contains(focused.id) else { return nil }
            return .insert(terminalKey: focused.id)
          }
          return .copy
        }()

        if let promptsMode {
          ChromedIconButton(systemImage: "text.insert", help: "Prompts") {
            showPromptPicker.toggle()
          }
          .popover(isPresented: $showPromptPicker) {
            PromptsPopover(
              workingDirectory: workingDirectory(for: focused),
              mode: promptsMode,
              builtin: builtinPrompts(),
              query: $promptQuery,
              loaded: $loadedPrompts,
              hovered: $hoveredPromptKey,
              pendingDelete: $pendingDelete,
              onDismiss: { showPromptPicker = false }
            )
          }
        }

        // Sync from Task (when focused session is part of a Task and local)
        if let workspace = viewModel.workspaceVM,
           !focused.isRemote,
           workspace.tasks.contains(where: { $0.sessionIds.contains(focused.id) }) {
          ChromedIconButton(systemImage: "arrow.triangle.2.circlepath", help: "Sync from Task") {
            syncFromTask(for: focused)
          }
        }

        // Export Markdown or Return to History
        if selectedDetailTab != .terminal {
          ChromedIconButton(
            systemImage: "square.and.arrow.up", help: "Export conversation as Markdown"
          ) {
            exportMarkdownForFocused()
          }
        } else {
          ChromedIconButton(systemImage: "arrow.uturn.backward", help: "Return to History") {
            // Close the terminal currently displayed in the Terminal tab.
            let id = visibleTerminalKeyInDetail() ?? focused.id
            softReturnPending = true
            requestStopEmbedded(forKey: id)
          }
        }
      } else if let project = selectedProjectForDetailNew() {
        // When there is no focused session but a single real project
        // is selected, still offer project-scoped New entry so users
        // can start Codex/Claude sessions directly from the detail bar.
        if selectedDetailTab != .terminal {
          let embeddedPreferredNew =
            viewModel.preferences.defaultResumeUseEmbeddedTerminal && !AppSandbox.isEnabled
          SplitPrimaryMenuButton(
            title: "New",
            systemImage: "plus",
            primary: {
              if embeddedPreferredNew {
                // Defer to shared embedded flow for project-level New
                viewModel.newSession(project: project)
              } else {
                startExternalNewForProject(project)
              }
            },
            items: buildProjectNewMenuItems(for: project)
          )
        }
      }

    }
  }
}

// MARK: - Project-level New helpers (detail toolbar)

private extension ContentView {
  /// Single selected real project for project-scoped New.
  func selectedProjectForDetailNew() -> Project? {
    guard viewModel.selectedProjectIDs.count == 1,
      let pid = viewModel.selectedProjectIDs.first
    else { return nil }
    // Exclude synthetic "Other" bucket
    if pid == SessionListViewModel.otherProjectId { return nil }
    return viewModel.projects.first(where: { $0.id == pid })
  }

  // Minimal shell path escaper for cd commands in clipboard
  func shellEscapedPath(_ path: String) -> String {
    if path.isEmpty { return "''" }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/.-_"))
    let needsQuotes = path.rangeOfCharacter(from: allowed.inverted) != nil
    var output = path.replacingOccurrences(of: "'", with: "'\\''")
    if needsQuotes { output = "'\(output)'" }
    return output
  }

  // Build split menu items for project-level New actions
  func buildProjectNewMenuItems(for project: Project) -> [SplitMenuItem] {
    var items: [SplitMenuItem] = []
    let profiles = externalTerminalMenuProfiles()
    func runCodex(for profile: ExternalTerminalProfile) {
      let dir =
        (project.directory?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
          $0.isEmpty ? nil : $0
        } ?? NSHomeDirectory()
      let fallbackCommand = simpleProjectNewCommands(project: project)
      let cmd = viewModel.buildNewProjectCLIInvocation(project: project)
      let shouldCopy = viewModel.shouldCopyCommandsToClipboard
      if profile.usesWarpCommands {
        guard viewModel.copyNewProjectCommandsIfEnabled(project: project, destinationApp: profile)
        else {
          return
        }
        viewModel.openPreferredTerminalViaScheme(profile: profile, directory: dir)
        if shouldCopy {
          Task {
            await SystemNotifier.shared.notify(
              title: "CodMate", body: "Command copied. Paste it in \(profile.displayTitle).")
          }
        }
        return
      }
      if profile.isTerminal {
        if shouldCopy {
          let pb = NSPasteboard.general
          pb.clearContents()
          pb.setString(fallbackCommand + "\n", forType: .string)
        }
        _ = viewModel.openAppleTerminal(at: dir)
        if shouldCopy {
          Task {
            await SystemNotifier.shared.notify(
              title: "CodMate", body: "Command copied. Paste it in Terminal.")
          }
        }
        return
      }

      if !profile.supportsCommandResolved, shouldCopy {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(fallbackCommand + "\n", forType: .string)
      }
      let runCommand = profile.supportsDirectoryResolved ? cmd : fallbackCommand
      let inline = profile.supportsCommandResolved ? runCommand : nil
      viewModel.openPreferredTerminalViaScheme(profile: profile, directory: dir, command: inline)
      if !profile.supportsCommandResolved, shouldCopy {
        Task {
          await SystemNotifier.shared.notify(
            title: "CodMate", body: "Command copied. Paste it in \(profile.displayTitle).")
        }
      }
    }

    // Project-level Claude invocation
    func runClaude(for profile: ExternalTerminalProfile) {
      let dir =
        (project.directory?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
          $0.isEmpty ? nil : $0
        } ?? NSHomeDirectory()
      let cmd = buildClaudeProjectInvocation(for: project)
      let cdCommand = "cd " + shellEscapedPath(dir) + "\n" + cmd
      let shouldCopy = viewModel.shouldCopyCommandsToClipboard
      if profile.isTerminal {
        if shouldCopy {
          let pb = NSPasteboard.general
          pb.clearContents()
          pb.setString(cdCommand + "\n", forType: .string)
        }
        _ = viewModel.openAppleTerminal(at: dir)
        if shouldCopy {
          Task {
            await SystemNotifier.shared.notify(
              title: "CodMate", body: "Command copied. Paste it in Terminal.")
          }
        }
        return
      }

      if !profile.supportsCommandResolved, shouldCopy {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(cdCommand + "\n", forType: .string)
      }
      let runCommand = profile.supportsDirectoryResolved ? cmd : cdCommand
      let inline = profile.supportsCommandResolved ? runCommand : nil
      viewModel.openPreferredTerminalViaScheme(profile: profile, directory: dir, command: inline)
      if !profile.supportsCommandResolved, shouldCopy {
        Task {
          await SystemNotifier.shared.notify(
            title: "CodMate", body: "Command copied. Paste it in \(profile.displayTitle).")
        }
      }
    }
    func runGemini(for profile: ExternalTerminalProfile) {
      let dir =
        (project.directory?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
          $0.isEmpty ? nil : $0
        } ?? NSHomeDirectory()
      let cmd = buildGeminiProjectInvocation(for: project)
      let cdCommand = "cd " + shellEscapedPath(dir) + "\n" + cmd
      let shouldCopy = viewModel.shouldCopyCommandsToClipboard

      if profile.isTerminal {
        if shouldCopy {
          let pb = NSPasteboard.general
          pb.clearContents()
          pb.setString(cdCommand + "\n", forType: .string)
        }
        _ = viewModel.openAppleTerminal(at: dir)
        if shouldCopy {
          Task {
            await SystemNotifier.shared.notify(
              title: "CodMate", body: "Command copied. Paste it in Terminal.")
          }
        }
        return
      }

      if !profile.supportsCommandResolved, shouldCopy {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(cdCommand + "\n", forType: .string)
      }
      let runCommand = profile.supportsDirectoryResolved ? cmd : cdCommand
      let inline = profile.supportsCommandResolved ? runCommand : nil
      viewModel.openPreferredTerminalViaScheme(profile: profile, directory: dir, command: inline)
      if !profile.supportsCommandResolved, shouldCopy {
        Task {
          await SystemNotifier.shared.notify(
            title: "CodMate", body: "Command copied. Paste it in \(profile.displayTitle).")
        }
      }
    }

    // Two-level menu: provider -> terminals
    items.append(
      .init(
        id: "provider-codex",
        kind: .submenu(
          title: "Codex",
          assetImage: "ChatGPTIcon",
          items: externalTerminalMenuItems(idPrefix: "project-codex", profiles: profiles) {
            profile in
            runCodex(for: profile)
          }
        )
      )
    )
    items.append(
      .init(
        id: "provider-claude",
        kind: .submenu(
          title: "Claude",
          assetImage: "ClaudeIcon",
          items: externalTerminalMenuItems(idPrefix: "project-claude", profiles: profiles) {
            profile in
            runClaude(for: profile)
          }
        )
      )
    )
    items.append(
      .init(
        id: "provider-gemini",
        kind: .submenu(
          title: "Gemini",
          assetImage: "GeminiIcon",
          items: externalTerminalMenuItems(idPrefix: "project-gemini", profiles: profiles) {
            profile in
            runGemini(for: profile)
          }
        )
      )
    )
    return items
  }

  // Build external Terminal flow exactly like SessionListColumnView's project New
  // external branch, but scoped to the detail toolbar.
  func startExternalNewForProject(_ project: Project) {
    guard let profile = ExternalTerminalProfileStore.shared.resolvePreferredProfile(
      id: viewModel.preferences.defaultResumeExternalAppId
    ) else { return }
    let dir: String = {
      let d = (project.directory ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      return d.isEmpty ? NSHomeDirectory() : d
    }()
    if profile.isNone {
      _ = viewModel.copyNewProjectCommandsIfEnabled(project: project, destinationApp: profile)
      if viewModel.shouldCopyCommandsToClipboard {
        Task {
          await SystemNotifier.shared.notify(
            title: "CodMate", body: "Command copied. Paste it in the opened terminal.")
        }
      }
      return
    }
    if profile.usesWarpCommands {
      guard viewModel.copyNewProjectCommandsIfEnabled(project: project, destinationApp: profile) else {
        return
      }
      viewModel.openPreferredTerminalViaScheme(profile: profile, directory: dir)
    } else if profile.isTerminal {
      if viewModel.shouldCopyCommandsToClipboard {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(simpleProjectNewCommands(project: project) + "\n", forType: .string)
      }
      _ = viewModel.openAppleTerminal(at: dir)
    } else if !profile.isNone {
      let cmd = profile.supportsCommandResolved
        ? viewModel.buildNewProjectCLIInvocation(project: project)
        : nil
      if !profile.supportsCommandResolved, viewModel.shouldCopyCommandsToClipboard {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(simpleProjectNewCommands(project: project) + "\n", forType: .string)
      }
      viewModel.openPreferredTerminalViaScheme(profile: profile, directory: dir, command: cmd)
    }
    if viewModel.shouldCopyCommandsToClipboard {
      Task {
        await SystemNotifier.shared.notify(
          title: "CodMate", body: "Command copied. Paste it in the opened terminal.")
      }
    }
    // Hint + targeted refresh aligns with viewModel.newSession external path
    viewModel.setIncrementalHintForCodexToday()
    Task { await viewModel.refreshIncrementalForNewCodexToday() }
  }

  func simpleProjectNewCommands(project: Project) -> String {
    let dir: String = {
      let d = (project.directory ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      return d.isEmpty ? NSHomeDirectory() : d
    }()
    let cd = "cd " + shellEscapedPath(dir)
    let cmd = viewModel.buildNewProjectCLIInvocation(project: project)
    return cd + "\n" + cmd
  }

  /// Sync shared Task context for the focused session and expose it to the running CLI.
  /// - In Timeline tab: regenerates the context file and copies a prompt with path hint.
  /// - In Terminal tab (embedded): regenerates the context file and inserts the prompt
  ///   into the embedded terminal input for this session.
  func syncFromTask(for focused: SessionSummary) {
    guard !focused.isRemote else { return }
    guard let workspace = viewModel.workspaceVM else { return }
    guard let task = workspace.tasks.first(where: { $0.sessionIds.contains(focused.id) }) else {
      return
    }

    Task { @MainActor in
      _ = await workspace.syncTaskContext(taskId: task.id)
      let taskIdString = task.id.uuidString
      let pathHint = "~/.codmate/tasks/context-\(taskIdString).md"
      let promptLines: [String] = [
        "当前 Task 的共享上下文已更新并保存到本地文件：",
        pathHint,
        "",
        "在回答接下来的问题前，如有需要，请先阅读该文件以了解任务历史记录和相关约束。"
      ]
      let text = promptLines.joined(separator: "\n")

      if selectedDetailTab == .terminal, runningSessionIDs.contains(focused.id) {
        #if canImport(SwiftTerm) && !APPSTORE
          TerminalSessionManager.shared.send(to: focused.id, text: text)
        #else
          let pb = NSPasteboard.general
          pb.clearContents()
          pb.setString(text + "\n", forType: .string)
        #endif
      } else {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text + "\n", forType: .string)
      }

      await SystemNotifier.shared.notify(
        title: "CodMate",
        body: "Task context synced. Prompt is ready for use.")
    }
  }

  // Build a Claude invocation honoring project/default model and runtime flags
  func buildClaudeProjectInvocation(for project: Project) -> String {
    viewModel.buildClaudeProjectInvocation(project: project)
  }

  // Build a Gemini invocation honoring resume options.
  func buildGeminiProjectInvocation(for project: Project) -> String {
    viewModel.buildGeminiProjectInvocation()
  }
}

// MARK: - SegmentedIconPicker (AppKit-backed)
struct SegmentedIconPicker<Selection: Hashable>: NSViewRepresentable {
  struct Item {
    let title: String
    let systemImage: String
    let tag: Selection
    let isEnabled: Bool

    init(title: String, systemImage: String, tag: Selection, isEnabled: Bool = true) {
      self.title = title
      self.systemImage = systemImage
      self.tag = tag
      self.isEnabled = isEnabled
    }
  }

  let items: [Item]
  @Binding var selection: Selection
  var isInteractive: Bool = true
  var iconScale: CGFloat = 1

  func makeCoordinator() -> Coordinator {
    Coordinator(selection: $selection, items: items, iconScale: iconScale)
  }

  func makeNSView(context: Context) -> NSSegmentedControl {
    let control = NSSegmentedControl()
    control.translatesAutoresizingMaskIntoConstraints = true
    control.segmentStyle = .automatic
    control.controlSize = .regular
    control.trackingMode = .selectOne
    control.target = context.coordinator
    control.action = #selector(Coordinator.changed(_:))
    control.setContentHuggingPriority(.required, for: .horizontal)
    control.setContentCompressionResistancePriority(.required, for: .horizontal)
    rebuild(control)
    context.coordinator.control = control
    context.coordinator.isInteractive = isInteractive
    return control
  }

  func updateNSView(_ control: NSSegmentedControl, context: Context) {
    // Update coordinator's items to ensure it has the latest data
    context.coordinator.items = items
    context.coordinator.iconScale = iconScale

    if control.segmentCount != items.count { rebuild(control) }
    for (i, it) in items.enumerated() {
      control.setLabel(it.title, forSegment: i)
      if let img = NSImage(systemSymbolName: it.systemImage, accessibilityDescription: nil) {
        // Use template mode to allow proper tinting in selected state
        img.isTemplate = true

        // Apply icon scaling
        let scaledImg = scaleImage(img, scale: iconScale)
        control.setImage(scaledImg, forSegment: i)
        control.setImageScaling(.scaleNone, forSegment: i)
      }
      control.setEnabled(it.isEnabled, forSegment: i)
    }
    if let idx = items.firstIndex(where: { $0.tag == selection }) {
      control.selectedSegment = idx
    } else {
      control.selectedSegment = -1
    }
    context.coordinator.isInteractive = isInteractive
  }

  private func scaleImage(_ image: NSImage, scale: CGFloat) -> NSImage {
    let originalSize = image.size
    let scaledSize = NSSize(width: originalSize.width * scale, height: originalSize.height * scale)

    // Add left padding to the icon
    let leftPadding: CGFloat = 4
    let newSize = NSSize(width: scaledSize.width + leftPadding, height: scaledSize.height)

    let scaledImage = NSImage(size: newSize)
    scaledImage.isTemplate = true  // Preserve template mode for proper tinting
    scaledImage.lockFocus()
    image.draw(
      in: NSRect(x: leftPadding, y: 0, width: scaledSize.width, height: scaledSize.height),
      from: NSRect(origin: .zero, size: originalSize),
      operation: .copy,
      fraction: 1.0)
    scaledImage.unlockFocus()
    return scaledImage
  }

  private func rebuild(_ control: NSSegmentedControl) {
    control.segmentCount = items.count
    for (i, it) in items.enumerated() {
      control.setLabel(it.title, forSegment: i)
      if let img = NSImage(systemSymbolName: it.systemImage, accessibilityDescription: nil) {
        // Use template mode to allow proper tinting in selected state
        img.isTemplate = true
        let scaledImg = scaleImage(img, scale: iconScale)
        control.setImage(scaledImg, forSegment: i)
        control.setImageScaling(.scaleNone, forSegment: i)
      }
      control.setEnabled(it.isEnabled, forSegment: i)
    }
  }

  final class Coordinator: NSObject {
    weak var control: NSSegmentedControl?
    var selection: Binding<Selection>
    var items: [Item]
    var isInteractive: Bool = true
    var iconScale: CGFloat = 1.0

    init(selection: Binding<Selection>, items: [Item], iconScale: CGFloat = 1.0) {
      self.selection = selection
      self.items = items
      self.iconScale = iconScale
    }

    @objc func changed(_ sender: NSSegmentedControl) {
      guard isInteractive else { return }
      let idx = sender.selectedSegment
      guard idx >= 0 && idx < items.count else { return }
      // Directly update the binding
      selection.wrappedValue = items[idx].tag
    }
  }
}

// MARK: - Chromed icon button to match split buttons
private struct ChromedIconButton: View {
  let systemImage: String
  var help: String? = nil
  let action: () -> Void
  var body: some View {
    let h: CGFloat = 24
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .frame(height: h)
        .frame(minWidth: h)  // keep a minimum square feel when padding is small
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    .buttonStyle(.plain)
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
    )
    .help(help ?? "")
  }
}

// MARK: - Prompts popover content
private struct PromptsPopover: View {
  enum Mode {
    case insert(terminalKey: String)
    case copy

    var hint: String {
      switch self {
      case .insert:
        return "Selecting a prompt inserts it into the embedded terminal."
      case .copy:
        return "Selecting a prompt copies it to the clipboard."
      }
    }

  }

  let workingDirectory: String
  let mode: Mode
  let builtin: [PresetPromptsStore.Prompt]
  @Binding var query: String
  @Binding var loaded: [ContentView.SourcedPrompt]
  @Binding var hovered: String?
  @Binding var pendingDelete: ContentView.SourcedPrompt?
  let onDismiss: () -> Void
  @FocusState private var searchFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Preset Prompts").font(.headline)
        Spacer()
        Button {
          Task {
            await PresetPromptsStore.shared.openOrCreatePreferredFile(
              for: workingDirectory, withTemplate: builtin)
          }
        } label: {
          Image(systemName: "wrench.and.screwdriver")
        }
        .buttonStyle(.plain)
        .help("Open prompts file")
      }
      Text(mode.hint)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      TextField("Search or type a new command", text: $query)
        .textFieldStyle(.roundedBorder)
        .frame(width: 320)
        .focused($searchFocused)
        .onChange(of: query) { _ in reload() }

      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          let rows = filtered()
          ForEach(rows.indices, id: \.self) { idx in
            let sp = rows[idx]
            let rowKey = sp.command
            HStack(spacing: 8) {
              if hovered == rowKey {
                Button {
                  Task {
                    await PresetPromptsStore.shared.delete(
                      prompt: sp.prompt, location: location(of: sp),
                      workingDirectory: workingDirectory)
                  }
                  reload()
                } label: {
                  Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                .help("Remove")
              }
              Text(sp.label)
                .font(.system(size: 13, weight: .regular))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 8)
            .padding(.trailing, 24)
            .frame(height: 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(idx % 2 == 0 ? Color.secondary.opacity(0.06) : Color.clear)
            .contentShape(Rectangle())
            .onHover { inside in
              if inside { hovered = rowKey } else if hovered == rowKey { hovered = nil }
            }
            .onTapGesture {
              handleSelection(sp.command)
              // Auto-dismiss popover after selecting a preset
              onDismiss()
            }
          }
          if shouldOfferAdd() {
            Button {
              let p = PresetPromptsStore.Prompt(label: query, command: query)
              Task {
                _ = await PresetPromptsStore.shared.add(prompt: p, for: workingDirectory)
                reload()
              }
            } label: {
              Label("Add \(query)", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .padding(.top, 6)
            .padding(.trailing, 24)
          }
        }
      }
      .frame(height: 160)
    }
    .padding(12)
    .onAppear {
      reload()
      // Focus search field by default for quick keyboard input
      DispatchQueue.main.async { self.searchFocused = true }
    }
  }

  private func location(of sp: ContentView.SourcedPrompt) -> PresetPromptsStore.PromptLocation {
    switch sp.source {
    case .project: return .project
    case .user: return .user
    case .builtin: return .builtin
    }
  }

  private func handleSelection(_ value: String) {
    switch mode {
    case .insert(let terminalKey):
      #if canImport(SwiftTerm) && !APPSTORE
        TerminalSessionManager.shared.send(to: terminalKey, text: value)
      #else
        copyToClipboard(value)
      #endif
    case .copy:
      copyToClipboard(value)
      Task {
        await SystemNotifier.shared.notify(
          title: "CodMate",
          body: "Prompt copied. Paste it into your terminal.")
      }
    }
  }

  private func copyToClipboard(_ value: String) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(value, forType: .string)
  }

  private func filtered() -> [ContentView.SourcedPrompt] {
    if query.trimmingCharacters(in: .whitespaces).isEmpty { return loaded }
    let q = query.lowercased()
    return loaded.filter {
      $0.label.lowercased().contains(q) || $0.command.lowercased().contains(q)
    }
  }

  private func shouldOfferAdd() -> Bool {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return false }
    return !loaded.contains(where: { $0.command == q })
  }

  private func reload() {
    Task {
      let store = PresetPromptsStore.shared
      let project = await store.loadProjectOnly(for: workingDirectory)
      let user = await store.loadUserOnly()
      let hidden = await store.loadHidden(for: workingDirectory)
      var seen = Set<String>()
      var out: [ContentView.SourcedPrompt] = []
      func push(_ p: PresetPromptsStore.Prompt, _ src: ContentView.SourcedPrompt.Source) {
        if hidden.contains(p.command) { return }
        if seen.insert(p.command).inserted {
          out.append(ContentView.SourcedPrompt(prompt: p, source: src))
        }
      }
      project.forEach { push($0, .project) }
      user.forEach { push($0, .user) }
      builtin.forEach { push($0, .builtin) }
      await MainActor.run { loaded = out }
    }
  }
}

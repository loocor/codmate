import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
  @ObservedObject var preferences: SessionPreferencesStore
  @Binding private var selectedCategory: SettingCategory
  @Binding private var selectedExtensionsTab: ExtensionsSettingsTab
  @StateObject private var codexVM = CodexVM()
  @StateObject private var geminiVM = GeminiVM()
  @StateObject private var claudeVM = ClaudeCodeVM()
  @StateObject private var updateViewModel = UpdateViewModel()
  @EnvironmentObject private var viewModel: SessionListViewModel
  @ObservedObject private var permissionsManager = SandboxPermissionsManager.shared
  @State private var showLicensesSheet = false
  @State private var availableRemoteHosts: [SSHHost] = []
  @State private var isRequestingSSHAccess = false

  init(
    preferences: SessionPreferencesStore, selection: Binding<SettingCategory>,
    extensionsTab: Binding<ExtensionsSettingsTab>
  ) {
    self._preferences = ObservedObject(wrappedValue: preferences)
    self._selectedCategory = selection
    self._selectedExtensionsTab = extensionsTab
  }

  var body: some View {
    ZStack(alignment: .topLeading) {
      WindowConfigurator { window in
        window.isMovableByWindowBackground = false
        window.identifier = NSUserInterfaceItemIdentifier("CodMateSettingsWindow")
        window.delegate = SettingsWindowDelegate.shared
        if window.toolbar == nil {
          let toolbar = NSToolbar(identifier: "CodMateSettingsToolbar")
          SettingsToolbarCoordinator.shared.configure(toolbar: toolbar)
          window.toolbar = toolbar
        }
        window.title = "Settings"
        // Ensure the system titlebar bottom hairline is shown to unify
        // appearance across all settings pages.
        window.titlebarSeparatorStyle = .line

        var minSize = window.contentMinSize
        minSize.width = max(minSize.width, 800)
        minSize.height = max(minSize.height, 560)
        window.contentMinSize = minSize

        var maxSize = window.contentMaxSize
        if maxSize.width > 0 { maxSize.width = max(maxSize.width, 2000) }
        if maxSize.height > 0 { maxSize.height = max(maxSize.height, 1400) }
        window.contentMaxSize = maxSize
      }
      .frame(width: 0, height: 0)

      NavigationSplitView {
        List(SettingCategory.allCases, selection: $selectedCategory) { category in
          let isSelected = (category == selectedCategory)
          HStack(alignment: .center, spacing: 8) {
            Image(systemName: category.icon)
              .foregroundStyle(isSelected ? Color.white : Color.accentColor)
              .frame(width: 26, alignment: .center)
            VStack(alignment: .leading, spacing: 0) {
              Text(category.title)
                .font(.headline)
              Text(category.description)
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
          }
          .padding(.vertical, 6)
          .tag(category)
        }
        .listStyle(.sidebar)
        .controlSize(.small)
        .environment(\.defaultMinListRowHeight, 18)
        .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 300)
      } detail: {
        selectedCategoryView
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .task { await codexVM.loadAll() }
          .navigationSplitViewColumnWidth(min: 640, ideal: 800, max: 1800)
      }
      .codmateNavigationSplitViewBalancedIfAvailable()
      .codmateToolbarRemovingSidebarToggleIfAvailable()
    }
    .frame(minWidth: 900, minHeight: 520)
  }

  private final class SettingsWindowDelegate: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowDelegate()

    func windowShouldClose(_ sender: NSWindow) -> Bool {
      // Check if main window is still visible
      let mainWindowId = NSUserInterfaceItemIdentifier("CodMateMainWindow")
      let mainWindowVisible = NSApplication.shared.windows.contains { window in
        window.identifier == mainWindowId && window.isVisible
      }

      // Only hide Dock icon if no other app windows are visible
      if !mainWindowVisible {
        NSApplication.shared.setActivationPolicy(.accessory)
      }

      return true
    }
  }

  private final class SettingsToolbarCoordinator: NSObject, NSToolbarDelegate {
    static let shared = SettingsToolbarCoordinator()
    private let spacerID = NSToolbarItem.Identifier("CodMateSettingsSpacer")

    func configure(toolbar: NSToolbar) {
      toolbar.delegate = self
      toolbar.allowsUserCustomization = false
      toolbar.allowsExtensionItems = false
      toolbar.displayMode = .iconOnly
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
      [spacerID]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
      [spacerID]
    }

    func toolbar(
      _ toolbar: NSToolbar,
      itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
      willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
      guard itemIdentifier == spacerID else { return nil }
      let item = NSToolbarItem(itemIdentifier: itemIdentifier)
      let view = NSView(frame: .zero)
      view.translatesAutoresizingMaskIntoConstraints = false
      view.isHidden = true
      view.widthAnchor.constraint(equalToConstant: 1).isActive = true
      view.heightAnchor.constraint(equalToConstant: 1).isActive = true
      item.view = view
      return item
    }
  }

  @ViewBuilder
  private var selectedCategoryView: some View {
    switch selectedCategory {
    case .general:
      generalSettings
    case .terminal:
      terminalSettings
    case .notifications:
      notificationsSettings
    case .command:
      commandSettings
    case .providers:
      providersSettings
    case .codex:
      codexSettings
    case .gemini:
      geminiSettings
    case .remoteHosts:
      RemoteHostsSettingsPane(preferences: preferences)
    case .gitReview:
      gitReviewSettings
    case .claudeCode:
      claudeCodeSettings
    case .advanced:
      advancedSettings
    case .mcpServer:
      extensionsSettings
    case .about:
      aboutSettings
    }
  }

  private var generalSettings: some View {
    settingsScroll {
      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 6) {
          Text("General Settings")
            .font(.title2)
            .fontWeight(.bold)
          Text("Configure basic application settings")
            .font(.subheadline)
            .foregroundColor(.secondary)
        }

        VStack(alignment: .leading, spacing: 10) {
          Text("App Behavior").font(.headline).fontWeight(.semibold)
          settingsCard {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
              GridRow {
                VStack(alignment: .leading, spacing: 2) {
                  Label("Confirm before quit", systemImage: "exclamationmark.triangle")
                    .font(.subheadline).fontWeight(.medium)
                  Text("Show confirmation dialog when quitting the app")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("", isOn: $preferences.confirmBeforeQuit)
                  .labelsHidden()
                  .toggleStyle(.switch)
                  .controlSize(.small)
                  .frame(maxWidth: .infinity, alignment: .trailing)
                  .gridColumnAlignment(.trailing)
              }

              gridDivider

              GridRow {
                VStack(alignment: .leading, spacing: 2) {
                  Label("Launch at login", systemImage: "power")
                    .font(.subheadline).fontWeight(.medium)
                  Text("Automatically start CodMate when you log in")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("", isOn: $preferences.launchAtLogin)
                  .labelsHidden()
                  .toggleStyle(.switch)
                  .controlSize(.small)
                  .frame(maxWidth: .infinity, alignment: .trailing)
                  .gridColumnAlignment(.trailing)
              }
            }
          }
        }

        VStack(alignment: .leading, spacing: 10) {
          Text("System Menu").font(.headline).fontWeight(.semibold)
          settingsCard {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
              GridRow {
                VStack(alignment: .leading, spacing: 2) {
                  Label("System menu bar icon", systemImage: "menubar.rectangle")
                    .font(.subheadline).fontWeight(.medium)
                  Text("Control whether the menu bar icon appears")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Picker("", selection: $preferences.systemMenuVisibility) {
                  ForEach(SystemMenuVisibility.allCases) { visibility in
                    Text(visibility.title).tag(visibility)
                  }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .trailing)
                .pickerStyle(.segmented)
                .padding(2)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
              }
            }
          }
        }

        VStack(alignment: .leading, spacing: 10) {
          Text("Editor").font(.headline).fontWeight(.semibold)
          settingsCard {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
              GridRow {
                let editors = EditorApp.installedEditors
                VStack(alignment: .leading, spacing: 0) {
                  Label("Default Editor", systemImage: "pencil.and.outline")
                    .font(.subheadline).fontWeight(.medium)
                  Text("Used for quick open actions in Review and elsewhere")
                    .font(.caption).foregroundStyle(.secondary)
                }
                if editors.isEmpty {
                  Text("No supported editors found. Install VS Code, Cursor, or Zed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                  Picker("", selection: $preferences.defaultFileEditor) {
                    ForEach(editors) { app in
                      Text(app.title).tag(app)
                    }
                  }
                  .labelsHidden()
                  .frame(maxWidth: .infinity, alignment: .trailing)
                }
              }
            }
          }
        }

        VStack(alignment: .leading, spacing: 10) {
          Text("Search").font(.headline).fontWeight(.semibold)
          settingsCard {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
              GridRow {
                VStack(alignment: .leading, spacing: 2) {
                  Label("Global search panel", systemImage: "magnifyingglass")
                    .font(.subheadline).fontWeight(.medium)
                  Text("Choose how the ⌘F panel appears")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Picker("Search panel style", selection: $preferences.searchPanelStyle) {
                  ForEach(GlobalSearchPanelStyle.allCases) { style in
                    Text(style.title).tag(style)
                  }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .padding(2)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                  RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
                )
                .disabled(false)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .gridColumnAlignment(.trailing)
                .gridCellAnchor(.trailing)
              }
            }
          }
        }

        VStack(alignment: .leading, spacing: 10) {
          Text("Message Types").font(.headline).fontWeight(.semibold)
          settingsCard {
            messageTypeVisibilitySection()
          }
        }

        #if APPSTORE
          VStack(alignment: .leading, spacing: 10) {
            Text("App Store Version").font(.headline).fontWeight(.semibold)
            settingsCard {
              VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                  Image(systemName: "info.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
                  VStack(alignment: .leading, spacing: 8) {
                    Text("About This Version")
                      .font(.subheadline)
                      .fontWeight(.semibold)
                    Text(
                      "You're using the Mac App Store version of CodMate, which includes enhanced security through App Sandbox."
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                  }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                  Label("Embedded Terminal Behavior", systemImage: "terminal")
                    .font(.subheadline)
                    .fontWeight(.medium)
                  Text(
                    "The embedded terminal provides a basic shell environment for navigation and system commands. Third-party CLI tools (codex, claude) cannot be executed directly from the embedded terminal due to macOS security restrictions."
                  )
                  .font(.caption)
                  .foregroundColor(.secondary)
                  .fixedSize(horizontal: false, vertical: true)

                  Text(
                    "To run CLI sessions, use the \"Copy Command\" or \"Open in Terminal.app\" buttons to execute commands in the external Terminal app."
                  )
                  .font(.caption)
                  .foregroundColor(.blue)
                  .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                  Label("Git Review Functionality", systemImage: "square.and.pencil")
                    .font(.subheadline)
                    .fontWeight(.medium)
                  Text(
                    "Git Review works fully in the App Store version using the system git tool (/usr/bin/git). You may be prompted to authorize repository folders for the first time."
                  )
                  .font(.caption)
                  .foregroundColor(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
                }
              }
              .padding(4)
            }
          }
        #endif
      }
      .padding(.bottom, 16)
    }
  }

  // MARK: - Message Type Visibility Section
  @ViewBuilder
  private func messageTypeVisibilitySection() -> some View {
    VStack(alignment: .leading, spacing: 16) {

      // Timeline visibility section
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Image(systemName: "eye")
            .font(.subheadline)
            .foregroundStyle(.secondary)
          Text("Timeline visibility")
            .font(.subheadline)
            .fontWeight(.medium)
          Spacer()
          Button(action: {
            preferences.timelineVisibleKinds = MessageVisibilityKind.timelineDefault
          }) {
            Image(systemName: "arrow.counterclockwise.circle.fill")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .frame(width: 24, height: 24)
          .help("Restore timeline visibility to defaults")
        }
        Text("Choose which message types appear in the conversation timeline")
          .font(.caption)
          .foregroundStyle(.secondary)

        messageTypeGrid(for: $preferences.timelineVisibleKinds)
      }

      Divider()

      // Markdown export section
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Image(systemName: "doc.text")
            .font(.subheadline)
            .foregroundStyle(.secondary)
          Text("Markdown export")
            .font(.subheadline)
            .fontWeight(.medium)
          Spacer()
          Button(action: {
            preferences.markdownVisibleKinds = MessageVisibilityKind.markdownDefault
          }) {
            Image(systemName: "arrow.counterclockwise.circle.fill")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .frame(width: 24, height: 24)
          .help("Restore markdown export to defaults")
        }
        Text("Choose which message types are included when exporting Markdown")
          .font(.caption)
          .foregroundStyle(.secondary)

        messageTypeGrid(for: $preferences.markdownVisibleKinds)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func messageTypeGrid(for selection: Binding<Set<MessageVisibilityKind>>) -> some View {
    let columns = [
      GridItem(.flexible(), spacing: 12),
      GridItem(.flexible(), spacing: 12),
      GridItem(.flexible(), spacing: 12),
      GridItem(.flexible(), spacing: 12),
    ]

    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
      ForEach(messageTypeRows) { row in
        if let kind = row.kind {
          HStack(spacing: 6) {
            Toggle("", isOn: binding(selection, kind))
              .labelsHidden()
              .toggleStyle(.switch)
              .controlSize(.small)
            Text(row.title)
              .font(.caption)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }
  }

  private func binding(
    _ selection: Binding<Set<MessageVisibilityKind>>, _ kind: MessageVisibilityKind
  ) -> Binding<Bool> {
    Binding<Bool>(
      get: { selection.wrappedValue.contains(kind) },
      set: { newVal in
        var s = selection.wrappedValue
        if newVal { s.insert(kind) } else { s.remove(kind) }
        selection.wrappedValue = s
      }
    )
  }

  private struct MessageTypeRow: Identifiable {
    let id: String
    let title: String
    let kind: MessageVisibilityKind?
    let level: Int
    let isGroup: Bool
  }

  private var messageTypeRows: [MessageTypeRow] {
    [
      MessageTypeRow(
        id: MessageVisibilityKind.user.rawValue, title: MessageVisibilityKind.user.settingsLabel,
        kind: .user, level: 0,
        isGroup: false),
      MessageTypeRow(
        id: MessageVisibilityKind.assistant.rawValue,
        title: MessageVisibilityKind.assistant.settingsLabel, kind: .assistant,
        level: 0, isGroup: false),
      MessageTypeRow(
        id: MessageVisibilityKind.reasoning.rawValue,
        title: MessageVisibilityKind.reasoning.settingsLabel, kind: .reasoning,
        level: 0, isGroup: false),
      MessageTypeRow(
        id: MessageVisibilityKind.codeEdit.rawValue,
        title: MessageVisibilityKind.codeEdit.settingsLabel, kind: .codeEdit,
        level: 0, isGroup: false),
      MessageTypeRow(
        id: MessageVisibilityKind.tool.rawValue, title: MessageVisibilityKind.tool.settingsLabel,
        kind: .tool, level: 0,
        isGroup: false),
      MessageTypeRow(
        id: MessageVisibilityKind.tokenUsage.rawValue,
        title: MessageVisibilityKind.tokenUsage.settingsLabel, kind: .tokenUsage,
        level: 0, isGroup: false),
      MessageTypeRow(
        id: MessageVisibilityKind.infoOther.rawValue,
        title: MessageVisibilityKind.infoOther.settingsLabel, kind: .infoOther,
        level: 0, isGroup: false),
    ]
  }

  private var codexSettings: some View {
    settingsScroll {
      CodexSettingsView(codexVM: codexVM, preferences: preferences)
    }
  }

  private var geminiSettings: some View {
    settingsScroll {
      GeminiSettingsView(vm: geminiVM, preferences: preferences)
    }
  }

  private var claudeCodeSettings: some View {
    settingsScroll {
      ClaudeCodeSettingsView(vm: claudeVM, preferences: preferences)
    }
  }

  private var gitReviewSettings: some View {
    settingsScroll {
      GitReviewSettingsView(preferences: preferences)
    }
  }

  private var providersSettings: some View {
    settingsScroll {
      ProvidersSettingsView(preferences: preferences)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
  }

  // MARK: - Advanced
  private var advancedSettings: some View {
    settingsScroll {
      AdvancedSettingsView(preferences: preferences)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
  }

  private var terminalSettings: some View {
    settingsScroll {
      if AppSandbox.isEnabled {
        VStack(alignment: .leading, spacing: 20) {
          VStack(alignment: .leading, spacing: 6) {
            Text("Terminal Settings")
              .font(.title2)
              .fontWeight(.bold)
            Text("Embedded terminal features are unavailable in the App Store build.")
              .font(.subheadline)
              .foregroundColor(.secondary)
          }

          VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 18) {
              // Row: Copy to clipboard (always relevant)
              // Row: Default external app (still relevant)
              GridRow {
                VStack(alignment: .leading, spacing: 0) {
                  Text("Auto open external terminal")
                    .font(.subheadline).fontWeight(.medium)
                  Text("CodMate helps open the terminal app for external sessions")
                    .font(.caption).foregroundColor(.secondary)
                }
                let terminals = externalTerminalOrderedProfiles(includeNone: true)
                Picker("", selection: $preferences.defaultResumeExternalAppId) {
                  ForEach(terminals) { profile in
                    Text(profile.displayTitle).tag(profile.id)
                  }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .gridColumnAlignment(.trailing)
                .gridCellAnchor(.trailing)
              }

              gridDivider

              GridRow {
                VStack(alignment: .leading, spacing: 0) {
                  Text("Copy new or resume commands to clipboard")
                    .font(.subheadline).fontWeight(.medium)
                  Text("Automatically copy new or resume commands when starting sessions")
                    .font(.caption).foregroundColor(.secondary)
                }
                Toggle("", isOn: $preferences.defaultResumeCopyToClipboard)
                  .labelsHidden()
                  .toggleStyle(.switch)
                  .controlSize(.small)
                  .frame(maxWidth: .infinity, alignment: .trailing)
                  .gridColumnAlignment(.trailing)
              }

              gridDivider

              GridRow {
                VStack(alignment: .leading, spacing: 0) {
                  Text("Prompt for Warp tab title")
                    .font(.subheadline).fontWeight(.medium)
                  Text("Show an input dialog before copying Warp commands")
                    .font(.caption).foregroundColor(.secondary)
                }
                Toggle("", isOn: $preferences.promptForWarpTitle)
                  .labelsHidden()
                  .toggleStyle(.switch)
                  .controlSize(.small)
                  .frame(maxWidth: .infinity, alignment: .trailing)
                  .gridColumnAlignment(.trailing)
              }
            }
          }
        }
        .padding(.bottom, 16)
      } else {
        VStack(alignment: .leading, spacing: 20) {
          VStack(alignment: .leading, spacing: 6) {
            Text("Terminal Settings")
              .font(.title2)
              .fontWeight(.bold)
            Text("Configure terminal behavior and resume preferences")
              .font(.subheadline)
              .foregroundColor(.secondary)
          }

          VStack(alignment: .leading, spacing: 10) {
            Text("Embedded Terminal").font(.headline).fontWeight(.semibold)
            settingsCard {
              Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                // Row: Embedded terminal toggle
                GridRow {
                  VStack(alignment: .leading, spacing: 2) {
                    Label("Run in embedded terminal", systemImage: "terminal")
                      .font(.subheadline).fontWeight(.medium)
                    Text("Use the built-in terminal instead of an external one")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      .fixedSize(horizontal: false, vertical: true)
                  }
                  Toggle("", isOn: $preferences.defaultResumeUseEmbeddedTerminal)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .gridColumnAlignment(.trailing)
                    .disabled(AppDistribution.isAppStore || AppSandbox.isEnabled)
                }

                gridDivider

                if AppSandbox.isEnabled {
                  // Row: Use CLI console (no shell)
                  GridRow {
                    VStack(alignment: .leading, spacing: 2) {
                      Label("Use embedded CLI console (no shell)", systemImage: "text.terminal")
                        .font(.subheadline).fontWeight(.medium)
                      Text("Starts codex/claude directly")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Toggle("", isOn: $preferences.useEmbeddedCLIConsole)
                      .labelsHidden()
                      .toggleStyle(.switch)
                      .controlSize(.small)
                      .frame(maxWidth: .infinity, alignment: .trailing)
                      .gridColumnAlignment(.trailing)
                      .disabled(AppDistribution.isAppStore || AppSandbox.isEnabled)
                  }

                  gridDivider
                }

                // Row: Font family & size (system font panel)
                GridRow {
                  VStack(alignment: .leading, spacing: 2) {
                    Label("Font & size", systemImage: "textformat")
                      .font(.subheadline).fontWeight(.medium)
                    Text("Opens the macOS font panel to pick a monospaced font.")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      .fixedSize(horizontal: false, vertical: true)
                  }
                  FontPickerButton(
                    fontName: $preferences.terminalFontName,
                    fontSize: $preferences.terminalFontSize
                  )
                  .frame(maxWidth: .infinity, alignment: .trailing)
                  .gridColumnAlignment(.trailing)
                  .disabled(!preferences.defaultResumeUseEmbeddedTerminal)
                }

                gridDivider

                // Row: Cursor style only
                GridRow {
                  VStack(alignment: .leading, spacing: 2) {
                    Label("Cursor style", systemImage: "cursorarrow")
                      .font(.subheadline).fontWeight(.medium)
                    Text("Choose the caret shape shown inside the terminal.")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      .fixedSize(horizontal: false, vertical: true)
                  }
                  Picker(
                    "",
                    selection: Binding(
                      get: { preferences.terminalCursorStyleOption },
                      set: { preferences.terminalCursorStyleOption = $0 }
                    )
                  ) {
                    ForEach(TerminalCursorStyleOption.allCases) { option in
                      Text(option.title).tag(option)
                    }
                  }
                  .labelsHidden()
                  .pickerStyle(.menu)
                  .frame(maxWidth: .infinity, alignment: .trailing)
                  .gridColumnAlignment(.trailing)
                  .disabled(!preferences.defaultResumeUseEmbeddedTerminal)
                }
              }
            }
          }

          VStack(alignment: .leading, spacing: 10) {
            Text("External Terminal").font(.headline).fontWeight(.semibold)
            settingsCard {
              Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                  VStack(alignment: .leading, spacing: 2) {
                    Label("Auto open external terminal", systemImage: "arrow.up.right.square")
                      .font(.subheadline).fontWeight(.medium)
                    Text("CodMate helps open the terminal app for external sessions")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      .fixedSize(horizontal: false, vertical: true)
                  }
                  let terminals = externalTerminalOrderedProfiles(includeNone: true)
                  Picker("", selection: $preferences.defaultResumeExternalAppId) {
                    ForEach(terminals) { profile in
                      Text(profile.displayTitle).tag(profile.id)
                    }
                  }
                  .labelsHidden()
                  .pickerStyle(.menu)
                  .frame(maxWidth: .infinity, alignment: .trailing)
                  .gridColumnAlignment(.trailing)
                  .gridCellAnchor(.trailing)
                }

                gridDivider

                GridRow {
                  VStack(alignment: .leading, spacing: 2) {
                    Label("Copy new or resume commands to clipboard", systemImage: "doc.on.clipboard")
                      .font(.subheadline).fontWeight(.medium)
                    Text("Automatically copy new or resume commands when starting sessions")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      .fixedSize(horizontal: false, vertical: true)
                  }
                  Toggle("", isOn: $preferences.defaultResumeCopyToClipboard)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .gridColumnAlignment(.trailing)
                }

                gridDivider

                GridRow {
                  VStack(alignment: .leading, spacing: 2) {
                    Label("Prompt for Warp tab title", systemImage: "text.bubble")
                      .font(.subheadline).fontWeight(.medium)
                    Text("Show an input dialog before copying Warp commands")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      .fixedSize(horizontal: false, vertical: true)
                  }
                  Toggle("", isOn: $preferences.promptForWarpTitle)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .gridColumnAlignment(.trailing)
                }
              }
            }
          }
        }
        .padding(.bottom, 16)
      }
    }
  }

  private var notificationsSettings: some View {
    settingsScroll {
      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Notifications Settings")
            .font(.title2)
            .fontWeight(.bold)
          Text("Configure notification delivery and hooks")
            .font(.subheadline)
            .foregroundColor(.secondary)
        }

        VStack(alignment: .leading, spacing: 10) {
          Text("Common").font(.headline).fontWeight(.semibold)
          settingsCard {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
              GridRow {
                VStack(alignment: .leading, spacing: 2) {
                  Label("Commit message notifications", systemImage: "square.and.pencil")
                    .font(.subheadline).fontWeight(.medium)
                  Text("Notify when commit message generation completes or fails.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("", isOn: $preferences.commitMessageNotificationsEnabled)
                  .labelsHidden()
                  .toggleStyle(.switch)
                  .controlSize(.small)
                  .frame(maxWidth: .infinity, alignment: .trailing)
                  .gridColumnAlignment(.trailing)
              }

              gridDivider

              GridRow {
                VStack(alignment: .leading, spacing: 2) {
                  Label("Title & comment notifications", systemImage: "text.bubble")
                    .font(.subheadline).fontWeight(.medium)
                  Text("Notify when title and comment generation completes or fails.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("", isOn: $preferences.titleCommentNotificationsEnabled)
                  .labelsHidden()
                  .toggleStyle(.switch)
                  .controlSize(.small)
                  .frame(maxWidth: .infinity, alignment: .trailing)
                  .gridColumnAlignment(.trailing)
              }

              gridDivider

              GridRow {
                VStack(alignment: .leading, spacing: 2) {
                  Label("Copy command notifications", systemImage: "doc.on.doc")
                    .font(.subheadline).fontWeight(.medium)
                  Text("Notify after copying New/Resume commands to the clipboard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("", isOn: $preferences.commandCopyNotificationsEnabled)
                  .labelsHidden()
                  .toggleStyle(.switch)
                  .controlSize(.small)
                  .frame(maxWidth: .infinity, alignment: .trailing)
                  .gridColumnAlignment(.trailing)
              }
            }
          }
        }

        VStack(alignment: .leading, spacing: 10) {
          Text("Codex").font(.headline).fontWeight(.semibold)
          settingsCard {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
              GridRow {
                VStack(alignment: .leading, spacing: 2) {
                  Label("TUI Notifications", systemImage: "terminal")
                    .font(.subheadline).fontWeight(.medium)
                  Text(
                    "Show in-terminal notifications during TUI sessions (supported terminals only)."
                  )
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("", isOn: $codexVM.tuiNotifications)
                  .labelsHidden()
                  .toggleStyle(.switch)
                  .controlSize(.small)
                  .onChange(of: codexVM.tuiNotifications) { _ in
                    codexVM.scheduleApplyTuiNotificationsDebounced()
                  }
                  .frame(maxWidth: .infinity, alignment: .trailing)
              }

              gridDivider

              GridRow {
                VStack(alignment: .leading, spacing: 2) {
                  Label("System Notifications", systemImage: "bell")
                    .font(.subheadline).fontWeight(.medium)
                  Text(
                    "Forward Codex turn-complete events to macOS notifications via notify."
                  )
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("", isOn: $codexVM.systemNotifications)
                  .labelsHidden()
                  .toggleStyle(.switch)
                  .controlSize(.small)
                  .onChange(of: codexVM.systemNotifications) { _ in
                    codexVM.scheduleApplySystemNotificationsDebounced()
                  }
                  .frame(maxWidth: .infinity, alignment: .trailing)
              }

              if let path = codexVM.notifyBridgePath {
                gridDivider
                GridRow {
                  VStack(alignment: .leading, spacing: 2) {
                    Label("Notify bridge", systemImage: "link")
                      .font(.subheadline).fontWeight(.medium)
                    Text(path)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      .fixedSize(horizontal: false, vertical: true)
                  }
                }
              }

              gridDivider

              GridRow {
                VStack(alignment: .leading, spacing: 2) {
                  Label("Self-test", systemImage: "checkmark.seal")
                    .font(.subheadline).fontWeight(.medium)
                  Text("Send a sample event through the notify bridge.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                  if codexVM.notifyBridgeHealthy {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                  } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                      .foregroundStyle(.orange)
                  }
                  Button("Run Self-test") { Task { await codexVM.runNotifySelfTest() } }
                    .controlSize(.small)
                  if let r = codexVM.notifySelfTestResult {
                    Text(r).font(.caption).foregroundStyle(.secondary)
                  }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
              }
            }
          }
        }

        VStack(alignment: .leading, spacing: 10) {
          Text("Claude Code").font(.headline).fontWeight(.semibold)
          settingsCard {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
              GridRow {
                VStack(alignment: .leading, spacing: 2) {
                  Label("System Notifications", systemImage: "bell")
                    .font(.subheadline).fontWeight(.medium)
                  Text("Forward Claude Code permission and completion hooks to macOS via codmate://notify.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("", isOn: $claudeVM.notificationsEnabled)
                  .labelsHidden()
                  .toggleStyle(.switch)
                  .controlSize(.small)
                  .frame(maxWidth: .infinity, alignment: .trailing)
                  .onChange(of: claudeVM.notificationsEnabled) { _ in
                    claudeVM.scheduleApplyNotificationSettingsDebounced()
                  }
              }

              gridDivider

              GridRow {
                VStack(alignment: .leading, spacing: 2) {
                  Label("Self-test", systemImage: "checkmark.seal")
                    .font(.subheadline).fontWeight(.medium)
                  Text("Send a sample event through the notify bridge.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                  if claudeVM.notificationBridgeHealthy {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                  } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                      .foregroundStyle(.orange)
                  }
                  Button("Run Self-test") { Task { await claudeVM.runNotificationSelfTest() } }
                    .controlSize(.small)
                  if let result = claudeVM.notificationSelfTestResult {
                    Text(result).font(.caption).foregroundStyle(.secondary)
                  }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
              }
            }
          }
        }

        VStack(alignment: .leading, spacing: 10) {
          Text("Gemini CLI").font(.headline).fontWeight(.semibold)
          settingsCard {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
              GridRow {
                VStack(alignment: .leading, spacing: 2) {
                  Label("System Notifications", systemImage: "bell")
                    .font(.subheadline).fontWeight(.medium)
                  Text("Forward Gemini permission prompts to macOS via codmate://notify.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("", isOn: $geminiVM.notificationsEnabled)
                  .labelsHidden()
                  .toggleStyle(.switch)
                  .controlSize(.small)
                  .onChange(of: geminiVM.notificationsEnabled) { _ in
                    geminiVM.scheduleApplyNotificationSettingsDebounced()
                  }
                  .frame(maxWidth: .infinity, alignment: .trailing)
              }

              gridDivider

              GridRow {
                VStack(alignment: .leading, spacing: 2) {
                  Label("Self-test", systemImage: "checkmark.seal")
                    .font(.subheadline).fontWeight(.medium)
                  Text("Send a sample event through the notify bridge.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                  if geminiVM.notificationBridgeHealthy {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                  } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                      .foregroundStyle(.orange)
                  }
                  Button("Run Self-test") { Task { await geminiVM.runNotificationSelfTest() } }
                    .controlSize(.small)
                  if let result = geminiVM.notificationSelfTestResult {
                    Text(result).font(.caption).foregroundStyle(.secondary)
                  }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
              }
            }
          }
        }
      }
      .padding(.bottom, 16)
    }
    .task {
      await claudeVM.loadAll()
      await geminiVM.loadIfNeeded()
    }
  }

  private var commandSettings: some View {
    settingsScroll {
      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Command Options")
            .font(.title2)
            .fontWeight(.bold)
          Text("Default sandbox and approval policies for Codex commands")
            .font(.subheadline)
            .foregroundColor(.secondary)
        }

        VStack(alignment: .leading, spacing: 10) {
          Text("Codex CLI Defaults").font(.headline).fontWeight(.semibold)
          settingsCard {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 18) {
              GridRow {
                VStack(alignment: .leading, spacing: 0) {
                  Text("Sandbox policy (-s, --sandbox)")
                    .font(.subheadline).fontWeight(.medium)
                  Text("Filesystem access level for generated commands")
                    .font(.caption).foregroundColor(.secondary)
                }
                Picker("", selection: $preferences.defaultResumeSandboxMode) {
                  ForEach(SandboxMode.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .trailing)
                .gridColumnAlignment(.trailing)
              }

              gridDivider

              GridRow {
                VStack(alignment: .leading, spacing: 0) {
                  Text("Approval policy (-a, --ask-for-approval)")
                    .font(.subheadline).fontWeight(.medium)
                  Text("When human confirmation is required")
                    .font(.caption).foregroundColor(.secondary)
                }
                Picker("", selection: $preferences.defaultResumeApprovalPolicy) {
                  ForEach(ApprovalPolicy.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .trailing)
                .gridColumnAlignment(.trailing)
              }

              gridDivider

              GridRow {
                VStack(alignment: .leading, spacing: 0) {
                  Text("Enable full-auto (--full-auto)")
                    .font(.subheadline).fontWeight(.medium)
                  Text("Alias for on-failure approvals with workspace-write sandbox")
                    .font(.caption).foregroundColor(.secondary)
                }
                Toggle("", isOn: $preferences.defaultResumeFullAuto)
                  .labelsHidden()
                  .toggleStyle(.switch)
                  .frame(maxWidth: .infinity, alignment: .trailing)
                  .gridColumnAlignment(.trailing)
              }

              gridDivider

              GridRow {
                VStack(alignment: .leading, spacing: 0) {
                  Text("Bypass approvals & sandbox")
                    .font(.subheadline).fontWeight(.medium)
                    .foregroundColor(.red)
                  Text("--dangerously-bypass-approvals-and-sandbox (use with care)")
                    .font(.caption).foregroundColor(.secondary)
                }
                Toggle("", isOn: $preferences.defaultResumeDangerBypass)
                  .labelsHidden()
                  .toggleStyle(.switch)
                  .tint(.red)
                  .frame(maxWidth: .infinity, alignment: .trailing)
                  .gridColumnAlignment(.trailing)
              }
            }
          }
        }
      }
      .padding(.bottom, 16)
    }
  }

  private var aboutSettings: some View {
    settingsScroll {
      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 6) {
          Text("About CodMate")
            .font(.title2)
            .fontWeight(.bold)
          Text("CodMate is a macOS SwiftUI app for managing CLI AI sessions: browse, search, organize, resume, and review work produced by Codex, Claude Code, and Gemini CLI.")
            .font(.subheadline)
            .foregroundColor(.secondary)
        }

        VStack(alignment: .leading, spacing: 12) {
          LabeledContent("Version") { Text(versionString) }
          LabeledContent("Build Timestamp") { Text(buildTimestampString) }
          LabeledContent("Latest Release") {
            Link(releasesURL.absoluteString, destination: releasesURL)
          }
          LabeledContent("Repository") {
            Link(repoURL.absoluteString, destination: repoURL)
          }
          LabeledContent("Project URL") {
            Link(projectURL.absoluteString, destination: projectURL)
          }
          LabeledContent("Open Source Licenses") {
            Button("View…") { showLicensesSheet = true }
              .buttonStyle(.bordered)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        AboutUpdateSection(viewModel: updateViewModel)
          .onAppear {
            updateViewModel.loadCached()
            updateViewModel.checkIfNeeded(trigger: .aboutAuto)
          }

        // Discord Community Card
        HStack(spacing: 12) {
          Image(systemName: "bubble.left.and.bubble.right.fill")
            .font(.title2)
            .foregroundStyle(.blue)
            .frame(width: 32)
          VStack(alignment: .leading, spacing: 4) {
            Text("Join our Discord community")
              .font(.headline)
              .fontWeight(.semibold)
            Text("Get help, share feedback, and connect with other users")
              .font(.caption)
              .foregroundStyle(.secondary)
            Link("Join Discord", destination: discordURL)
              .font(.subheadline)
              .fontWeight(.medium)
              .padding(.top, 2)
          }
          Spacer()
        }
        .padding(16)
        .background(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.blue.opacity(0.08))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color.blue.opacity(0.2), lineWidth: 1)
        )
      }
    }
    .sheet(isPresented: $showLicensesSheet) {
      OpenSourceLicensesView(repoURL: repoURL)
        .frame(minWidth: 600, minHeight: 480)
    }
  }

  private var versionString: String {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "—"
    let build = info?["CFBundleVersion"] as? String ?? "—"
    return "\(version) (\(build))"
  }

  private var buildTimestampString: String {
    guard let executableURL = Bundle.main.executableURL,
      let attrs = try? FileManager.default.attributesOfItem(atPath: executableURL.path),
      let date = attrs[.modificationDate] as? Date
    else { return "Unavailable" }
    return Self.buildDateFormatter.string(from: date)
  }

  private var projectURL: URL { URL(string: "https://umate.ai/codmate")! }
  private var repoURL: URL { URL(string: "https://github.com/loocor/CodMate")! }
  private var releasesURL: URL { URL(string: "https://github.com/loocor/CodMate/releases/latest")! }
  private var discordURL: URL { URL(string: "https://discord.gg/5AcaTpVCcx")! }
  private var mcpMateURL: URL { URL(string: "https://mcpmate.io/")! }
  private let mcpMateTagline = "Dedicated MCP orchestration for Codex workflows."

  private static let buildDateFormatter: DateFormatter = {
    let df = DateFormatter()
    df.dateStyle = .medium
    df.timeStyle = .medium
    return df
  }()

  private var extensionsSettings: some View {
    ExtensionsSettingsView(
      selectedTab: $selectedExtensionsTab, openMCPMateDownload: openMCPMateDownload
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .padding(.top, 24)
    .padding(.horizontal, 24)
    .padding(.bottom, 24)
  }

  private var remoteHostsSettings: some View {
    settingsScroll {
      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Remote Hosts")
            .font(.title2)
            .fontWeight(.bold)
          Text("Choose which SSH hosts CodMate should mirror for remote Codex/Claude sessions.")
            .font(.subheadline)
            .foregroundColor(.secondary)
        }

        let sshPermissionGranted = permissionsManager.hasPermission(for: .sshConfig)

        HStack(alignment: .firstTextBaseline) {
          Spacer(minLength: 8)
          HStack(spacing: 10) {
            Button(role: .none) {
              DispatchQueue.main.async {
                preferences.enabledRemoteHosts = []
              }
            } label: {
              Text("Clear All")
            }
            .buttonStyle(.bordered)
            .disabled(preferences.enabledRemoteHosts.isEmpty)
            Button {
              Task { await viewModel.syncRemoteHosts(force: true, refreshAfter: true) }
            } label: {
              Label("Sync Hosts", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.bordered)
            .disabled(preferences.enabledRemoteHosts.isEmpty)
            Button {
              reloadRemoteHosts()
            } label: {
              Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(!sshPermissionGranted)
          }
        }

        if !sshPermissionGranted {
          VStack(alignment: .leading, spacing: 8) {
            Label("Grant Access to ~/.ssh", systemImage: "lock.square")
              .font(.headline)
            Text(
              "CodMate needs permission to read ~/.ssh/config before it can list your SSH hosts. Grant access once and the app will remember it for future launches."
            )
            .font(.caption)
            .foregroundColor(.secondary)
            Button {
              guard !isRequestingSSHAccess else { return }
              isRequestingSSHAccess = true
              Task {
                let granted = await permissionsManager.requestPermission(for: .sshConfig)
                await MainActor.run {
                  isRequestingSSHAccess = false
                  if granted { reloadRemoteHosts() }
                }
              }
            } label: {
              HStack(spacing: 6) {
                if isRequestingSSHAccess {
                  ProgressView()
                    .controlSize(.small)
                }
                Text(isRequestingSSHAccess ? "Requesting…" : "Grant Access")
              }
              .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
          }
          .padding()
          .background(Color(nsColor: .separatorColor).opacity(0.2))
          .cornerRadius(10)
        }

        let hosts = sshPermissionGranted ? availableRemoteHosts : []
        if sshPermissionGranted {
          if hosts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
              Text("No SSH hosts were found in ~/.ssh/config.")
                .font(.body)
                .foregroundColor(.secondary)
              Text(
                "Add host aliases to your SSH config, then refresh to enable remote session mirroring."
              )
              .font(.caption)
              .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
          } else {
            VStack(alignment: .leading, spacing: 10) {
              ForEach(hosts, id: \.alias) { host in
                VStack(alignment: .leading, spacing: 2) {
                  Toggle(isOn: bindingForRemoteHost(alias: host.alias)) {
                    Text(host.alias)
                      .font(.body)
                      .fontWeight(.medium)
                  }
                  .toggleStyle(.switch)
                  let (statusText, statusColor) = syncStatusDescription(for: host.alias)
                  Text(statusText)
                    .font(.caption2)
                    .foregroundColor(statusColor)
                }
              }
            }
            .padding(.vertical, 4)
          }
        } else {
          VStack(alignment: .leading, spacing: 8) {
            Text("Grant access above to inspect ~/.ssh/config.")
              .font(.body)
              .foregroundColor(.secondary)
            Text("CodMate cannot mirror remote sessions until it can read your SSH config.")
              .font(.caption)
              .foregroundStyle(.tertiary)
          }
          .padding(.vertical, 12)
          .frame(maxWidth: .infinity, alignment: .leading)
        }

        let hostAliases = Set(hosts.map { $0.alias })
        let dangling = preferences.enabledRemoteHosts.subtracting(hostAliases)
        if sshPermissionGranted && !dangling.isEmpty {
          VStack(alignment: .leading, spacing: 6) {
            Text("Unavailable Hosts")
              .font(.subheadline)
              .fontWeight(.semibold)
            Text(
              "The following host aliases are enabled but not present in your current SSH config:"
            )
            .font(.caption)
            .foregroundColor(.secondary)
            ForEach(Array(dangling).sorted(), id: \.self) { alias in
              Text("• \(alias)")
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
          }
          .padding(.vertical, 6)
        }

        Text(
          "CodMate mirrors only the hosts you enable. Hosts that prompt for passwords will open interactively when needed."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      .onAppear {
        if permissionsManager.hasPermission(for: .sshConfig) && availableRemoteHosts.isEmpty {
          DispatchQueue.main.async { reloadRemoteHosts() }
        }
      }
      .onChange(of: permissionsManager.hasPermission(for: .sshConfig)) { granted in
        if granted {
          reloadRemoteHosts()
        } else {
          availableRemoteHosts = []
        }
      }
    }
  }

  @MainActor
  private func reloadRemoteHosts() {
    guard permissionsManager.hasPermission(for: .sshConfig) else {
      availableRemoteHosts = []
      return
    }
    let resolver = SSHConfigResolver()
    let hosts = resolver.resolvedHosts().sorted { $0.alias.lowercased() < $1.alias.lowercased() }
    availableRemoteHosts = hosts
    let hostAliases = Set(hosts.map { $0.alias })
    let filtered = preferences.enabledRemoteHosts.filter { hostAliases.contains($0) }
    if filtered.count != preferences.enabledRemoteHosts.count {
      DispatchQueue.main.async {
        preferences.enabledRemoteHosts = Set(filtered)
      }
    }
  }

  private func bindingForRemoteHost(alias: String) -> Binding<Bool> {
    Binding(
      get: { preferences.enabledRemoteHosts.contains(alias) },
      set: { isOn in
        DispatchQueue.main.async {
          var hosts = preferences.enabledRemoteHosts
          if isOn {
            hosts.insert(alias)
          } else {
            hosts.remove(alias)
          }
          preferences.enabledRemoteHosts = hosts
        }
      }
    )
  }

  private static let relativeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .full
    return f
  }()

  private func syncStatusDescription(for alias: String) -> (String, Color) {
    guard let state = viewModel.remoteSyncStates[alias] else {
      return ("Not synced yet", .secondary)
    }
    switch state {
    case .idle:
      return ("Not synced yet", .secondary)
    case .syncing:
      return ("Syncing…", .secondary)
    case .succeeded(let date):
      let relative = Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
      return ("Last synced \(relative)", .secondary)
    case .failed(let date, let message):
      let relative = Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
      let detail = Self.syncFailureDetail(from: message)
      if detail.isEmpty {
        return ("Sync failed \(relative)", .red)
      }
      return ("Sync failed \(relative): \(detail)", .red)
    }
  }

  private static func syncFailureDetail(from rawMessage: String) -> String {
    let firstLine =
      rawMessage
      .split(whereSeparator: \.isNewline)
      .first
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
    guard !firstLine.isEmpty else { return "" }

    let prefix = "sync failed"
    if firstLine.lowercased().hasPrefix(prefix) {
      var separators = CharacterSet.whitespacesAndNewlines
      separators.insert(charactersIn: ":-–—")
      let remainder = firstLine.dropFirst(prefix.count)
      let sanitized = String(remainder).trimmingCharacters(in: separators)
      return sanitized
    }
    return firstLine
  }

  private func resetToDefaults() {
    preferences.projectsRoot = SessionPreferencesStore.defaultProjectsRoot(
      for: FileManager.default.homeDirectoryForCurrentUser)
    preferences.notesRoot = SessionPreferencesStore.defaultNotesRoot(
      for: preferences.sessionsRoot)
    preferences.codexCommandPath = ""
    preferences.claudeCommandPath = ""
    preferences.geminiCommandPath = ""
    preferences.defaultResumeUseEmbeddedTerminal = true
    preferences.defaultResumeCopyToClipboard = true
    preferences.defaultResumeExternalAppId = "terminal"
    preferences.defaultResumeSandboxMode = .workspaceWrite
    preferences.defaultResumeApprovalPolicy = .onRequest
    preferences.defaultResumeFullAuto = false
    preferences.defaultResumeDangerBypass = false
  }

  private func openMCPMateDownload() {
    NSWorkspace.shared.open(mcpMateURL)
  }

  // MARK: - Helper Views

  private func settingsScroll<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    ScrollView {
      content()
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.top, 24)
        .padding(.horizontal, 24)
        .padding(.bottom, 32)
    }
    // Allow the scroll view to clip to its bounds so the system
    // titlebar bottom separator (hairline) remains visible consistently.
  }

  @ViewBuilder
  private func settingsCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      content()
    }
    .padding(10)
    .background(Color(nsColor: .separatorColor).opacity(0.35))
    .cornerRadius(10)
  }

  @ViewBuilder
  private var gridDivider: some View {
    Divider()
  }
}

struct SettingsView_Previews: PreviewProvider {
  static var previews: some View {
    let prefs = SessionPreferencesStore()
    let vm = SessionListViewModel(preferences: prefs)
    return SettingsView(
      preferences: prefs, selection: .constant(.general), extensionsTab: .constant(.mcp)
    )
    .environmentObject(vm)
  }
}

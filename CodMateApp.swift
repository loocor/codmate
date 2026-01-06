import SwiftUI

#if os(macOS)
  import AppKit
#endif

@main
struct CodMateApp: App {
  #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  #endif
  @StateObject private var listViewModel: SessionListViewModel
  @StateObject private var preferences: SessionPreferencesStore
  @State private var settingsSelection: SettingCategory = .general
  @State private var extensionsTabSelection: ExtensionsSettingsTab = .commands
  @Environment(\.openWindow) private var openWindow

  init() {
    let prefs = SessionPreferencesStore()
    let listVM = SessionListViewModel(preferences: prefs)
    _preferences = StateObject(wrappedValue: prefs)
    _listViewModel = StateObject(wrappedValue: listVM)
    // Prepare user notifications early so banners can show while app is active
    SystemNotifier.shared.bootstrap()
    // Setup menu bar before windows appear
    #if os(macOS)
      MenuBarController.shared.configure(viewModel: listVM, preferences: prefs)
    #endif
    // In App Sandbox, restore security-scoped access to user-selected directories
    SecurityScopedBookmarks.shared.restoreAndStartAccess()
    // Restore all dynamic bookmarks (e.g., repository directories for Git Review)
    SecurityScopedBookmarks.shared.restoreAllDynamicBookmarks()
    // Restore and check sandbox permissions for critical directories
    Task { @MainActor in
      SandboxPermissionsManager.shared.restoreAccess()
    }
    // Sync launch at login state with system
    Task { @MainActor in
      LaunchAtLoginService.shared.syncWithPreferences(prefs)
    }
    // Daily update check (non-App Store builds only)
    Task {
      _ = await UpdateService.shared.checkIfNeeded(trigger: .appLaunch)
    }
    // Log startup info to Status Bar
    Task { @MainActor in
      let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
      AppLogger.shared.info("CodMate v\(version) started", source: "App")
    }
  }

  var bodyCommands: some Commands {
    Group {
      CommandGroup(replacing: .appInfo) {
        Button("About CodMate") { presentSettings(for: .about) }
      }
      CommandGroup(replacing: .appSettings) {
        Button("Settings…") { presentSettings(for: .general) }
          .keyboardShortcut(",", modifiers: [.command])
      }
      CommandGroup(after: .appSettings) {
        Button("Global Search…") {
          NotificationCenter.default.post(name: .codMateFocusGlobalSearch, object: nil)
        }
        .keyboardShortcut("f", modifiers: [.command])
      }
      // Integrate actions into the system View menu
      CommandGroup(after: .sidebar) {
        Button(action: {
          NotificationCenter.default.post(name: .codMateGlobalRefresh, object: nil)
        }) {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .keyboardShortcut("r", modifiers: [.command])

        Button(action: {
          NotificationCenter.default.post(name: .codMateToggleSidebar, object: nil)
        }) {
          Label("Toggle Sidebar", systemImage: "sidebar.left")
        }
        .keyboardShortcut("1", modifiers: [.command])

        Button(action: {
          NotificationCenter.default.post(name: .codMateToggleList, object: nil)
        }) {
          Label("Toggle Session List", systemImage: "sidebar.leading")
        }
        .keyboardShortcut("2", modifiers: [.command])

        Divider()

        Button(action: {
          withAnimation {
            if preferences.statusBarVisibility == .hidden {
              preferences.statusBarVisibility = .auto
            } else {
              preferences.statusBarVisibility = .hidden
            }
          }
        }) {
          if preferences.statusBarVisibility == .hidden {
            Label("Show Status Bar", systemImage: "rectangle.bottomthird.inset.filled")
          } else {
            Label("Hide Status Bar", systemImage: "rectangle.bottomthird.inset.filled")
          }
        }
        .keyboardShortcut("3", modifiers: [.command])
      }
      // Override Cmd+Q to use smart quit behavior
      CommandGroup(replacing: .appTermination) {
        Button("Quit CodMate") {
          MenuBarController.shared.handleQuit()
        }
        .keyboardShortcut("q", modifiers: [.command])
      }
    }
  }

  var body: some Scene {
    // Use Window instead of WindowGroup to enforce single instance
    Window("CodMate", id: "main") {
      ContentView(viewModel: listViewModel)
        .frame(minWidth: 880, minHeight: 600)
        .onReceive(NotificationCenter.default.publisher(for: .codMateOpenSettings)) { note in
          let raw = note.userInfo?["category"] as? String
          if let raw, let cat = SettingCategory(rawValue: raw) {
            settingsSelection = cat
            if cat == .mcpServer,
               let tab = note.userInfo?["extensionsTab"] as? String,
               let parsed = ExtensionsSettingsTab(rawValue: tab) {
              extensionsTabSelection = parsed
            }
          } else {
            settingsSelection = .general
          }
          if !bringWindow(identifier: "CodMateSettingsWindow") {
            openWindow(id: "settings")
          }
        }
        .onReceive(NotificationCenter.default.publisher(for: .codMateOpenMainWindow)) { _ in
          // Window is singleton, so openWindow is idempotent
          if !bringWindow(identifier: "CodMateMainWindow") {
            openWindow(id: "main")
          }
        }
    }
    .defaultSize(width: 1200, height: 780)
    .windowToolbarStyle(.unified)  // Prevent toolbar KVO issues with Window singleton
    .handlesExternalEvents(matching: [])  // Prevent URL scheme from triggering new window creation
    .commands { bodyCommands }
    #if os(macOS)
      Window("Settings", id: "settings") {
        SettingsWindowContainer(
          preferences: preferences,
          listViewModel: listViewModel,
          selection: $settingsSelection,
          extensionsTab: $extensionsTabSelection
        )
      }
      .defaultSize(width: 800, height: 640)
      .windowStyle(.titleBar)
      .windowToolbarStyle(.automatic)
      .windowResizability(.contentMinSize)
      .handlesExternalEvents(matching: [])  // Prevent URL scheme from triggering new window creation
    #endif
  }

  private func presentSettings(for category: SettingCategory) {
    settingsSelection = category
    if category == .mcpServer {
      extensionsTabSelection = .mcp
    }
    #if os(macOS)
      NSApplication.shared.activate(ignoringOtherApps: true)
    #endif
    if !bringWindow(identifier: "CodMateSettingsWindow") {
      openWindow(id: "settings")
    }
  }

  private func bringWindow(identifier: String) -> Bool {
    #if os(macOS)
      let id = NSUserInterfaceItemIdentifier(identifier)
      if let window = NSApplication.shared.windows.first(where: { $0.identifier == id }) {
        window.makeKeyAndOrderFront(nil)
        return true
      }
    #endif
    return false
  }
}

private struct SettingsWindowContainer: View {
  let preferences: SessionPreferencesStore
  let listViewModel: SessionListViewModel
  @Binding var selection: SettingCategory
  @Binding var extensionsTab: ExtensionsSettingsTab

  var body: some View {
    SettingsView(preferences: preferences, selection: $selection, extensionsTab: $extensionsTab)
      .environmentObject(listViewModel)
  }
}

#if os(macOS)
  @MainActor
  final class AppDelegate: NSObject, NSApplicationDelegate {
    private var suppressNextReopenActivation = false
    private var suppressResetTask: Task<Void, Never>? = nil

    func applicationDidFinishLaunching(_ notification: Notification) {
      // Hide from Dock to make CodMate a pure menu bar app
      NSApp.setActivationPolicy(.accessory)
      
      // Start CLI Proxy Service if available
      Task { @MainActor in
        if CLIProxyService.shared.isBinaryInstalled {
            try? await CLIProxyService.shared.start()
        }
      }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
      print("🔗 [AppDelegate] Received URLs: \(urls)")
      print("🪟 [AppDelegate] Current windows count: \(application.windows.count)")
      print("🪟 [AppDelegate] Visible windows: \(application.windows.filter { $0.isVisible }.count)")
      let fileURLs = urls.filter { $0.isFileURL }
      let nonFileURLs = urls.filter { !$0.isFileURL }
      if let directoryURL = firstDirectoryURL(in: fileURLs) {
        handleDockFolderDrop(directoryURL)
      }
      if nonFileURLs.contains(where: { $0.scheme?.lowercased() == "codmate" && ($0.host ?? "").lowercased() == "notify" }) {
        suppressNextReopenActivation = true
        suppressResetTask?.cancel()
        suppressResetTask = Task { @MainActor [weak self] in
          try? await Task.sleep(nanoseconds: 1_000_000_000)
          self?.suppressNextReopenActivation = false
        }
      }
      if !nonFileURLs.isEmpty {
        ExternalURLRouter.handle(nonFileURLs)
      }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
      handleDockFileOpenPaths([filename])
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
      let handled = handleDockFileOpenPaths(filenames)
      sender.reply(toOpenOrPrint: handled ? .success : .failure)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool)
      -> Bool
    {
      print("🔄 [AppDelegate] applicationShouldHandleReopen called, hasVisibleWindows: \(flag)")
      if suppressNextReopenActivation {
        suppressNextReopenActivation = false
        return true
      }
      // Delegate to MenuBarController for unified window activation logic
      // This ensures consistent behavior between Dock clicks and menu bar actions
      MenuBarController.shared.handleDockIconClick()
      //  Always return true to prevent the system from creating new windows
      //  This is particularly important for notification forwarding triggered by URL scheme (codmate://)
      return true
    }

    func applicationWillTerminate(_ notification: Notification) {
      // Stop CLI Proxy Service
      CLIProxyService.shared.stop()

      #if canImport(SwiftTerm) && !APPSTORE
        // Synchronously stop all terminal sessions to ensure clean exit
        // This prevents orphaned codex/claude processes when app quits
        let manager = TerminalSessionManager.shared

        // Use sync mode to block until all processes are killed
        // This ensures no orphaned processes when app terminates
        manager.stopAll(withPrefix: "", sync: true)

      // No sleep needed - sync mode blocks until processes are dead
      #endif
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
      #if canImport(SwiftTerm) && !APPSTORE
        // Check if there are any running terminal sessions
        let manager = TerminalSessionManager.shared
        if manager.hasAnyRunningProcesses() {
          // Show confirmation dialog
          let alert = NSAlert()
          alert.messageText = "Stop Running Sessions?"
          alert.informativeText =
            "There are Codex/Claude Code sessions still running. Quitting now will terminate them."
          alert.alertStyle = .warning
          alert.addButton(withTitle: "Quit")
          alert.addButton(withTitle: "Cancel")

          let response = alert.runModal()
          if response == .alertSecondButtonReturn {
            return .terminateCancel
          }
        }
      #endif
      return .terminateNow
    }

    private func firstDirectoryURL(in urls: [URL]) -> URL? {
      for url in urls {
        guard url.isFileURL else { continue }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
          return url.standardizedFileURL
        }
      }
      return nil
    }

    @MainActor
    @discardableResult
    private func handleDockFileOpenPaths(_ paths: [String]) -> Bool {
      let urls = paths.map { URL(fileURLWithPath: $0) }
      guard let directoryURL = firstDirectoryURL(in: urls) else { return false }
      handleDockFolderDrop(directoryURL)
      return true
    }

    @MainActor
    private func handleDockFolderDrop(_ url: URL) {
      let directory = url.path
      let name = url.lastPathComponent
      guard !directory.isEmpty else { return }
      MenuBarController.shared.handleDockIconClick()
      NotificationCenter.default.post(name: .codMateOpenMainWindow, object: nil)
      Task {
        await waitForMainWindow()
        DockOpenCoordinator.shared.enqueueNewProject(directory: directory, name: name)
      }
    }

    @MainActor
    private func waitForMainWindow() async {
      if MainWindowCoordinator.shared.hasAttachedWindow { return }
      for _ in 0..<20 {
        try? await Task.sleep(nanoseconds: 100_000_000)
        if MainWindowCoordinator.shared.hasAttachedWindow { return }
      }
    }
  }
#endif

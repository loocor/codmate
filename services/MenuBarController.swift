import AppKit
import Combine
import Foundation

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
  static let shared = MenuBarController()

  private let statusMenu = NSMenu()
  private var statusItem: NSStatusItem?
  private weak var viewModel: SessionListViewModel?
  private weak var preferences: SessionPreferencesStore?

  private let providersRegistry = ProvidersRegistryService()
  private let mcpStore = MCPServersStore()
  private let skillsStore = SkillsStore()
  private let skillsSyncer = SkillsSyncService()

  private var cachedBindings = ProvidersRegistryService.Bindings(
    activeProvider: nil, defaultModel: nil)
  private var cachedProviders: [ProvidersRegistryService.Provider] = []
  private var cachedMCPServers: [MCPServer] = []
  private var cachedSkills: [SkillRecord] = []
  private var refreshTask: Task<Void, Never>?
  private var actionHandlers: [() -> Void] = []
  private var preferencesCancellable: AnyCancellable?

  private let relativeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter
  }()

  private let usageCountdownFormatter: DateComponentsFormatter = {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = [.day, .hour, .minute]
    formatter.unitsStyle = .abbreviated
    formatter.maximumUnitCount = 2
    formatter.includesTimeRemainingPhrase = false
    return formatter
  }()

  private let usageResetFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("MMM d HH:mm")
    return formatter
  }()

  func configure(viewModel: SessionListViewModel, preferences: SessionPreferencesStore) {
    self.viewModel = viewModel
    self.preferences = preferences
    statusMenu.delegate = self
    preferencesCancellable?.cancel()
    preferencesCancellable = preferences.$systemMenuVisibility.sink { [weak self] visibility in
      self?.applySystemMenuVisibility(visibility)
    }
    applySystemMenuVisibility(preferences.systemMenuVisibility)
    refreshMenuData()
  }

  func menuWillOpen(_ menu: NSMenu) {
    ensureMenuDataLoaded()
    rebuildMenu()
    refreshMenuData()
  }

  func reapplyVisibilityFromPreferences() {
    guard let preferences else { return }
    applySystemMenuVisibility(preferences.systemMenuVisibility)
  }

  private func ensureStatusItem() {
    guard statusItem == nil else { return }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = item.button {
      if let image = NSImage(
        systemSymbolName: "fossil.shell.fill", accessibilityDescription: "CodMate")
      {
        image.isTemplate = true
        // Apply horizontal flip to make the shell spiral clockwise
        let flipped = horizontallyFlippedImage(image)
        button.image = flipped ?? image
        button.imagePosition = .imageOnly
      }
    }
    item.menu = statusMenu
    statusItem = item
  }

  private func horizontallyFlippedImage(_ image: NSImage) -> NSImage? {
    // Create new image with swapped dimensions for 90° rotation
    let rotatedSize = NSSize(width: image.size.height, height: image.size.width)
    let transformed = NSImage(size: rotatedSize)
    transformed.lockFocus()

    let transform = NSAffineTransform()
    // Move to center of rotated canvas
    transform.translateX(by: rotatedSize.width / 2, yBy: rotatedSize.height / 2)
    // Scale to 95% of original size
    transform.scaleX(by: 0.95, yBy: 0.95)
    // Rotate 90° clockwise (negative angle for clockwise)
    transform.rotate(byDegrees: -90)
    // Flip horizontally (to make shell spiral clockwise)
    transform.scaleX(by: -1.0, yBy: 1.0)
    // Move back to draw from center
    transform.translateX(by: -image.size.width / 2, yBy: -image.size.height / 2)
    transform.concat()

    image.draw(
      at: .zero,
      from: NSRect(origin: .zero, size: image.size),
      operation: .copy,
      fraction: 1.0
    )

    transformed.unlockFocus()
    transformed.isTemplate = true
    return transformed
  }

  private func applySystemMenuVisibility(_ visibility: SystemMenuVisibility) {
    updateActivationPolicy(for: visibility)
    switch visibility {
    case .hidden:
      if let item = statusItem {
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
      }
    case .visible, .menuOnly:
      ensureStatusItem()
      rebuildMenu()
      refreshMenuData()
    }
    MainWindowCoordinator.shared.applyMenuVisibility(visibility)
  }

  private func updateActivationPolicy(for visibility: SystemMenuVisibility) {
    #if os(macOS)
      let app = NSApplication.shared
      switch visibility {
      case .menuOnly:
        guard MainWindowCoordinator.shared.hasAttachedWindow else {
          app.setActivationPolicy(.regular)
          return
        }
        app.setActivationPolicy(.accessory)
      case .hidden, .visible:
        app.setActivationPolicy(.regular)
      }
    #endif
  }

  // MARK: - Menu Builders

  private func rebuildMenu() {
    statusMenu.removeAllItems()
    actionHandlers.removeAll(keepingCapacity: true)
    guard viewModel != nil else {
      statusMenu.addItem(disabledItem(title: "CodMate starting..."))
      return
    }

    // 0) Show main window
    let showMainItem = actionItem(
      title: "Show CodMate Window", action: #selector(handleOpenCodMate))
    applySystemImage(showMainItem, name: "rectangle.stack")
    statusMenu.addItem(showMainItem)

    statusMenu.addItem(.separator())

    // 1) Usage
    for provider in usageOrder() {
      let item = NSMenuItem(title: usageTitle(for: provider), action: nil, keyEquivalent: "")
      item.image = providerImage(for: provider)
      item.submenu = buildUsageProviderMenu(provider)
      statusMenu.addItem(item)
    }

    statusMenu.addItem(.separator())

    // 2) Recent Projects
    let recentProjects = recentProjectEntries(limit: 10)
    if recentProjects.isEmpty {
      let item = disabledItem(title: "No recent projects")
      applySystemImage(item, name: "square.grid.2x2")
      statusMenu.addItem(item)
    } else {
      for entry in recentProjects {
        let title = "\(entry.project.name) \(relativeDateString(entry.lastActive))"
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        applySystemImage(item, name: "square.grid.2x2")
        item.submenu = buildProjectMenu(entry)
        statusMenu.addItem(item)
      }
    }

    statusMenu.addItem(.separator())

    // 3) Providers
    statusMenu.addItem(providerMenuItem(for: .codex))
    statusMenu.addItem(providerMenuItem(for: .claude))
    statusMenu.addItem(providerMenuItem(for: .gemini))

    statusMenu.addItem(.separator())

    // 4) Extensions
    let mcpItem = NSMenuItem(title: "MCP Servers", action: nil, keyEquivalent: "")
    applySystemImage(mcpItem, name: "puzzlepiece.extension")
    mcpItem.submenu = buildMCPServersMenu()
    statusMenu.addItem(mcpItem)

    let skillsItem = NSMenuItem(title: "Skills", action: nil, keyEquivalent: "")
    applySystemImage(skillsItem, name: "sparkles")
    skillsItem.submenu = buildSkillsMenu()
    statusMenu.addItem(skillsItem)

    let extensionsItem = actionItem(
      title: "Extensions...", action: #selector(handleOpenExtensionsSettings))
    applySystemImage(extensionsItem, name: "puzzlepiece.extension")
    statusMenu.addItem(extensionsItem)

    statusMenu.addItem(.separator())

    // 5) Global actions
    let globalSearchItem = actionItem(
      title: "Global Search...", action: #selector(handleSearchSessions))
    applySystemImage(globalSearchItem, name: "magnifyingglass")
    statusMenu.addItem(globalSearchItem)
    let settingsItem = actionItem(title: "Settings...", action: #selector(handleOpenSettings))
    applySystemImage(settingsItem, name: "gear")
    statusMenu.addItem(settingsItem)

    statusMenu.addItem(.separator())

    // 6) About / Updates / Quit
    let aboutItem = actionItem(title: "About CodMate", action: #selector(handleOpenAbout))
    applySystemImage(aboutItem, name: "info.circle")
    statusMenu.addItem(aboutItem)
    let updates = NSMenuItem(title: "Check for Updates...", action: nil, keyEquivalent: "")
    applySystemImage(updates, name: "arrow.triangle.2.circlepath")
    updates.isEnabled = false
    statusMenu.addItem(updates)

    let quitItem = actionItem(title: "Quit", action: #selector(handleQuit))
    applySystemImage(quitItem, name: "power")
    statusMenu.addItem(quitItem)
  }

  private func buildUsageProviderMenu(_ provider: UsageProviderKind) -> NSMenu {
    let menu = NSMenu()
    guard let viewModel, let snapshot = viewModel.usageSnapshots[provider] else {
      menu.addItem(disabledItem(title: "No usage data available"))
      return menu
    }

    if snapshot.origin == .thirdParty {
      menu.addItem(disabledItem(title: "Custom provider (usage unavailable)"))
      return menu
    }

    switch snapshot.availability {
    case .ready:
      let referenceDate = Date()
      let metrics = snapshot.metrics.filter { $0.kind != .snapshot && $0.kind != .context }
      if metrics.isEmpty {
        menu.addItem(disabledItem(title: "No usage metrics"))
      } else {
        for metric in metrics {
          let line = usageMetricLine(metric, referenceDate: referenceDate)
          menu.addItem(disabledItem(title: line))
        }
      }
      menu.addItem(.separator())
      menu.addItem(disabledItem(title: updatedLabel(snapshot, referenceDate: referenceDate)))
    case .empty:
      menu.addItem(disabledItem(title: snapshot.statusMessage ?? "Usage not available"))
      if let action = snapshot.action {
        menu.addItem(.separator())
        menu.addItem(actionMenuItem(for: action, provider: provider))
      }
    case .comingSoon:
      menu.addItem(disabledItem(title: snapshot.statusMessage ?? "Usage coming soon"))
    }

    return menu
  }

  private func buildProjectMenu(_ entry: RecentProjectEntry) -> NSMenu {
    let menu = NSMenu()
    guard let anchor = projectAnchor(for: entry.project) else {
      menu.addItem(disabledItem(title: "No sessions found"))
      return menu
    }

    let newItems = buildNewSessionMenuItems(anchor: anchor)
    if newItems.isEmpty {
      menu.addItem(disabledItem(title: "New Session"))
    } else {
      appendSplitMenuItems(newItems, to: menu)
    }

    menu.addItem(.separator())

    let sessions = recentSessions(for: entry.project.id)
    let history = Array(sessions.prefix(10))
    if history.isEmpty {
      menu.addItem(disabledItem(title: "No recent sessions"))
      return menu
    }

    for session in history {
      let title = "\(session.effectiveTitle) \(relativeDateString(anchorDate(for: session)))"
      let item = actionItem(title: title, action: #selector(handleResumeSession(_:)))
      item.representedObject = session.id
      item.image = providerImage(for: providerKind(for: session))
      menu.addItem(item)
    }

    if sessions.count > history.count {
      let moreItem = actionItem(title: "More...", action: #selector(handleShowProjectTasks(_:)))
      moreItem.representedObject = entry.project.id
      applySystemImage(moreItem, name: "list.bullet.rectangle")
      menu.addItem(moreItem)
    }

    return menu
  }

  private func providerMenuItem(for provider: UsageProviderKind) -> NSMenuItem {
    let title = "\(provider.displayName) Provider"
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.image = providerImage(for: provider)

    if provider == .gemini {
      item.isEnabled = false
      return item
    }

    item.submenu = buildProviderMenu(for: provider)
    return item
  }

  private func buildProviderMenu(for provider: UsageProviderKind) -> NSMenu {
    let menu = NSMenu()

    let consumer: ProvidersRegistryService.Consumer? = {
      switch provider {
      case .codex: return .codex
      case .claude: return .claudeCode
      case .gemini: return nil
      }
    }()

    guard let consumer else {
      menu.addItem(disabledItem(title: "Providers not available"))
      return menu
    }

    let activeId = cachedBindings.activeProvider?[consumer.rawValue]

    let builtIn = actionItem(title: "(Built-in)", action: #selector(handleSelectProvider(_:)))
    builtIn.representedObject = ProviderSelection(consumer: consumer, providerId: nil)
    builtIn.state = (activeId == nil || activeId?.isEmpty == true) ? .on : .off
    menu.addItem(builtIn)

    let compatible =
      cachedProviders
      .filter { $0.connectors[consumer.rawValue] != nil }
      .sorted {
        providerDisplayName($0).localizedCaseInsensitiveCompare(providerDisplayName($1))
          == .orderedAscending
      }

    if !compatible.isEmpty {
      menu.addItem(.separator())
      for provider in compatible {
        let name = providerDisplayName(provider)
        let item = actionItem(title: name, action: #selector(handleSelectProvider(_:)))
        item.representedObject = ProviderSelection(consumer: consumer, providerId: provider.id)
        item.state = (provider.id == activeId) ? .on : .off
        menu.addItem(item)
      }
    }

    return menu
  }

  private func buildMCPServersMenu() -> NSMenu {
    let menu = NSMenu()
    let servers = cachedMCPServers.sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
    if servers.isEmpty {
      menu.addItem(disabledItem(title: "No MCP servers"))
      return menu
    }

    for server in servers.prefix(10) {
      let item = actionItem(title: server.name, action: #selector(handleToggleMCPServer(_:)))
      item.representedObject = server.name
      item.state = server.enabled ? .on : .off
      menu.addItem(item)
    }

    return menu
  }

  private func buildSkillsMenu() -> NSMenu {
    let menu = NSMenu()
    let skills = cachedSkills.sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
    if skills.isEmpty {
      menu.addItem(disabledItem(title: "No skills installed"))
      return menu
    }

    for skill in skills.prefix(10) {
      let item = actionItem(title: skill.name, action: #selector(handleToggleSkill(_:)))
      item.representedObject = skill.id
      item.state = skill.isEnabled ? .on : .off
      menu.addItem(item)
    }

    return menu
  }

  // MARK: - Usage Helpers

  private func usageOrder() -> [UsageProviderKind] {
    [.codex, .claude, .gemini]
  }

  private func usageTitle(for provider: UsageProviderKind) -> String {
    guard let viewModel, let snapshot = viewModel.usageSnapshots[provider] else {
      return provider.displayName
    }

    if snapshot.origin == .thirdParty {
      return "\(provider.displayName) Custom provider"
    }

    switch snapshot.availability {
    case .ready:
      let urgent = snapshot.urgentMetric()
      let percent = urgent?.percentText ?? "-"
      let reset = resetSummaryText(for: urgent)
      if reset.isEmpty {
        return "\(provider.displayName) (\(percent))"
      }
      return "\(provider.displayName) \(reset) (\(percent))"
    case .empty:
      return "\(provider.displayName) Not available"
    case .comingSoon:
      return provider.displayName
    }
  }

  private func usageMetricLine(_ metric: UsageMetricSnapshot, referenceDate: Date) -> String {
    let state = MetricDisplayState(
      metric: metric, referenceDate: referenceDate, resetFormatter: usageResetFormatter)
    var parts: [String] = [metric.label]
    if let usage = state.usageText, !usage.isEmpty { parts.append(usage) }
    if let percent = state.percentText, !percent.isEmpty { parts.append(percent) }
    if !state.resetText.isEmpty { parts.append(state.resetText) }
    return parts.joined(separator: " | ")
  }

  private func updatedLabel(_ snapshot: UsageProviderSnapshot, referenceDate: Date) -> String {
    if let updated = snapshot.updatedAt {
      let relative = relativeFormatter.localizedString(for: updated, relativeTo: referenceDate)
      return "Updated \(relative)"
    }
    return "Waiting for usage data"
  }

  private func resetSummaryText(for metric: UsageMetricSnapshot?) -> String {
    guard let metric else { return "" }
    if let reset = metric.resetDate {
      if let countdown = resetCountdown(from: reset, kind: metric.kind) {
        return countdown
      }
      return usageResetFormatter.string(from: reset)
    }
    if let minutes = metric.fallbackWindowMinutes {
      if minutes >= 60 {
        return String(format: "%.1fh window", Double(minutes) / 60.0)
      }
      return "\(minutes)m window"
    }
    return ""
  }

  private func resetCountdown(from date: Date, kind: UsageMetricSnapshot.Kind) -> String? {
    let interval = date.timeIntervalSinceNow
    guard interval > 0 else {
      return kind == .sessionExpiry ? "expired" : "reset"
    }
    if let formatted = usageCountdownFormatter.string(from: interval) {
      let verb = kind == .sessionExpiry ? "expires in" : "resets in"
      return "\(verb) \(formatted)"
    }
    return nil
  }

  private func actionMenuItem(
    for action: UsageProviderSnapshot.Action,
    provider: UsageProviderKind
  ) -> NSMenuItem {
    let label: String
    switch action {
    case .refresh:
      label = "Load usage"
    case .authorizeKeychain:
      label = "Grant access"
    }
    let item = actionItem(title: label, action: #selector(handleUsageAction(_:)))
    item.representedObject = provider.rawValue
    return item
  }

  // MARK: - Projects / Sessions Helpers

  private func anchorDate(for session: SessionSummary) -> Date {
    session.lastUpdatedAt ?? session.startedAt
  }

  private struct RecentProjectEntry {
    let project: Project
    let lastActive: Date
    let lastSession: SessionSummary?
  }

  private func recentProjectEntries(limit: Int) -> [RecentProjectEntry] {
    guard let viewModel else { return [] }
    let sessions = allSessionSnapshot()
      .sorted { anchorDate(for: $0) > anchorDate(for: $1) }
    var seen: Set<String> = []
    var recent: [RecentProjectEntry] = []

    for session in sessions {
      guard let pid = viewModel.projectIdForSession(session.id) else { continue }
      if pid == SessionListViewModel.otherProjectId { continue }
      guard !seen.contains(pid) else { continue }
      guard let project = viewModel.projects.first(where: { $0.id == pid }) else { continue }
      seen.insert(pid)
      recent.append(
        RecentProjectEntry(
          project: project, lastActive: anchorDate(for: session), lastSession: session))
      if recent.count >= limit { break }
    }

    // Keep time-based descending order (most recently active projects first)
    return recent
  }

  private func recentSessions(for projectId: String) -> [SessionSummary] {
    guard let viewModel else { return [] }
    return allSessionSnapshot()
      .filter { viewModel.projectIdForSession($0.id) == projectId }
      .sorted { anchorDate(for: $0) > anchorDate(for: $1) }
  }

  private func projectAnchor(for project: Project) -> SessionSummary? {
    guard let viewModel else { return nil }
    if let visible = viewModel.sections.flatMap({ $0.sessions }).first(where: {
      viewModel.projectIdForSession($0.id) == project.id
    }) {
      return visible
    }
    return allSessionSnapshot().first(where: { viewModel.projectIdForSession($0.id) == project.id })
  }

  private func relativeDateString(_ date: Date) -> String {
    relativeFormatter.localizedString(for: date, relativeTo: Date())
  }

  // MARK: - New Session Menu (Project)

  private func buildNewSessionMenuItems(anchor: SessionSummary) -> [MenuNode] {
    guard let viewModel else { return [] }
    let allowed = Set(viewModel.allowedSources(for: anchor))
    let requestedOrder: [ProjectSessionSource] = [.claude, .codex, .gemini]
    let enabledRemoteHosts = viewModel.preferences.enabledRemoteHosts.sorted()

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

    func remoteSource(for base: ProjectSessionSource, host: String) -> SessionSource {
      switch base {
      case .codex: return .codexRemote(host: host)
      case .claude: return .claudeRemote(host: host)
      case .gemini: return .geminiRemote(host: host)
      }
    }

    // Build "New with" menu items - directly launch with default terminal
    var menuItems: [MenuNode] = []
    for base in requestedOrder where allowed.contains(base) {
      let providerKind = providerKindForBase(base)
      let icon = providerImage(for: providerKind)
      let menuTitle = "New with \(base.displayName)"

      // If no remote hosts, create a simple action item
      if enabledRemoteHosts.isEmpty {
        menuItems.append(
          .action(
            id: "new-\(base.rawValue)",
            title: menuTitle,
            icon: icon,
            run: { [weak self] in
              self?.launchNewSessionWithDefaultTerminal(for: anchor, using: base.sessionSource)
            }
          )
        )
      } else {
        // If remote hosts exist, create a submenu
        var providerItems: [MenuNode] = [
          .action(
            id: "new-\(base.rawValue)-local",
            title: "Local",
            run: { [weak self] in
              self?.launchNewSessionWithDefaultTerminal(for: anchor, using: base.sessionSource)
            }
          )
        ]

        providerItems.append(.separator)
        for host in enabledRemoteHosts {
          let remote = remoteSource(for: base, host: host)
          providerItems.append(
            .action(
              id: "new-\(base.rawValue)-\(host)",
              title: host,
              run: { [weak self] in
                self?.launchNewSessionWithDefaultTerminal(for: anchor, using: remote)
              }
            )
          )
        }

        menuItems.append(
          .submenu(
            id: "newwith-\(base.rawValue)", title: menuTitle, icon: icon, children: providerItems)
        )
      }
    }

    if menuItems.isEmpty {
      let fallbackSource = anchor.source
      let fallbackKind = providerKind(for: anchor)
      let fallbackIcon = providerImage(for: fallbackKind)
      menuItems.append(
        .action(
          id: "newwith-fallback",
          title: "New with \(fallbackSource.branding.displayName)",
          icon: fallbackIcon,
          run: { [weak self] in
            self?.launchNewSessionWithDefaultTerminal(for: anchor, using: fallbackSource)
          }
        )
      )
    }

    return menuItems
  }

  private func launchNewSession(
    for session: SessionSummary,
    using source: SessionSource,
    profile: ExternalTerminalProfile
  ) {
    guard let viewModel else { return }
    let target = session.overridingSource(source)
    viewModel.recordIntentForDetailNew(anchor: target)
    let dir = target.cwd
    guard viewModel.copyNewSessionCommandsIfEnabled(session: target, destinationApp: profile)
    else { return }

    if profile.usesWarpCommands {
      viewModel.openPreferredTerminalViaScheme(profile: profile, directory: dir)
      if viewModel.shouldCopyCommandsToClipboard {
        Task {
          await SystemNotifier.shared.notify(
            title: "CodMate", body: "Command copied. Paste it in the opened terminal.")
        }
      }
      return
    }
    if profile.isTerminal {
      if !viewModel.openNewSession(session: target) {
        _ = viewModel.openAppleTerminal(at: dir)
        if viewModel.shouldCopyCommandsToClipboard {
          Task {
            await SystemNotifier.shared.notify(
              title: "CodMate", body: "Command copied. Paste it in the opened terminal.")
          }
        }
      }
      return
    }
    if profile.isNone {
      if viewModel.shouldCopyCommandsToClipboard {
        Task {
          await SystemNotifier.shared.notify(
            title: "CodMate", body: "Command copied. Paste it in the opened terminal.")
        }
      }
      return
    }

    let cmd =
      profile.supportsCommandResolved
      ? viewModel.buildNewSessionCLIInvocationRespectingProject(session: target)
      : nil
    viewModel.openPreferredTerminalViaScheme(profile: profile, directory: dir, command: cmd)
  }

  private func launchNewSessionWithDefaultTerminal(
    for session: SessionSummary,
    using source: SessionSource
  ) {
    guard let preferences else { return }
    let profile = ExternalTerminalProfileStore.shared.resolvePreferredProfile(
      id: preferences.defaultResumeExternalAppId
    )
    guard let profile else { return }
    launchNewSession(for: session, using: source, profile: profile)
  }

  // MARK: - Menu Node Builder

  private enum MenuNode {
    case action(id: String, title: String, icon: NSImage? = nil, run: () -> Void)
    case separator
    case submenu(id: String, title: String, icon: NSImage? = nil, children: [MenuNode])
  }

  private func appendSplitMenuItems(_ items: [MenuNode], to menu: NSMenu) {
    for item in items {
      switch item {
      case .separator:
        menu.addItem(.separator())
      case .action(let id, let title, let icon, let run):
        let mi = actionItem(title: title, action: #selector(handleDynamicAction(_:)))
        mi.tag = registerAction(run)
        mi.identifier = NSUserInterfaceItemIdentifier(id)
        if let icon = icon {
          mi.image = icon
        }
        menu.addItem(mi)
      case .submenu(_, let title, let icon, let children):
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let icon = icon {
          mi.image = icon
        }
        let sub = NSMenu(title: title)
        appendSplitMenuItems(children, to: sub)
        mi.submenu = sub
        menu.addItem(mi)
      }
    }
  }

  private func registerAction(_ action: @escaping () -> Void) -> Int {
    actionHandlers.append(action)
    return actionHandlers.count - 1
  }

  private func actionItem(title: String, action: Selector) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    return item
  }

  // MARK: - Provider / Extension Data

  private func refreshMenuData() {
    refreshTask?.cancel()
    refreshTask = Task { [weak self] in
      guard let self else { return }
      if SecurityScopedBookmarks.shared.isSandboxed {
        let home = SessionPreferencesStore.getRealUserHomeURL()
        let codmate = home.appendingPathComponent(".codmate", isDirectory: true)
        _ = AuthorizationHub.shared.ensureDirectoryAccessOrPromptSync(
          directory: codmate, purpose: .generalAccess)
      }

      async let bindings = providersRegistry.getBindings()
      async let providers = providersRegistry.listProviders()
      async let mcpServers = mcpStore.list()
      async let skills = skillsStore.list()

      let (bindingsResult, providersResult, mcpResult, skillsResult) = await (
        bindings, providers, mcpServers, skills
      )

      await MainActor.run {
        self.cachedBindings = bindingsResult
        self.cachedProviders = providersResult
        self.cachedMCPServers = mcpResult
        self.cachedSkills = skillsResult
        self.rebuildMenu()
      }
    }
  }

  private func ensureMenuDataLoaded() {
    guard let viewModel else { return }
    if viewModel.allSessions.isEmpty && !viewModel.isLoading {
      Task { [weak self] in
        await viewModel.refreshSessions(force: true)
        await MainActor.run { self?.rebuildMenu() }
      }
    }
    if viewModel.usageSnapshots.isEmpty {
      viewModel.requestUsageStatusRefresh(for: .codex)
      viewModel.requestUsageStatusRefresh(for: .claude)
      viewModel.requestUsageStatusRefresh(for: .gemini)
      Task { [weak self] in
        try? await Task.sleep(nanoseconds: 300_000_000)
        await MainActor.run { self?.rebuildMenu() }
      }
    }
  }

  private func providerDisplayName(_ provider: ProvidersRegistryService.Provider) -> String {
    provider.name?.isEmpty == false ? provider.name! : provider.id
  }

  private func systemMenuImage(_ name: String, fallback: String? = nil) -> NSImage? {
    let image =
      NSImage(systemSymbolName: name, accessibilityDescription: nil)
      ?? (fallback.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) })
    guard let image else { return nil }
    image.isTemplate = true
    image.size = NSSize(width: 14, height: 14)
    return image
  }

  private func applySystemImage(_ item: NSMenuItem, name: String, fallback: String? = nil) {
    if let image = systemMenuImage(name, fallback: fallback) {
      item.image = image
    }
  }

  private func providerImage(for provider: UsageProviderKind) -> NSImage? {
    let name: String
    switch provider {
    case .codex: name = "ChatGPTIcon"
    case .claude: name = "ClaudeIcon"
    case .gemini: name = "GeminiIcon"
    }
    guard var image = NSImage(named: NSImage.Name(name)) else { return nil }
    image.size = NSSize(width: 14, height: 14)

    // Apply color inversion for Codex icon in dark mode
    if provider == .codex, isDarkMode() {
      image = invertedImage(image) ?? image
    }

    return image
  }

  private func isDarkMode() -> Bool {
    if let appearance = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) {
      return appearance == .darkAqua
    }
    return false
  }

  private func invertedImage(_ image: NSImage) -> NSImage? {
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      return nil
    }

    let ciImage = CIImage(cgImage: cgImage)
    guard let filter = CIFilter(name: "CIColorInvert") else { return nil }
    filter.setValue(ciImage, forKey: kCIInputImageKey)
    guard let outputImage = filter.outputImage else { return nil }

    let rep = NSCIImageRep(ciImage: outputImage)
    let newImage = NSImage(size: image.size)
    newImage.addRepresentation(rep)
    return newImage
  }

  private func providerKind(for session: SessionSummary) -> UsageProviderKind {
    switch session.source.baseKind {
    case .codex: return .codex
    case .claude: return .claude
    case .gemini: return .gemini
    }
  }

  private func providerKindForBase(_ base: ProjectSessionSource) -> UsageProviderKind {
    switch base {
    case .codex: return .codex
    case .claude: return .claude
    case .gemini: return .gemini
    }
  }

  private func disabledItem(title: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    return item
  }

  private func allSessionSnapshot() -> [SessionSummary] {
    guard let viewModel else { return [] }
    if !viewModel.allSessions.isEmpty { return viewModel.allSessions }
    return viewModel.sections.flatMap(\.sessions)
  }

  // MARK: - Actions

  @objc private func handleDynamicAction(_ sender: NSMenuItem) {
    let idx = sender.tag
    guard idx >= 0 && idx < actionHandlers.count else { return }
    actionHandlers[idx]()
  }

  @objc private func handleUsageAction(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String,
      let provider = UsageProviderKind(rawValue: raw)
    else { return }
    viewModel?.requestUsageStatusRefresh(for: provider)
  }

  @objc private func handleSearchSessions() {
    activateApp(raiseWindows: true)
    NotificationCenter.default.post(name: .codMateFocusGlobalSearch, object: nil)
  }

  @objc private func handleOpenCodMate() {
    activateApp(raiseWindows: true)
  }

  /// Public method to handle app activation from Dock icon clicks or other external triggers
  func handleDockIconClick() {
    activateApp(raiseWindows: true)
  }

  @objc private func handleOpenSettings() {
    activateApp(raiseWindows: false)
    NotificationCenter.default.post(name: .codMateOpenSettings, object: nil)
  }

  @objc private func handleOpenAbout() {
    activateApp(raiseWindows: false)
    NotificationCenter.default.post(
      name: .codMateOpenSettings,
      object: nil,
      userInfo: ["category": SettingCategory.about.rawValue]
    )
  }

  @objc private func handleOpenExtensionsSettings() {
    activateApp(raiseWindows: false)
    NotificationCenter.default.post(
      name: .codMateOpenSettings,
      object: nil,
      userInfo: [
        "category": SettingCategory.mcpServer.rawValue,
        "extensionsTab": ExtensionsSettingsTab.mcp.rawValue,
      ]
    )
  }

  @objc private func handleQuit() {
    NSApp.terminate(nil)
  }

  @objc private func handleResumeSession(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String else { return }
    guard let session = viewModel?.sessionSummary(for: id) else { return }
    resumeSession(session)
  }

  @objc private func handleShowProjectTasks(_ sender: NSMenuItem) {
    guard let projectId = sender.representedObject as? String else { return }
    guard let viewModel else { return }
    activateApp(raiseWindows: true)
    viewModel.setSelectedProject(projectId)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak viewModel] in
      viewModel?.projectWorkspaceMode = .tasks
    }
  }

  private final class ProviderSelection: NSObject {
    let consumer: ProvidersRegistryService.Consumer
    let providerId: String?
    init(consumer: ProvidersRegistryService.Consumer, providerId: String?) {
      self.consumer = consumer
      self.providerId = providerId
    }
  }

  @objc private func handleSelectProvider(_ sender: NSMenuItem) {
    guard let selection = sender.representedObject as? ProviderSelection else { return }
    Task { [weak self] in
      guard let self else { return }
      switch selection.consumer {
      case .codex:
        await applyCodexProviderSelection(providerId: selection.providerId)
      case .claudeCode:
        await applyClaudeProviderSelection(providerId: selection.providerId)
      }
      await MainActor.run { self.refreshMenuData() }
    }
  }

  @objc private func handleToggleMCPServer(_ sender: NSMenuItem) {
    guard let name = sender.representedObject as? String else { return }
    Task { [weak self] in
      await self?.toggleMCPServer(named: name)
    }
  }

  @objc private func handleToggleSkill(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String else { return }
    Task { [weak self] in
      await self?.toggleSkill(id: id)
    }
  }

  private func resumeSession(_ session: SessionSummary) {
    guard let preferences else { return }
    activateApp(raiseWindows: true)
    if preferences.defaultResumeUseEmbeddedTerminal {
      NotificationCenter.default.post(
        name: .codMateResumeSession,
        object: nil,
        userInfo: ["sessionId": session.id]
      )
    } else {
      openPreferredExternal(session)
    }
  }

  private func openPreferredExternal(_ session: SessionSummary) {
    guard let viewModel, let preferences else { return }
    guard
      let profile = ExternalTerminalProfileStore.shared
        .resolvePreferredProfile(id: preferences.defaultResumeExternalAppId)
    else { return }

    guard viewModel.copyResumeCommandsIfEnabled(session: session, destinationApp: profile) else {
      return
    }

    let dir = viewModel.resolvedWorkingDirectory(for: session)
    var didNotify = false
    if profile.isNone {
      if viewModel.shouldCopyCommandsToClipboard {
        Task {
          await SystemNotifier.shared.notify(
            title: "CodMate", body: "Command copied. Paste it in the opened terminal.")
        }
      }
      return
    }

    if profile.usesWarpCommands {
      viewModel.openPreferredTerminalViaScheme(profile: profile, directory: dir)
    } else if profile.isTerminal {
      if !viewModel.openInTerminal(session: session) {
        _ = viewModel.copyResumeCommandsIfEnabled(session: session, destinationApp: profile)
        _ = viewModel.openAppleTerminal(at: dir)
        if viewModel.shouldCopyCommandsToClipboard {
          Task {
            await SystemNotifier.shared.notify(
              title: "CodMate",
              body: "Command copied. Paste it in the opened terminal."
            )
          }
          didNotify = true
        }
      }
    } else {
      let cmd =
        profile.supportsCommandResolved
        ? viewModel.buildResumeCLIInvocationRespectingProject(session: session)
        : nil
      viewModel.openPreferredTerminalViaScheme(profile: profile, directory: dir, command: cmd)
    }

    if viewModel.shouldCopyCommandsToClipboard, didNotify == false {
      Task {
        await SystemNotifier.shared.notify(
          title: "CodMate", body: "Command copied. Paste it in the opened terminal.")
      }
    }
  }

  private func applyCodexProviderSelection(providerId: String?) async {
    do {
      try await providersRegistry.setActiveProvider(.codex, providerId: providerId)
      let all = await providersRegistry.listAllProviders()
      let provider = providerId.flatMap { id in all.first(where: { $0.id == id }) }
      try await CodexConfigService().applyProviderFromRegistry(provider)
    } catch {
      await SystemNotifier.shared.notify(title: "CodMate", body: "Failed to switch provider.")
    }
  }

  private func applyClaudeProviderSelection(providerId: String?) async {
    do {
      try await providersRegistry.setActiveProvider(.claudeCode, providerId: providerId)
    } catch {
      await SystemNotifier.shared.notify(title: "CodMate", body: "Failed to switch provider.")
      return
    }

    if SecurityScopedBookmarks.shared.isSandboxed {
      let home = SessionPreferencesStore.getRealUserHomeURL()
      _ = AuthorizationHub.shared.ensureDirectoryAccessOrPromptSync(
        directory: home, purpose: .generalAccess)
    }

    let settings = ClaudeSettingsService()
    let isBuiltin = (providerId == nil)

    if isBuiltin {
      try? await settings.setModel(nil)
      try? await settings.setEnvBaseURL(nil)
      try? await settings.setForceLoginMethod(nil)
      try? await settings.setEnvToken(nil)
      return
    }

    let providers = await providersRegistry.listAllProviders()
    guard let provider = providers.first(where: { $0.id == providerId }) else { return }
    let connector = provider.connectors[ProvidersRegistryService.Consumer.claudeCode.rawValue]
    let loginMethod =
      connector?.loginMethod?.lowercased() == "subscription" ? "subscription" : "api"

    if let base = connector?.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines), !base.isEmpty
    {
      try? await settings.setEnvBaseURL(base)
    } else {
      try? await settings.setEnvBaseURL(nil)
    }

    if loginMethod == "api" {
      try? await settings.setForceLoginMethod("console")
    } else {
      try? await settings.setForceLoginMethod(nil)
    }

    if loginMethod == "api" {
      var token: String? = nil
      let keyName = provider.envKey ?? connector?.envKey ?? "ANTHROPIC_AUTH_TOKEN"
      let env = ProcessInfo.processInfo.environment
      if let val = env[keyName], !val.isEmpty {
        token = val
      } else {
        let looksLikeToken =
          keyName.lowercased().contains("sk-") || keyName.hasPrefix("eyJ") || keyName.contains(".")
        if looksLikeToken { token = keyName }
      }
      try? await settings.setEnvToken(token)
    } else {
      try? await settings.setEnvToken(nil)
    }
  }

  private func toggleMCPServer(named name: String) async {
    do {
      if SecurityScopedBookmarks.shared.isSandboxed {
        let home = SessionPreferencesStore.getRealUserHomeURL()
        let codmate = home.appendingPathComponent(".codmate", isDirectory: true)
        let codex = home.appendingPathComponent(".codex", isDirectory: true)
        _ = AuthorizationHub.shared.ensureDirectoryAccessOrPromptSync(
          directory: codmate, purpose: .generalAccess)
        _ = AuthorizationHub.shared.ensureDirectoryAccessOrPromptSync(
          directory: codex, purpose: .generalAccess)
        _ = AuthorizationHub.shared.ensureDirectoryAccessOrPromptSync(
          directory: home, purpose: .generalAccess)
      }

      let list = await mcpStore.list()
      guard let server = list.first(where: { $0.name == name }) else { return }
      try await mcpStore.setEnabled(name: name, enabled: !server.enabled)
      let updated = await mcpStore.list()
      let codex = CodexConfigService()
      try? await codex.applyMCPServers(updated)
      try? await mcpStore.exportEnabledForClaudeConfig(servers: updated)
      let gemini = GeminiSettingsService()
      try? await gemini.applyMCPServers(updated)
      await MainActor.run {
        cachedMCPServers = updated
        rebuildMenu()
      }
    } catch {
      await SystemNotifier.shared.notify(title: "CodMate", body: "Failed to update MCP server.")
    }
  }

  private func toggleSkill(id: String) async {
    if SecurityScopedBookmarks.shared.isSandboxed {
      let home = SessionPreferencesStore.getRealUserHomeURL()
      _ = AuthorizationHub.shared.ensureDirectoryAccessOrPromptSync(
        directory: home, purpose: .generalAccess)
    }

    var records = await skillsStore.list()
    guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
    records[idx].isEnabled.toggle()
    await skillsStore.saveAll(records)

    let home = SessionPreferencesStore.getRealUserHomeURL()
    AuthorizationHub.shared.ensureDirectoryAccessOrPrompt(
      directory: home.appendingPathComponent(".codex", isDirectory: true),
      purpose: .generalAccess,
      message: "Authorize ~/.codex to sync Codex skills"
    )
    AuthorizationHub.shared.ensureDirectoryAccessOrPrompt(
      directory: home.appendingPathComponent(".claude", isDirectory: true),
      purpose: .generalAccess,
      message: "Authorize ~/.claude to sync Claude skills"
    )
    let warnings = await skillsSyncer.syncGlobal(skills: records)
    if warnings.first != nil {
      await SystemNotifier.shared.notify(title: "CodMate", body: "Failed to sync skills.")
    }

    await MainActor.run {
      cachedSkills = records
      rebuildMenu()
    }
  }

  private func activateApp(raiseWindows: Bool) {
    // If in .accessory mode, temporarily switch to .regular to allow window activation
    let needsRegularMode = NSApp.activationPolicy() == .accessory
    if needsRegularMode {
      NSApp.setActivationPolicy(.regular)
    }

    NSApp.activate(ignoringOtherApps: true)
    guard raiseWindows else { return }

    // Try to find and activate visible windows first
    let keyable = NSApp.windows.filter { $0.canBecomeKey }
    if let front = keyable.first(where: { $0.isVisible }) {
      front.makeKeyAndOrderFront(nil)
      return
    }

    // Then try to find main window by identifier (should always exist since Window is singleton)
    let mainWindowId = NSUserInterfaceItemIdentifier("CodMateMainWindow")
    if let mainWindow = NSApp.windows.first(where: { $0.identifier == mainWindowId }) {
      mainWindow.makeKeyAndOrderFront(nil)
      return
    }

    // Fallback: post notification to create/show window (e.g., first launch)
    NotificationCenter.default.post(name: .codMateOpenMainWindow, object: nil)
  }
}

private struct MetricDisplayState {
  var progress: Double?
  var usageText: String?
  var percentText: String?
  var resetText: String

  init(metric: UsageMetricSnapshot, referenceDate: Date, resetFormatter: DateFormatter) {
    let expired = metric.resetDate.map { $0 <= referenceDate } ?? false
    if expired {
      progress = metric.progress != nil ? 0 : nil
      percentText = metric.percentText != nil ? "0%" : nil
      if metric.kind == .fiveHour {
        usageText = "No usage since reset"
      } else {
        usageText = metric.usageText
      }
      if metric.kind == .fiveHour {
        resetText = "Reset"
      } else {
        resetText = ""
      }
    } else {
      progress = metric.progress
      percentText = metric.percentText
      usageText = Self.remainingText(for: metric, referenceDate: referenceDate)
      resetText = Self.resetDescription(for: metric, resetFormatter: resetFormatter)
    }
  }

  private static func remainingText(for metric: UsageMetricSnapshot, referenceDate: Date) -> String?
  {
    guard let resetDate = metric.resetDate else {
      return metric.usageText
    }

    let remaining = resetDate.timeIntervalSince(referenceDate)
    if remaining <= 0 {
      return metric.kind == .sessionExpiry ? "Expired" : "Reset"
    }

    let minutes = Int(remaining / 60)
    let hours = minutes / 60
    let days = hours / 24

    switch metric.kind {
    case .fiveHour:
      let mins = minutes % 60
      if hours > 0 { return "\(hours)h \(mins)m remaining" }
      return "\(mins)m remaining"
    case .weekly:
      let remainingHours = hours % 24
      if days > 0 {
        if remainingHours > 0 { return "\(days)d \(remainingHours)h remaining" }
        return "\(days)d remaining"
      } else if hours > 0 {
        let mins = minutes % 60
        return "\(hours)h \(mins)m remaining"
      }
      return "\(minutes)m remaining"
    case .sessionExpiry, .quota:
      let mins = minutes % 60
      if hours > 0 { return "\(hours)h \(mins)m remaining" }
      return "\(mins)m remaining"
    case .context, .snapshot:
      return metric.usageText
    }
  }

  private static func resetDescription(
    for metric: UsageMetricSnapshot, resetFormatter: DateFormatter
  ) -> String {
    if let date = metric.resetDate {
      let prefix = metric.kind == .sessionExpiry ? "Expires at " : ""
      return prefix + resetFormatter.string(from: date)
    }
    if let minutes = metric.fallbackWindowMinutes {
      if minutes >= 60 {
        return String(format: "%.1fh window", Double(minutes) / 60.0)
      }
      return "\(minutes) min window"
    }
    return ""
  }
}

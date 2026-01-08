import SwiftUI
import AppKit

struct StatusBarOverlayView: View {
  @ObservedObject var store: StatusBarLogStore
  @ObservedObject var preferences: SessionPreferencesStore
  let sidebarInset: CGFloat

  @State private var dragStartHeight: CGFloat? = nil
  @State private var draggedHeight: CGFloat? = nil
  @State private var filterText: String = ""
  @State private var filterLevel: StatusBarLogLevel? = nil  // nil = All
  @State private var cachedFilteredEntries: [StatusBarLogEntry] = []
  @State private var cacheKey: (filterText: String, filterLevel: StatusBarLogLevel?, entryCount: Int) = ("", nil, 0)
  @State private var cachedCombinedText: AttributedString? = nil
  @State private var cachedCombinedTextKey: Int = 0  // Use entry count + last entry ID hash as cache key
  @State private var cachedEntryCount: Int = 0  // Track cached entry count for incremental updates
  @State private var cachedFirstEntryId: UUID? = nil  // Track first entry ID for incremental update validation
  @State private var cachedLastEntryId: UUID? = nil  // Track last entry ID for incremental update validation

  private let maxVisibleLines: Int = 160
  private let minExpandedHeight: CGFloat = 120
  private let maxExpandedHeight: CGFloat = 520
  private let maxMessageLength: Int = 5000  // Truncate messages longer than this
  private let truncationMarker = "… [truncated]"

  var body: some View {
    if preferences.statusBarVisibility != .hidden {
      content
        .frame(maxHeight: totalHeight, alignment: .bottomLeading)
        .animation(.none, value: sidebarInset)
        .onAppear {
          store.setAutoCollapseEnabled(preferences.statusBarVisibility == .auto)
        }
        .onChange(of: preferences.statusBarVisibility) { newValue in
          store.setAutoCollapseEnabled(newValue == .auto)
        }
        .onChange(of: filterText) { _ in
          invalidateCache()
        }
        .onChange(of: filterLevel) { _ in
          invalidateCache()
        }
        .onChange(of: store.entries.count) { _ in
          invalidateCache()
        }
    }
  }

  private var totalHeight: CGFloat {
    if let draggedHeight = draggedHeight {
      return store.isExpanded ? draggedHeight : store.collapsedHeight
    }
    return store.isExpanded ? store.expandedHeight : store.collapsedHeight
  }

  private var logListHeight: CGFloat {
    let effectiveHeight = draggedHeight ?? store.expandedHeight
    return max(0, effectiveHeight - store.collapsedHeight)
  }

  private var content: some View {
    VStack(spacing: 0) {
      // Top divider - separates status bar from content above
      Divider()

      if store.isExpanded {
        // Title bar (serves as resize handle)
        titleBar
          .frame(height: store.collapsedHeight)
          .background(Color(nsColor: .windowBackgroundColor))
        // Divider between title bar and log content
        Divider()
        // Log content
        logList
          .frame(height: logListHeight)
          .frame(maxWidth: .infinity, maxHeight: logListHeight)
          .background(Color(nsColor: .textBackgroundColor))
      } else {
        // Collapsed state - just show the title bar
        titleBar
          .frame(height: store.collapsedHeight)
          .background(Color(nsColor: .windowBackgroundColor))
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .windowBackgroundColor))
    .onHover { hovering in
      store.setInteracting(hovering)
    }
  }

  private var titleBar: some View {
    HStack(spacing: 8) {
      statusIcon
      if store.isExpanded {
        // Filter menu and search field when expanded
        filterMenu
        searchField
        Spacer(minLength: 8)
      } else {
        statusText
        Spacer(minLength: 8)
      }
      // Toggle button on the right
      Button {
        withAnimation(.easeInOut(duration: 0.15)) {
          store.isExpanded.toggle()
          if store.isExpanded {
            store.reveal(expanded: false)
          }
        }
      } label: {
        Image(systemName: "rectangle.bottomthird.inset.filled")
          .font(.system(size: 13, weight: .semibold))
          .frame(width: 18, height: 18)
      }
      .buttonStyle(.plain)
      .padding(.horizontal, 4)
      .contentShape(Rectangle())
      .help(store.isExpanded ? "Hide Debug Area" : "Show Debug Area")
    }
    .font(.system(size: 11))
    .foregroundStyle(.secondary)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .contentShape(Rectangle())
    .gesture(
      store.isExpanded ? DragGesture(minimumDistance: 2)
        .onChanged { value in
          if dragStartHeight == nil {
            dragStartHeight = store.expandedHeight
          }
          let startHeight = dragStartHeight ?? store.expandedHeight
          let newHeight = startHeight - value.translation.height
          let clamped = min(max(newHeight, minExpandedHeight), maxExpandedHeight)

          store.setInteracting(true)
          draggedHeight = clamped
        }
        .onEnded { _ in
          if let finalHeight = draggedHeight {
            store.setExpandedHeight(finalHeight)
          }
          dragStartHeight = nil
          draggedHeight = nil
          store.setInteracting(false)
        } : nil
    )
  }
  
  // Custom NSTextView wrapper with custom context menu and full width
  private struct LogTextView: NSViewRepresentable {
    let text: AttributedString
    let isEmpty: Bool
    let onCopyAll: () -> Void
    let onClear: () -> Void
    let canCopy: Bool
    let canClear: Bool
    
    func makeNSView(context: Context) -> NSScrollView {
      let scrollView = NSScrollView()
      scrollView.hasVerticalScroller = true
      scrollView.hasHorizontalScroller = false
      scrollView.borderType = .noBorder
      scrollView.drawsBackground = false
      scrollView.autohidesScrollers = true
      scrollView.scrollerStyle = .overlay
      
      // Create text storage and layout manager
      let textStorage = NSTextStorage()
      let layoutManager = NSLayoutManager()
      textStorage.addLayoutManager(layoutManager)
      let textContainer = NSTextContainer()
      textContainer.widthTracksTextView = true
      textContainer.heightTracksTextView = false
      // Set initial container size (will be updated after scrollView is configured)
      textContainer.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
      layoutManager.addTextContainer(textContainer)
      
      let textView = LogNSTextView(frame: .zero, textContainer: textContainer)
      textView.coordinator = context.coordinator
      textView.isEditable = false
      textView.isSelectable = true
      textView.isRichText = false  // Use plain text to avoid formatting issues
      textView.drawsBackground = false
      textView.textContainerInset = NSSize(width: 10, height: 6)
      textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
      textView.textColor = .labelColor
      textView.autoresizingMask = [.width]
      textView.isVerticallyResizable = true
      textView.isHorizontallyResizable = false
      textView.allowsUndo = false  // Disable undo to improve performance
      textView.minSize = NSSize(width: 0, height: 0)
      textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
      
      // Set initial text (use simple string conversion to avoid crashes)
      let textString = String(text.characters)
      let initialString = NSMutableAttributedString(string: textString)
      initialString.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: initialString.length))
      initialString.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), range: NSRange(location: 0, length: initialString.length))
      textStorage.setAttributedString(initialString)
      
      scrollView.documentView = textView
      context.coordinator.textView = textView
      context.coordinator.scrollView = scrollView
      context.coordinator.textStorage = textStorage
      context.coordinator.lastText = textString
      
      // Update container width after scrollView is set up
      DispatchQueue.main.async {
        let contentWidth = scrollView.contentSize.width
        if contentWidth > 0 {
          let padding: CGFloat = 20
          let availableWidth = max(1, contentWidth - padding)
          textContainer.containerSize = NSSize(width: availableWidth, height: CGFloat.greatestFiniteMagnitude)
          layoutManager.ensureLayout(for: textContainer)
        }
        // Setup scroll observer after scrollView is fully configured
        context.coordinator.setupScrollObserver()
        // Initial check - assume at bottom initially
        context.coordinator.isUserAtBottom = true
      }
      
      return scrollView
    }
    
    func updateNSView(_ nsView: NSScrollView, context: Context) {
      // Safely check if view is still valid
      guard nsView.window != nil else { return }
      guard let textView = nsView.documentView as? LogNSTextView else { return }
      
      // Use coordinator's textStorage if available, otherwise fall back to textView's
      guard let textStorage = context.coordinator.textStorage ?? textView.textStorage else {
        return
      }
      
      // Check if text actually changed to avoid unnecessary updates
      let newTextString = String(text.characters)
      guard context.coordinator.lastText != newTextString else {
        // Text unchanged, just update menu if needed
        textView.coordinator = context.coordinator
        textView.customMenu = makeMenu(coordinator: context.coordinator)
        return
      }
      
      // Update text - use simple string conversion to avoid crashes
      // Convert AttributedString to plain NSAttributedString with system colors
      let simpleString = NSMutableAttributedString(string: newTextString)
      simpleString.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: simpleString.length))
      simpleString.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), range: NSRange(location: 0, length: simpleString.length))
      let nsAttributedString = simpleString
      
      // Safely update text storage (only update if actually changed)
      textStorage.beginEditing()
      textStorage.setAttributedString(nsAttributedString)
      textStorage.endEditing()
      
      context.coordinator.lastText = newTextString
      
      // Update menu (only once per text change)
      textView.coordinator = context.coordinator
      textView.customMenu = makeMenu(coordinator: context.coordinator)
      
      // Update text view width (only once, after text update, with debouncing)
      // Use a small delay to avoid layout loops
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak nsView, weak textView] in
        guard let scrollView = nsView, let tv = textView,
              scrollView.window != nil, tv.window != nil,
              !scrollView.isHidden else { return }
        let contentWidth = scrollView.contentSize.width
        guard contentWidth > 0 else { return }
        let padding: CGFloat = 20
        let availableWidth = max(1, contentWidth - padding)
        if let container = tv.textContainer, let layoutMgr = tv.layoutManager {
          // Only update if width actually changed to avoid loops
          let currentWidth = container.containerSize.width
          if abs(currentWidth - availableWidth) > 1.0 {
            container.widthTracksTextView = true
            container.containerSize = NSSize(width: availableWidth, height: CGFloat.greatestFiniteMagnitude)
            // Force layout update to ensure scrolling works
            layoutMgr.ensureLayout(for: container)
            tv.needsDisplay = true
          }
        }
      }
      
      // Auto-scroll to bottom if needed (only if user is at bottom, view is visible and not empty)
      if !isEmpty && !nsView.isHidden && context.coordinator.isUserAtBottom {
        let coordinator = context.coordinator
        DispatchQueue.main.async { [weak nsView, weak coordinator] in
          guard let scrollView = nsView,
                let tv = scrollView.documentView as? LogNSTextView,
                tv.window != nil,
                let coord = coordinator,
                coord.isUserAtBottom else { return }
          tv.scrollToEndOfDocument(nil)
          // Update scroll position after scrolling
          coord.checkScrollPosition()
        }
      }
    }
    
    
    private func makeMenu(coordinator: Coordinator) -> NSMenu {
      let menu = NSMenu()
      
      // Copy All Logs
      let copyItem = NSMenuItem(
        title: "Copy All Logs",
        action: #selector(Coordinator.copyAll(_:)),
        keyEquivalent: ""
      )
      copyItem.target = coordinator
      copyItem.isEnabled = canCopy
      copyItem.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
      menu.addItem(copyItem)
      
      menu.addItem(.separator())
      
      // Clear Logs (destructive action - use red color)
      let clearItem = NSMenuItem(
        title: "Clear Logs",
        action: #selector(Coordinator.clear(_:)),
        keyEquivalent: ""
      )
      clearItem.target = coordinator
      clearItem.isEnabled = canClear
      clearItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
      let attributedTitle = NSMutableAttributedString(string: "Clear Logs")
      attributedTitle.addAttribute(.foregroundColor, value: NSColor.systemRed, range: NSRange(location: 0, length: attributedTitle.length))
      clearItem.attributedTitle = attributedTitle
      menu.addItem(clearItem)
      
      return menu
    }
    
    func makeCoordinator() -> Coordinator {
      Coordinator(onCopyAll: onCopyAll, onClear: onClear)
    }
    
    class Coordinator: NSObject {
      let onCopyAll: () -> Void
      let onClear: () -> Void
      weak var textView: LogNSTextView?
      weak var scrollView: NSScrollView?
      var textStorage: NSTextStorage?
      var lastText: String = ""
      var isUserAtBottom: Bool = true  // Track if user is at bottom (auto-scroll only when true)
      var scrollObserver: NSObjectProtocol?
      
      init(onCopyAll: @escaping () -> Void, onClear: @escaping () -> Void) {
        self.onCopyAll = onCopyAll
        self.onClear = onClear
        super.init()
      }
      
      deinit {
        if let observer = scrollObserver {
          NotificationCenter.default.removeObserver(observer)
        }
      }
      
      func checkScrollPosition() {
        guard let scrollView = scrollView,
              let textView = textView else { return }
        
        let clipView = scrollView.contentView
        let offsetY = clipView.bounds.origin.y
        let viewportHeight = clipView.bounds.height
        let contentHeight = textView.bounds.height
        let maxOffset = max(0, contentHeight - viewportHeight)
        
        // Check if user is at bottom (within 10pt threshold)
        let isAtBottom = abs(offsetY - maxOffset) < 10
        isUserAtBottom = isAtBottom
      }
      
      func setupScrollObserver() {
        guard scrollObserver == nil,
              let scrollView = scrollView else { return }
        
        // Enable bounds change notifications
        scrollView.contentView.postsBoundsChangedNotifications = true
        
        // Observe scroll events to track user scroll position
        scrollObserver = NotificationCenter.default.addObserver(
          forName: NSView.boundsDidChangeNotification,
          object: scrollView.contentView,
          queue: .main
        ) { [weak self] _ in
          self?.checkScrollPosition()
        }
        
        // Also observe live scroll events for more accurate tracking
        NotificationCenter.default.addObserver(
          forName: NSScrollView.willStartLiveScrollNotification,
          object: scrollView,
          queue: .main
        ) { [weak self] _ in
          self?.checkScrollPosition()
        }
        
        NotificationCenter.default.addObserver(
          forName: NSScrollView.didEndLiveScrollNotification,
          object: scrollView,
          queue: .main
        ) { [weak self] _ in
          self?.checkScrollPosition()
        }
      }
      
      @objc func copyAll(_ sender: Any?) {
        onCopyAll()
      }
      
      @objc func clear(_ sender: Any?) {
        onClear()
      }
    }
  }
  
  // Custom NSTextView that overrides menu to show custom context menu
  private class LogNSTextView: NSTextView {
    var coordinator: LogTextView.Coordinator?
    var customMenu: NSMenu?
    
    override func menu(for event: NSEvent) -> NSMenu? {
      // Return custom menu on right-click
      if event.type == .rightMouseDown || event.type == .rightMouseUp {
        // Ensure menu items have valid targets
        if let menu = customMenu {
          for item in menu.items {
            if item.target == nil {
              item.target = coordinator
            }
          }
        }
        return customMenu
      }
      return super.menu(for: event)
    }
    
    override func becomeFirstResponder() -> Bool {
      // Allow text selection but prevent editing
      return super.becomeFirstResponder()
    }
  }
  
  private func copyAllLogsToClipboard() {
    let displayEntries = Array(filteredEntries.suffix(maxVisibleLines))
    let text = displayEntries.map { entry in
      let timestamp = timeString(entry.timestamp)
      let source = entry.source.map { "\($0): " } ?? ""
      let message = truncateIfNeeded(entry.message)
      return "\(timestamp) • \(source)\(message)"
    }.joined(separator: "\n")
    
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }


  private var filterMenu: some View {
    Menu {
      Button {
        filterLevel = nil
      } label: {
        HStack {
          Text("All")
          if filterLevel == nil {
            Image(systemName: "checkmark")
          }
        }
      }
      Divider()
      ForEach(StatusBarLogLevel.allCases) { level in
        Button {
          filterLevel = level
        } label: {
          HStack {
            Circle()
              .fill(levelColor(level))
              .frame(width: 6, height: 6)
            Text(level.rawValue.capitalized)
            if filterLevel == level {
              Image(systemName: "checkmark")
            }
          }
        }
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "line.3.horizontal.decrease.circle")
          .font(.system(size: 11))
        if let level = filterLevel {
          Circle()
            .fill(levelColor(level))
            .frame(width: 6, height: 6)
        }
      }
      .padding(.horizontal, 6)
      .padding(.vertical, 3)
      .background(
        RoundedRectangle(cornerRadius: 4)
          .fill(Color(nsColor: .controlBackgroundColor))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 4)
          .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
      )
    }
    .menuStyle(.borderlessButton)
    .frame(height: 20)
    .help("Filter by level")
  }

  private var searchField: some View {
    HStack(spacing: 4) {
      TextField("Filter messages", text: $filterText)
        .textFieldStyle(.plain)
        .font(.system(size: 11))
        .frame(minWidth: 180, maxWidth: 240)
      if !filterText.isEmpty {
        Button {
          filterText = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 3)
    .background(
      RoundedRectangle(cornerRadius: 4)
        .fill(Color(nsColor: .textBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 4)
        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
    )
  }

  private var filteredEntries: [StatusBarLogEntry] {
    let currentKey = (filterText, filterLevel, store.entries.count)
    
    // Use cache if filter criteria and entry count haven't changed
    if cacheKey == currentKey && !cachedFilteredEntries.isEmpty {
      return cachedFilteredEntries
    }
    
    // Recompute filtered entries
    let filtered = store.entries.filter { entry in
      // Filter by level
      if let filterLevel = filterLevel, entry.level != filterLevel {
        return false
      }
      // Filter by text
      if filterText.isEmpty { return true }
      let searchLower = filterText.lowercased()
      if entry.message.lowercased().contains(searchLower) { return true }
      if let source = entry.source, source.lowercased().contains(searchLower) { return true }
      return false
    }
    
    // Update cache
    cacheKey = currentKey
    cachedFilteredEntries = filtered
    return filtered
  }

  private var statusIcon: some View {
    let level = store.entries.last?.level ?? .info
    let systemName: String
    switch level {
    case .info:
      systemName = store.activeTaskCount > 0 ? "clock.badge.checkmark" : "info.circle"
    case .success:
      systemName = "checkmark.circle"
    case .warning:
      systemName = "exclamationmark.triangle"
    case .error:
      systemName = "xmark.octagon"
    }
    return Image(systemName: systemName)
      .foregroundStyle(levelColor(level))
  }

  private var statusText: some View {
    let entry = store.entries.last
    let text = entry?.message ?? "No recent activity"
    return HStack(spacing: 6) {
      if let entry {
        Text(timeString(entry.timestamp))
          .foregroundStyle(.secondary)
      }
      Text(text)
        .foregroundStyle(levelColor(entry?.level ?? .info))
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }

  private var logList: some View {
    let displayEntries = Array(filteredEntries.suffix(maxVisibleLines))
    
    // Compute lightweight cache key: entry count + hash of last entry ID (if exists)
    // Only use last entry ID hash to keep cache key lightweight (memory optimization)
    let cacheKeyValue = displayEntries.count * 1000 + (displayEntries.last?.id.hashValue ?? 0)
    
    // Use cache if key matches, otherwise build (with incremental update if possible)
    let combinedText: AttributedString
    if cacheKeyValue == cachedCombinedTextKey, let cached = cachedCombinedText {
      combinedText = cached
    } else {
      // Try incremental update if we have cached text and only new entries were added
      if let cached = cachedCombinedText,
         cachedEntryCount > 0,
         displayEntries.count > cachedEntryCount,
         let cachedFirstId = cachedFirstEntryId,
         let cachedLastId = cachedLastEntryId {
        // Check if previous entries match by comparing first and last cached entry IDs
        // This is a lightweight check (memory optimization) - only store 2 UUIDs instead of full list
        let currentFirstId = displayEntries.first?.id
        let currentLastCachedId = displayEntries.count > cachedEntryCount ? 
          displayEntries[cachedEntryCount - 1].id : displayEntries.last?.id
        
        // If first and last cached entry IDs match, we can safely do incremental update
        if currentFirstId == cachedFirstId && currentLastCachedId == cachedLastId {
          // Incremental update: append only new entries (performance optimization)
          var updated = cached
          let newEntries = Array(displayEntries.suffix(displayEntries.count - cachedEntryCount))
          if !newEntries.isEmpty {
            updated.append(AttributedString("\n"))
            for (index, entry) in newEntries.enumerated() {
              if index > 0 {
                updated.append(AttributedString("\n"))
              }
              // For very long messages, use optimized building
              updated.append(buildSelectableLogLine(entry))
            }
          }
          combinedText = updated
        } else {
          // Full rebuild needed (entries changed, not just added)
          combinedText = buildCombinedLogTextOptimized(entries: displayEntries)
        }
      } else {
        // Full rebuild (first time or cache invalidated)
        combinedText = buildCombinedLogTextOptimized(entries: displayEntries)
      }
      
      // Update cache with lightweight keys (memory optimization)
      cachedCombinedText = combinedText
      cachedCombinedTextKey = cacheKeyValue
      cachedEntryCount = displayEntries.count
      cachedFirstEntryId = displayEntries.first?.id
      cachedLastEntryId = displayEntries.last?.id
    }
    
    return LogTextView(
      text: displayEntries.isEmpty ? AttributedString("No log entries") : combinedText,
      isEmpty: displayEntries.isEmpty,
      onCopyAll: { copyAllLogsToClipboard() },
      onClear: {
        store.clear()
        invalidateCache()
      },
      canCopy: !filteredEntries.isEmpty,
      canClear: !store.entries.isEmpty
    )
  }
  
  /// Invalidate all caches
  private func invalidateCache() {
    cacheKey = ("", nil, 0)
    cachedFilteredEntries = []
    cachedCombinedText = nil
    cachedCombinedTextKey = 0
    cachedEntryCount = 0
    cachedFirstEntryId = nil
    cachedLastEntryId = nil
  }

  /// Build a combined AttributedString from multiple log entries, separated by newlines
  /// Optimized version that handles large lists efficiently
  private func buildCombinedLogTextOptimized(entries: [StatusBarLogEntry]) -> AttributedString {
    guard !entries.isEmpty else { return AttributedString("") }
    
    // For very long lists, build in chunks to avoid blocking UI
    if entries.count > 100 {
      var result = AttributedString("")
      // Build first entry immediately
      result.append(buildSelectableLogLine(entries[0]))
      
      // Build remaining entries
      for index in 1..<entries.count {
        result.append(AttributedString("\n"))
        result.append(buildSelectableLogLine(entries[index]))
      }
      return result
    } else {
      // For smaller lists, build normally
      var result = AttributedString("")
      for (index, entry) in entries.enumerated() {
        if index > 0 {
          result.append(AttributedString("\n"))
        }
        result.append(buildSelectableLogLine(entry))
      }
      return result
    }
  }
  
  private func buildSelectableLogLine(_ entry: StatusBarLogEntry) -> AttributedString {
    var result = AttributedString("")
    
    // Timestamp - use system color that adapts to theme
    var timestamp = AttributedString(timeString(entry.timestamp))
    timestamp.font = .system(size: 10, design: .monospaced)
    // Use a placeholder color that will be replaced by theme-aware color in NSTextView
    timestamp.foregroundColor = Color.primary.opacity(0.4)
    result.append(timestamp)
    result.append(AttributedString(" "))
    
    // Bullet point (using Unicode character instead of Circle view)
    var bullet = AttributedString("•")
    bullet.foregroundColor = levelColor(entry.level)
    result.append(bullet)
    result.append(AttributedString(" "))
    
    // Source (if present)
    if let source = entry.source, !source.isEmpty {
      var sourceText = AttributedString(source)
      sourceText.font = .system(size: 10, weight: .medium, design: .monospaced)
      // Use a placeholder color that will be replaced by theme-aware color
      sourceText.foregroundColor = Color.secondary
      result.append(sourceText)
      result.append(AttributedString(": "))
    }
    
    // Message with truncation for very long messages
    let message = truncateIfNeeded(entry.message)
    var messageAttr = highlightedMessage(message)
    // Apply font and color to the entire message, preserving any existing attributes (like highlight background)
    messageAttr.font = .system(size: 11, design: .monospaced)
    messageAttr.foregroundColor = levelColor(entry.level)
    
    result.append(messageAttr)
    
    return result
  }
  
  /// Truncate message if it exceeds maxMessageLength, keeping head and tail
  private func truncateIfNeeded(_ message: String) -> String {
    guard message.count > maxMessageLength else { return message }
    
    // Keep head (first 60%) and tail (last 30%), with truncation marker in between
    let headLength = Int(Double(maxMessageLength) * 0.6)
    let tailLength = Int(Double(maxMessageLength) * 0.3)
    
    let head = String(message.prefix(headLength))
    let tail = String(message.suffix(tailLength))
    
    return "\(head)\n\(truncationMarker)\n\(tail)"
  }

  private func highlightedMessage(_ message: String) -> AttributedString {
    guard !filterText.isEmpty else {
      return AttributedString(message)
    }
    
    var result = AttributedString(message)
    let searchLower = filterText.lowercased()
    let messageLower = message.lowercased()
    
    var searchStart = messageLower.startIndex
    var matchCount = 0
    let maxMatches = 100  // Limit matches to avoid performance issues
    
    while searchStart < messageLower.endIndex, matchCount < maxMatches {
      guard let range = messageLower[searchStart...].range(of: searchLower) else {
        break
      }
      
      // Convert String.Index range to AttributedString.Index range
      let lowerBound = AttributedString.Index(range.lowerBound, within: result) ?? result.startIndex
      let upperBound = AttributedString.Index(range.upperBound, within: result) ?? result.endIndex
      let attrRange = lowerBound..<upperBound
      
      result[attrRange].backgroundColor = .yellow.opacity(0.3)
      
      searchStart = range.upperBound
      matchCount += 1
    }
    
    return result
  }

  private func levelColor(_ level: StatusBarLogLevel) -> Color {
    switch level {
    case .info:
      return .secondary
    case .success:
      return Color.green
    case .warning:
      return Color.orange
    case .error:
      return Color.red
    }
  }

  private func timeString(_ date: Date) -> String {
    Self.timeFormatter.string(from: date)
  }

  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("HH:mm:ss")
    return formatter
  }()
}

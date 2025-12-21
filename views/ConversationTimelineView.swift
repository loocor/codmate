import AppKit
import SwiftUI

private let timelineTimeFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.dateFormat = "HH:mm:ss"
  return formatter
}()

struct ConversationTimelineView: View {
  let turns: [ConversationTurn]
  @Binding var expandedTurnIDs: Set<String>
  let refreshToken: Int
  var ascending: Bool = false
  var branding: SessionSourceBranding = SessionSource.codexLocal.branding
  var allowManualToggle: Bool = true
  var autoExpandVisible: Bool = false
  var isActive: Bool = false
  var nowModeEnabled: Bool = false
  var onNowModeChange: ((Bool) -> Void)? = nil
  @State private var scrollView: NSScrollView?
  @State private var scrollObserver: NSObjectProtocol?
  @State private var suppressNowModeCallback = false
  @State private var liveScrollObservers: [NSObjectProtocol] = []
  @State private var userScrollActive = false
  @State private var lastUserScrollTime: TimeInterval = 0
  private let userScrollWindow: TimeInterval = 0.35
  @State private var stickyTurnID: String? = nil
  @State private var markerHeadFrames: [String: CGRect] = [:]
  @State private var markerHeadHeight: CGFloat = 0
  @State private var viewportHeight: CGFloat = 0
  @State private var previewContext: ImagePreviewContext? = nil
  @State private var timelinePositions: [Int: TimelinePositionData] = [:]

  var body: some View {
    let positions = Dictionary(uniqueKeysWithValues: turns.enumerated().map { index, turn in
      let pos = ascending ? (index + 1) : (turns.count - index)
      return (turn.id, pos)
    })
    let turnsByID = Dictionary(uniqueKeysWithValues: turns.map { ($0.id, $0) })

    let topPadding: CGFloat = turns.isEmpty ? 8 : 0

    ZStack {
    ScrollViewReader { proxy in
        ScrollView {
          ScrollViewAccessor { sv in
            attachScrollView(sv)
          }
          .frame(width: 0, height: 0)

          LazyVStack(alignment: .leading, spacing: 20) {
            ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
              let pos = ascending ? (index + 1) : (turns.count - index)
              let markerOpacity = markerOpacity(for: turn.id)
              ConversationTurnRow(
                turn: turn,
                position: pos,
                isFirst: index == turns.startIndex,
                isLast: index == turns.count - 1,
                markerOpacity: markerOpacity,
                isExpanded: expandedTurnIDs.contains(turn.id),
                branding: branding,
                allowToggle: allowManualToggle,
                autoExpandVisible: autoExpandVisible,
                toggleExpanded: { toggle(turn) },
                onSelectAttachment: { attachments, index in
                  previewContext = ImagePreviewContext(attachments: attachments, index: index)
                }
              )
              .id(turn.id)
            }
          }
          .padding(.horizontal, 12)
          .padding(.top, topPadding)
          .padding(.bottom, 8)
        }
        .coordinateSpace(name: "timelineScroll")
        .background(alignment: .topLeading) {
          timelineVerticalLine
        }
        .overlay(alignment: .topLeading) {
          if let stickyTurnID,
             let turn = turnsByID[stickyTurnID],
             let position = positions[stickyTurnID] {
            let extraLineHeight = extraStickyLineHeight()
            HStack(alignment: .top, spacing: 8) {
              StickyTimelineMarker(
                position: position,
                timeText: timelineTimeFormatter.string(from: turn.timestamp),
                isActive: isActive,
                extraLineHeight: extraLineHeight
              )
              Spacer(minLength: 0)
            }
            .padding(.leading, 12)
            .padding(.top, topPadding)
            .contentShape(Rectangle())
            .onTapGesture {
              withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(stickyTurnID, anchor: .top)
              }
            }
            .hoverHand()
          }
        }
      }

      ImagePreviewOverlay(context: $previewContext)
    }
    .onChange(of: turns.map(\.id)) { _, _ in
      if previewContext != nil {
        previewContext = nil
      }
      // Auto-scroll to bottom when Now mode is enabled and content changes
      if nowModeEnabled {
        scrollToBottom()
      }
    }
    .onChange(of: refreshToken) { _, _ in
      if nowModeEnabled {
        scrollToBottom()
      }
    }
    .onPreferenceChange(MarkerHeadFramePreferenceKey.self) { frames in
      markerHeadFrames = frames
      if let height = frames.values.first?.height, height > 0, abs(height - markerHeadHeight) > 0.5 {
        markerHeadHeight = height
      }
      updateStickyTurnID(using: frames)
    }
    .onPreferenceChange(TimelinePositionPreferenceKey.self) { positions in
      timelinePositions = positions
    }
    .onChange(of: nowModeEnabled) { _, isEnabled in
      // Scroll to bottom when user explicitly enables Now mode
      if isEnabled {
        scrollToBottom()
      }
    }
    .onDisappear {
      removeScrollObservers()
    }
  }

  @ViewBuilder
  private var timelineVerticalLine: some View {
    // Draw vertical timeline line (behind all markers)
    if let lineParams = calculateTimelineLineParams() {
      Rectangle()
        .fill(Color.secondary.opacity(0.25))
        .frame(width: 2, height: lineParams.height)
        .offset(x: lineParams.x - 1, y: lineParams.y)
        .animation(nil, value: timelinePositions)
    }
  }

  private func calculateTimelineLineParams() -> (x: CGFloat, y: CGFloat, height: CGFloat)? {
    guard !timelinePositions.isEmpty,
          let firstPos = timelinePositions.keys.min(),
          let lastPos = timelinePositions.keys.max(),
          let firstData = timelinePositions[firstPos],
          let lastData = timelinePositions[lastPos] else {
      return nil
    }

    let hasValidMarkerData = firstData.markerCenterX != 0 || firstData.markerCenterY != 0
    let hasValidCardData = lastData.messageBoxBottomY != 0

    guard hasValidMarkerData && hasValidCardData else { return nil }

    let lineX = firstData.markerCenterX
    var lineTop = firstData.markerCenterY

    // Limit line top to sticky marker bottom when sticky marker is visible
    if stickyTurnID != nil && markerHeadHeight > 0 {
      let topPadding: CGFloat = turns.isEmpty ? 8 : 0
      lineTop = max(lineTop, markerHeadHeight + topPadding)
    }

    let lineBottom = lastData.messageBoxBottomY
    let lineHeight = lineBottom - lineTop

    guard lineHeight > 0 else { return nil }

    return (x: lineX, y: lineTop, height: lineHeight)
  }

  private func attachScrollView(_ sv: NSScrollView) {
    guard scrollView !== sv else { return }
    scrollView = sv
    sv.contentView.postsBoundsChangedNotifications = true

    removeScrollObservers()

    scrollObserver = NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification,
      object: sv.contentView,
      queue: .main
    ) { [weak sv] _ in
      guard sv != nil else { return }
      Task { @MainActor in
        self.didScroll()
      }
    }

    let startObserver = NotificationCenter.default.addObserver(
      forName: NSScrollView.willStartLiveScrollNotification,
      object: sv,
      queue: .main
    ) { _ in
      userScrollActive = true
      markUserScrollActivity()
    }

    let liveObserver = NotificationCenter.default.addObserver(
      forName: NSScrollView.didLiveScrollNotification,
      object: sv,
      queue: .main
    ) { _ in
      markUserScrollActivity()
    }

    let endObserver = NotificationCenter.default.addObserver(
      forName: NSScrollView.didEndLiveScrollNotification,
      object: sv,
      queue: .main
    ) { _ in
      userScrollActive = false
      markUserScrollActivity()
    }

    liveScrollObservers = [startObserver, liveObserver, endObserver]

    // Initialize scroll position without disabling an explicitly enabled Now mode.
    DispatchQueue.main.async {
      if self.nowModeEnabled {
        self.scrollToBottom()
      } else {
        self.didScroll()
      }
    }
  }

  @MainActor
  private func didScroll() {
    guard let scrollView else { return }
    if suppressNowModeCallback { return }

    let offsetY = scrollView.contentView.bounds.origin.y
    let viewportHeight = scrollView.contentView.bounds.height
    let contentHeight = scrollView.documentView?.bounds.height ?? 0
    let maxOffset = max(0, contentHeight - viewportHeight)
    let isAtBottom = abs(offsetY - maxOffset) < 10  // 10pt threshold
    if abs(viewportHeight - self.viewportHeight) > 0.5 {
      self.viewportHeight = viewportHeight
    }

    let now = Date().timeIntervalSinceReferenceDate
    let userInitiated = userScrollActive || (now - lastUserScrollTime) < userScrollWindow
    guard userInitiated else { return }

    if nowModeEnabled && !isAtBottom {
      onNowModeChange?(false)
    } else if !nowModeEnabled && isAtBottom {
      onNowModeChange?(true)
    }
  }

  private func scrollToBottom() {
    guard let scrollView else { return }
    let viewport = scrollView.contentView.bounds.height
    let contentHeight = scrollView.documentView?.bounds.height ?? 0
    let maxOffset = max(0, contentHeight - viewport)

    suppressNowModeCallback = true
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: maxOffset))
    scrollView.reflectScrolledClipView(scrollView.contentView)

    DispatchQueue.main.async {
      self.suppressNowModeCallback = false
      // Trigger sticky marker update after scroll completes
      self.updateStickyTurnID(using: self.markerHeadFrames)
    }
  }

  private func markUserScrollActivity() {
    lastUserScrollTime = Date().timeIntervalSinceReferenceDate
  }

  private func removeScrollObservers() {
    if let observer = scrollObserver {
      NotificationCenter.default.removeObserver(observer)
      scrollObserver = nil
    }
    if !liveScrollObservers.isEmpty {
      for observer in liveScrollObservers {
        NotificationCenter.default.removeObserver(observer)
      }
      liveScrollObservers.removeAll()
    }
  }

  private func updateStickyTurnID(using frames: [String: CGRect]) {
    guard !frames.isEmpty else {
      if stickyTurnID != nil {
        stickyTurnID = nil
      }
      return
    }

    // Find all markers that have scrolled past the top (minY <= 0)
    let scrolledPast = frames.filter { $0.value.minY <= 0 }

    if let topmost = scrolledPast.max(by: { $0.value.minY < $1.value.minY }) {
      // Use the marker closest to the top (highest minY among those <= 0)
      if topmost.key != stickyTurnID {
        stickyTurnID = topmost.key
      }
    } else {
      // No marker has scrolled past the top, use the first visible one
      if let first = frames.min(by: { $0.value.minY < $1.value.minY }) {
        if first.key != stickyTurnID {
          stickyTurnID = first.key
        }
      }
    }
  }

  private func markerOpacity(for id: String) -> Double {
    guard id == stickyTurnID else { return 1 }
    guard let frame = markerHeadFrames[id], frame.height > 0 else { return 1 }
    let minY = frame.minY
    if minY <= 0 { return 0 }
    if minY >= frame.height { return 1 }
    return Double(minY / frame.height)
  }

  private func extraStickyLineHeight() -> CGFloat {
    guard viewportHeight > 0, markerHeadHeight > 0 else { return 0 }
    let nextVisibleHeadMinY = markerHeadFrames.values
      .filter { $0.minY > 0 && $0.minY < viewportHeight }
      .map { $0.minY }
      .min()
    guard nextVisibleHeadMinY == nil else { return 0 }
    return max(0, viewportHeight - markerHeadHeight)
  }

  private func toggle(_ turn: ConversationTurn) {
    guard allowManualToggle else { return }
    if expandedTurnIDs.contains(turn.id) {
      expandedTurnIDs.remove(turn.id)
    } else {
      expandedTurnIDs.insert(turn.id)
    }
  }
}

// ScrollViewAccessor to get the underlying NSScrollView
private struct ScrollViewAccessor: NSViewRepresentable {
  let onScrollViewAvailable: (NSScrollView) -> Void

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async {
      if let scrollView = view.enclosingScrollView {
        onScrollViewAvailable(scrollView)
      }
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct MarkerHeadFramePreferenceKey: PreferenceKey {
  static var defaultValue: [String: CGRect] = [:]
  static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
    value.merge(nextValue(), uniquingKeysWith: { $1 })
  }
}

private struct TimelinePositionData: Equatable {
  var markerCenterX: CGFloat = 0
  var markerCenterY: CGFloat = 0
  var messageBoxBottomY: CGFloat = 0
}

private struct TimelinePositionPreferenceKey: PreferenceKey {
  static var defaultValue: [Int: TimelinePositionData] = [:]
  static func reduce(value: inout [Int: TimelinePositionData], nextValue: () -> [Int: TimelinePositionData]) {
    value.merge(nextValue(), uniquingKeysWith: { existing, new in
      var merged = existing
      if new.markerCenterX != 0 {
        merged.markerCenterX = new.markerCenterX
      }
      if new.markerCenterY != 0 {
        merged.markerCenterY = new.markerCenterY
      }
      if new.messageBoxBottomY != 0 {
        merged.messageBoxBottomY = new.messageBoxBottomY
      }
      return merged
    })
  }
}

private struct ConversationTurnRow: View {
  let turn: ConversationTurn
  let position: Int
  let isFirst: Bool
  let isLast: Bool
  let markerOpacity: Double
  let isExpanded: Bool
  let branding: SessionSourceBranding
  let allowToggle: Bool
  let autoExpandVisible: Bool
  let toggleExpanded: () -> Void
  let onSelectAttachment: ([TimelineAttachment], Int) -> Void
  @State private var isVisible = false

  var body: some View {
    let expanded = autoExpandVisible ? isVisible : isExpanded
    HStack(alignment: .top, spacing: 8) {
      TimelineMarker(
        position: position,
        timeText: timelineTimeFormatter.string(from: turn.timestamp),
        isFirst: isFirst,
        isLast: isLast,
        frameKeyID: turn.id,
        reportPosition: position
      )
      .opacity(markerOpacity)

      ConversationCard(
        turn: turn,
        isExpanded: expanded,
        branding: branding,
        allowToggle: allowToggle,
        toggle: toggleExpanded,
        onSelectAttachment: onSelectAttachment,
        reportPosition: position
      )
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .onAppear {
      if autoExpandVisible {
        isVisible = true
      }
    }
    .onDisappear {
      if autoExpandVisible {
        isVisible = false
      }
    }
    .onChange(of: autoExpandVisible) { _, newValue in
      if !newValue {
        isVisible = false
      }
    }
  }
}

private struct TimelineMarker: View {
  let position: Int
  let timeText: String
  let isFirst: Bool
  let isLast: Bool
  var frameKeyID: String? = nil
  var reportPosition: Int? = nil
  var showBackground: Bool = true

  var body: some View {
    TimelineMarkerHead(
      position: position,
      timeText: timeText,
      isFirst: isFirst,
      frameKeyID: frameKeyID,
      showBackground: showBackground
    )
    .frame(width: 72, alignment: .top)
    .background(
      GeometryReader { proxy in
        Color.clear.preference(
          key: TimelinePositionPreferenceKey.self,
          value: reportPosition.map { pos in
            let frame = proxy.frame(in: .named("timelineScroll"))
            var data = TimelinePositionData()
            data.markerCenterX = frame.midX
            data.markerCenterY = frame.midY
            return [pos: data]
          } ?? [:]
        )
      }
    )
  }
}

private struct TimelineMarkerHead: View {
  let position: Int
  let timeText: String
  let isFirst: Bool
  var frameKeyID: String? = nil
  var showBackground: Bool = true

  var body: some View {
    VStack(alignment: .center, spacing: 6) {
      Text(String(position))
        .font(.caption.bold())
        .foregroundColor(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
          Capsule()
            .fill(Color.accentColor)
        )

      Text(timeText)
        .font(.caption2.monospacedDigit())
        .foregroundStyle(Color.accentColor)
    }
    .padding(.horizontal, 8)
    .padding(.bottom, 8)
    .background(showBackground ? Color(nsColor: .controlBackgroundColor) : Color.clear)
    .background(
      GeometryReader { proxy in
        if let id = frameKeyID {
          Color.clear.preference(
            key: MarkerHeadFramePreferenceKey.self,
            value: [id: proxy.frame(in: .named("timelineScroll"))]
          )
        } else {
          Color.clear
        }
      }
    )
  }
}

private struct StickyTimelineMarker: View {
  let position: Int
  let timeText: String
  let isActive: Bool
  let extraLineHeight: CGFloat

  var body: some View {
    TimelineMarker(
      position: position,
      timeText: timeText,
      isFirst: true,
      isLast: true,
      showBackground: false
    )
  }
}

private struct ConversationCard: View {
  let turn: ConversationTurn
  let isExpanded: Bool
  let branding: SessionSourceBranding
  let allowToggle: Bool
  let toggle: () -> Void
  let onSelectAttachment: ([TimelineAttachment], Int) -> Void
  var reportPosition: Int? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header

      if isExpanded {
        expandedBody
      } else {
        collapsedBody
      }
    }
    .padding(16)
    .background(
      UnevenRoundedRectangle(
        topLeadingRadius: 0,
        bottomLeadingRadius: 14,
        bottomTrailingRadius: 14,
        topTrailingRadius: 14
      )
      .fill(Color(nsColor: .controlBackgroundColor))
    )
    .overlay(
      UnevenRoundedRectangle(
        topLeadingRadius: 0,
        bottomLeadingRadius: 14,
        bottomTrailingRadius: 14,
        topTrailingRadius: 14
      )
      .stroke(Color.primary.opacity(0.07), lineWidth: 1)
    )
    .background(
      GeometryReader { proxy in
        Color.clear.preference(
          key: TimelinePositionPreferenceKey.self,
          value: reportPosition.map { pos in
            let frame = proxy.frame(in: .named("timelineScroll"))
            var data = TimelinePositionData()
            data.messageBoxBottomY = frame.maxY
            return [pos: data]
          } ?? [:]
        )
      }
    )
  }

  private var header: some View {
    HStack {
      Text(turn.actorSummary(using: branding.displayName))
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.primary)
      Spacer()
      if allowToggle {
        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.secondary)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture {
      if allowToggle {
        toggle()
      }
    }
    .hoverHand()
  }

  @ViewBuilder
  private var collapsedBody: some View {
    if let preview = turn.previewText, !preview.isEmpty {
      Text(preview)
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(3)
        .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      Text("Tap to view details")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
  }

  @ViewBuilder
  private var expandedBody: some View {
    if let user = turn.userMessage {
      EventSegmentView(event: user, branding: branding, onSelectAttachment: onSelectAttachment)
    }

    ForEach(Array(turn.outputs.enumerated()), id: \.offset) { index, event in
      if index > 0 || turn.userMessage != nil {
        Divider()
      }
      EventSegmentView(event: event, branding: branding, onSelectAttachment: onSelectAttachment)
    }
  }
}

private struct EventSegmentView: View {
  let event: TimelineEvent
  let branding: SessionSourceBranding
  let onSelectAttachment: ([TimelineAttachment], Int) -> Void
  @State private var isHover = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        roleIconView
          .foregroundStyle(roleColor)

        Text(roleTitle)
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)

        if event.repeatCount > 1 {
          Text("×\(event.repeatCount)")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
              Capsule()
                .fill(Color.secondary.opacity(0.1))
            )
        }

        Spacer()

        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(event.text ?? "", forType: .string)
        } label: {
          Image(systemName: "doc.on.doc")
            .font(.caption2)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .opacity(isHover ? 1 : 0)
        .help("Copy to clipboard")
      }

      if let text = event.text, !text.isEmpty {
        // User messages and tool_output use collapsible text
        if event.visibilityKind == .user {
          CollapsibleText(text: text, lineLimit: 10)
        } else if event.actor == .tool {
          CollapsibleText(text: text, lineLimit: 3)
        } else {
          Text(text)
            .textSelection(.enabled)
            .font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }

      if !event.attachments.isEmpty {
        AttachmentStripView(attachments: event.attachments, onSelect: onSelectAttachment)
      }

      if let metadata = event.metadata {
        MetadataView(metadata: metadata)
      }
    }
    .onHover { hovering in
      isHover = hovering
    }
  }

  private var roleTitle: String {
    event.visibilityKind.settingsLabel
  }

  @ViewBuilder
  private var roleIconView: some View {
    switch event.visibilityKind {
    case .assistant:
      ProviderIconView(provider: branding.providerKind, size: 12, cornerRadius: 2)
    default:
      Image(systemName: roleIconName)
        .font(.caption2)
    }
  }

  private var roleIconName: String {
    switch event.visibilityKind {
    case .user: return "person.fill"
    case .assistant: return branding.symbolName
    case .tool: return "hammer.fill"
    case .codeEdit: return "square.and.pencil"
    case .reasoning: return "brain"
    case .tokenUsage: return "gauge"
    case .environmentContext: return "macwindow"
    case .turnContext: return "arrow.triangle.2.circlepath"
    case .infoOther: return "info.circle"
    }
  }

  private var roleColor: Color {
    switch event.visibilityKind {
    case .user: return .accentColor
    case .assistant: return branding.iconColor
    case .tool: return .yellow
    case .codeEdit: return .green
    case .reasoning: return .purple
    case .tokenUsage: return .orange
    case .environmentContext, .turnContext, .infoOther:
      return .gray
    }
  }
}

private struct ImagePreviewContext: Equatable {
  var attachments: [TimelineAttachment]
  var index: Int
}

private struct ImagePreviewOverlay: View {
  @Binding var context: ImagePreviewContext?
  @State private var image: NSImage? = nil
  @State private var isLoading = false
  @State private var errorText: String? = nil
  @State private var scale: CGFloat = 1
  @State private var gestureScale: CGFloat = 1
  @State private var offset: CGSize = .zero
  @GestureState private var dragOffset: CGSize = .zero

  var body: some View {
    if let context, let attachment = currentAttachment(from: context) {
      GeometryReader { proxy in
        ZStack {
          Color.black.opacity(0.78)
            .onTapGesture { close() }

          VStack(spacing: 16) {
            ZStack {
              if let image {
                ZStack {
                  Image(nsImage: image)
                    .interpolation(.high)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(currentScale)
                    .offset(
                      x: offset.width + dragOffset.width,
                      y: offset.height + dragOffset.height
                    )
                    .shadow(color: Color.black.opacity(0.5), radius: 24, x: 0, y: 12)

                  ScrollWheelZoomView { delta in
                    applyScrollZoom(delta)
                  }
                  .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .gesture(
                  DragGesture()
                    .updating($dragOffset) { value, state, _ in
                      state = value.translation
                    }
                    .onEnded { value in
                      offset.width += value.translation.width
                      offset.height += value.translation.height
                    }
                )
                .simultaneousGesture(
                  MagnificationGesture()
                    .onChanged { value in
                      gestureScale = value
                    }
                    .onEnded { value in
                      scale = clampScale(scale * value)
                      gestureScale = 1
                    }
                )
                .frame(maxWidth: 1200, maxHeight: 800)
              } else if isLoading {
                ProgressView()
                  .progressViewStyle(.circular)
                  .tint(.white)
              } else {
                Text(errorText ?? "Unable to preview image")
                  .foregroundStyle(.white)
                  .font(.callout)
              }
            }

            HStack(spacing: 12) {
              Button {
                goPrevious()
              } label: {
                Image(systemName: "chevron.left")
              }
              .disabled(!canGoPrevious)

              Text("\(context.index + 1) / \(context.attachments.count)")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.85))

              Button {
                goNext()
              } label: {
                Image(systemName: "chevron.right")
              }
              .disabled(!canGoNext)

              Spacer(minLength: 12)

              Button("Close (Esc)") { close() }
              Button("Open Externally") { TimelineAttachmentOpener.shared.open(attachment) }
            }
            .buttonStyle(.bordered)
            .foregroundStyle(.white)
          }
          .padding(24)

          KeyCommandCatcher { event in
            handleKey(event)
          }
          .frame(width: proxy.size.width, height: proxy.size.height)
          .allowsHitTesting(false)
        }
        .frame(width: proxy.size.width, height: proxy.size.height)
        .clipped()
      }
      .onAppear {
        resetTransform()
        load(attachment)
      }
      .onChange(of: attachment.id) { _, _ in
        resetTransform()
        load(attachment)
      }
    }
  }

  private var currentScale: CGFloat {
    clampScale(scale * gestureScale)
  }

  private var canGoPrevious: Bool {
    guard let context else { return false }
    return context.index > 0
  }

  private var canGoNext: Bool {
    guard let context else { return false }
    return context.index < (context.attachments.count - 1)
  }

  private func currentAttachment(from context: ImagePreviewContext) -> TimelineAttachment? {
    guard context.index >= 0, context.index < context.attachments.count else { return nil }
    return context.attachments[context.index]
  }

  private func close() {
    context = nil
  }

  private func goPrevious() {
    guard var context, context.index > 0 else { return }
    context.index -= 1
    self.context = context
  }

  private func goNext() {
    guard var context, context.index + 1 < context.attachments.count else { return }
    context.index += 1
    self.context = context
  }

  private func resetTransform() {
    scale = 1
    gestureScale = 1
    offset = .zero
  }

  private func clampScale(_ value: CGFloat) -> CGFloat {
    min(max(value, 0.2), 6)
  }

  private func applyScrollZoom(_ delta: CGFloat) {
    guard delta != 0 else { return }
    let step = max(-0.25, min(0.25, delta / 300))
    scale = clampScale(scale * (1 + step))
  }

  private func handleKey(_ event: NSEvent) -> Bool {
    switch event.keyCode {
    case 53: // escape
      close()
      return true
    case 123: // left arrow
      goPrevious()
      return true
    case 124: // right arrow
      goNext()
      return true
    default:
      return false
    }
  }

  private func load(_ attachment: TimelineAttachment) {
    isLoading = true
    image = nil
    errorText = nil
    Task.detached {
      let resolvedData = TimelineAttachmentDecoder.imageData(for: attachment)
      await MainActor.run {
        if let resolvedData {
          self.image = NSImage(data: resolvedData)
        } else {
          self.image = nil
        }
        self.isLoading = false
        if resolvedData == nil {
          self.errorText = "Unable to preview this image."
        }
      }
    }
  }
}

private struct KeyCommandCatcher: NSViewRepresentable {
  let onKeyDown: (NSEvent) -> Bool

  func makeNSView(context: Context) -> KeyCommandCatcherView {
    let view = KeyCommandCatcherView()
    view.onKeyDown = onKeyDown
    DispatchQueue.main.async {
      view.window?.makeFirstResponder(view)
    }
    return view
  }

  func updateNSView(_ nsView: KeyCommandCatcherView, context: Context) {
    nsView.onKeyDown = onKeyDown
    DispatchQueue.main.async {
      if nsView.window?.firstResponder !== nsView {
        nsView.window?.makeFirstResponder(nsView)
      }
    }
  }
}

private final class KeyCommandCatcherView: NSView {
  var onKeyDown: ((NSEvent) -> Bool)?

  override var acceptsFirstResponder: Bool { true }

  override func keyDown(with event: NSEvent) {
    if onKeyDown?(event) == true { return }
    super.keyDown(with: event)
  }
}

private struct ScrollWheelZoomView: NSViewRepresentable {
  let onScroll: (CGFloat) -> Void

  func makeNSView(context: Context) -> ScrollWheelCatcher {
    let view = ScrollWheelCatcher()
    view.onScroll = onScroll
    return view
  }

  func updateNSView(_ nsView: ScrollWheelCatcher, context: Context) {
    nsView.onScroll = onScroll
  }
}

private final class ScrollWheelCatcher: NSView {
  var onScroll: ((CGFloat) -> Void)?

  override func scrollWheel(with event: NSEvent) {
    onScroll?(event.scrollingDeltaY)
  }
}

private struct AttachmentStripView: View {
  let attachments: [TimelineAttachment]
  let onSelect: ([TimelineAttachment], Int) -> Void

  var body: some View {
    HStack(spacing: 8) {
      ForEach(Array(attachments.enumerated()), id: \.element.id) { index, attachment in
        Button {
          onSelect(attachments, index)
        } label: {
          HStack(spacing: 4) {
            Image(systemName: "photo")
              .font(.caption)
            Text(attachment.label ?? "Image \(index + 1)")
              .font(.caption2)
          }
          .padding(.vertical, 2)
          .padding(.horizontal, 6)
          .background(
            RoundedRectangle(cornerRadius: 6)
              .fill(Color.secondary.opacity(0.1))
          )
        }
        .buttonStyle(.plain)
        .help(attachment.label ?? "Open image")
        .hoverHand()
      }
    }
  }
}

private struct CollapsibleText: View {
  let text: String
  let lineLimit: Int
  @State private var isExpanded = false

  var body: some View {
    let previewInfo = linePreview(text, limit: lineLimit)
    let preview = previewInfo.text
    let truncated = previewInfo.truncated
    VStack(alignment: .leading, spacing: 6) {
      Text(isExpanded ? text : preview)
        .textSelection(.enabled)
        .font(.body)
        .frame(maxWidth: .infinity, alignment: .leading)

      if truncated {
        Button(action: { isExpanded.toggle() }) {
          Image(systemName: "ellipsis")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(4)  // Add padding to increase tap area
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())  // Make entire button area tappable
        .hoverHand()
      }
    }
  }

  private func linePreview(_ text: String, limit: Int) -> (text: String, truncated: Bool) {
    // limit = 0 means no truncation, show all
    guard limit > 0 else { return (text, false) }
    var newlineCount = 0
    for index in text.indices {
      if text[index] == "\n" {
        newlineCount += 1
        if newlineCount == limit {
          return (String(text[..<index]), true)
        }
      }
    }
    return (text, false)
  }
}

private struct MetadataView: View {
  let metadata: [String: String]
  private let keyColumnWidth: CGFloat = 240

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(metadata.keys.sorted(), id: \.self) { key in
        if let value = metadata[key], !value.isEmpty {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key)
              .font(.caption2)
              .foregroundStyle(.tertiary)
              .lineLimit(1)
              .truncationMode(.tail)
              .frame(width: keyColumnWidth, alignment: .trailing)
            Text(value)
              .font(.caption2.monospaced())
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 8)
          }
        }
      }
    }
    .padding(.top, 4)
  }
}

#Preview {
  ConversationTimelinePreview()
}

private struct ConversationTimelinePreview: View {
  @State private var expanded: Set<String> = []

  private var sampleTurn: ConversationTurn {
    let now = Date()
    let userEvent = TimelineEvent(
      id: UUID().uuidString,
      timestamp: now,
      actor: .user,
      title: nil,
      text: "Please outline a multi-tenant design for the MCP Mate project.",
      metadata: nil,
      repeatCount: 1,
      attachments: [],
      visibilityKind: .user
    )
    let infoEvent = TimelineEvent(
      id: UUID().uuidString,
      timestamp: now.addingTimeInterval(6),
      actor: .info,
      title: "Context Updated",
      text: "model: gpt-5.2-codex\npolicy: on-request",
      metadata: nil,
      repeatCount: 3,
      attachments: [],
      visibilityKind: .turnContext
    )
    let assistantEvent = TimelineEvent(
      id: UUID().uuidString,
      timestamp: now.addingTimeInterval(12),
      actor: .assistant,
      title: nil,
      text: "Certainly. Here are the key considerations for a multi-tenant design...",
      metadata: nil,
      repeatCount: 1,
      attachments: [],
      visibilityKind: .assistant
    )
    return ConversationTurn(
      id: UUID().uuidString,
      timestamp: now,
      userMessage: userEvent,
      outputs: [infoEvent, assistantEvent]
    )
  }

  var body: some View {
    ConversationTimelineView(
      turns: [sampleTurn],
      expandedTurnIDs: $expanded,
      refreshToken: 0,
      branding: SessionSource.codexLocal.branding,
      isActive: true
    )
    .padding()
    .frame(width: 540)
  }
}

// Provide a handy pointer extension to keep cursor behavior consistent on clickable areas
extension View {
  func hoverHand() -> some View {
    self.onHover { inside in
      if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
    }
  }
}

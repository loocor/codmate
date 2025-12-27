import SwiftUI

#if canImport(SwiftTerm)

struct ActiveTerminalSessionsControl: View {
  let viewModel: SessionListViewModel
  let runningSessionIDs: Set<SessionSummary.ID>
  @State private var showPopover = false
  @State private var activeSessions: [TerminalSessionManager.ActiveSessionInfo] = []
  @State private var isHovering = false

  init(viewModel: SessionListViewModel, runningSessionIDs: Set<SessionSummary.ID>) {
    self.viewModel = viewModel
    self.runningSessionIDs = runningSessionIDs
  }

  var body: some View {
    let count = activeSessions.count

    Button {
      refreshSessions()
      showPopover.toggle()
    } label: {
      ZStack {
        Image(systemName: "chevron.forward.2")
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(iconColor)
          .offset(x: 1)

        if count > 0 {
          Text("\(count)")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(minWidth: 14, minHeight: 14)
            .background(
              Circle()
                .fill(count > 0 ? Color.accentColor : Color.secondary)
            )
            .offset(x: 8, y: -8)
        }
      }
      .frame(width: 14, height: 14)
      .padding(8)
      .background(
        Circle()
          .fill(backgroundColor)
      )
      .overlay(
        Circle()
          .stroke(borderColor, lineWidth: 1)
      )
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .help(count == 0 ? "No active terminal sessions" : "\(count) active terminal session\(count == 1 ? "" : "s")")
    .onHover { hovering in
      withAnimation(.easeInOut(duration: 0.15)) {
        isHovering = hovering
      }
    }
    .popover(isPresented: $showPopover, arrowEdge: .top) {
      ActiveTerminalSessionsPopover(
        sessions: activeSessions,
        viewModel: viewModel,
        isPresented: $showPopover
      )
    }
    .onAppear {
      refreshSessions()
    }
    .onReceive(NotificationCenter.default.publisher(for: .codMateTerminalSessionsUpdated)) { _ in
      refreshSessions()
    }
    .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
      refreshSessions()
    }
    .onChange(of: runningSessionIDs) { _ in
      refreshSessions()
    }
  }

  private var iconColor: Color {
    return isHovering ? Color.primary : Color.primary.opacity(0.55)
  }

  private var backgroundColor: Color {
    return (isHovering ? Color.primary.opacity(0.12) : Color(nsColor: .separatorColor).opacity(0.18))
  }

  private var borderColor: Color {
    return Color(nsColor: .separatorColor).opacity(isHovering ? 0.65 : 0.45)
  }

  private func refreshSessions() {
    let manager = TerminalSessionManager.shared
    let resolved = manager.getActiveSessions().filter { info in
      manager.hasRunningProcess(key: info.terminalKey)
    }
    activeSessions = resolved
  }

}

private struct ActiveTerminalSessionsPopover: View {
  let sessions: [TerminalSessionManager.ActiveSessionInfo]
  let viewModel: SessionListViewModel
  @Binding var isPresented: Bool
  @Environment(\.colorScheme) private var colorScheme

  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("HH:mm:ss")
    return formatter
  }()

  private var listHeight: CGFloat {
    let rowHeight: CGFloat = 42
    let dividerHeight: CGFloat = 1
    let count = CGFloat(sessions.count)
    let dividers = max(count - 1, 0)
    return count * rowHeight + dividers * dividerHeight + 6
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Sessions list
      if sessions.isEmpty {
        VStack(spacing: 12) {
          Image(systemName: "terminal")
            .font(.system(size: 32, weight: .light))
            .foregroundStyle(.tertiary)

          Text("No active terminal sessions")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
      } else {
        ScrollView {
          VStack(spacing: 0) {
            ForEach(Array(sessions.enumerated()), id: \.element.terminalKey) { index, session in
              SessionRowView(
                session: session,
                viewModel: viewModel,
                colorScheme: colorScheme,
                onSelect: { handleSessionSelect(session) }
              )
              if index < sessions.count - 1 {
                Divider()
                  .padding(.leading, 28)
              }
            }
          }
        }
        .frame(height: listHeight)
        .padding(.top, 6)
      }
    }
    .frame(width: 320)
    .padding(16)
  }
  private func handleSessionSelect(_ session: TerminalSessionManager.ActiveSessionInfo) {
    if let summary = viewModel.sessionSummary(for: session.terminalKey) {
      focusSession(summary)
    } else {
      NotificationCenter.default.post(
        name: .codMateResumeSession,
        object: nil,
        userInfo: ["sessionId": session.terminalKey]
      )
    }
    isPresented = false
  }

  private func focusSession(_ summary: SessionSummary) {
    NotificationCenter.default.post(
      name: .codMateFocusSessionSummary,
      object: nil,
      userInfo: ["summary": summary]
    )
  }

  private struct SessionRowView: View {
    let session: TerminalSessionManager.ActiveSessionInfo
    let viewModel: SessionListViewModel
    let colorScheme: ColorScheme
    let onSelect: () -> Void
    @State private var isHovering = false

    private var sessionSummary: SessionSummary? {
      viewModel.sessionSummary(for: session.terminalKey)
    }

    var body: some View {
      Button(action: onSelect) {
        HStack(spacing: 10) {
          iconView
          VStack(alignment: .leading, spacing: 2) {
            Text(displayName)
              .font(.subheadline.weight(.medium))
              .foregroundStyle(.primary)
              .lineLimit(1)
            Text("Started \(startTimeText)")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .opacity(isHovering ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(
          RoundedRectangle(cornerRadius: 6)
            .fill(isHovering ? Color.primary.opacity(0.06) : Color.clear)
        )
      }
      .buttonStyle(.plain)
      .focusable(false)
      .onHover { hovering in
        withAnimation(.easeInOut(duration: 0.1)) {
          isHovering = hovering
        }
      }
    }

    private var iconView: some View {
      Group {
        if let summary = sessionSummary {
          let branding = summary.source.branding
          if let asset = branding.badgeAssetName {
            let shouldInvertCodexDark = summary.source.baseKind == .codex && colorScheme == .dark
            Image(asset)
              .resizable()
              .renderingMode(.original)
              .aspectRatio(contentMode: .fit)
              .frame(width: 18, height: 18)
              .modifier(DarkModeInvertModifier(active: shouldInvertCodexDark))
          } else {
            Image(systemName: branding.symbolName)
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(branding.iconColor)
              .frame(width: 18, height: 18)
          }
        } else {
          Image(systemName: session.isConsoleMode ? "cube.fill" : "terminal.fill")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(session.isConsoleMode ? Color.accentColor : Color.secondary)
            .frame(width: 18, height: 18)
        }
      }
    }

    private var displayName: String {
      if let summary = sessionSummary {
        return summary.effectiveTitle
      }
      return session.terminalKey
    }

    private var startTimeText: String {
      ActiveTerminalSessionsPopover.timeFormatter.string(from: session.startedAt)
    }

    static func displayName(
      for session: TerminalSessionManager.ActiveSessionInfo,
      viewModel: SessionListViewModel
    ) -> String {
      if let summary = viewModel.sessionSummary(for: session.terminalKey) {
        return summary.effectiveTitle
      }
      return session.terminalKey
    }
  }
}

#else

struct ActiveTerminalSessionsControl: View {
  let viewModel: SessionListViewModel

  var body: some View {
    EmptyView()
  }
}

#endif

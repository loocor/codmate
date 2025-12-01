import SwiftUI
import AppKit

struct RecentSessionsListView: View {
  typealias ProjectInfo = (id: String, name: String)

  var title: String = "Recent Sessions"
  var sessions: [SessionSummary]
  var emptyMessage: String
  var projectInfoProvider: ((SessionSummary) -> ProjectInfo?)? = nil
  var projectColumnWidth: CGFloat = 100
  var onSelectSession: (SessionSummary) -> Void
  var onSelectProject: ((String) -> Void)? = nil

  @Environment(\.colorScheme) private var colorScheme

  private var hasProjectColumn: Bool { projectInfoProvider != nil }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.headline)
      if sessions.isEmpty {
        OverviewCard {
          Text(emptyMessage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      } else {
        OverviewCard {
          VStack(spacing: 2) {
            ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
              sessionRow(session: session)
                .padding(.vertical, 8)
                .padding(.leading, hasProjectColumn ? 0 : 4)
                .padding(.trailing, 8)
                .contentShape(Rectangle())
                .onTapGesture { onSelectSession(session) }
                .onHover { hovering in
                  if hovering {
                    NSCursor.pointingHand.set()
                  } else {
                    NSCursor.arrow.set()
                  }
                }

              if index < sessions.count - 1 {
                Divider()
                  .padding(.leading, dividerLeadingPadding)
                  .padding(.trailing, 4)
              }
            }
          }
        }
      }
    }
  }

  private var dividerLeadingPadding: CGFloat {
    hasProjectColumn ? projectColumnWidth + 36 : 36
  }

  private func sessionRow(session: SessionSummary) -> some View {
    HStack(alignment: .center, spacing: 12) {
      if let projectInfoProvider,
        let info = projectInfoProvider(session)
      {
        projectLabel(for: info)
          .frame(width: projectColumnWidth, alignment: .leading)
      } else if hasProjectColumn {
        Rectangle()
          .fill(Color.clear)
          .frame(width: projectColumnWidth, alignment: .leading)
      }

      let branding = session.source.branding
      if let asset = branding.badgeAssetName {
        Image(asset)
          .resizable()
          .renderingMode(.original)
          .aspectRatio(contentMode: .fit)
          .frame(width: 16, height: 16)
          .modifier(
            DarkModeInvertModifier(
              active: session.source.baseKind == .codex && colorScheme == .dark
            )
          )
      } else {
        Image(systemName: branding.symbolName)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(branding.iconColor)
          .frame(width: 16)
      }

      VStack(alignment: .leading, spacing: 4) {
        Text(session.effectiveTitle)
          .font(.subheadline)
          .fontWeight(.medium)
          .lineLimit(1)
          .truncationMode(.tail)

        HStack(spacing: 6) {
          let date = session.lastUpdatedAt ?? session.startedAt
          Text(date, style: .relative)
            .font(.caption)
            .foregroundStyle(.secondary)

          Text("·")
            .font(.caption)
            .foregroundStyle(.tertiary)

          Text(session.commentSnippet)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
      }

      Spacer()
      Image(systemName: "chevron.right")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
  }

  @ViewBuilder
  private func projectLabel(for info: ProjectInfo) -> some View {
    if let onSelectProject {
      Text(info.name)
        .font(.subheadline)
        .fontWeight(.semibold)
        .lineLimit(1)
        .truncationMode(.tail)
        .contentShape(Rectangle())
        .onTapGesture { onSelectProject(info.id) }
    } else {
      Text(info.name)
        .font(.subheadline)
        .fontWeight(.semibold)
        .lineLimit(1)
        .truncationMode(.tail)
    }
  }
}

import SwiftUI

struct ProjectOverviewView: View {
  @ObservedObject var viewModel: ProjectOverviewViewModel
  var onSelectSession: (SessionSummary) -> Void
  var onResumeSession: (SessionSummary) -> Void // Keeping this for consistency, though not used in ProjectOverviewViewModel directly
  var onFocusToday: () -> Void // Keeping this for consistency, though not used in ProjectOverviewViewModel directly

  private func columns(for width: CGFloat) -> [GridItem] {
    let minWidth: CGFloat = 220
    let spacing: CGFloat = 16
    let availableWidth = width - 48  // 24 horizontal padding * 2
    let count = max(1, Int((availableWidth + spacing) / (minWidth + spacing)))
    // Cap at 4 columns to match the max number of items per section (4)
    var targetCount = min(4, count)
    
    // Optimization: Avoid 3 columns for 4-item grids to prevent "3 on top, 1 on bottom" layout.
    // Since we mostly have sets of 4 items (Hero, Projects), a 2x2 grid looks better than 3+1.
    if targetCount == 3 {
      targetCount = 2
    }
    
    return Array(repeating: GridItem(.flexible(), spacing: spacing), count: targetCount)
  }

  var body: some View {
    GeometryReader { geometry in
      let cols = columns(for: geometry.size.width)
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          headerSection
          heroSection(columns: cols)
          efficiencySection(columns: cols)
          recentSection
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, alignment: .center)
      }
    }
  }

  private var snapshot: ProjectOverviewSnapshot { viewModel.snapshot }

  private var headerSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Project Overview") // Changed from Workspace Overview
        .font(.largeTitle.weight(.semibold))
      Text("Updated \(snapshot.lastUpdated.formatted(date: .abbreviated, time: .shortened))")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func heroSection(columns: [GridItem]) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      LazyVGrid(columns: columns, spacing: 16) {
        heroMetric(
          title: "Sessions",
          value: snapshot.totalSessions.formatted(),
          detail: "In selected range"
        )
        heroMetric(
          title: "Messages",
          value: (snapshot.userMessages + snapshot.assistantMessages).formatted(),
          detail: "\(snapshot.userMessages) user · \(snapshot.assistantMessages) assistant"
        )
        heroMetric(
          title: "Active Time",
          value: Self.durationFormatter.string(from: snapshot.totalDuration) ?? "—",
          detail: "Tokens \(snapshot.totalTokens.formatted())"
        )
        heroMetric(
            title: "Tool Invocations",
            value: snapshot.totalToolInvocations.formatted(),
            detail: "Tools used"
        )
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func heroMetric(title: String, value: String, detail: String) -> some View {
    OverviewCard {
      VStack(alignment: .leading, spacing: 6) {
        Text(title).font(.subheadline).foregroundStyle(.secondary)
        Text(value).font(.title2.monospacedDigit()).fontWeight(.semibold)
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private func efficiencySection(columns: [GridItem]) -> some View {
    if !snapshot.sourceStats.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        Text("Efficiency & Cost")
          .font(.headline)
        LazyVGrid(columns: columns, spacing: 16) {
          ForEach(snapshot.sourceStats) { stat in
            OverviewCard {
              VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                  Text(stat.displayName).font(.headline)
                  Spacer()
                  Text("\(stat.sessionCount) sessions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Label {
                        Text("Total \(stat.totalTokens.formatted()) tokens")
                    } icon: {
                        Image(systemName: "text.quote")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    
                    Label {
                        Text("Avg \(Self.durationFormatter.string(from: stat.avgDuration) ?? "—")")
                    } icon: {
                        Image(systemName: "clock")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
              }
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  @ViewBuilder
  private var recentSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Recent Sessions in Project") // Changed from Recent Sessions
        .font(.headline)
      if snapshot.recentSessions.isEmpty {
        OverviewCard {
          Text("No sessions in this project for the selected range.") // Changed message
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      } else {
        VStack(spacing: 12) {
          ForEach(snapshot.recentSessions, id: \.id) { session in
            let projectInfo = viewModel.resolveProject(for: session)
            OverviewCard {
              // Removed onProjectClick as we are already in the project view
              sessionRow(
                session: session,
                project: projectInfo,
                onProjectClick: nil, // Project already selected
                actionTitle: "Open"
              ) {
                onSelectSession(session)
              }
            }
          }
        }
      }
    }
  }

  private func sessionRow(
    session: SessionSummary,
    project: (id: String, name: String)?,
    onProjectClick: ((String) -> Void)?,
    actionTitle: String,
    action: @escaping () -> Void
  ) -> some View {
    HStack(alignment: .center, spacing: 12) {
      // In Project Overview, we don't need project name column to jump to itself.
      // We can just show project name as text or remove it. Let's remove the column.
      // The overall context is this project.

      // Leading: Title and Date
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 8) {
          Text(session.effectiveTitle)
            .font(.subheadline)
            .fontWeight(.medium)
            .lineLimit(1)
            .truncationMode(.tail)
          
          Text(session.displayModel ?? session.source.branding.displayName)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(4)
            .foregroundStyle(.secondary)
        }
        
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
      
      Button(actionTitle, action: action)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .font(.caption)
    }
    .padding(.vertical, 4)
  }

  private struct OverviewCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
      self.content = content()
    }

    var body: some View {
      content
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }
  }

  private static let durationFormatter: DateComponentsFormatter = {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = [.hour, .minute]
    formatter.unitsStyle = .abbreviated
    formatter.zeroFormattingBehavior = .dropLeading
    return formatter
  }()
}

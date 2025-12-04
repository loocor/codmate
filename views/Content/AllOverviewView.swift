import SwiftUI

struct AllOverviewView: View {
  @ObservedObject var viewModel: AllOverviewViewModel
  var onSelectSession: (SessionSummary) -> Void
  var onResumeSession: (SessionSummary) -> Void
  var onFocusToday: () -> Void
  var onSelectProject: (String) -> Void

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
          if viewModel.isLoading && snapshot.totalSessions == 0 {
            OverviewLoadingPlaceholder()
          } else {
            if !snapshot.activityChartData.points.isEmpty {
               OverviewActivityChart(data: snapshot.activityChartData)
            }
            heroSection(columns: cols)
            efficiencySection(columns: cols)
            recentSection
          }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, alignment: .center)
      }
    }
  }

  private var snapshot: AllOverviewSnapshot { viewModel.snapshot }

  private var headerSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Workspace Overview")
        .font(.largeTitle.weight(.semibold))
      Text("Updated \(snapshot.lastUpdated.formatted(date: .abbreviated, time: .shortened))")
        .font(.caption)
        .foregroundStyle(.secondary)
      if let coverageText = coverageLine {
        Text(coverageText)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var coverageLine: String? {
    guard let coverage = viewModel.cacheCoverage else { return nil }
    let sources = coverage.sources.isEmpty
      ? "Cache building…"
      : coverage.sources.map { $0.displayName }.joined(separator: ", ")
    let datePart: String
    if let dt = coverage.lastFullIndexAt {
      datePart = "indexed \(dt.formatted(date: .abbreviated, time: .shortened))"
    } else {
      datePart = "indexed n/a"
    }
    return "Cache: \(coverage.sessionCount) entries • \(sources) • \(datePart)"
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
          detail: "Tokens \(TokenFormatter.short(snapshot.totalTokens))"
        )
        heroMetric(
          title: "Projects",
          value: snapshot.projectCount.formatted(),
          detail: "Tracked projects"
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
                    Text("Total \(TokenFormatter.short(stat.totalTokens)) tokens")
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
    RecentSessionsListView(
      sessions: snapshot.recentSessions,
      emptyMessage: "Start a new Codex or Claude session to populate your history.",
      projectInfoProvider: { session in viewModel.resolveProject(for: session) },
      projectColumnWidth: 120,
      onSelectSession: onSelectSession,
      onSelectProject: onSelectProject
    )
  }

  private static let durationFormatter: DateComponentsFormatter = {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = [.hour, .minute]
    formatter.unitsStyle = .abbreviated
    formatter.zeroFormattingBehavior = .dropLeading
    return formatter
  }()
}

private struct OverviewLoadingPlaceholder: View {
  var body: some View {
    VStack(alignment: .center, spacing: 24) {
      // Loading indicator with message
      VStack(spacing: 12) {
        ProgressView()
          .scaleEffect(1.2)
          .progressViewStyle(.circular)

        VStack(spacing: 4) {
          Text("Building Session Index")
            .font(.headline)
            .foregroundStyle(.primary)
          Text("Scanning and caching session files for fast access…")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
      }
      .padding(.top, 40)

      // Skeleton preview
      VStack(alignment: .leading, spacing: 16) {
        RoundedRectangle(cornerRadius: 12)
          .fill(Color.secondary.opacity(0.1))
          .frame(height: 160)
          .overlay(
            VStack(alignment: .leading, spacing: 8) {
              HStack {
                RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.2)).frame(width: 80, height: 10)
                Spacer()
              }
              RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.2)).frame(width: 140, height: 10)
              RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)).frame(height: 80)
            }
            .padding()
          )
        HStack(spacing: 12) {
          ForEach(0..<4) { _ in
            RoundedRectangle(cornerRadius: 12)
              .fill(Color.secondary.opacity(0.08))
              .frame(height: 110)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        RoundedRectangle(cornerRadius: 12)
          .fill(Color.secondary.opacity(0.08))
          .frame(height: 120)
      }
      .redacted(reason: .placeholder)
    }
  }
}

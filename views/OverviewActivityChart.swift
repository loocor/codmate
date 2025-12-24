import SwiftUI
import Charts

struct OverviewActivityChart: View {
    let data: ActivityChartData
    var onSelectDate: ((Date) -> Void)?

    @State private var selectedMetric: Metric = .count
    @State private var hiddenSources: Set<SessionSource.Kind> = []
    @State private var hoverDate: Date?
    @State private var hoverLocation: CGPoint = .zero
    @AppStorage("overviewChartBarWidth") private var barWidth: Double = 32.0
    @State private var isHoveringZoomControls = false
    @State private var isHoveringChartArea = false
    @State private var hoverExitTask: Task<Void, Never>? = nil

    private let minBarWidth: CGFloat = 16.0
    private let maxBarWidth: CGFloat = 64.0

    enum Metric: String, CaseIterable, Identifiable {
        case count = "Sessions"
        case duration = "Duration"
        case tokens = "Tokens"

        var id: String { rawValue }
    }

    // All available sources for the legend
    private let allSources: [SessionSource.Kind] = [.codex, .claude, .gemini]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerView

            if data.points.isEmpty {
                emptyStateView
            } else {
                chartContainer
            }
        }
    }

    // MARK: - Header
    private var headerView: some View {
        HStack {
            // Left: Metric Picker + Zoom
            HStack(spacing: 8) {
                Picker("Metric", selection: $selectedMetric) {
                    ForEach(Metric.allCases) { metric in
                        Text(metric.rawValue).tag(metric)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)

                // Zoom Controls
                HStack(spacing: 0) {
                    Button {
                        withAnimation(.spring(response: 0.3)) {
                            barWidth = max(Double(minBarWidth), barWidth - 8)
                        }
                    } label: {
                        Image(systemName: "minus")
                            .frame(width: 16, height: 16)
                    }
                    .disabled(barWidth <= Double(minBarWidth))
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())

                    Button {
                        withAnimation(.spring(response: 0.3)) {
                            barWidth = min(Double(maxBarWidth), barWidth + 8)
                        }
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 16, height: 16)
                    }
                    .disabled(barWidth >= Double(maxBarWidth))
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                }
                .background(Color.primary.opacity(isHoveringZoomControls ? 0.15 : 0.05))
                .cornerRadius(4)
                .opacity(zoomControlsOpacity)
                .onHover { isHovering in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isHoveringZoomControls = isHovering
                    }
                }
            }

            Spacer()

            // Right: Legend
            HStack(spacing: 12) {
                ForEach(allSources, id: \.self) { source in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(color(for: source))
                            .frame(width: 8, height: 8)
                            .opacity(hiddenSources.contains(source) ? 0.3 : 1.0)

                        Text(source.rawValue.capitalized)
                            .font(.caption)
                            .foregroundStyle(hiddenSources.contains(source) ? .secondary : .primary)
                    }
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if hiddenSources.contains(source) {
                                hiddenSources.remove(source)
                            } else {
                                hiddenSources.insert(source)
                            }
                        }
                    }
                    .contentShape(Rectangle()) // Improve tap area
                    .help("Toggle \(source.rawValue.capitalized)")
                }
            }
        }
    }

    // MARK: - Chart
    private var chartContainer: some View {
        GeometryReader { geometry in
            let stepWidth: CGFloat = CGFloat(barWidth)
            let uniqueDates = Set(data.points.map { $0.date }).sorted()
            // uniqueXCount is no longer used for width calculation
            // let uniqueXCount = uniqueDates.count
            // requiredWidth is calculated later based on time span
            let chartAreaWidth = geometry.size.width // Full width now

            // Determine Y-axis domain (Value) - Filtered
            let maxVal = maxYValue(for: uniqueDates)
            let yScale = 0...maxVal

            // Determine X-axis domain (Time) - FULL (Unfiltered)
            // This ensures the axis doesn't shrink if data points are hidden
            // We use the min/max of the actual data available in this view model snapshot
            let minDate = uniqueDates.first ?? Date()
            let maxDate = uniqueDates.last ?? Date()

            // Adjust domain to center bars (add 0.5 unit padding on each side)
            let calendar = Calendar.current
            let (adjMin, adjMax): (Date, Date) = {
                if data.unit == .day {
                    let min = calendar.date(byAdding: .hour, value: -12, to: minDate) ?? minDate
                    let max = calendar.date(byAdding: .hour, value: 12, to: maxDate) ?? maxDate
                    return (min, max)
                } else {
                    let min = calendar.date(byAdding: .minute, value: -30, to: minDate) ?? minDate
                    let max = calendar.date(byAdding: .minute, value: 30, to: maxDate) ?? maxDate
                    return (min, max)
                }
            }()
            let xDomain = adjMin...adjMax

            // Calculate required width based on TIME SPAN, not point count
            let component: Calendar.Component = data.unit == .day ? .day : .hour
            let diff = calendar.dateComponents([component], from: minDate, to: maxDate).value(for: component) ?? 0
            let totalSlots = max(1, diff + 1) // Inclusive count
            let requiredWidth = CGFloat(totalSlots) * stepWidth

            // Scrollable Chart Area
            scrollContainer {
                ZStack {
                    HStack(spacing: 0) {
                        if requiredWidth < chartAreaWidth {
                            Spacer(minLength: 0)
                        }

                        chartContent(yScale: yScale, xDomain: xDomain)
                            .frame(width: requiredWidth, height: 160)
                            .chartOverlay { proxy in
                                GeometryReader { geo in
                                    Rectangle().fill(.clear).contentShape(Rectangle())
                                        .onContinuousHover { phase in
                                            switch phase {
                                            case .active(let location):
                                                hoverExitTask?.cancel()
                                                hoverExitTask = nil
                                                if !isHoveringChartArea {
                                                    withAnimation(.easeInOut(duration: 0.2)) {
                                                        isHoveringChartArea = true
                                                    }
                                                }
                                                hoverLocation = location
                                                // Convert location to X value (Date)
                                                if let date = proxy.value(atX: location.x, as: Date.self) {
                                                    // Snap to closest bin
                                                    hoverDate = snapDate(date, dates: uniqueDates)
                                                }
                                            case .ended:
                                                hoverDate = nil
                                                hoverExitTask?.cancel()
                                                hoverExitTask = Task {
                                                    try? await Task.sleep(nanoseconds: 250_000_000)
                                                    await MainActor.run {
                                                        withAnimation(.easeInOut(duration: 0.2)) {
                                                            isHoveringChartArea = false
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                        .onTapGesture(count: 1, coordinateSpace: .local) { location in
                                            if let date = proxy.value(atX: location.x, as: Date.self),
                                               let snapped = snapDate(date, dates: uniqueDates) {
                                                onSelectDate?(snapped)
                                            }
                                        }
                                }
                            }
                            .overlay {
                                if let hoverDate, let points = pointsByDate[hoverDate] {
                                    tooltip(for: hoverDate, points: points, in: geoSize(from: requiredWidth))
                                }
                            }
                    }
                    .padding(.trailing, CGFloat(barWidth) * 2.0) // Dynamic padding based on bar width
                    .frame(minWidth: chartAreaWidth, alignment: .trailing)
                }
            }
        }
        .frame(height: 160)
    }

    @ViewBuilder
    private var emptyStateView: some View {
        ZStack {
            if #available(macOS 14.0, *) {
                ContentUnavailableView {
                    Label("No Activity", systemImage: "chart.bar")
                } description: {
                    Text("No sessions found in this time range.")
                }
            } else {
                UnavailableStateView(
                    "No Activity",
                    systemImage: "chart.bar",
                    description: "No sessions found in this time range.",
                    titleFont: .callout
                )
            }
        }
        .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 160, alignment: .center)
    }

    @ViewBuilder
    private func scrollContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if #available(macOS 14.0, *) {
            ScrollView(.horizontal, showsIndicators: true) {
                content()
            }
            .defaultScrollAnchor(.trailing)
        } else {
            ScrollView(.horizontal, showsIndicators: true) {
                content()
            }
        }
    }

    private func geoSize(from width: CGFloat) -> CGSize {
        CGSize(width: width, height: 160)
    }

    private func chartContent(yScale: ClosedRange<Double>, xDomain: ClosedRange<Date>) -> some View {
        Chart {
            // Baseline axis line
            RuleMark(y: .value("Baseline", 0))
                .foregroundStyle(Color.secondary.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1))

            ForEach(visiblePoints) { point in
                BarMark(
                    x: .value("Date", point.date, unit: data.unit == .day ? .day : .hour),
                    y: .value("Value", value(for: point)),
                    width: .fixed(barWidth * 0.8) // Use a ratio of the stepWidth for the bar itself
                )
                .foregroundStyle(by: .value("Source", point.source.rawValue.capitalized))
            }
        }
        .chartLegend(.hidden)
        .chartXScale(domain: xDomain) // FIX: Lock X-axis domain
        .chartXAxis {
            AxisMarks(values: .stride(by: data.unit == .day ? .day : .hour)) { value in
                if let date = value.as(Date.self) {
                    // Custom Month Separator logic
                    if data.unit == .day, isFirstDayOfMonth(date) {
                        AxisTick(length: 20, stroke: StrokeStyle(lineWidth: 1.5))
                            .foregroundStyle(.primary)
                        AxisValueLabel(format: .dateTime.month(.abbreviated))
                            .font(.system(size: 10, weight: .bold))
                    } else {
                        AxisGridLine()
                            .foregroundStyle(.clear) // Hide regular grid lines

                        AxisTick()

                        AxisValueLabel(format: data.unit == .day ? .dateTime.day() : .dateTime.hour())
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartYAxis(.hidden) // Hide internal Y axis
        .chartYScale(domain: yScale)
        .chartForegroundStyleScale([
            "Codex": color(for: .codex),
            "Claude": color(for: .claude),
            "Gemini": color(for: .gemini)
        ])
    }

    // MARK: - Tooltip
    @ViewBuilder
    private func tooltip(for date: Date, points: [ActivityChartDataPoint], in containerSize: CGSize) -> some View {
        // Filter points based on hidden sources
        let visible = points.filter { !hiddenSources.contains($0.source) }
        if !visible.isEmpty {
            let total = visible.reduce(0) { $0 + value(for: $1) }
            let dateString = data.unit == .day
                ? date.formatted(date: .abbreviated, time: .omitted)
                : date.formatted(date: .omitted, time: .shortened)

            let tooltipWidth: CGFloat = 140
            // Estimate height based on items + padding
            let tooltipHeight: CGFloat = CGFloat(40 + (visible.count * 15) + 20)

            // Determine Y Position
            let initialY = hoverLocation.y - (tooltipHeight / 2) - 20
            let finalY = (initialY - (tooltipHeight / 2) < 0)
                ? hoverLocation.y + (tooltipHeight / 2) + 20
                : initialY

            // Determine X Position (Clamp to edges)
            let halfWidth = tooltipWidth / 2
            let rawX = hoverLocation.x
            let finalX = max(halfWidth, min(rawX, containerSize.width - halfWidth))

            VStack(alignment: .leading, spacing: 6) {
                Text(dateString)
                    .font(.caption).bold()
                    .padding(.bottom, 2)

                ForEach(visible.sorted { value(for: $0) > value(for: $1) }) { point in
                    HStack {
                        Circle().fill(color(for: point.source)).frame(width: 6, height: 6)
                        Text(point.source.rawValue.capitalized).font(.caption2)
                        Spacer()
                        Text(formatValue(value(for: point)))
                            .font(.caption2.monospacedDigit())
                    }
                }

                Divider()

                HStack {
                    Text("Total").font(.caption2).bold()
                    Spacer()
                    Text(formatValue(total))
                        .font(.caption2.monospacedDigit()).bold()
                }
            }
            .padding(8)
            .background(.regularMaterial)
            .cornerRadius(8)
            .shadow(radius: 4)
            .frame(width: tooltipWidth)
            .position(x: finalX, y: finalY)
            .allowsHitTesting(false)
        }
    }

    // MARK: - Helpers

    private var visiblePoints: [ActivityChartDataPoint] {
        data.points.filter { !hiddenSources.contains($0.source) }
    }

    private var pointsByDate: [Date: [ActivityChartDataPoint]] {
        Dictionary(grouping: data.points, by: { $0.date })
    }

    private func maxYValue(for dates: [Date]) -> Double {
        var maxVal: Double = 0
        let grouped = pointsByDate
        for date in dates {
            let points = grouped[date] ?? []
            let filtered = points.filter { !hiddenSources.contains($0.source) }
            let sum = filtered.reduce(0) { $0 + value(for: $1) }
            if sum > maxVal { maxVal = sum }
        }
        // Add some headroom
        return maxVal == 0 ? 10 : maxVal * 1.1
    }

    private func value(for point: ActivityChartDataPoint) -> Double {
        switch selectedMetric {
        case .count:
            return Double(point.sessionCount)
        case .duration:
            return point.duration / 3600 // Hours
        case .tokens:
            return Double(point.totalTokens)
        }
    }

    private func formatValue(_ val: Double) -> String {
        switch selectedMetric {
        case .count:
            return String(Int(val))
        case .duration:
            return String(format: "%.1fh", val)
        case .tokens:
            return "\(TokenFormatter.short(Int(val.rounded())))"
        }
    }

    private func color(for source: SessionSource.Kind) -> Color {
        switch source {
        case .codex: return .purple
        case .claude: return .orange
        case .gemini: return .blue
        }
    }

    private func isFirstDayOfMonth(_ date: Date) -> Bool {
        let calendar = Calendar.current
        let day = calendar.component(.day, from: date)
        return day == 1
    }

    private func snapDate(_ target: Date, dates: [Date]) -> Date? {
        // Find closest date in the dataset
        // Since bars are discrete, finding the date with min distance is enough
        guard !dates.isEmpty else { return nil }
        // Optimization: since sorted, binary search or linear scan if small
        return dates.min(by: { abs($0.timeIntervalSince(target)) < abs($1.timeIntervalSince(target)) })
    }

    private var zoomControlsOpacity: Double {
        guard isHoveringChartArea || isHoveringZoomControls else { return 0 }
        return isHoveringZoomControls ? 1.0 : 0.85
    }
}
